// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaLendingPool} from "../../src/lending/KaliMagaLendingPool.sol";
import {KaliMagaInterestRateModel} from "../../src/lending/KaliMagaInterestRateModel.sol";
import {KaliMagaPriceOracle} from "../../src/lending/KaliMagaPriceOracle.sol";
import {IFlashLoanReceiver} from "../../src/interfaces/IFlashLoanReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Honest receiver: repays amount + fee in the callback
contract HonestReceiver is IFlashLoanReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 fee,
        address,
        bytes calldata
    ) external override returns (bool) {
        IERC20(asset).transfer(msg.sender, amount + fee);
        return true;
    }
}

/// @dev Dishonest receiver: only repays the principal, keeps the fee
contract DishonestReceiver is IFlashLoanReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 /*fee*/,
        address,
        bytes calldata
    ) external override returns (bool) {
        // deliberately underpays — no fee returned
        IERC20(asset).transfer(msg.sender, amount);
        return true;
    }
}

/// @dev Greedy receiver: returns false from the callback
contract FailingReceiver is IFlashLoanReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 fee,
        address,
        bytes calldata
    ) external override returns (bool) {
        IERC20(asset).transfer(msg.sender, amount + fee);
        return false;
    }
}

contract KaliMagaFlashLoanTest is Test {
    KaliMagaLendingPool pool;
    KaliMagaPriceOracle oracle;
    KaliMagaInterestRateModel irm;
    MockERC20 usdc;

    HonestReceiver honest;
    DishonestReceiver dishonest;
    FailingReceiver failing;

    function setUp() public {
        oracle = new KaliMagaPriceOracle();
        irm = new KaliMagaInterestRateModel(200, 1000, 30000, 8000);
        pool = new KaliMagaLendingPool(address(oracle));
        usdc = new MockERC20("USD Coin", "USDC", 18);

        oracle.setPrice(address(usdc), 1e18);
        pool.addMarket(address(usdc), address(irm), 8000);

        // seed the pool with liquidity
        usdc.mint(address(this), 100_000e18);
        usdc.approve(address(pool), 100_000e18);
        pool.deposit(address(usdc), 100_000e18);

        honest = new HonestReceiver();
        dishonest = new DishonestReceiver();
        failing = new FailingReceiver();

        // fund receivers so they can repay the fee
        usdc.mint(address(honest), 1000e18);
        usdc.mint(address(dishonest), 1000e18);
        usdc.mint(address(failing), 1000e18);
    }

    function test_FlashLoan_HappyPath() public {
        uint256 amount = 10_000e18;
        uint256 expectedFee = (amount * 9) / 10_000;
        uint256 poolBalanceBefore = usdc.balanceOf(address(pool));

        pool.flashLoan(address(honest), address(usdc), amount, "");

        uint256 poolBalanceAfter = usdc.balanceOf(address(pool));
        assertEq(poolBalanceAfter, poolBalanceBefore + expectedFee);
    }

    function test_FlashLoan_FeeAccruesToTotalBorrows() public {
        uint256 amount = 10_000e18;
        uint256 expectedFee = (amount * 9) / 10_000;
        (, KaliMagaLendingPool.Market memory marketBefore) = _getMarket();

        pool.flashLoan(address(honest), address(usdc), amount, "");

        (, KaliMagaLendingPool.Market memory marketAfter) = _getMarket();
        assertEq(marketAfter.totalBorrows, marketBefore.totalBorrows + expectedFee);
    }

    function test_RevertWhen_ReceiverDoesNotRepayFee() public {
        vm.expectRevert("flash loan not repaid");
        pool.flashLoan(address(dishonest), address(usdc), 10_000e18, "");
    }

    function test_RevertWhen_CallbackReturnsFalse() public {
        vm.expectRevert("flash loan callback failed");
        pool.flashLoan(address(failing), address(usdc), 10_000e18, "");
    }

    function test_RevertWhen_AmountExceedsCash() public {
        vm.expectRevert(KaliMagaLendingPool.InsufficientCash.selector);
        pool.flashLoan(address(honest), address(usdc), 200_000e18, "");
    }

    // helper to read market struct
    function _getMarket() internal view returns (address asset, KaliMagaLendingPool.Market memory market) {
        asset = address(usdc);
        (
            bool isListed,
            address interestRateModel,
            uint256 collateralFactorBps,
            uint256 totalSupplyShares,
            uint256 totalBorrows,
            uint256 borrowIndex,
            uint256 lastAccrualTime
        ) = pool.markets(asset);
        market = KaliMagaLendingPool.Market({
            isListed: isListed,
            interestRateModel: interestRateModel,
            collateralFactorBps: collateralFactorBps,
            totalSupplyShares: totalSupplyShares,
            totalBorrows: totalBorrows,
            borrowIndex: borrowIndex,
            lastAccrualTime: lastAccrualTime
        });
    }
}
