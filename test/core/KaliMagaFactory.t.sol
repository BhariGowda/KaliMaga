// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaFactory} from "../../src/core/KaliMagaFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract KaliMagaFactoryTest is Test {
    KaliMagaFactory factory;
    MockERC20 tokenA;
    MockERC20 tokenB;

    function setUp() public {
        factory = new KaliMagaFactory();
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
    }

    function test_CreatePair_RegistersBothDirections() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair);
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair);
        assertEq(factory.allPairsLength(), 1);
    }

    function test_RevertWhen_CreatingDuplicatePair() public {
        factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(KaliMagaFactory.PairExists.selector);
        factory.createPair(address(tokenA), address(tokenB));
    }

    function test_RevertWhen_IdenticalAddresses() public {
        vm.expectRevert(KaliMagaFactory.IdenticalAddresses.selector);
        factory.createPair(address(tokenA), address(tokenA));
    }

    function test_RevertWhen_ZeroAddress() public {
        vm.expectRevert(KaliMagaFactory.ZeroAddress.selector);
        factory.createPair(address(0), address(tokenA));
    }
}
