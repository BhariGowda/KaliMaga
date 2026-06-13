// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaFactory} from "../../src/core/KaliMagaFactory.sol";
import {KaliMagaPair} from "../../src/core/KaliMagaPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract KaliMagaPairTest is Test {
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

    function test_Mint_LocksMinimumLiquidity() public {
        vm.startPrank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 1000e18);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenB.transfer(address(pair), 1000e18);
        uint256 liquidity = pair.mint(alice);
        vm.stopPrank();

        // MINIMUM_LIQUIDITY is permanently locked at address(0xdead)
        assertEq(pair.balanceOf(address(0xdead)), pair.MINIMUM_LIQUIDITY());
        assertEq(pair.totalSupply(), liquidity + pair.MINIMUM_LIQUIDITY());
    }

    function test_RevertWhen_MintWithNoTokensSent() public {
        vm.expectRevert(KaliMagaPair.InsufficientLiquidityMinted.selector);
        pair.mint(alice);
    }

    function test_RevertWhen_SwapWithoutSendingInput() public {
        vm.startPrank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 1000e18);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenB.transfer(address(pair), 1000e18);
        pair.mint(alice);

        // try to take tokens out without putting any in -> breaks K invariant
        vm.expectRevert(KaliMagaPair.InsufficientInputAmount.selector);
        pair.swap(0, 100e18, alice);
        vm.stopPrank();
    }

    function test_RevertWhen_SwapExceedsReserves() public {
        vm.startPrank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pair), 1000e18);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenB.transfer(address(pair), 1000e18);
        pair.mint(alice);

        vm.expectRevert(KaliMagaPair.InsufficientLiquidity.selector);
        pair.swap(0, 1000e18, alice); // requesting the entire reserve
        vm.stopPrank();
    }
}
