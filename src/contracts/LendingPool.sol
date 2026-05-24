// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
contract LendingPool {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Fraction of a user's deposit they may borrow, in basis points.
    uint256 public constant COLLATERAL_FACTOR = 7_500; // 75 %
    uint256 private constant _BASIS = 10_000;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Tokens deposited per user per asset.
    /// @dev    deposits[token][user]
    mapping(address => mapping(address => uint256)) public deposits;

    /// @notice Tokens borrowed per user per asset.
    /// @dev    borrows[token][user]
    mapping(address => mapping(address => uint256)) public borrows;

    /// @notice Net token balance held by the pool for each asset.
    /// @dev    Increases on deposit/repay; decreases on withdraw/borrow.
    mapping(address => uint256) public poolLiquidity;

    /// @dev Two-state reentrancy lock (1 = unlocked, 2 = locked).
    uint256 private _locked = 1;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a user deposits tokens into the pool.
     * @param user   Depositor address.
     * @param token  ERC-20 asset deposited.
     * @param amount Amount deposited.
     */
    event Deposited(address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a user borrows tokens from the pool.
     * @param user   Borrower address.
     * @param token  ERC-20 asset borrowed.
     * @param amount Amount borrowed.
     */
    event Borrowed(address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a user repays part or all of their outstanding debt.
     * @param user      Repayer address.
     * @param token     ERC-20 asset repaid.
     * @param amount    Amount repaid in this transaction.
     * @param remaining Debt balance still outstanding after repayment.
     */
    event Repaid(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 remaining
    );

    /**
     * @notice Emitted when a user withdraws previously deposited tokens.
     * @param user   Withdrawer address.
     * @param token  ERC-20 asset withdrawn.
     * @param amount Amount withdrawn.
     */
    event Withdrawn(address indexed user, address indexed token, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Token or recipient address is the zero address.
    error ZeroAddress();

    /// @notice Amount argument is zero.
    error ZeroAmount();

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

    /// @notice Low-level ERC-20 transfer call failed or returned false.
    error TransferFailed();

    /// @notice Call entered a function protected by nonReentrant while locked.
    error Reentrancy();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

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
     *         Cross-asset collateral requires an oracle integration (future work).
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

        // Cap to actual debt so callers can use type(uint256).max for full repayment
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

        // Minimum deposit required to keep active borrows within collateral factor.
        // Uses ceiling division so rounding never allows an under-collateralised state.
        uint256 debt = borrows[token][msg.sender];
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

    // -------------------------------------------------------------------------
    // Internal: safe ERC-20 wrappers
    // -------------------------------------------------------------------------

    /**
     * @dev Low-level transferFrom that handles both bool-returning (standard)
     *      and non-returning (e.g. USDT) ERC-20 implementations.
     */
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /**
     * @dev Low-level transfer that handles both bool-returning and
     *      non-returning ERC-20 implementations.
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
