// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Collateral} from "../src/contracts/Collateral.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// ---------------------------------------------------------------------------
// Concrete harness — gives tests direct write-access to storage
// ---------------------------------------------------------------------------
contract CollateralHarness is Collateral {
    function setDeposit(address token, address user, uint256 amount) external {
        deposits[token][user] = amount;
    }

    function setBorrow(address token, address user, uint256 amount) external {
        borrows[token][user] = amount;
    }

    function setPoolLiquidity(address token, uint256 amount) external {
        poolLiquidity[token] = amount;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
contract CollateralTest is Test {
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed token,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    CollateralHarness public col;
    MockERC20 public token;

    address constant ALICE = address(0xA11CE); // borrower
    address constant BOB   = address(0xB0B);   // liquidator

    // mirrors Collateral constants
    uint256 constant CF        = 7_500;
    uint256 constant BASIS     = 10_000;
    uint256 constant BONUS     = 500;
    uint256 constant CLOSE     = 5_000;
    uint256 constant PRECISION = 1e18;

    function setUp() public {
        col   = new CollateralHarness();
        token = new MockERC20("Test Token", "TST", 18);

        token.mint(BOB, 100_000e18);
        vm.prank(BOB);
        token.approve(address(col), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// Set up an unhealthy position (dep=1000, debt=900, HF≈0.833) and fund
    /// the harness with enough tokens to cover the seized collateral.
    function _setupUnhealthyPosition(uint256 dep, uint256 debt) internal {
        col.setDeposit(address(token), ALICE, dep);
        col.setBorrow(address(token), ALICE, debt);
        col.setPoolLiquidity(address(token), dep);
        token.mint(address(col), dep);
    }

    function _hf(uint256 dep, uint256 debt) internal pure returns (uint256) {
        return (dep * CF * PRECISION) / (BASIS * debt);
    }

    function _seized(uint256 repay) internal pure returns (uint256) {
        return (repay * (BASIS + BONUS)) / BASIS;
    }

    // =========================================================================
    // healthFactor
    // =========================================================================

    function test_healthFactor_noBorrow_returnsMax() public view {
        assertEq(col.healthFactor(address(token), ALICE), type(uint256).max);
    }

    function test_healthFactor_exactlyOne() public {
        // dep * CF == BASIS * debt  →  dep=10000, debt=7500
        col.setDeposit(address(token), ALICE, 10_000e18);
        col.setBorrow(address(token), ALICE, 7_500e18);

        assertEq(col.healthFactor(address(token), ALICE), PRECISION);
    }

    function test_healthFactor_aboveOne() public {
        // dep=1000, debt=500  →  HF = 1000*7500/10000/500 = 1.5
        col.setDeposit(address(token), ALICE, 1_000e18);
        col.setBorrow(address(token), ALICE, 500e18);

        uint256 hf = col.healthFactor(address(token), ALICE);
        assertEq(hf, _hf(1_000e18, 500e18));
        assertTrue(hf > PRECISION);
    }

    function test_healthFactor_belowOne() public {
        // dep=100, debt=100  →  HF = 0.75
        col.setDeposit(address(token), ALICE, 100e18);
        col.setBorrow(address(token), ALICE, 100e18);

        uint256 hf = col.healthFactor(address(token), ALICE);
        assertEq(hf, _hf(100e18, 100e18));
        assertTrue(hf < PRECISION);
    }

    function testFuzz_healthFactor_matchesFormula(uint128 dep, uint128 debt) public {
        vm.assume(debt > 0);
        col.setDeposit(address(token), ALICE, dep);
        col.setBorrow(address(token), ALICE, debt);

        assertEq(
            col.healthFactor(address(token), ALICE),
            _hf(dep, debt)
        );
    }

    // =========================================================================
    // isLiquidatable
    // =========================================================================

    function test_isLiquidatable_false_noBorrow() public view {
        assertFalse(col.isLiquidatable(address(token), ALICE));
    }

    function test_isLiquidatable_false_healthyPosition() public {
        col.setDeposit(address(token), ALICE, 1_000e18);
        col.setBorrow(address(token), ALICE, 500e18); // HF = 1.5
        assertFalse(col.isLiquidatable(address(token), ALICE));
    }

    function test_isLiquidatable_false_exactlyAtThreshold() public {
        // HF == 1.0 is NOT liquidatable (strict less-than required)
        col.setDeposit(address(token), ALICE, 10_000e18);
        col.setBorrow(address(token), ALICE, 7_500e18);
        assertFalse(col.isLiquidatable(address(token), ALICE));
    }

    function test_isLiquidatable_true_undercollateralized() public {
        // dep=100, debt=100  →  HF = 0.75 < 1
        col.setDeposit(address(token), ALICE, 100e18);
        col.setBorrow(address(token), ALICE, 100e18);
        assertTrue(col.isLiquidatable(address(token), ALICE));
    }

    // =========================================================================
    // maxLiquidatableDebt
    // =========================================================================

    function test_maxLiquidatableDebt_noBorrow_returnsZero() public view {
        assertEq(col.maxLiquidatableDebt(address(token), ALICE), 0);
    }

    function test_maxLiquidatableDebt_closeFactorBinding() public {
        // debt=1000, deposit large  →  byCloseFactor is the tighter ceiling
        uint256 debt = 1_000e18;
        uint256 dep  = 10_000e18;
        col.setDeposit(address(token), ALICE, dep);
        col.setBorrow(address(token), ALICE, debt);

        uint256 byCloseFactor = (debt * CLOSE) / BASIS;          // 500e18
        uint256 byDeposit     = (dep  * BASIS) / (BASIS + BONUS); // ~9523e18

        assertTrue(byCloseFactor < byDeposit, "expected CF to bind");
        assertEq(col.maxLiquidatableDebt(address(token), ALICE), byCloseFactor);
    }

    function test_maxLiquidatableDebt_depositBinding() public {
        // debt=10000, deposit small  →  byDeposit is the tighter ceiling
        uint256 debt = 10_000e18;
        uint256 dep  = 100e18;
        col.setDeposit(address(token), ALICE, dep);
        col.setBorrow(address(token), ALICE, debt);

        uint256 byCloseFactor = (debt * CLOSE) / BASIS;          // 5000e18
        uint256 byDeposit     = (dep  * BASIS) / (BASIS + BONUS); // ~95e18

        assertTrue(byDeposit < byCloseFactor, "expected deposit to bind");
        assertEq(col.maxLiquidatableDebt(address(token), ALICE), byDeposit);
    }

    function testFuzz_maxLiquidatableDebt_neverExceedsDebtOrDeposit(
        uint128 dep,
        uint128 debt
    ) public {
        vm.assume(debt > 0);
        col.setDeposit(address(token), ALICE, dep);
        col.setBorrow(address(token), ALICE, debt);

        uint256 max           = col.maxLiquidatableDebt(address(token), ALICE);
        uint256 seizedIfUsed  = (max * (BASIS + BONUS)) / BASIS;

        assertTrue(max <= uint256(debt),     "max > debt");
        assertTrue(seizedIfUsed <= uint256(dep), "seized would exceed deposit");
    }

    // =========================================================================
    // liquidate — happy paths
    // =========================================================================

    function test_liquidate_updatesState() public {
        uint256 dep  = 1_000e18;
        uint256 debt = 900e18;
        _setupUnhealthyPosition(dep, debt);

        uint256 repayAmount = 450e18; // == maxRepay (50 % of debt)
        uint256 seized      = _seized(repayAmount); // 472.5e18

        vm.prank(BOB);
        col.liquidate(address(token), ALICE, repayAmount);

        assertEq(col.borrows(address(token),  ALICE), debt - repayAmount);
        assertEq(col.deposits(address(token), ALICE), dep  - seized);
        assertEq(col.poolLiquidity(address(token)),   dep  + repayAmount - seized);
    }

    function test_liquidate_tokenBalances() public {
        uint256 dep  = 1_000e18;
        uint256 debt = 900e18;
        _setupUnhealthyPosition(dep, debt);

        uint256 repayAmount = 450e18;
        uint256 seized      = _seized(repayAmount);

        uint256 bobBefore  = token.balanceOf(BOB);
        uint256 poolBefore = token.balanceOf(address(col));

        vm.prank(BOB);
        col.liquidate(address(token), ALICE, repayAmount);

        assertEq(token.balanceOf(BOB),         bobBefore  - repayAmount + seized);
        assertEq(token.balanceOf(address(col)), poolBefore + repayAmount - seized);
    }

    function test_liquidate_emitsLiquidated() public {
        uint256 dep  = 1_000e18;
        uint256 debt = 900e18;
        _setupUnhealthyPosition(dep, debt);

        uint256 repayAmount = 450e18;
        uint256 seized      = _seized(repayAmount);

        vm.prank(BOB);
        vm.expectEmit(true, true, true, true);
        emit Liquidated(BOB, ALICE, address(token), repayAmount, seized);
        col.liquidate(address(token), ALICE, repayAmount);
    }

    function test_liquidate_partial_belowMaxRepay() public {
        uint256 dep  = 1_000e18;
        uint256 debt = 900e18;
        _setupUnhealthyPosition(dep, debt);

        uint256 repayAmount = 100e18; // well below the 450e18 ceiling
        uint256 seized      = _seized(repayAmount); // 105e18

        vm.prank(BOB);
        col.liquidate(address(token), ALICE, repayAmount);

        assertEq(col.borrows(address(token),  ALICE), debt - repayAmount);
        assertEq(col.deposits(address(token), ALICE), dep  - seized);
    }

    // =========================================================================
    // liquidate — revert cases
    // =========================================================================

    function test_liquidate_revert_zeroTokenAddress() public {
        vm.prank(BOB);
        vm.expectRevert(Collateral.ZeroAddress.selector);
        col.liquidate(address(0), ALICE, 1e18);
    }

    function test_liquidate_revert_zeroBorrowerAddress() public {
        vm.prank(BOB);
        vm.expectRevert(Collateral.ZeroAddress.selector);
        col.liquidate(address(token), address(0), 1e18);
    }

    function test_liquidate_revert_zeroRepayAmount() public {
        vm.prank(BOB);
        vm.expectRevert(Collateral.ZeroAmount.selector);
        col.liquidate(address(token), ALICE, 0);
    }

    function test_liquidate_revert_positionHealthy_noBorrow() public {
        // debt=0  →  HF = type(uint256).max  →  PositionHealthy fires before NoBorrowPosition
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(Collateral.PositionHealthy.selector, type(uint256).max)
        );
        col.liquidate(address(token), ALICE, 1e18);
    }

    function test_liquidate_revert_positionHealthy_overcollateralized() public {
        col.setDeposit(address(token), ALICE, 1_000e18);
        col.setBorrow(address(token), ALICE, 500e18); // HF = 1.5

        uint256 hf = col.healthFactor(address(token), ALICE);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(Collateral.PositionHealthy.selector, hf)
        );
        col.liquidate(address(token), ALICE, 100e18);
    }

    function test_liquidate_revert_positionHealthy_exactlyAtThreshold() public {
        // HF == 1.0: not liquidatable (strict less-than required)
        col.setDeposit(address(token), ALICE, 10_000e18);
        col.setBorrow(address(token), ALICE, 7_500e18);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(Collateral.PositionHealthy.selector, PRECISION)
        );
        col.liquidate(address(token), ALICE, 100e18);
    }

    function test_liquidate_revert_exceedsCloseFactor() public {
        uint256 dep  = 1_000e18;
        uint256 debt = 900e18;
        _setupUnhealthyPosition(dep, debt);

        uint256 maxRepay = (debt * CLOSE) / BASIS; // 450e18
        uint256 over     = maxRepay + 1;

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(Collateral.ExceedsCloseFactor.selector, maxRepay, over)
        );
        col.liquidate(address(token), ALICE, over);
    }

    function test_liquidate_revert_borrowerCollateralInsufficient() public {
        // dep=100, debt=200  →  HF=0.375, maxRepay=100, seized=105 > dep
        uint256 dep  = 100e18;
        uint256 debt = 200e18;
        col.setDeposit(address(token), ALICE, dep);
        col.setBorrow(address(token), ALICE, debt);
        col.setPoolLiquidity(address(token), 1_000e18); // large pool so step 6 won't fire
        token.mint(address(col), 1_000e18);

        uint256 repayAmount = 100e18; // == maxRepay
        uint256 seized      = _seized(repayAmount); // 105e18 > dep

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(Collateral.BorrowerCollateralInsufficient.selector, dep, seized)
        );
        col.liquidate(address(token), ALICE, repayAmount);
    }

    function test_liquidate_revert_poolLiquidityInsufficient() public {
        uint256 dep  = 1_000e18;
        uint256 debt = 900e18;
        col.setDeposit(address(token), ALICE, dep);
        col.setBorrow(address(token), ALICE, debt);

        uint256 repayAmount   = 100e18;
        uint256 seized        = _seized(repayAmount); // 105e18
        uint256 lowLiquidity  = 50e18;                // < 105e18

        col.setPoolLiquidity(address(token), lowLiquidity);
        token.mint(address(col), lowLiquidity);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                Collateral.PoolLiquidityInsufficient.selector,
                lowLiquidity,
                seized
            )
        );
        col.liquidate(address(token), ALICE, repayAmount);
    }

    // =========================================================================
    // Fuzz: liquidate invariants
    // =========================================================================

    function testFuzz_liquidate_stateConsistency(
        uint64 dep,
        uint64 debt,
        uint64 repayAmount
    ) public {
        // Force HF < 1.0: dep * CF < debt * BASIS
        vm.assume(dep > 0 && debt > 0);
        vm.assume(uint256(dep) * CF < uint256(debt) * BASIS);
        vm.assume(repayAmount > 0);

        uint256 maxRepay = (uint256(debt) * CLOSE) / BASIS;
        vm.assume(uint256(repayAmount) <= maxRepay);

        uint256 seized = _seized(repayAmount);
        vm.assume(seized <= dep);           // deposit covers seized collateral
        vm.assume(seized <= type(uint64).max); // sanity: no overflow

        col.setDeposit(address(token), ALICE, dep);
        col.setBorrow(address(token), ALICE, debt);
        col.setPoolLiquidity(address(token), dep);
        token.mint(address(col), dep);

        token.mint(BOB, repayAmount); // top up liquidator for this run

        uint256 poolLiqBefore = col.poolLiquidity(address(token));

        vm.prank(BOB);
        col.liquidate(address(token), ALICE, repayAmount);

        assertEq(col.borrows(address(token),  ALICE), uint256(debt) - repayAmount);
        assertEq(col.deposits(address(token), ALICE), uint256(dep)  - seized);
        assertEq(col.poolLiquidity(address(token)),   poolLiqBefore + repayAmount - seized);
    }
}
