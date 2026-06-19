# Slither Static Analysis

Run with:
```bash
slither . --config-file slither.config.json
```

98 detectors run across 24 contracts, 44 results. Most are low-severity or false positives (see Notes below). Findings worth tracking:

## Real Findings

### Reentrancy in `KaliMagaFactory.createPair()`
**Detector:** reentrancy-benign, reentrancy-events
State (`allPairs.push`) is written and an event is emitted after the external call to `KaliMagaPair.initialize()`. Benign here because `initialize()` can only be called once per pair and there's no way for it to call back into `createPair()` meaningfully, but flagged for awareness — standard practice is checks-effects-interactions.

### Reentrancy in `KaliMagaLendingPool.flashLoan()`
**Detector:** reentrancy-balance
The flash loan receiver is called before the final balance check. This is expected behavior for flash loans (the receiver needs control to use the funds), and is protected by `nonReentrant`. Flagged here for documentation, not a real issue.

### Divide-before-multiply in `accrueInterest()`
**Detector:** divide-before-multiply
`interestFactor = (borrowRateBps * elapsed * SCALE) / (SECONDS_PER_YEAR * BPS)` divides before later being multiplied by `totalBorrows`. This can lose precision on very small elapsed times or low borrow rates. Acceptable for this protocol's scale (interest is meant to accrue over days/weeks, not seconds), but worth tightening with higher internal precision if extended to higher-frequency accrual.

### Missing zero-check in `KaliMagaPair.initialize()`
**Detector:** missing-zero-check
`_token0` and `_token1` are not checked against `address(0)` before being stored. In practice, the factory always sorts and validates tokens before calling `initialize()`, so this is mitigated at the call site — but the pair itself doesn't enforce it independently.

### Calls inside a loop in `getAccountLiquidity()` and `_swap()`
**Detector:** calls-loop
Both functions make external calls (`priceOracle.getPrice()`, pair `swap()`) inside loops over markets/path. This is necessary for the protocol's multi-asset/multi-hop design and is bounded by the number of listed markets or path length, both of which are owner/caller controlled — not unbounded user input.

### Weak PRNG warning on `blockTimestampLast`
**Detector:** weak-prng
`block.timestamp % 2**32` is flagged because Slither's heuristic treats any modulo on timestamp as a PRNG pattern. This is not randomness — it's truncating the timestamp to fit `uint32` storage, the same pattern used in Uniswap V2.

## Notes

- `timestamp` detector results (block.timestamp used in comparisons) are excluded from analysis above — these are standard deadline/precision checks, not actual timestamp manipulation vulnerabilities, and Slither flags them broadly across nearly every function that touches state after a time-based check.
- `unused-return` findings on `getReserves()`/`sortTokens()` destructuring are intentional — only the needed return values are used, with `(x,)` syntax to discard the rest.

## Action Items

None of the above require code changes for the current testnet scope. The reentrancy and missing-zero-check findings should be revisited if this protocol is ever extended toward mainnet (see [AUDIT.md](../AUDIT.md) for the formal severity-rated findings).
