// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/contracts/LendingPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract LendingPoolTest is Test {
    // Redeclared here so vm.expectEmit can use them as templates
    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, address indexed token, uint256 amount);
    event Repaid(address indexed user, address indexed token, uint256 amount, uint256 remaining);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);

    LendingPool public pool;
    MockERC20 public token;

    address public constant ALICE = address(0xA11CE);
    address public constant BOB = address(0xB0B);

    uint256 public constant DEPOSIT = 1_000e18;
    // 75 % of DEPOSIT
    uint256 public constant MAX_BORROW = 750e18;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        pool = new LendingPool();
        token = new MockERC20("Test Token", "TST", 18);

        // Give Alice and Bob tokens and pre-approve the pool
        token.mint(ALICE, 10_000e18);
        token.mint(BOB, 10_000e18);

        vm.prank(ALICE);
        token.approve(address(pool), type(uint256).max);

        vm.prank(BOB);
        token.approve(address(pool), type(uint256).max);
    }

    // =========================================================================
    // deposit
    // =========================================================================

    function test_deposit_updatesState() public {
        vm.prank(ALICE);
        pool.deposit(address(token), DEPOSIT);

        assertEq(pool.deposits(address(token), ALICE), DEPOSIT);
        assertEq(pool.poolLiquidity(address(token)), DEPOSIT);
        assertEq(token.balanceOf(address(pool)), DEPOSIT);
    }

    function test_deposit_emitsDeposited() public {
        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit Deposited(ALICE, address(token), DEPOSIT);
        pool.deposit(address(token), DEPOSIT);
    }

    function test_deposit_accumulates() public {
        vm.startPrank(ALICE);
        pool.deposit(address(token), DEPOSIT);
        pool.deposit(address(token), DEPOSIT);
        vm.stopPrank();

        assertEq(pool.deposits(address(token), ALICE), DEPOSIT * 2);
    }

    function test_deposit_revert_zeroAddress() public {
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.ZeroAddress.selector);
        pool.deposit(address(0), DEPOSIT);
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.deposit(address(token), 0);
    }

    // =========================================================================
    // borrow
    // =========================================================================

    function test_borrow_upToCollateralFactor() public {
        _deposit(ALICE, DEPOSIT);

        vm.prank(ALICE);
        pool.borrow(address(token), MAX_BORROW);

        assertEq(pool.borrows(address(token), ALICE), MAX_BORROW);
        assertEq(pool.poolLiquidity(address(token)), DEPOSIT - MAX_BORROW);
        assertEq(token.balanceOf(ALICE), 10_000e18 - DEPOSIT + MAX_BORROW);
    }

    function test_borrow_partial() public {
        _deposit(ALICE, DEPOSIT);

        uint256 partialBorrow = 500e18;
        vm.prank(ALICE);
        pool.borrow(address(token), partialBorrow);

        assertEq(pool.borrows(address(token), ALICE), partialBorrow);
    }

    function test_borrow_emitsBorrowed() public {
        _deposit(ALICE, DEPOSIT);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit Borrowed(ALICE, address(token), MAX_BORROW);
        pool.borrow(address(token), MAX_BORROW);
    }

    function test_borrow_multiplePartialBorrows() public {
        _deposit(ALICE, DEPOSIT);

        vm.startPrank(ALICE);
        pool.borrow(address(token), 300e18);
        pool.borrow(address(token), 450e18); // total = 750 = MAX_BORROW
        vm.stopPrank();

        assertEq(pool.borrows(address(token), ALICE), MAX_BORROW);
    }

    function test_borrow_revert_zeroAddress() public {
        _deposit(ALICE, DEPOSIT);
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.ZeroAddress.selector);
        pool.borrow(address(0), 100e18);
    }

    function test_borrow_revert_zeroAmount() public {
        _deposit(ALICE, DEPOSIT);
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.borrow(address(token), 0);
    }

    function test_borrow_revert_exceedsCollateral() public {
        _deposit(ALICE, DEPOSIT);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.ExceedsCollateral.selector, MAX_BORROW, MAX_BORROW + 1)
        );
        pool.borrow(address(token), MAX_BORROW + 1);
    }

    function test_borrow_revert_exceedsCollateral_noDeposit() public {
        // BOB has no deposit — borrowable = 0
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.ExceedsCollateral.selector, 0, 1e18)
        );
        pool.borrow(address(token), 1e18);
    }

    function test_borrow_revert_insufficientLiquidity() public {
        // Alice deposits a small amount; Bob deposits less so pool has 1e18
        _deposit(ALICE, DEPOSIT);

        // Drain pool liquidity: Alice borrows MAX_BORROW (750), leaving 250
        vm.prank(ALICE);
        pool.borrow(address(token), MAX_BORROW);

        // Bob deposits 400, giving Bob a collateral ceiling of 300
        // Pool liquidity: 250 + 400 = 650. Bob borrows 300 — that's fine.
        // For InsufficientLiquidity we need Bob's ceiling > pool balance.
        // Deposit 1000 gives Bob a ceiling of 750.
        // Drain pool first: have Alice borrow all she can.
        // Simplest: use a fresh pool state via a helper approach.
        // Instead, let's just test the error with a direct manipulation.

        // Teleport pool liquidity to near-zero using vm.store
        // poolLiquidity slot: slot 2 (deposits=0, borrows=1, poolLiquidity=2)
        bytes32 liquiditySlot = _tokenMappingSlot(2, address(token));
        vm.store(address(pool), liquiditySlot, bytes32(uint256(10e18)));

        // Bob needs a deposit of at least 1e18/0.75 ≈ 13.34e18 to borrow 10e18+1
        // Give Bob a large fake deposit via vm.store
        bytes32 bobDepositSlot = _userMappingSlot(0, address(token), BOB);
        vm.store(address(pool), bobDepositSlot, bytes32(uint256(100e18)));

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 10e18, 11e18)
        );
        pool.borrow(address(token), 11e18);
    }

    // =========================================================================
    // repay
    // =========================================================================

    function test_repay_full() public {
        _depositAndBorrow(ALICE, DEPOSIT, MAX_BORROW);

        vm.prank(ALICE);
        pool.repay(address(token), MAX_BORROW);

        assertEq(pool.borrows(address(token), ALICE), 0);
        assertEq(pool.poolLiquidity(address(token)), DEPOSIT);
    }

    function test_repay_partial() public {
        _depositAndBorrow(ALICE, DEPOSIT, MAX_BORROW);

        vm.prank(ALICE);
        pool.repay(address(token), 250e18);

        assertEq(pool.borrows(address(token), ALICE), MAX_BORROW - 250e18);
        assertEq(pool.poolLiquidity(address(token)), DEPOSIT - MAX_BORROW + 250e18);
    }

    function test_repay_maxUint256_capped_toDebt() public {
        _depositAndBorrow(ALICE, DEPOSIT, MAX_BORROW);

        vm.prank(ALICE);
        pool.repay(address(token), type(uint256).max);

        // Debt fully cleared; no over-transfer
        assertEq(pool.borrows(address(token), ALICE), 0);
    }

    function test_repay_emitsRepaid() public {
        _depositAndBorrow(ALICE, DEPOSIT, MAX_BORROW);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit Repaid(ALICE, address(token), MAX_BORROW, 0);
        pool.repay(address(token), MAX_BORROW);
    }

    function test_repay_emitsRepaid_partial() public {
        _depositAndBorrow(ALICE, DEPOSIT, MAX_BORROW);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit Repaid(ALICE, address(token), 100e18, MAX_BORROW - 100e18);
        pool.repay(address(token), 100e18);
    }

    function test_repay_revert_zeroAddress() public {
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.ZeroAddress.selector);
        pool.repay(address(0), 1e18);
    }

    function test_repay_revert_zeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.repay(address(token), 0);
    }

    function test_repay_revert_nothingToRepay() public {
        // Alice has no borrow
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.NothingToRepay.selector);
        pool.repay(address(token), 1e18);
    }

    // =========================================================================
    // withdraw
    // =========================================================================

    function test_withdraw_full_noBorrows() public {
        _deposit(ALICE, DEPOSIT);
        uint256 balBefore = token.balanceOf(ALICE);

        vm.prank(ALICE);
        pool.withdraw(address(token), DEPOSIT);

        assertEq(pool.deposits(address(token), ALICE), 0);
        assertEq(pool.poolLiquidity(address(token)), 0);
        assertEq(token.balanceOf(ALICE), balBefore + DEPOSIT);
    }

    function test_withdraw_partial_noBorrows() public {
        _deposit(ALICE, DEPOSIT);

        vm.prank(ALICE);
        pool.withdraw(address(token), 400e18);

        assertEq(pool.deposits(address(token), ALICE), DEPOSIT - 400e18);
        assertEq(pool.poolLiquidity(address(token)), DEPOSIT - 400e18);
    }

    function test_withdraw_afterRepay_canWithdrawAll() public {
        _depositAndBorrow(ALICE, DEPOSIT, MAX_BORROW);

        // Repay in full
        vm.prank(ALICE);
        pool.repay(address(token), MAX_BORROW);

        // Now full deposit is free
        vm.prank(ALICE);
        pool.withdraw(address(token), DEPOSIT);

        assertEq(pool.deposits(address(token), ALICE), 0);
    }

    function test_withdraw_emitsWithdrawn() public {
        _deposit(ALICE, DEPOSIT);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(ALICE, address(token), DEPOSIT);
        pool.withdraw(address(token), DEPOSIT);
    }

    function test_withdraw_maxAllowedWhileBorrowed() public {
        _depositAndBorrow(ALICE, DEPOSIT, MAX_BORROW);
        // minDeposit = ceil(750e18 * 10000 / 7500) = 1000e18
        // maxWithdraw = 1000 - 1000 = 0
        // Borrow the exact ceiling, so nothing can be withdrawn

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.ExceedsCollateral.selector, 0, 1)
        );
        pool.withdraw(address(token), 1);
    }

    function test_withdraw_partialFreeCollateral() public {
        _deposit(ALICE, DEPOSIT);
        // Borrow 500 (< 750 max). minDeposit = ceil(500e18 * 10000 / 7500) = 666.67e18 → 666666...667
        uint256 borrowed = 500e18;
        vm.prank(ALICE);
        pool.borrow(address(token), borrowed);

        // minDeposit (ceiling div) = (500e18 * 10000 + 7499) / 7500
        uint256 minDeposit = (borrowed * 10_000 + 7_500 - 1) / 7_500;
        uint256 maxWithdraw = DEPOSIT - minDeposit;

        vm.prank(ALICE);
        pool.withdraw(address(token), maxWithdraw); // should succeed

        assertEq(pool.deposits(address(token), ALICE), DEPOSIT - maxWithdraw);
    }

    function test_withdraw_revert_zeroAddress() public {
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.ZeroAddress.selector);
        pool.withdraw(address(0), 1e18);
    }

    function test_withdraw_revert_zeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.withdraw(address(token), 0);
    }

    function test_withdraw_revert_insufficientDeposit() public {
        _deposit(ALICE, DEPOSIT);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.InsufficientDeposit.selector, DEPOSIT, DEPOSIT + 1)
        );
        pool.withdraw(address(token), DEPOSIT + 1);
    }

    function test_withdraw_revert_exceedsCollateral_activeBorrow() public {
        _depositAndBorrow(ALICE, DEPOSIT, MAX_BORROW);

        // minDeposit = ceil(750 * 10000 / 7500) = 1000; maxWithdraw = 0
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(LendingPool.ExceedsCollateral.selector, 0, 1e18)
        );
        pool.withdraw(address(token), 1e18);
    }

    // =========================================================================
    // Multi-user isolation
    // =========================================================================

    function test_multiUser_depositsAreIsolated() public {
        _deposit(ALICE, DEPOSIT);
        _deposit(BOB, 500e18);

        assertEq(pool.deposits(address(token), ALICE), DEPOSIT);
        assertEq(pool.deposits(address(token), BOB), 500e18);
        assertEq(pool.poolLiquidity(address(token)), DEPOSIT + 500e18);
    }

    function test_multiUser_borrowsAreIsolated() public {
        _deposit(ALICE, DEPOSIT);
        _deposit(BOB, DEPOSIT);

        vm.prank(ALICE);
        pool.borrow(address(token), MAX_BORROW);

        // Bob's borrow capacity is unaffected by Alice's debt
        assertEq(pool.borrows(address(token), BOB), 0);
        vm.prank(BOB);
        pool.borrow(address(token), MAX_BORROW); // should succeed
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_deposit_withdraw_roundtrip(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 10_000e18);

        vm.prank(ALICE);
        pool.deposit(address(token), amount);

        vm.prank(ALICE);
        pool.withdraw(address(token), amount);

        assertEq(pool.deposits(address(token), ALICE), 0);
        assertEq(pool.poolLiquidity(address(token)), 0);
    }

    function testFuzz_borrow_never_exceeds_collateral(uint256 depositAmt, uint256 borrowAmt) public {
        vm.assume(depositAmt > 0 && depositAmt <= 10_000e18);
        vm.assume(borrowAmt > 0);

        _deposit(ALICE, depositAmt);

        uint256 ceiling = (depositAmt * 7_500) / 10_000;

        if (borrowAmt > ceiling) {
            vm.prank(ALICE);
            vm.expectRevert();
            pool.borrow(address(token), borrowAmt);
        } else {
            vm.prank(ALICE);
            pool.borrow(address(token), borrowAmt);
            assertEq(pool.borrows(address(token), ALICE), borrowAmt);
        }
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        pool.deposit(address(token), amount);
    }

    function _depositAndBorrow(address user, uint256 depositAmt, uint256 borrowAmt) internal {
        _deposit(user, depositAmt);
        vm.prank(user);
        pool.borrow(address(token), borrowAmt);
    }

    /// @dev Compute storage slot for a single-key mapping at `mapSlot` keyed by `key`.
    function _tokenMappingSlot(uint256 mapSlot, address key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, mapSlot));
    }

    /// @dev Compute storage slot for a nested mapping at `mapSlot` keyed by [token][user].
    function _userMappingSlot(
        uint256 mapSlot,
        address token_,
        address user
    ) internal pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(token_, mapSlot));
        return keccak256(abi.encode(user, inner));
    }
}
