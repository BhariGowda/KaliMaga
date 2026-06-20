// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaLendingPool} from "../../src/lending/KaliMagaLendingPool.sol";
import {KaliMagaInterestRateModel} from "../../src/lending/KaliMagaInterestRateModel.sol";
import {KaliMagaPriceOracle} from "../../src/lending/KaliMagaPriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Targeted tests for revert guards in KaliMagaLendingPool not covered by the main test suite.
/// Written to close the branch coverage gap identified in docs/COVERAGE.md.
contract KaliMagaLendingPoolGuardsTest is Test {
    KaliMagaLendingPool pool;
    KaliMagaPriceOracle oracle;
    KaliMagaInterestRateModel irm;
    MockERC20 usdc;
    MockERC20 unlisted;

    address alice = makeAddr("alice");

    function setUp() public {
        oracle = new KaliMagaPriceOracle();
        irm = new KaliMagaInterestRateModel(200, 1000, 30000, 8000);
        pool = new KaliMagaLendingPool(address(oracle));
        usdc = new MockERC20("USD Coin", "USDC", 18);
        unlisted = new MockERC20("Unlisted Token", "UNL", 18);

        oracle.setPrice(address(usdc), 1e18);
        pool.addMarket(address(usdc), address(irm), 8000);

        usdc.mint(alice, 1_000_000e18);
        unlisted.mint(alice, 1_000_000e18);
    }

    function test_RevertWhen_AddMarketAlreadyListed() public {
        vm.expectRevert(KaliMagaLendingPool.MarketAlreadyListed.selector);
        pool.addMarket(address(usdc), address(irm), 8000);
    }

    function test_RevertWhen_AddMarketInvalidCollateralFactor() public {
        vm.expectRevert(KaliMagaLendingPool.InvalidCollateralFactor.selector);
        pool.addMarket(address(unlisted), address(irm), 10_001);
    }

    function test_RevertWhen_DepositToUnlistedMarket() public {
        vm.startPrank(alice);
        unlisted.approve(address(pool), 1000e18);
        vm.expectRevert(KaliMagaLendingPool.MarketNotListed.selector);
        pool.deposit(address(unlisted), 1000e18);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositZeroAmount() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e18);
        vm.expectRevert(KaliMagaLendingPool.ZeroAmount.selector);
        pool.deposit(address(usdc), 0);
        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawFromUnlistedMarket() public {
        vm.expectRevert(KaliMagaLendingPool.MarketNotListed.selector);
        pool.withdraw(address(unlisted), 1000e18);
    }

    function test_RevertWhen_WithdrawZeroShares() public {
        vm.expectRevert(KaliMagaLendingPool.ZeroAmount.selector);
        pool.withdraw(address(usdc), 0);
    }

    function test_RevertWhen_WithdrawMoreSharesThanOwned() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e18);
        pool.deposit(address(usdc), 1000e18);
        vm.expectRevert(KaliMagaLendingPool.InsufficientShares.selector);
        pool.withdraw(address(usdc), 2000e18);
        vm.stopPrank();
    }

    function test_RevertWhen_BorrowFromUnlistedMarket() public {
        vm.expectRevert(KaliMagaLendingPool.MarketNotListed.selector);
        pool.borrow(address(unlisted), 1000e18);
    }

    function test_RevertWhen_BorrowZeroAmount() public {
        vm.expectRevert(KaliMagaLendingPool.ZeroAmount.selector);
        pool.borrow(address(usdc), 0);
    }

    function test_RevertWhen_BorrowExceedsAvailableCash() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 100e18);
        pool.deposit(address(usdc), 100e18);
        // no collateral deposited, but cash check should fire first since pool only has 100e18
        vm.expectRevert(KaliMagaLendingPool.InsufficientCash.selector);
        pool.borrow(address(usdc), 200e18);
        vm.stopPrank();
    }

    function test_RevertWhen_RepayToUnlistedMarket() public {
        vm.expectRevert(KaliMagaLendingPool.MarketNotListed.selector);
        pool.repay(address(unlisted), 1000e18);
    }

    function test_RevertWhen_RepayZeroAmount() public {
        vm.expectRevert(KaliMagaLendingPool.ZeroAmount.selector);
        pool.repay(address(usdc), 0);
    }

    function test_RevertWhen_FlashLoanFromUnlistedMarket() public {
        vm.expectRevert(KaliMagaLendingPool.MarketNotListed.selector);
        pool.flashLoan(alice, address(unlisted), 1000e18, "");
    }

    function test_RevertWhen_FlashLoanZeroAmount() public {
        vm.expectRevert(KaliMagaLendingPool.ZeroAmount.selector);
        pool.flashLoan(alice, address(usdc), 0, "");
    }
}
