// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaFactory} from "../../src/core/KaliMagaFactory.sol";
import {KaliMagaRouter} from "../../src/core/KaliMagaRouter.sol";
import {KaliMagaPair} from "../../src/core/KaliMagaPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract KaliMagaRouterTest is Test {
    KaliMagaFactory factory;
    KaliMagaRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        factory = new KaliMagaFactory();
        router = new KaliMagaRouter(address(factory));
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        tokenA.mint(alice, 1_000_000e18);
        tokenB.mint(alice, 1_000_000e18);
        tokenA.mint(bob, 1_000_000e18);
        tokenB.mint(bob, 1_000_000e18);
    }

    function test_AddLiquidity_CreatesPairAndMintsLP() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), 1000e18);
        tokenB.approve(address(router), 1000e18);
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 1000e18, 1000e18, 0, 0, alice, block.timestamp
        );
        vm.stopPrank();

        assertEq(amountA, 1000e18);
        assertEq(amountB, 1000e18);
        assertGt(liquidity, 0);
        assertTrue(factory.getPair(address(tokenA), address(tokenB)) != address(0));
    }

    function test_AddLiquidity_ProportionalSecondDeposit() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        router.addLiquidity(address(tokenA), address(tokenB), 1000e18, 1000e18, 0, 0, alice, block.timestamp);

        (uint256 amountA, uint256 amountB,) =
            router.addLiquidity(address(tokenA), address(tokenB), 500e18, 500e18, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        assertEq(amountA, 500e18);
        assertEq(amountB, 500e18);
    }

    function test_RemoveLiquidity_ReturnsTokens() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        (,, uint256 liquidity) =
            router.addLiquidity(address(tokenA), address(tokenB), 1000e18, 1000e18, 0, 0, alice, block.timestamp);

        address pair = factory.getPair(address(tokenA), address(tokenB));
        KaliMagaPair(pair).approve(address(router), liquidity);

        (uint256 amountA, uint256 amountB) =
            router.removeLiquidity(address(tokenA), address(tokenB), liquidity, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(amountA, 0);
        assertGt(amountB, 0);
    }

    function test_SwapExactTokensForTokens() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        router.addLiquidity(address(tokenA), address(tokenB), 100_000e18, 100_000e18, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        vm.startPrank(bob);
        tokenA.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 balBefore = tokenB.balanceOf(bob);
        uint256[] memory amounts = router.swapExactTokensForTokens(1000e18, 0, path, bob, block.timestamp);
        vm.stopPrank();

        assertGt(amounts[1], 0);
        assertEq(tokenB.balanceOf(bob) - balBefore, amounts[1]);
        assertLt(amounts[1], 1000e18);
    }

    function test_RevertWhen_DeadlineExpired() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), 1000e18);
        tokenB.approve(address(router), 1000e18);
        vm.expectRevert(KaliMagaRouter.Expired.selector);
        router.addLiquidity(address(tokenA), address(tokenB), 1000e18, 1000e18, 0, 0, alice, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_RevertWhen_OutputBelowMinimum() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        router.addLiquidity(address(tokenA), address(tokenB), 100_000e18, 100_000e18, 0, 0, alice, block.timestamp);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.expectRevert(KaliMagaRouter.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(1000e18, type(uint256).max, path, alice, block.timestamp);
        vm.stopPrank();
    }
}
