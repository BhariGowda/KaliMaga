// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Collateral
 * @notice Abstract base contract providing health-factor accounting and
 *         liquidation logic for the LendingPool.
 *
 * @dev    Inherit this contract in LendingPool:
 *
 *             contract LendingPool is Collateral { ... }
 *
 *         When doing so, remove the duplicate declarations of `deposits`,
 *         `borrows`, `poolLiquidity`, `_locked`, `nonReentrant`,
 *         `TransferFailed`, `Reentrancy`, `ZeroAddress`, `ZeroAmount`,
 *         `_safeTransfer`, and `_safeTransferFrom` — they are provided here.
 *
 *         Health factor formula (single-asset, oracle-free model):
 *
 *             HF = (deposits[token][user] × COLLATERAL_FACTOR / BASIS)
 *                  ────────────────────────────────────────────────────  × 1e18
 *                               borrows[token][user]
 *
 *         A position is liquidatable when HF < HEALTH_FACTOR_PRECISION (< 1.0).
 *
 *         In the current single-asset model, under normal operations a position
 *         can never become unhealthy because LendingPool enforces the collateral
 *         ceiling at borrow and withdraw time. This contract is forward-looking:
 *         it becomes exercisable once interest accrual or an oracle integration
 *         is added to LendingPool.
 */
