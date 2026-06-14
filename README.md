# KaliMaga

A DeFi protocol suite built from scratch in Solidity  an AMM-style decentralized exchange paired with a multi-asset lending and borrowing market.

This is a portfolio project focused on understanding how core DeFi primitives work under the hood, not just how to use them: constant-product market making, share-based yield accounting, utilization-based interest rates, and collateral-factor-weighted health checks.

## Protocols

### AMM / DEX

- Constant-product pairs (`KaliMagaPair`) with a 0.3% swap fee
- Factory (`KaliMagaFactory`) deploying pairs deterministically via CREATE2
- Router (`KaliMagaRouter`) for adding/removing liquidity and multi-hop swaps, with slippage and deadline protection
- Shared math library for quotes and swap output calculations

### Lending & Borrowing

- Multi-asset money market (`KaliMagaLendingPool`)
- Share-based supply accounting  depositors earn yield via a growing exchange rate (Compound-style)
- Two-slope, utilization-based interest rate model (`KaliMagaInterestRateModel`)
- Per-asset collateral factors and a health-factor check gating borrows and withdrawals
- Simple owner-managed price oracle, structured to be swapped for a real feed later

## Stack

| Layer | Tool |
|---|---|
| Smart contracts | Solidity 0.8.20 + Foundry |
| Dependencies | OpenZeppelin Contracts v5.6.1 |
| Compilation | via-ir pipeline (optimizer enabled) |

## Tests
29/29 tests passing  covering core AMM flows (mint/burn/swap, K-invariant checks, minimum liquidity lock) and lending flows (deposit, borrow against collateral, repayment, interest accrual over time).

## Roadmap

- [x] Flash loans on the lending pool
- [ ] Liquidation engine seize undercollateralized positions and settle them through the built-in DEX router
- [ ] Fuzz and invariant tests
- [ ] CI pipeline running the test suite on every push

## Goal

Build a coherent protocol suite where the AMM and lending market actually interact  not just two unrelated contracts side by side.
