# Changelog

## [1.0.0] - 2026-06-22

### Added

**AMM Core**
- `KaliMagaPair` — constant-product AMM pool (x*y=k) with 0.3% swap fee, LP share minting, minimum liquidity lock
- `KaliMagaFactory` — CREATE2 pair deployer and registry
- `KaliMagaRouter` — user entry point for add/remove liquidity and swaps with slippage and deadline protection
- `KaliMagaLibrary` — shared math: quote, getAmountOut, getAmountsOut

**Lending**
- `KaliMagaLendingPool` — multi-asset money market with share-based supply accounting, borrow-index debt accrual, health factor checks, flash loans
- `KaliMagaInterestRateModel` — two-slope utilization-based rate model (kink model)
- `KaliMagaPriceOracle` — owner-managed price feed with Chainlink-ready interface
- `KaliMagaLiquidator` — liquidation engine: seizes undercollateralized collateral and settles debt atomically through the internal DEX router

**Tests**
- 73 tests: unit, fuzz (5000 runs/property), invariant (128,000 calls/invariant)
- Systematic revert-path guard tests across all 7 contracts
- Branch coverage: 72.94% overall, 5 of 7 contracts at 100%

**Documentation & Tooling**
- Full NatSpec on every public function across all contracts and interfaces
- AUDIT.md: 1 High (fixed), 2 Medium, 2 Low, 2 Informational
- docs/SLITHER.md: static analysis with 101 detectors, findings documented
- docs/COVERAGE.md: per-contract breakdown with honest gap analysis
- docs/ARCHITECTURE.md: design decisions for AMM, lending, and liquidation integration
- docs/DEPLOYMENT.md: step-by-step Sepolia deployment guide
- docs/SECURITY.md: vulnerability disclosure policy
- CI/CD: GitHub Actions running full test suite on every push
- Deploy scripts: `script/Deploy.s.sol` deploying all 6 contracts in dependency order
- Gas snapshot committed

### Fixed
- Integer underflow in `KaliMagaPair.mint()` on zero deposit — `_sqrt(0) - MINIMUM_LIQUIDITY` caused arithmetic panic instead of `InsufficientLiquidityMinted` revert; fixed by checking rootK before subtraction
- Cheatcode ordering bug in test suite — `vm.expectRevert` consumed by an inline view call instead of the intended target; fixed by storing addresses in variables before calling expectRevert

## Roadmap

- Sepolia deployment with Etherscan verification
- `onlyLiquidator` access control on `liquidationRepay()` and `seizeCollateral()` (M-01)
- Chainlink price feed integration replacing the manual oracle (M-02)
