// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaLendingPool} from "../../src/lending/KaliMagaLendingPool.sol";
import {KaliMagaLiquidator} from "../../src/lending/KaliMagaLiquidator.sol";
import {KaliMagaInterestRateModel} from "../../src/lending/KaliMagaInterestRateModel.sol";
import {KaliMagaPriceOracle} from "../../src/lending/KaliMagaPriceOracle.sol";
import {KaliMagaFactory} from "../../src/core/KaliMagaFactory.sol";
import {KaliMagaRouter} from "../../src/core/KaliMagaRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract KaliMagaLiquidatorTest is Test {
    KaliMagaLendingPool pool;
    KaliMagaLiquidator liquidator;
    KaliMagaPriceOracle oracle;
    KaliMagaInterestRateModel irm;
    KaliMagaFactory factory;
    KaliMagaRouter router;

    MockERC20 usdc;
    MockERC20 weth;

    address alice = makeAddr("alice");   // borrower
    address bob = makeAddr("bob");       // liquidity provider
    address charlie = makeAddr("charlie"); // liquidator

    function setUp() public {
        // deploy DEX
        factory = new KaliMagaFactory();
        router = new KaliMagaRouter(address(factory));

        // deploy lending
        oracle = new KaliMagaPriceOracle();
        irm = new KaliMagaInterestRateModel(200, 1000, 30000, 8000);
        pool = new KaliMagaLendingPool(address(oracle));
        liquidator = new KaliMagaLiquidator(address(pool), address(oracle), address(router));

        // tokens
        usdc = new MockERC20("USD Coin", "USDC", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // prices: WETH=$2000, USDC=$1
        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(usdc), 1e18);

        // markets: WETH 75% CF, USDC 80% CF
        pool.addMarket(address(weth), address(irm), 7500);
        pool.addMarket(address(usdc), address(irm), 8000);

        // mint tokens
        weth.mint(alice, 100e18);
        usdc.mint(bob, 1_000_000e18);
        usdc.mint(charlie, 1_000_000e18);
        weth.mint(charlie, 100e18);

        // seed DEX pool so liquidator can swap WETH -> USDC
        weth.mint(address(this), 500e18);
        usdc.mint(address(this), 1_000_000e18);
        weth.approve(address(router), 500e18);
        usdc.approve(address(router), 1_000_000e18);
        router.addLiquidity(
            address(weth), address(usdc), 500e18, 1_000_000e18, 0, 0, address(this), block.timestamp
        );

        // bob provides USDC liquidity to lending pool
        vm.startPrank(bob);
        usdc.approve(address(pool), 500_000e18);
        pool.deposit(address(usdc), 500_000e18);
        vm.stopPrank();

        // alice deposits WETH as collateral and borrows USDC
        // 10 WETH = $20,000 * 75% CF = $15,000 borrow power
        vm.startPrank(alice);
        weth.approve(address(pool), 10e18);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 12_000e18); // $12,000 — health factor = 15000/12000 = 1.25
        vm.stopPrank();
    }

    function test_HealthFactor_AboveOneBeforePriceDrop() public view {
        uint256 hf = pool.healthFactor(alice);
        assertGt(hf, 1e18);
    }

    function test_Liquidate_AfterCollateralPriceDrop() public {
        // drop WETH price to $1200 — alice's position becomes undercollateralized
        // new collateral value = 10 * $1200 * 75% = $9,000 < $12,000 debt
        oracle.setPrice(address(weth), 1200e18);
        assertLt(pool.healthFactor(alice), 1e18);

        uint256 debtBefore = pool.currentBorrowBalance(alice, address(usdc));
        uint256 maxRepay = (debtBefore * 5000) / 10_000; // 50% close factor

        vm.startPrank(charlie);
        usdc.approve(address(liquidator), maxRepay);
        liquidator.liquidate(address(alice), address(usdc), address(weth), maxRepay, 0);
        vm.stopPrank();

        uint256 debtAfter = pool.currentBorrowBalance(alice, address(usdc));
        assertLt(debtAfter, debtBefore);
    }

    function test_RevertWhen_LiquidatingHealthyPosition() public {
        uint256 debtBefore = pool.currentBorrowBalance(alice, address(usdc));
        uint256 maxRepay = (debtBefore * 5000) / 10_000;

        vm.startPrank(charlie);
        usdc.approve(address(liquidator), maxRepay);
        vm.expectRevert(KaliMagaLiquidator.HealthFactorAboveThreshold.selector);
        liquidator.liquidate(address(alice), address(usdc), address(weth), maxRepay, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_RepayExceedsCloseFactor() public {
        oracle.setPrice(address(weth), 1200e18);

        uint256 totalDebt = pool.currentBorrowBalance(alice, address(usdc));

        vm.startPrank(charlie);
        usdc.approve(address(liquidator), totalDebt);
        vm.expectRevert(KaliMagaLiquidator.RepayAmountExceedsCloseFactor.selector);
        liquidator.liquidate(address(alice), address(usdc), address(weth), totalDebt, 0); // 100% > 50% close factor
        vm.stopPrank();
    }
}
