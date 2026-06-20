// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaPriceOracle} from "../../src/lending/KaliMagaPriceOracle.sol";

/// @dev Targeted tests for revert guards in KaliMagaPriceOracle not covered by the main
/// test suite. Written to close the branch coverage gap identified in docs/COVERAGE.md.
contract KaliMagaPriceOracleGuardsTest is Test {
    KaliMagaPriceOracle oracle;
    address asset = makeAddr("asset");

    function setUp() public {
        oracle = new KaliMagaPriceOracle();
    }

    function test_RevertWhen_SetPriceToZero() public {
        vm.expectRevert(KaliMagaPriceOracle.ZeroPrice.selector);
        oracle.setPrice(asset, 0);
    }

    function test_RevertWhen_GetPriceNotSet() public {
        vm.expectRevert(KaliMagaPriceOracle.PriceNotSet.selector);
        oracle.getPrice(asset);
    }

    function test_RevertWhen_SetPriceCalledByNonOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        oracle.setPrice(asset, 100e18);
    }
}
