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

/// @dev Targeted test for the remaining revert guard in KaliMagaLiquidator not covered
/// by the main test suite. Written to close the branch coverage gap identified in docs/COVERAGE.md.
contract KaliMagaLiquidatorGuardsTest is Test {
    KaliMagaLendingPool pool;
    KaliMagaLiquidator liquidator;
    KaliMagaPriceOracle oracle;
    KaliMagaInterestRateModel irm;
    KaliMagaFactory factory;
    KaliMagaRouter router;
    MockERC20 usdc;
    MockERC20 weth;

    address alice = makeAddr("alice");

    function setUp() public {
        factory = new KaliMagaFactory();
        router = new KaliMagaRouter(address(factory));
        oracle = new KaliMagaPriceOracle();
        irm = new KaliMagaInterestRateModel(200, 1000, 30000, 8000);
        pool = new KaliMagaLendingPool(address(oracle));
        liquidator = new KaliMagaLiquidator(address(pool), address(oracle), address(router));

        usdc = new MockERC20("USD Coin", "USDC", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 2000e18);
        pool.addMarket(address(usdc), address(irm), 8000);
        pool.addMarket(address(weth), address(irm), 7500);
    }

    function test_RevertWhen_LiquidateWithZeroRepayAmount() public {
        vm.prank(alice);
        vm.expectRevert(KaliMagaLiquidator.ZeroAmount.selector);
        liquidator.liquidate(alice, address(usdc), address(weth), 0, 0);
    }
}
