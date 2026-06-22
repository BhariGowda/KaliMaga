# Security Policy

## Scope

This policy covers the KaliMaga protocol suite:

- `src/core/KaliMagaPair.sol`
- `src/core/KaliMagaFactory.sol`
- `src/core/KaliMagaRouter.sol`
- `src/lending/KaliMagaLendingPool.sol`
- `src/lending/KaliMagaLiquidator.sol`
- `src/lending/KaliMagaInterestRateModel.sol`
- `src/lending/KaliMagaPriceOracle.sol`

## Known Issues

Before reporting, review [AUDIT.md](../AUDIT.md) and [docs/SLITHER.md](SLITHER.md) — the following are known and acknowledged:

- `liquidationRepay()` and `seizeCollateral()` lack `onlyLiquidator` access control (M-01)
- Price oracle has no staleness check (M-02)
- Reentrancy in `KaliMagaFactory.createPair()` post-initialize state write (benign)

## Reporting a Vulnerability

This is a portfolio and testnet project — not deployed on mainnet. If you find a security issue:

1. **Do not open a public GitHub issue** for potential vulnerabilities
2. Email: contact via GitHub profile (@BhariGowda)
3. Include: affected contract, description of the issue, steps to reproduce, and a proof-of-concept if possible

## Response

Acknowledged within 48 hours. For a genuine finding on a testnet deployment, credit will be given in the AUDIT.md findings section.

## Disclaimer

KaliMaga has not undergone a professional third-party audit. Do not use this code in production without a full audit by a qualified security firm.
