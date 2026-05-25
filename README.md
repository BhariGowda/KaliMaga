# KaliMaga — DeFi Protocol by Bhari Gowda

A from-scratch DEX Aggregator and Lending & Borrowing protocol built in Solidity.
Portfolio project going from DeFi user to DeFi builder.
Built with Claude Code.

## Protocols

### DEX Aggregator
- Off-chain quote fetching (Uniswap v3 + 1inch)
- On-chain swap execution via DexRouter.sol

### Lending & Borrowing
- Deposit, borrow, repay, withdraw
- 75% collateral factor, reentrancy guard, USDT-safe transfers
- Aave-inspired, built from scratch

## Stack

| Layer | Tool |
|---|---|
| Smart contracts | Solidity 0.8.20 + Foundry |
| Ethereum client | Viem |
| Language | TypeScript / JavaScript |
| AI assistant | Claude Code |
| OS | Ubuntu 24.04 |

## Tests

Run: forge test — 43/43 passing.

## Goal

Build. Test. Deploy. Ship.