abstract contract Collateral {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Fraction of a deposit that may back borrows, in basis points.
    uint256 public constant COLLATERAL_FACTOR = 7_500; // 75 % — mirrors LendingPool

    /// @notice Premium granted to liquidators on top of the repaid debt, in bps.
    uint256 public constant LIQUIDATION_BONUS = 500; // 5 %

    /// @notice Maximum share of a borrower's debt repayable in one liquidation call, in bps.
    uint256 public constant CLOSE_FACTOR = 5_000; // 50 %

    uint256 internal constant _BASIS = 10_000;

    /// @notice Scaling factor for health factor values (represents 1.0).
    uint256 public constant HEALTH_FACTOR_PRECISION = 1e18;

    // -------------------------------------------------------------------------
    // Storage  (shared with the inheriting LendingPool — do NOT redeclare)
    // -------------------------------------------------------------------------

    /// @notice Tokens deposited per user per asset.
    /// @dev deposits[token][user]
    mapping(address => mapping(address => uint256)) public deposits;

    /// @notice Tokens borrowed per user per asset.
    /// @dev borrows[token][user]
    mapping(address => mapping(address => uint256)) public borrows;

    /// @notice Net token balance physically held by the pool for each asset.
    mapping(address => uint256) public poolLiquidity;

    /// @dev Two-state reentrancy lock (1 = unlocked, 2 = locked).
    uint256 private _locked = 1;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when an undercollateralised position is liquidated.
     * @param liquidator       Caller that repaid the debt.
     * @param borrower         Account whose position was liquidated.
     * @param token            ERC-20 asset market.
     * @param debtRepaid       Amount of debt extinguished by the liquidator.
     * @param collateralSeized Collateral tokens transferred to the liquidator.
     */
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed token,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /**
     * @notice Liquidation attempted on a position whose health factor is >= 1.
     * @param currentHealthFactor The position's health factor at the time of the call.
     */
    error PositionHealthy(uint256 currentHealthFactor);

    /// @notice Borrower carries no outstanding debt for this token.
    error NoBorrowPosition();

    /**
     * @notice Requested repay amount exceeds the close-factor ceiling.
     * @param maxRepay  Maximum amount repayable in this call.
     * @param requested Amount the liquidator attempted.
     */
    error ExceedsCloseFactor(uint256 maxRepay, uint256 requested);

    /**
     * @notice Borrower's recorded deposit is smaller than the collateral to be seized.
     *         Use a smaller `repayAmount`.
     * @param available Borrower's deposit balance.
     * @param required  Collateral amount that would be seized.
     */
    error BorrowerCollateralInsufficient(uint256 available, uint256 required);

    /**
     * @notice Pool does not hold enough tokens to pay out the seized collateral.
     *         This can occur when a large share of the pool's deposits is already
     *         lent out to other borrowers.
     * @param available Pool's current liquid balance.
     * @param required  Collateral amount that would be sent to the liquidator.
     */
    error PoolLiquidityInsufficient(uint256 available, uint256 required);

    /// @notice Token or address argument is the zero address.
    error ZeroAddress();

    /// @notice Numeric argument is zero.
    error ZeroAmount();

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
    // Views: health factor
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the health factor for `user`'s position in `token`,
     *         scaled by HEALTH_FACTOR_PRECISION (1e18).
     *
     * @dev    Returns type(uint256).max when the user carries no debt.
     *         A value strictly below 1e18 means the position is liquidatable.
     *
     * @param token ERC-20 asset.
     * @param user  Position owner.
     * @return hf   Health factor (1e18 == 1.0).
     */
    function healthFactor(address token, address user) public view returns (uint256 hf) {
        uint256 debt = borrows[token][user];
        if (debt == 0) return type(uint256).max;
        // (deposit × CF × 1e18) / (BASIS × debt)
        return (deposits[token][user] * COLLATERAL_FACTOR * HEALTH_FACTOR_PRECISION) / (_BASIS * debt);
    }

    /**
     * @notice Returns true when `user`'s position in `token` can be liquidated.
     * @param token ERC-20 asset.
     * @param user  Position owner.
     */
    function isLiquidatable(address token, address user) public view returns (bool) {
        return healthFactor(token, user) < HEALTH_FACTOR_PRECISION;
    }

    /**
     * @notice Maximum debt the liquidator may repay in a single call,
     *         constrained by both the close factor and the borrower's deposit.
     *
     * @dev    The tighter of two ceilings:
     *           (a) CLOSE_FACTOR × total debt
     *           (b) largest repayAmount for which the seized collateral fits
     *               within the borrower's deposit:
     *                   repay ≤ deposits[token][borrower] × BASIS
     *                           ─────────────────────────────────
     *                              (BASIS + LIQUIDATION_BONUS)
     *
     * @param token    ERC-20 asset.
     * @param borrower Borrower address.
     * @return         Maximum repayable amount.
     */
    function maxLiquidatableDebt(address token, address borrower) public view returns (uint256) {
        uint256 debt = borrows[token][borrower];
        if (debt == 0) return 0;

        uint256 byCloseFactor = (debt * CLOSE_FACTOR) / _BASIS;

        // Max repayAmount such that seizedCollateral ≤ borrower's deposit.
        uint256 dep = deposits[token][borrower];
        uint256 byDeposit = (dep * _BASIS) / (_BASIS + LIQUIDATION_BONUS);

        return byCloseFactor < byDeposit ? byCloseFactor : byDeposit;
    }

    // -------------------------------------------------------------------------
    // Liquidation
    // -------------------------------------------------------------------------

    /**
     * @notice Liquidate an undercollateralised position.
     *
     * @dev    The caller (liquidator) repays up to `CLOSE_FACTOR` of the
     *         borrower's outstanding debt and receives seized collateral at a
     *         `LIQUIDATION_BONUS` premium.  The liquidator must have pre-
     *         approved this contract for at least `repayAmount` of `token`.
     *
     *         Seized collateral:
     *             seizedCollateral = repayAmount × (BASIS + LIQUIDATION_BONUS) / BASIS
     *
     *         Reverts when:
     *           • HF ≥ 1  (position is healthy)
     *           • no borrow position exists
     *           • repayAmount exceeds the close-factor ceiling
     *           • seized collateral would exceed the borrower's deposit balance
     *           • the pool lacks sufficient liquid tokens to pay the liquidator
     *
     *         Use `maxLiquidatableDebt` to calculate a safe `repayAmount`
     *         off-chain before calling.
     *
     * @param token        ERC-20 asset market to liquidate.
     * @param borrower     Account whose position will be partially closed.
     * @param repayAmount  Amount of debt the liquidator repays on the borrower's behalf.
     */
    function liquidate(
        address token,
        address borrower,
        uint256 repayAmount
    ) external nonReentrant {
        if (token == address(0) || borrower == address(0)) revert ZeroAddress();
        if (repayAmount == 0) revert ZeroAmount();

        // 1. Position must be unhealthy.
        uint256 hf = healthFactor(token, borrower);
        if (hf >= HEALTH_FACTOR_PRECISION) revert PositionHealthy(hf);

        // 2. Borrower must have an outstanding debt.
        uint256 debt = borrows[token][borrower];
        if (debt == 0) revert NoBorrowPosition();

        // 3. Close-factor ceiling.
        uint256 maxRepay = (debt * CLOSE_FACTOR) / _BASIS;
        if (repayAmount > maxRepay) revert ExceedsCloseFactor(maxRepay, repayAmount);

        // 4. Collateral seized = repaid principal + liquidation bonus.
        uint256 seizedCollateral = (repayAmount * (_BASIS + LIQUIDATION_BONUS)) / _BASIS;

        // 5. Seized amount must not exceed the borrower's recorded deposit.
        uint256 borrowerDeposit = deposits[token][borrower];
        if (seizedCollateral > borrowerDeposit)
            revert BorrowerCollateralInsufficient(borrowerDeposit, seizedCollateral);

        // 6. Pool must physically hold enough tokens (others may have borrowed them).
        uint256 liquidity = poolLiquidity[token];
        if (seizedCollateral > liquidity)
            revert PoolLiquidityInsufficient(liquidity, seizedCollateral);

        // 7. CEI: update all state before any external token calls.
        borrows[token][borrower]  -= repayAmount;
        deposits[token][borrower] -= seizedCollateral;
        // Net pool balance: +repayAmount (debt inflow) – seizedCollateral (collateral outflow).
        poolLiquidity[token] = liquidity + repayAmount - seizedCollateral;

        // 8. Token movements: liquidator sends debt tokens, receives seized collateral.
        _safeTransferFrom(token, msg.sender, address(this), repayAmount);
        _safeTransfer(token, msg.sender, seizedCollateral);

        emit Liquidated(msg.sender, borrower, token, repayAmount, seizedCollateral);
    }

    // -------------------------------------------------------------------------
    // Internal: safe ERC-20 wrappers
    // -------------------------------------------------------------------------

    /**
     * @dev Low-level transferFrom compatible with both bool-returning (ERC-20
     *      standard) and non-returning (e.g. USDT on mainnet) implementations.
     */
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal virtual {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /**
     * @dev Low-level transfer compatible with both bool-returning and
     *      non-returning ERC-20 implementations.
     */
    function _safeTransfer(address token, address to, uint256 amount) internal virtual {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
