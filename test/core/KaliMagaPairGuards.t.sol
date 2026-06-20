// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaFactory} from "../../src/core/KaliMagaFactory.sol";
import {KaliMagaPair} from "../../src/core/KaliMagaPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Targeted tests for revert guards in KaliMagaPair not covered by the main test suite.
/// Written to close the branch coverage gap identified in docs/COVERAGE.md.
contract KaliMagaPairGuardsTest is Test {
    KaliMagaFactory factory;
    KaliMagaPair pair;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address alice = makeAddr("alice");

    function setUp() public {
        factory = new KaliMagaFactory();
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        address pairAddr = factory.createPair(address(tokenA), address(tokenB));
        pair = KaliMagaPair(pairAddr);

        tokenA.mint(alice, 1_000_000e18);
        tokenB.mint(alice, 1_000_000e18);
    }

    function test_RevertWhen_InitializeCalledByNonFactory() public {
        vm.expectRevert(KaliMagaPair.NotFactory.selector);
        pair.initialize(address(tokenA), address(tokenB));
    }

    function test_RevertWhen_InitializeCalledTwice() public {
        // pair from setUp() is already initialized by the factory
        vm.prank(address(factory));
        vm.expectRevert(KaliMagaPair.AlreadyInitialized.selector);
        pair.initialize(address(tokenA), address(tokenB));
    }

    function test_RevertWhen_BurnWithZeroLPBalance() public {
        vm.startPrank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 1000e18);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenB.transfer(address(pair), 1000e18);
        pair.mint(alice);
        vm.stopPrank();

        // burn() called without sending any LP tokens to the pair first
        vm.expectRevert(KaliMagaPair.InsufficientLiquidityBurned.selector);
        pair.burn(alice);
    }

    function test_RevertWhen_SwapRequestsZeroOutputOnBothSides() public {
        vm.startPrank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 1000e18);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenB.transfer(address(pair), 1000e18);
        pair.mint(alice);

        vm.expectRevert(KaliMagaPair.InsufficientOutputAmount.selector);
        pair.swap(0, 0, alice);
        vm.stopPrank();
    }

    function test_RevertWhen_SwapRecipientIsToken0() public {
        vm.startPrank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 1000e18);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenB.transfer(address(pair), 1000e18);
        pair.mint(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 100e18);

        address badTo = pair.token0();
        vm.expectRevert(KaliMagaPair.InvalidTo.selector);
        pair.swap(0, 90e18, badTo);
        vm.stopPrank();
    }

    function test_RevertWhen_SwapRecipientIsToken1() public {
        vm.startPrank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 1000e18);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenB.transfer(address(pair), 1000e18);
        pair.mint(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 100e18);

        address badTo = pair.token1();
        vm.expectRevert(KaliMagaPair.InvalidTo.selector);
        pair.swap(0, 90e18, badTo);
        vm.stopPrank();
    }

    function test_RevertWhen_SwapViolatesKInvariant() public {
        vm.startPrank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 1000e18);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenB.transfer(address(pair), 1000e18);
        pair.mint(alice);

        // send only a tiny amount in but request a large amount out — fails the K check
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 1e18);

        vm.expectRevert(KaliMagaPair.KInvariant.selector);
        pair.swap(0, 500e18, alice);
        vm.stopPrank();
    }
}
