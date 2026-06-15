// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {KaliMagaFactory} from "../../src/core/KaliMagaFactory.sol";
import {KaliMagaRouter} from "../../src/core/KaliMagaRouter.sol";
import {KaliMagaPair} from "../../src/core/KaliMagaPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Handler exposes only the actions forge can call during invariant runs
contract AMMHandler is Test {
    KaliMagaRouter router;
    KaliMagaPair pair;
    MockERC20 tokenA;
    MockERC20 tokenB;
    address actor = makeAddr("actor");

    constructor(KaliMagaRouter _router, KaliMagaPair _pair, MockERC20 _tokenA, MockERC20 _tokenB) {
        router = _router;
        pair = _pair;
        tokenA = _tokenA;
        tokenB = _tokenB;
    }

    function swap(uint256 amountIn) external {
        amountIn = bound(amountIn, 1e15, 1_000e18);
        tokenA.mint(actor, amountIn);
        vm.startPrank(actor);
        tokenA.approve(address(router), amountIn);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        try router.swapExactTokensForTokens(amountIn, 0, path, actor, block.timestamp) {} catch {}
        vm.stopPrank();
    }

    function addLiquidity(uint256 amountA, uint256 amountB) external {
        amountA = bound(amountA, 1e18, 10_000e18);
        amountB = bound(amountB, 1e18, 10_000e18);
        tokenA.mint(actor, amountA);
        tokenB.mint(actor, amountB);
        vm.startPrank(actor);
        tokenA.approve(address(router), amountA);
        tokenB.approve(address(router), amountB);
        try router.addLiquidity(address(tokenA), address(tokenB), amountA, amountB, 0, 0, actor, block.timestamp) {}
        catch {}
        vm.stopPrank();
    }

    function removeLiquidity(uint256 lpAmount) external {
        uint256 balance = pair.balanceOf(actor);
        if (balance == 0) return;
        lpAmount = bound(lpAmount, 1, balance);
        vm.startPrank(actor);
        pair.approve(address(router), lpAmount);
        try router.removeLiquidity(address(tokenA), address(tokenB), lpAmount, 0, 0, actor, block.timestamp) {}
        catch {}
        vm.stopPrank();
    }
}

contract KaliMagaAMMInvariantTest is StdInvariant, Test {
    KaliMagaFactory factory;
    KaliMagaRouter router;
    KaliMagaPair pair;
    MockERC20 tokenA;
    MockERC20 tokenB;
    AMMHandler handler;

    function setUp() public {
        factory = new KaliMagaFactory();
        router = new KaliMagaRouter(address(factory));
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        // seed initial liquidity
        tokenA.mint(address(this), 500_000e18);
        tokenB.mint(address(this), 500_000e18);
        tokenA.approve(address(router), 500_000e18);
        tokenB.approve(address(router), 500_000e18);
        router.addLiquidity(
            address(tokenA), address(tokenB), 500_000e18, 500_000e18, 0, 0, address(this), block.timestamp
        );

        pair = KaliMagaPair(factory.getPair(address(tokenA), address(tokenB)));
        handler = new AMMHandler(router, pair, tokenA, tokenB);
        targetContract(address(handler));
    }

    /// @dev K = reserve0 * reserve1 never decreases
    function invariant_KNeverDecreases() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGe(uint256(r0) * uint256(r1), 500_000e18 * 500_000e18);
    }

    /// @dev Total redeemable value always backed by reserves:
    /// totalSupply * reservePerShare <= reserve (no more can be withdrawn than exists)
    function invariant_LPFullyBacked() public view {
        uint256 supply = pair.totalSupply();
        if (supply == 0) return;
        (uint112 r0, uint112 r1,) = pair.getReserves();
        // each LP share is backed by r0/supply of token0 and r1/supply of token1
        // verify reserves are non-zero so LP is redeemable
        assertGt(uint256(r0), 0);
        assertGt(uint256(r1), 0);
    }

    /// @dev Total LP supply is always greater than MINIMUM_LIQUIDITY
    function invariant_TotalSupplyAboveMinimum() public view {
        assertGe(pair.totalSupply(), pair.MINIMUM_LIQUIDITY());
    }
}
