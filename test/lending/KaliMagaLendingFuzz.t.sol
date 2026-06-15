// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaLendingPool} from "../../src/lending/KaliMagaLendingPool.sol";
import {KaliMagaInterestRateModel} from "../../src/lending/KaliMagaInterestRateModel.sol";
import {KaliMagaPriceOracle} from "../../src/lending/KaliMagaPriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract KaliMagaLendingFuzzTest is Test {
    KaliMagaLendingPool pool;
    KaliMagaPriceOracle oracle;
    KaliMagaInterestRateModel irm;
    MockERC20 usdc;
    MockERC20 weth;

    address supplier = makeAddr("supplier");
    address borrower = makeAddr("borrower");

    function setUp() public {
        oracle = new KaliMagaPriceOracle();
        irm = new KaliMagaInterestRateModel(200, 1000, 30000, 8000);
        pool = new KaliMagaLendingPool(address(oracle));
        usdc = new MockERC20("USD Coin", "USDC", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 2000e18);
        pool.addMarket(address(usdc), address(irm), 8000);
        pool.addMarket(address(weth), address(irm), 7500);
    }

    /// @dev Borrow rate always stays between base rate and theoretical max for any utilization
    function testFuzz_BorrowRateWithinBounds(uint256 cash, uint256 totalBorrows) public view {
        cash = bound(cash, 0, 1_000_000e18);
        totalBorrows = bound(totalBorrows, 0, 1_000_000e18);
        if (cash == 0 && totalBorrows == 0) return;

        uint256 rate = irm.getBorrowRateBps(cash, totalBorrows);
        assertGe(rate, irm.baseRateBps());
        assertLe(rate, irm.baseRateBps() + irm.slope1Bps() + irm.slope2Bps());
    }

    /// @dev Exchange rate never decreases after deposits (no borrows)
    function testFuzz_ExchangeRateNeverDecreasesOnDeposit(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1e18, 100_000e18);
        amount2 = bound(amount2, 1e18, 100_000e18);

        usdc.mint(supplier, amount1 + amount2);
        vm.startPrank(supplier);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), amount1);
        uint256 rateBefore = pool.exchangeRate(address(usdc));
        pool.deposit(address(usdc), amount2);
        uint256 rateAfter = pool.exchangeRate(address(usdc));
        vm.stopPrank();

        assertGe(rateAfter, rateBefore);
    }

    /// @dev Health factor is always max (no debt) when user has no borrows
    function testFuzz_HealthFactorMaxWithNoBorrows(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e18, 100_000e18);

        usdc.mint(supplier, depositAmount);
        vm.startPrank(supplier);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        assertEq(pool.healthFactor(supplier), type(uint256).max);
    }

    /// @dev Borrow always reverts when it would push health factor below 1
    function testFuzz_BorrowRevertsWhenUndercollateralized(uint256 collateral, uint256 borrowAmount) public {
        collateral = bound(collateral, 1e18, 100e18); // 1-100 WETH
        // borrow value that exceeds 75% CF: WETH=$2000, so borrow power = collateral * 2000 * 75%
        uint256 maxSafeBorrow = (collateral * 2000e18 * 7500) / (1e18 * 10_000);
        borrowAmount = bound(borrowAmount, maxSafeBorrow + 1e18, maxSafeBorrow * 2);

        // seed pool with enough USDC
        usdc.mint(address(this), borrowAmount);
        usdc.approve(address(pool), borrowAmount);
        pool.deposit(address(usdc), borrowAmount);

        weth.mint(borrower, collateral);
        vm.startPrank(borrower);
        weth.approve(address(pool), collateral);
        pool.deposit(address(weth), collateral);
        vm.expectRevert(KaliMagaLendingPool.InsufficientCollateral.selector);
        pool.borrow(address(usdc), borrowAmount);
        vm.stopPrank();
    }

    /// @dev Interest rate utilization: 0% utilization always returns base rate
    function testFuzz_ZeroUtilizationReturnsBaseRate(uint256 cash) public view {
        cash = bound(cash, 1, 1_000_000e18);
        uint256 rate = irm.getBorrowRateBps(cash, 0);
        assertEq(rate, irm.baseRateBps());
    }
}
