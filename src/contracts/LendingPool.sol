// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Collateral} from "./Collateral.sol";

/**
 * @title LendingPool
 * @notice Single-asset lending pool supporting deposit, borrow, repay, and
 *         withdraw. Each token market is independent: a user's deposit in a
 *         given token serves as collateral for borrowing that same token.
 *
 * @dev Collateral factor is fixed at 75 % (7 500 bps). Interest accrual and
 *      oracle-based cross-asset collateral are out of scope for this stub —
 *      extend via an `InterestRateModel` and a `PriceOracle` interface.
 *
 *      Re-entrancy is guarded with a two-state lock. Token transfers use
 *      low-level calls to handle both returning and non-returning ERC-20s
 *      (e.g. USDT on mainnet).
 */
contract LendingPool is Collateral {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a user deposits tokens into the pool.
    event Deposited(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when a user borrows tokens from the pool.
    event Borrowed(address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a user repays part or all of their outstanding debt.
     * @param remaining Debt balance still outstanding after repayment.
     */
    event Repaid(address indexed user, address indexed token, uint256 amount, uint256 remaining);

    /// @notice Emitted when a user withdraws previously deposited tokens.
    event Withdrawn(address indexed user, address indexed token, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Requested withdrawal exceeds the user's recorded deposit.
    error InsufficientDeposit(uint256 available, uint256 requested);

    /// @notice Pool does not hold enough of the token to fulfil the request.
    error InsufficientLiquidity(uint256 available, uint256 requested);

    /**
     * @notice Borrow or withdrawal would violate the collateral factor.
     * @param maxAllowed Maximum amount permitted without breaching the factor.
     * @param requested  Amount the user attempted.
     */
    error ExceedsCollateral(uint256 maxAllowed, uint256 requested);

    /// @notice Repay called but the caller has no outstanding debt for this token.
    error NothingToRepay();

    // -------------------------------------------------------------------------
    // External: core actions
    // -------------------------------------------------------------------------

    /**
     * @notice Deposit `amount` of `token` into the pool.
     * @dev    Caller must have approved this contract for at least `amount`
     *         before calling. The deposit immediately counts as collateral.
     * @param token  ERC-20 token to deposit.
     * @param amount Amount to deposit (in the token's smallest unit).
     */
    function deposit(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _safeTransferFrom(token, msg.sender, address(this), amount);

        deposits[token][msg.sender] += amount;
        poolLiquidity[token] += amount;

        emit Deposited(msg.sender, token, amount);
    }

    /**
     * @notice Borrow `amount` of `token` against the caller's existing deposit.
     * @dev    Borrow ceiling = COLLATERAL_FACTOR * deposits[token][caller] / BASIS.
     *         Single-asset model: only the same token can be used as collateral.
     * @param token  ERC-20 token to borrow.
     * @param amount Amount to borrow.
     */
    function borrow(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 ceiling = (deposits[token][msg.sender] * COLLATERAL_FACTOR) / _BASIS;
        uint256 alreadyBorrowed = borrows[token][msg.sender];
        uint256 borrowable = alreadyBorrowed >= ceiling ? 0 : ceiling - alreadyBorrowed;
        if (amount > borrowable) revert ExceedsCollateral(borrowable, amount);

        uint256 liquidity = poolLiquidity[token];
        if (amount > liquidity) revert InsufficientLiquidity(liquidity, amount);

        borrows[token][msg.sender] = alreadyBorrowed + amount;
        poolLiquidity[token] = liquidity - amount;

        _safeTransfer(token, msg.sender, amount);

        emit Borrowed(msg.sender, token, amount);
    }

    /**
     * @notice Repay up to `amount` towards the caller's outstanding debt.
     * @dev    Over-payment is silently capped at the actual debt balance so
     *         callers can pass `type(uint256).max` to repay in full.
     * @param token  ERC-20 token to repay.
     * @param amount Amount to repay; capped at outstanding debt.
     */
    function repay(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 outstanding = borrows[token][msg.sender];
        if (outstanding == 0) revert NothingToRepay();

        uint256 repayAmount = amount > outstanding ? outstanding : amount;

        _safeTransferFrom(token, msg.sender, address(this), repayAmount);

        uint256 newDebt = outstanding - repayAmount;
        borrows[token][msg.sender] = newDebt;
        poolLiquidity[token] += repayAmount;

        emit Repaid(msg.sender, token, repayAmount, newDebt);
    }

    /**
     * @notice Withdraw `amount` of a previously deposited token.
     * @dev    Withdrawal is blocked if removing the amount would leave the
     *         caller's remaining deposit unable to cover their active borrows.
     * @param token  ERC-20 token to withdraw.
     * @param amount Amount to withdraw.
     */
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 deposited = deposits[token][msg.sender];
        if (amount > deposited) revert InsufficientDeposit(deposited, amount);

        uint256 debt = borrows[token][msg.sender];
        // Ceiling division so rounding never allows an under-collateralised state.
        uint256 minDeposit = debt == 0 ? 0 : (debt * _BASIS + COLLATERAL_FACTOR - 1) / COLLATERAL_FACTOR;

        uint256 maxWithdraw = minDeposit >= deposited ? 0 : deposited - minDeposit;
        if (amount > maxWithdraw) revert ExceedsCollateral(maxWithdraw, amount);

        uint256 liquidity = poolLiquidity[token];
        if (amount > liquidity) revert InsufficientLiquidity(liquidity, amount);

        deposits[token][msg.sender] = deposited - amount;
        poolLiquidity[token] = liquidity - amount;

        _safeTransfer(token, msg.sender, amount);

        emit Withdrawn(msg.sender, token, amount);
    }
}
