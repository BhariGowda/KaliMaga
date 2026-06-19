# Deployment Guide

## Prerequisites

- Foundry installed (`forge --version`)
- A funded wallet on Sepolia testnet (get test ETH from a faucet)
- An RPC URL for Sepolia (Alchemy, Infura, or similar)
- An Etherscan API key for contract verification

## Setup

1. Copy the environment template and fill in your values:

```bash
cp .env.example .env
```

Edit `.env`:
2. Load the environment:

```bash
source .env
```

## Deploy

Dry run first (no broadcast, just simulation):

```bash
forge script script/Deploy.s.sol --rpc-url sepolia
```

If the simulation looks correct, deploy and verify on Etherscan:

```bash
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify
```

This deploys, in order:

1. `KaliMagaFactory` — AMM pair registry
2. `KaliMagaRouter` — wired to the factory
3. `KaliMagaPriceOracle` — owner-managed price feed
4. `KaliMagaInterestRateModel` — 2% base / 10% slope1 / 300% slope2 / 80% kink
5. `KaliMagaLendingPool` — wired to the oracle
6. `KaliMagaLiquidator` — wired to the pool, oracle, and router

## Post-Deployment Setup

After deployment, the lending pool has no markets listed and the oracle has no prices set. To make the protocol usable:

1. Set prices on the oracle for each asset you want to support:
```solidity
oracle.setPrice(tokenAddress, priceIn18Decimals);
```

2. List each asset as a market on the lending pool:
```solidity
pool.addMarket(tokenAddress, address(irm), collateralFactorBps);
```

3. Create AMM pairs and seed liquidity via the router's `addLiquidity()` function so the liquidator has somewhere to swap seized collateral.

## Verification

If `--verify` fails during deployment (rate limits, network issues), verify manually after the fact:

```bash
forge verify-contract <CONTRACT_ADDRESS> <CONTRACT_PATH>:<CONTRACT_NAME> --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY
```

## Known Limitations (Testnet Only)

This deployment script is for testnet validation. Before any mainnet deployment, address the open findings in [AUDIT.md](../AUDIT.md), particularly:

- Add `onlyLiquidator` access control to `liquidationRepay()` and `seizeCollateral()` (M-01)
- Replace the manual price oracle with a Chainlink-backed feed with staleness checks (M-02)
