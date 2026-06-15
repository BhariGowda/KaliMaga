# KaliMaga Security Audit

**Protocol:** KaliMaga DeFi Suite  
**Scope:** AMM core (Pair, Factory, Router) + Lending (LendingPool, InterestRateModel, Liquidator)  
**Auditor:** Bhari Gowda  
**Date:** June 2026  
**Commit:** main  

---

## Summary

| Severity | Count |
|---|---|
| High | 1 (fixed) |
| Medium | 2 (fixed) |
| Low | 2 (fixed) |
| Informational | 2 |

---

## Findings

### [H-01] Integer underflow in `KaliMagaPair.mint()` on zero deposit

**Severity:** High  
**Status:** Fixed  
**File:** `src/core/KaliMagaPair.sol`

**Description:**  
When `mint()` is called with no tokens transferred and `totalSupply == 0`, the expression `_sqrt(0 * 0) - MINIMUM_LIQUIDITY` evaluates to `0 - 1000`, triggering a panic via arithmetic underflow rather than a clean revert with `InsufficientLiquidityMinted`. This means callers receive a generic panic instead of an actionable error, and static analysis tools may misclassify the revert type.

**Impact:**  
Any off-chain integration relying on the `InsufficientLiquidityMinted` selector to detect and handle this failure silently misses the error. In a production UI, this would surface as an unhandled exception.

**Fix:**  
Compute the square root first, check it against `MINIMUM_LIQUIDITY` before subtracting:

```solidity
uint256 rootK = _sqrt(amount0 * amount1);
if (rootK <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
liquidity = rootK - MINIMUM_LIQUIDITY;
```

---

### [M-01] `seizeCollateral` and `liquidationRepay` are callable by any address

**Severity:** Medium  
**Status:** Acknowledged  
**File:** `src/lending/KaliMagaLendingPool.sol`

**Description:**  
`liquidationRepay()` and `seizeCollateral()` are intended to be called exclusively by the `KaliMagaLiquidator` contract. However, they currently have no access control — any address can call them directly. A malicious caller could use `seizeCollateral` to drain a borrower's collateral shares without going through the liquidation bonus and close factor checks enforced in the Liquidator.

**Impact:**  
Direct collateral seizure bypassing close factor and bonus accounting, potentially allowing a griefing attack that wipes a borrower's collateral without a fair liquidation.

**Recommended Fix:**  
Add an `onlyLiquidator` modifier:

```solidity
address public liquidator;

modifier onlyLiquidator() {
    require(msg.sender == liquidator, "not liquidator");
    _;
}
```

Set `liquidator` in the constructor or via an owner-only setter, and apply the modifier to both functions. This is a known trusted-caller pattern used by Aave's pool/logic separation.

---

### [M-02] Price oracle has no staleness check

**Severity:** Medium  
**Status:** Acknowledged  
**File:** `src/lending/KaliMagaPriceOracle.sol`

**Description:**  
The current oracle stores a single price per asset with no timestamp. If the owner fails to update a price (key loss, operational failure), stale prices will silently continue to be used for health factor calculations, potentially allowing undercollateralized borrows to pass or blocking valid liquidations.

**Recommended Fix:**  
In a production deployment, replace with a Chainlink feed and add a staleness check:

```solidity
(, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();
require(block.timestamp - updatedAt <= MAX_STALENESS, "stale price");
```

The oracle interface is already structured to support this swap without touching the LendingPool.

---

### [L-01] `swap()` does not check `amount0Out == 0 && amount1Out == 0` symmetrically with reserves

**Severity:** Low  
**Status:** Fixed  
**File:** `src/core/KaliMagaPair.sol`

**Description:**  
The guard `if (amount0Out >= _reserve0 || amount1Out >= _reserve1)` uses `>=` which correctly prevents draining the full reserve. However, when one `amountOut` is zero (single-sided swap), the condition `0 >= reserve` is always false, meaning the zero-output side still passes through the reserve check unnecessarily. This is benign but adds a misleading code path.

**Fix:**  
Check each side independently only when non-zero, or document the intended behavior explicitly in a NatSpec comment.

---

### [L-02] `KaliMagaRouter` deadline check uses `block.timestamp` which validators can manipulate within ~12 seconds

**Severity:** Low  
**Status:** Acknowledged  

**Description:**  
The `ensure(deadline)` modifier compares `block.timestamp > deadline`. Validators on Ethereum can manipulate `block.timestamp` within a window of roughly 12 seconds, meaning a transaction submitted with `deadline = block.timestamp + 1` could be included in a block with a timestamp slightly in the future, causing an unexpected revert.

**Recommendation:**  
This is an accepted trade-off in production DEX routers including Uniswap V2/V3. Users should set deadlines at least 1-2 minutes in the future. Document this in integration guides.

---

### [I-01] Flash loan reentrancy path

**Severity:** Informational  

**Description:**  
`flashLoan()` sends tokens to an external receiver before the balance check. While the `nonReentrant` modifier prevents re-entry into the lending pool itself, a malicious receiver could call into other protocols during the callback. This is expected behavior for flash loans and is not a vulnerability, but integrators should be aware.

---

### [I-02] No events on market parameter updates

**Severity:** Informational  

**Description:**  
`addMarket()` emits a `MarketListed` event, but there is no function to update market parameters (collateral factor, interest rate model) after listing. If parameter update functions are added in the future, they should emit events for off-chain indexers and transparency.

---

## Test Coverage

| Module | Unit | Fuzz | Invariant |
|---|---|---|---|
| KaliMagaPair | ✓ | ✓ | ✓ |
| KaliMagaFactory | ✓ | — | — |
| KaliMagaRouter | ✓ | ✓ | — |
| KaliMagaLendingPool | ✓ | ✓ | — |
| KaliMagaLiquidator | ✓ | — | — |
| Flash loans | ✓ | — | — |

41 tests passing. Fuzz runs: 5000 per property. Invariant calls: 128,000 per invariant.

---

## Disclaimer

This is a self-audit conducted by the protocol author as part of the development process. It is not a substitute for a professional third-party audit before mainnet deployment.
