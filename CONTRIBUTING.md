# Contributing

KaliMaga is a portfolio project but contributions, issues, and security findings are welcome.

## Development Setup

```bash
git clone https://github.com/BhariGowda/KaliMaga.git
cd KaliMaga
forge install
forge build
forge test
```

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.

## Running Tests

```bash
# Full suite
forge test

# With higher fuzz runs
forge test --fuzz-runs 5000

# Specific contract
forge test --match-contract KaliMagaPairTest

# Coverage report
forge coverage --report summary --ir-minimum
```

## Code Standards

- Solidity 0.8.20, no floating pragma
- Full NatSpec on every public and external function (`@notice`, `@dev`, `@param`, `@return`)
- Custom errors (`revert CustomError()`) over `require` strings
- `SafeERC20` for all token transfers
- `nonReentrant` on all state-changing external functions
- `forge fmt` for formatting before committing

## Test Standards

- Every new function needs at least one happy-path test and one revert test per guard
- Fuzz tests for any math-heavy or amount-based logic
- Run `forge coverage --ir-minimum` and document any branch coverage gaps honestly

## Pull Request Process

1. Fork the repo
2. Create a feature branch (`git checkout -b feat/your-feature`)
3. Write tests first, then implementation
4. Ensure `forge test` passes and no new lint warnings are introduced
5. Open a PR with a clear description of what changed and why

## Security

See [docs/SECURITY.md](docs/SECURITY.md) for vulnerability reporting guidelines. Do not open public issues for potential vulnerabilities.
