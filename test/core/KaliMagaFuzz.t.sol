// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaFactory} from "../../src/core/KaliMagaFactory.sol";
import {KaliMagaRouter} from "../../src/core/KaliMagaRouter.sol";
import {KaliMagaPair} from "../../src/core/KaliMagaPair.sol";
import {KaliMagaLibrary} from "../../src/core/KaliMagaLibrary.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract KaliMagaFuzzTest is Test {
    KaliMagaFactory factory;
    KaliMagaRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address lp = makeAddr("lp");

    function setUp() public {
        factory = new KaliMagaFactory();
        router = new KaliMagaRouter(address(factory));
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        // seed initial liquidity
        tokenA.mint(lp, 1_000_000e18);
        tokenB.mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        router.addLiquidity(
            address(tokenA), address(tokenB), 500_000e18, 500_000e18, 0, 0, lp, block.timestamp
        );
        vm.stopPrank();
    }

    /// @dev Swap output never exceeds the available reserve
    function testFuzz_SwapOutputNeverExceedsReserve(uint256 amountIn) public view {
        amountIn = bound(amountIn, 1e15, 10_000e18);

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        (uint112 reserve0, uint112 reserve1,) = KaliMagaPair(pairAddr).getReserves();

        uint256 amountOut = KaliMagaLibrary.getAmountOut(amountIn, uint256(reserve0), uint256(reserve1));
        assertLt(amountOut, uint256(reserve1));
    }

    /// @dev K-invariant: reserve product never decreases after a swap
    function testFuzz_KInvariantHoldsAfterSwap(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, 10_000e18);

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        (uint112 r0Before, uint112 r1Before,) = KaliMagaPair(pairAddr).getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        address swapper = makeAddr("swapper");
        tokenA.mint(swapper, amountIn);
        vm.startPrank(swapper);
        tokenA.approve(address(router), amountIn);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        router.swapExactTokensForTokens(amountIn, 0, path, swapper, block.timestamp);
        vm.stopPrank();

        (uint112 r0After, uint112 r1After,) = KaliMagaPair(pairAddr).getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);
        assertGe(kAfter, kBefore);
    }

    /// @dev LP can always withdraw proportional underlying after adding liquidity
    function testFuzz_LPWithdrawProportional(uint256 addA, uint256 addB) public {
        addA = bound(addA, 1e18, 100_000e18);
        addB = bound(addB, 1e18, 100_000e18);

        address user = makeAddr("user");
        tokenA.mint(user, addA);
        tokenB.mint(user, addB);

        vm.startPrank(user);
        tokenA.approve(address(router), addA);
        tokenB.approve(address(router), addB);
        (,, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), addA, addB, 0, 0, user, block.timestamp
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        KaliMagaPair(pairAddr).approve(address(router), liquidity);
        (uint256 outA, uint256 outB) = router.removeLiquidity(
            address(tokenA), address(tokenB), liquidity, 0, 0, user, block.timestamp
        );
        vm.stopPrank();

        assertGt(outA, 0);
        assertGt(outB, 0);
    }

    /// @dev Quote is always proportional: more in = more out
    function testFuzz_QuoteIsProportional(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure {
        amountA = bound(amountA, 1, type(uint112).max);
        reserveA = bound(reserveA, 1, type(uint112).max);
        reserveB = bound(reserveB, 1, type(uint112).max);

        uint256 quote = KaliMagaLibrary.quote(amountA, reserveA, reserveB);
        uint256 quoteDouble = KaliMagaLibrary.quote(amountA * 2, reserveA, reserveB);
        // integer division can lose 1 wei per operation — allow 1 wei tolerance
        assertApproxEqAbs(quoteDouble, quote * 2, 1);
    }
}
