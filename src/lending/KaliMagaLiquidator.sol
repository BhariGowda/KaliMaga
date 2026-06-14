// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KaliMagaLendingPool} from "./KaliMagaLendingPool.sol";
import {KaliMagaPriceOracle} from "./KaliMagaPriceOracle.sol";
import {KaliMagaRouter} from "../core/KaliMagaRouter.sol";

/// @title KaliMagaLiquidator
/// @notice Seizes collateral from undercollateralized positions and settles the debt
/// through the built-in KaliMaga DEX router. The liquidation bonus goes to the caller.
///
/// Flow:
/// 1. Caller identifies a borrower whose health factor has dropped below 1.0
/// 2. Caller calls liquidate(), supplying the debt asset to repay
/// 3. This contract repays the debt to the lending pool
/// 4. This contract seizes collateral from the borrower (at a 5% bonus)
/// 5. The seized collateral is swapped through KaliMagaRouter back to the debt asset
/// 6. Caller receives the swap output (which exceeds their repayment due to the bonus)
contract KaliMagaLiquidator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant SCALE = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant LIQUIDATION_BONUS_BPS = 500; // 5% bonus on seized collateral
    uint256 private constant HEALTH_FACTOR_THRESHOLD = 1e18;
    uint256 private constant CLOSE_FACTOR_BPS = 5000; // liquidator can repay up to 50% of debt

    KaliMagaLendingPool public immutable lendingPool;
    KaliMagaPriceOracle public immutable priceOracle;
    KaliMagaRouter public immutable router;

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

    constructor(address _lendingPool, address _priceOracle, address _router) {
        lendingPool = KaliMagaLendingPool(_lendingPool);
        priceOracle = KaliMagaPriceOracle(_priceOracle);
        router = KaliMagaRouter(_router);
    }

    /// @notice Liquidate an undercollateralized position.
    /// @param borrower The account to liquidate
    /// @param debtAsset The asset the borrower owes (caller repays this)
    /// @param collateralAsset The asset to seize from the borrower
    /// @param repayAmount The amount of debtAsset to repay (capped at 50% of total debt)
    /// @param minOutputAmount Minimum debt asset received after swap (slippage protection)
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

        // 2. enforce close factor — can't wipe more than 50% of debt in one tx
        uint256 totalDebt = lendingPool.currentBorrowBalance(borrower, debtAsset);
        uint256 maxRepay = (totalDebt * CLOSE_FACTOR_BPS) / BPS;
        if (repayAmount > maxRepay) revert RepayAmountExceedsCloseFactor();

        // 3. calculate how much collateral to seize (repay value + 5% bonus, in collateral terms)
        uint256 debtPrice = priceOracle.getPrice(debtAsset);
        uint256 collateralPrice = priceOracle.getPrice(collateralAsset);
        uint256 repayValueUsd = (repayAmount * debtPrice) / SCALE;
        uint256 collateralToSeize =
            (repayValueUsd * SCALE * (BPS + LIQUIDATION_BONUS_BPS)) / (collateralPrice * BPS);

        // 4. pull debt asset from liquidator and repay to lending pool
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), repayAmount);
        IERC20(debtAsset).forceApprove(address(lendingPool), repayAmount);

        // repay on behalf of borrower by temporarily acting as borrower — use internal accounting
        // We repay via the pool's repay(), which uses msg.sender, so we need the pool to accept
        // a direct transfer and adjust state. Since our pool's repay() uses msg.sender,
        // we instead directly adjust: pull funds, call repay as a helper.
        // Simpler: liquidator sends funds here, we approve pool, pool pulls via repay()
        // But pool.repay() uses msg.sender's debt — borrower's debt, not ours.
        // Solution: send debtAsset directly to pool and call a liquidationRepay on behalf of borrower.
        // For now: transfer directly to pool and manually reduce borrower's debt via pool's
        // exposed liquidationRepay function (added below as a trusted-caller pattern).
        lendingPool.liquidationRepay(borrower, debtAsset, repayAmount);

        // 5. seize collateral shares from borrower — transfer their supply shares to this contract
        uint256 exchangeRate = lendingPool.exchangeRate(collateralAsset);
        uint256 sharesToSeize = (collateralToSeize * SCALE) / exchangeRate;
        lendingPool.seizeCollateral(borrower, collateralAsset, sharesToSeize, address(this));

        // 6. withdraw the seized collateral from the pool to this contract
        uint256 collateralReceived = IERC20(collateralAsset).balanceOf(address(this));

        // 7. swap collateral → debt asset through the KaliMaga router
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
