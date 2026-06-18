# KaliMaga Architecture

## Overview

KaliMaga is a DeFi protocol suite built from scratch in Solidity. The core design decision is that the AMM and the lending market are not independent modules — the liquidation engine deliberately routes through the internal DEX router to settle undercollateralized positions. This means the two halves of the protocol compose with each other rather than sitting side by side.

## Module Map
## AMM Design

The AMM follows the Uniswap V2 constant-product model (x*y=k) with a 0.3% swap fee retained in the pool for LP holders. Key design choices:

- **Minimum liquidity lock**: On first deposit, 1000 wei of LP shares are permanently sent to `address(0xdead)` to prevent the pool price from being manipulated to zero.
- **Underflow protection on mint**: The square root of the initial deposit is checked against `MINIMUM_LIQUIDITY` before subtraction, preventing an arithmetic panic on zero deposits (bug found and fixed during development).
- **CREATE2 deployment**: Pairs are deployed with a deterministic salt (`keccak256(token0, token1)`), giving every pair a pre-computable address without needing to query the factory.

## Lending Design

The lending pool uses Compound V2-style share accounting:

- **Supply shares**: Depositors receive shares rather than token receipts. As interest accrues, each share redeems for more underlying — yield is automatic, no claiming needed.
- **Borrow index**: Each borrower's debt is stored as a principal snapshot against the market's borrow index at the time of borrowing. Current debt = principal * (currentIndex / snapshotIndex).
- **Health factor**: Borrowing power is determined by collateral value × collateral factor. Any action (borrow, withdraw) that would push health factor below 1e18 reverts.
- **Interest rate model**: Two-slope kink model. Rates rise slowly up to the kink utilization, then steeply beyond it to incentivize repayment and attract new supply.

## Liquidation Engine

The liquidation flow is the integration point between both modules:

1. A borrower's health factor drops below 1.0 (collateral value < debt value)
2. A liquidator calls `KaliMagaLiquidator.liquidate()`, specifying the borrower, debt asset, and collateral asset
3. The liquidator repays up to 50% of the debt (close factor) via `liquidationRepay()`
4. The pool seizes the equivalent collateral value + 5% liquidation bonus via `seizeCollateral()`
5. The seized collateral is swapped through `KaliMagaRouter` back to the debt asset
6. The liquidator receives the swap output, netting the 5% bonus minus DEX fees

The close factor (50%) and liquidation bonus (5%) are hardcoded constants, consistent with Aave V2's defaults.

## Flash Loans

Flash loans are implemented directly on the LendingPool. The fee (0.09%) accrues to `totalBorrows`, which increases the exchange rate for all suppliers — flash loan fees benefit LP holders automatically through the share accounting mechanism.

## Security Considerations

See [AUDIT.md](../AUDIT.md) for the full self-audit covering all known findings. Key open items:

- `liquidationRepay` and `seizeCollateral` lack an `onlyLiquidator` access control modifier (M-01)
- The price oracle has no staleness check (M-02) — mitigated in production by replacing with Chainlink
