// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KaliMagaLendingPool} from "./KaliMagaLendingPool.sol";
import {KaliMagaPriceOracle} from "./KaliMagaPriceOracle.sol";
import {KaliMagaRouter} from "../core/KaliMagaRouter.sol";

/// @title KaliMagaLiquidator
/// @author Bhari Gowda
/// @notice Liquidates undercollateralized lending positions by repaying debt and seizing
/// collateral, settling everything atomically through the built-in KaliMaga DEX router.
/// @dev Liquidation flow:
///   1. Caller identifies a borrower whose health factor has dropped below 1.0
///   2. Caller calls liquidate(), approving this contract to pull the debt asset
///   3. This contract repays up to 50% of the borrower's debt (close factor)
///   4. This contract seizes the equivalent collateral value plus a 5% liquidation bonus
///   5. Seized collateral is swapped through KaliMagaRouter back to the debt asset
///   6. Caller receives the swap output, which exceeds their repayment due to the bonus
contract KaliMagaLiquidator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant SCALE = 1e18;
    uint256 private constant BPS = 10_000;
    /// @dev 5% bonus on seized collateral, paid to the liquidator as incentive
    uint256 private constant LIQUIDATION_BONUS_BPS = 500;
    uint256 private constant HEALTH_FACTOR_THRESHOLD = 1e18;
    /// @dev Liquidator can repay at most 50% of a borrower's debt in a single call
    uint256 private constant CLOSE_FACTOR_BPS = 5000;

    /// @notice The lending pool this liquidator operates on
    KaliMagaLendingPool public immutable lendingPool;
    /// @notice Price oracle used to value debt and collateral assets
    KaliMagaPriceOracle public immutable priceOracle;
    /// @notice DEX router used to swap seized collateral back to the debt asset
    KaliMagaRouter public immutable router;

    /// @notice Emitted on every successful liquidation
    /// @param liquidator Address that triggered the liquidation and receives the profit
    /// @param borrower Address whose position was liquidated
    /// @param debtAsset Asset that was repaid
    /// @param collateralAsset Asset that was seized
    /// @param debtRepaid Amount of debtAsset repaid
    /// @param collateralSeized Amount of collateralAsset seized (including bonus)
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address debtAsset,
        address collateralAsset,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    error HealthFactorAboveThreshold();
    error RepayAmountExceedsCloseFactor();
    error ZeroAmount();

    /// @param _lendingPool Address of the KaliMagaLendingPool to liquidate against
    /// @param _priceOracle Address of the KaliMagaPriceOracle for asset valuation
    /// @param _router Address of the KaliMagaRouter for collateral swaps
    constructor(address _lendingPool, address _priceOracle, address _router) {
        lendingPool = KaliMagaLendingPool(_lendingPool);
        priceOracle = KaliMagaPriceOracle(_priceOracle);
        router = KaliMagaRouter(_router);
    }

    /// @notice Liquidate an undercollateralized borrower position.
    /// @dev Caller must approve this contract to pull `repayAmount` of `debtAsset` before calling.
    /// The caller receives the swap output of the seized collateral, which exceeds `repayAmount`
    /// by the 5% liquidation bonus (minus DEX fees).
    /// @param borrower The account to liquidate
    /// @param debtAsset The asset the borrower owes; caller repays this
    /// @param collateralAsset The collateral asset to seize from the borrower
    /// @param repayAmount Amount of debtAsset to repay; must not exceed 50% of total debt
    /// @param minOutputAmount Minimum debtAsset received after swapping seized collateral (slippage guard)
    function liquidate(
        address borrower,
        address debtAsset,
        address collateralAsset,
        uint256 repayAmount,
        uint256 minOutputAmount
    ) external nonReentrant {
        if (repayAmount == 0) revert ZeroAmount();

        // 1. confirm position is liquidatable
        uint256 hf = lendingPool.healthFactor(borrower);
        if (hf >= HEALTH_FACTOR_THRESHOLD) revert HealthFactorAboveThreshold();

        // 2. enforce close factor — at most 50% of debt per liquidation call
        uint256 totalDebt = lendingPool.currentBorrowBalance(borrower, debtAsset);
        uint256 maxRepay = (totalDebt * CLOSE_FACTOR_BPS) / BPS;
        if (repayAmount > maxRepay) revert RepayAmountExceedsCloseFactor();

        // 3. calculate collateral to seize: repay value + 5% liquidation bonus, in collateral terms
        uint256 debtPrice = priceOracle.getPrice(debtAsset);
        uint256 collateralPrice = priceOracle.getPrice(collateralAsset);
        uint256 repayValueUsd = (repayAmount * debtPrice) / SCALE;
        uint256 collateralToSeize =
            (repayValueUsd * SCALE * (BPS + LIQUIDATION_BONUS_BPS)) / (collateralPrice * BPS);

        // 4. pull debt asset from caller and repay to lending pool on behalf of borrower
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), repayAmount);
        IERC20(debtAsset).forceApprove(address(lendingPool), repayAmount);
        lendingPool.liquidationRepay(borrower, debtAsset, repayAmount);

        // 5. seize borrower's collateral shares and transfer underlying to this contract
        uint256 exchangeRate = lendingPool.exchangeRate(collateralAsset);
        uint256 sharesToSeize = (collateralToSeize * SCALE) / exchangeRate;
        lendingPool.seizeCollateral(borrower, collateralAsset, sharesToSeize, address(this));

        // 6. swap seized collateral → debt asset, sending output directly to the caller
        uint256 collateralReceived = IERC20(collateralAsset).balanceOf(address(this));
        IERC20(collateralAsset).forceApprove(address(router), collateralReceived);
        address[] memory path = new address[](2);
        path[0] = collateralAsset;
        path[1] = debtAsset;
        router.swapExactTokensForTokens(
            collateralReceived, minOutputAmount, path, msg.sender, block.timestamp
        );

        emit Liquidated(msg.sender, borrower, debtAsset, collateralAsset, repayAmount, collateralToSeize);
    }
}
