// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaliMagaInterestRateModel} from "../../src/lending/KaliMagaInterestRateModel.sol";

/// @dev Targeted tests for the constructor guard in KaliMagaInterestRateModel not covered
/// by the main test suite. Written to close the branch coverage gap identified in docs/COVERAGE.md.
contract KaliMagaInterestRateModelGuardsTest is Test {
    function test_RevertWhen_KinkIsZero() public {
        vm.expectRevert(KaliMagaInterestRateModel.InvalidKink.selector);
        new KaliMagaInterestRateModel(200, 1000, 30000, 0);
    }

    function test_RevertWhen_KinkExceedsBps() public {
        vm.expectRevert(KaliMagaInterestRateModel.InvalidKink.selector);
        new KaliMagaInterestRateModel(200, 1000, 30000, 10_000);
    }

    function test_RevertWhen_KinkAboveBps() public {
        vm.expectRevert(KaliMagaInterestRateModel.InvalidKink.selector);
        new KaliMagaInterestRateModel(200, 1000, 30000, 10_001);
    }
}
