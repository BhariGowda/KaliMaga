// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DexRouter} from "../src/contracts/DexRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DexRouterTest is Test {
    // Redeclared here so vm.expectEmit can use it as a template
    event SwapExecuted(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    DexRouter public router;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public constant SWAPPER = address(0xBEEF);
    uint256 public constant AMOUNT = 1_000e18;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        router = new DexRouter();
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        tokenA.mint(SWAPPER, AMOUNT);
    }

    // -------------------------------------------------------------------------
    // Happy paths
    // -------------------------------------------------------------------------

    function test_swap_emitsSwapExecuted() public {
        vm.prank(SWAPPER);

        vm.expectEmit(true, true, true, true);
        emit SwapExecuted(SWAPPER, address(tokenA), address(tokenB), AMOUNT, AMOUNT);

        uint256 out = router.swap(address(tokenA), address(tokenB), AMOUNT);
        assertEq(out, AMOUNT);
    }

    function test_swap_returnsAmountOut() public {
        vm.prank(SWAPPER);
        uint256 out = router.swap(address(tokenA), address(tokenB), AMOUNT);
        assertEq(out, AMOUNT, "stub should return amountIn as amountOut");
    }

    /// @dev Any non-zero amount should succeed — fuzz over the full uint range.
    function testFuzz_swap_anyAmount(uint256 amount) public {
        vm.assume(amount > 0);
        vm.prank(SWAPPER);
        uint256 out = router.swap(address(tokenA), address(tokenB), amount);
        assertEq(out, amount);
    }

    // -------------------------------------------------------------------------
    // Revert: ZeroAddress
    // -------------------------------------------------------------------------

    function test_swap_revert_tokenInZeroAddress() public {
        vm.prank(SWAPPER);
        vm.expectRevert(DexRouter.ZeroAddress.selector);
        router.swap(address(0), address(tokenB), AMOUNT);
    }

    function test_swap_revert_tokenOutZeroAddress() public {
        vm.prank(SWAPPER);
        vm.expectRevert(DexRouter.ZeroAddress.selector);
        router.swap(address(tokenA), address(0), AMOUNT);
    }

    // -------------------------------------------------------------------------
    // Revert: ZeroAmount
    // -------------------------------------------------------------------------

    function test_swap_revert_zeroAmountIn() public {
        vm.prank(SWAPPER);
        vm.expectRevert(DexRouter.ZeroAmount.selector);
        router.swap(address(tokenA), address(tokenB), 0);
    }

    // -------------------------------------------------------------------------
    // Revert: IdenticalTokens
    // -------------------------------------------------------------------------

    function test_swap_revert_identicalTokens() public {
        vm.prank(SWAPPER);
        vm.expectRevert(DexRouter.IdenticalTokens.selector);
        router.swap(address(tokenA), address(tokenA), AMOUNT);
    }
}
