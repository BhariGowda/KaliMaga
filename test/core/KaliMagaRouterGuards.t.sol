// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaFactory} from "../../src/core/KaliMagaFactory.sol";
import {KaliMagaRouter} from "../../src/core/KaliMagaRouter.sol";
import {KaliMagaPair} from "../../src/core/KaliMagaPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Targeted tests for slippage-guard revert paths in KaliMagaRouter not covered
/// by the main test suite. Written to close the branch coverage gap identified in docs/COVERAGE.md.
contract KaliMagaRouterGuardsTest is Test {
    KaliMagaFactory factory;
    KaliMagaRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address lp = makeAddr("lp");
    address alice = makeAddr("alice");
    address pairAddr;

    function setUp() public {
        factory = new KaliMagaFactory();
        router = new KaliMagaRouter(address(factory));
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        // seed an unbalanced pool: 1000 tokenA : 2000 tokenB (1:2 ratio)
        tokenA.mint(lp, 1_000_000e18);
        tokenB.mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        router.addLiquidity(address(tokenA), address(tokenB), 1000e18, 2000e18, 0, 0, lp, block.timestamp);
        vm.stopPrank();

        pairAddr = factory.getPair(address(tokenA), address(tokenB));

        tokenA.mint(alice, 1_000_000e18);
        tokenB.mint(alice, 1_000_000e18);
    }

    function test_RevertWhen_AddLiquidityBOptimalBelowMinimum() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        // pool ratio is 1:2, so 100 tokenA wants 200 tokenB.
        // we supply plenty of tokenB but set an unreachable amountBMin to force the revert.
        vm.expectRevert(KaliMagaRouter.InsufficientBAmount.selector);
        router.addLiquidity(address(tokenA), address(tokenB), 100e18, 500e18, 0, 250e18, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_RevertWhen_AddLiquidityAOptimalBelowMinimum() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        // pool ratio is 1:2. amountBDesired=50e18 is tight: amountBOptimal for 100e18
        // tokenA would be 200e18, which exceeds amountBDesired, so the router falls
        // back to computing amountAOptimal from tokenB. With amountBDesired=50e18,
        // amountAOptimal = 25e18, which we push below amountAMin to force the revert.
        vm.expectRevert(KaliMagaRouter.InsufficientAAmount.selector);
        router.addLiquidity(address(tokenA), address(tokenB), 100e18, 50e18, 26e18, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_RevertWhen_RemoveLiquidityAmountABelowMinimum() public {
        vm.startPrank(lp);
        uint256 liquidity = KaliMagaPair(pairAddr).balanceOf(lp);
        KaliMagaPair(pairAddr).approve(address(router), liquidity);

        // demand an unreachable amountAMin
        vm.expectRevert(KaliMagaRouter.InsufficientAAmount.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenB), liquidity, type(uint256).max, 0, lp, block.timestamp
        );
        vm.stopPrank();
    }

    function test_RevertWhen_RemoveLiquidityAmountBBelowMinimum() public {
        vm.startPrank(lp);
        uint256 liquidity = KaliMagaPair(pairAddr).balanceOf(lp);
        KaliMagaPair(pairAddr).approve(address(router), liquidity);

        // demand an unreachable amountBMin
        vm.expectRevert(KaliMagaRouter.InsufficientBAmount.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenB), liquidity, 0, type(uint256).max, lp, block.timestamp
        );
        vm.stopPrank();
    }
}
