// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaLendingPool} from "../../src/lending/KaliMagaLendingPool.sol";
import {KaliMagaInterestRateModel} from "../../src/lending/KaliMagaInterestRateModel.sol";
import {KaliMagaPriceOracle} from "../../src/lending/KaliMagaPriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract KaliMagaLendingPoolTest is Test {
    KaliMagaLendingPool pool;
    KaliMagaPriceOracle oracle;
    KaliMagaInterestRateModel irm;

    MockERC20 usdc;
    MockERC20 weth;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        oracle = new KaliMagaPriceOracle();
        irm = new KaliMagaInterestRateModel(200, 1000, 30000, 8000); // 2% base, 10% slope1, 300% slope2, 80% kink

        pool = new KaliMagaLendingPool(address(oracle));

        usdc = new MockERC20("USD Coin", "USDC", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        oracle.setPrice(address(usdc), 1e18); // $1
        oracle.setPrice(address(weth), 2000e18); // $2000

        pool.addMarket(address(usdc), address(irm), 8000); // 80% collateral factor
        pool.addMarket(address(weth), address(irm), 7500); // 75% collateral factor

        usdc.mint(alice, 1_000_000e18);
        weth.mint(alice, 1_000e18);
        usdc.mint(bob, 1_000_000e18);
        weth.mint(bob, 1_000e18);
    }

    function test_Deposit_MintsSharesOneToOne() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 10_000e18);
        pool.deposit(address(usdc), 10_000e18);
        vm.stopPrank();

        assertEq(pool.supplyShares(alice, address(usdc)), 10_000e18);
        assertEq(usdc.balanceOf(address(pool)), 10_000e18);
    }

    function test_Borrow_AgainstCollateral() public {
        vm.startPrank(bob);
        weth.approve(address(pool), 10e18);
        pool.deposit(address(weth), 10e18); // 10 WETH = $20,000, 75% CF = $15,000 borrow power
        vm.stopPrank();

        vm.startPrank(alice);
        usdc.approve(address(pool), 100_000e18);
        pool.deposit(address(usdc), 100_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        pool.borrow(address(usdc), 10_000e18); // within $15,000 limit
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), 1_000_000e18 + 10_000e18);
        assertEq(pool.currentBorrowBalance(bob, address(usdc)), 10_000e18);
    }

    function test_RevertWhen_BorrowExceedsCollateral() public {
        vm.startPrank(bob);
        weth.approve(address(pool), 10e18);
        pool.deposit(address(weth), 10e18);
        vm.stopPrank();

        vm.startPrank(alice);
        usdc.approve(address(pool), 100_000e18);
        pool.deposit(address(usdc), 100_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(KaliMagaLendingPool.InsufficientCollateral.selector);
        pool.borrow(address(usdc), 16_000e18); // exceeds $15,000 borrow power
        vm.stopPrank();
    }

    function test_Repay_ReducesDebtToZero() public {
        vm.startPrank(bob);
        weth.approve(address(pool), 10e18);
        pool.deposit(address(weth), 10e18);
        vm.stopPrank();

        vm.startPrank(alice);
        usdc.approve(address(pool), 100_000e18);
        pool.deposit(address(usdc), 100_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        pool.borrow(address(usdc), 10_000e18);
        usdc.approve(address(pool), 10_000e18);
        pool.repay(address(usdc), 10_000e18);
        vm.stopPrank();

        assertEq(pool.currentBorrowBalance(bob, address(usdc)), 0);
    }

    function test_RevertWhen_WithdrawBreaksHealthFactor() public {
        vm.startPrank(bob);
        weth.approve(address(pool), 10e18);
        pool.deposit(address(weth), 10e18);
        vm.stopPrank();

        vm.startPrank(alice);
        usdc.approve(address(pool), 100_000e18);
        pool.deposit(address(usdc), 100_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        pool.borrow(address(usdc), 10_000e18); // health factor = 1.5

        vm.expectRevert(KaliMagaLendingPool.InsufficientCollateral.selector);
        pool.withdraw(address(weth), 5e18); // would drop health factor below 1
        vm.stopPrank();
    }

    function test_InterestAccrual_IncreasesDebtAndExchangeRate() public {
        vm.startPrank(bob);
        weth.approve(address(pool), 10e18);
        pool.deposit(address(weth), 10e18);
        vm.stopPrank();

        vm.startPrank(alice);
        usdc.approve(address(pool), 100_000e18);
        pool.deposit(address(usdc), 100_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        pool.borrow(address(usdc), 10_000e18);
        vm.stopPrank();

        uint256 debtBefore = pool.currentBorrowBalance(bob, address(usdc));
        uint256 rateBefore = pool.exchangeRate(address(usdc));

        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest(address(usdc));

        uint256 debtAfter = pool.currentBorrowBalance(bob, address(usdc));
        uint256 rateAfter = pool.exchangeRate(address(usdc));

        assertGt(debtAfter, debtBefore);
        assertGt(rateAfter, rateBefore);
    }
}
