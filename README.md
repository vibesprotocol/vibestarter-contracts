# Vibestarter Smart Contracts

Smart contracts for [Vibestarter](https://vibestarter.xyz) - a crowdfunding platform for vibecoded applications on Base.

## Overview

Vibestarter enables founders to raise funds for AI-collaborative software projects with built-in backer protection through time-released funding and community challenge mechanisms.

## Contracts

### Core Contracts

| Contract | Description |
|----------|-------------|
| `VibesLaunchRouterV2.sol` | Main entry point for launching raises |
| `VibesTranchEscrow.sol` | Per-raise escrow with time-based fund release |
| `VibesTranchEscrowFactory.sol` | Factory for deploying escrow contracts |
| `VibesTokenDistributorV2.sol` | Handles token distribution to backers |
| `VibesLPLocker.sol` | Locks liquidity pool tokens indefinitely |
| `VibesRegistry.sol` | Central registry for platform configuration |
| `VibesToken.sol` | ERC20 token template for project tokens |
| `VibesTokenFactory.sol` | Factory for deploying project tokens |

### Key Parameters

```solidity
// Fund release schedule
uint256 constant VIBESTART_PERCENT = 10;   // 10% released immediately
uint256 constant TRANCHE_PERCENT = 15;      // 15% per monthly tranche
uint256 constant TRANCHE_INTERVAL = 30 days;
uint256 constant CHALLENGE_WINDOW = 72 hours;

// Token distribution
uint256 constant BACKER_ALLOCATION = 70;    // 70% to backers
uint256 constant LIQUIDITY_ALLOCATION = 20; // 20% to LP (locked indefinitely)
uint256 constant MAX_FOUNDER_ALLOCATION = 10; // Up to 10% to founder

// Platform fees
uint256 constant PLATFORM_FEE = 250;        // 2.5% (in basis points)
```

## Security

- Contracts use battle-tested [OpenZeppelin](https://openzeppelin.com/) libraries for core security patterns
- All contract code is verified on [Basescan](https://basescan.org/)
- Reentrancy guards on all state-changing functions
- Per-raise contract isolation (each raise deploys its own escrow)

## Deployments

### Base Mainnet

Contracts are deployed on Base (Ethereum L2). Verified contract addresses available on Basescan.

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Setup

```bash
# Clone the repository
git clone https://github.com/vibesprotocol/vibestarter-contracts.git
cd vibestarter-contracts

# Install dependencies
forge install

# Copy environment variables
cp .env.example .env
# Edit .env with your configuration

# Build contracts
forge build

# Run tests
forge test
```

### Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test testTrancheRelease
```

## How It Works

### Fund Flow

1. **Contribution**: Backers contribute ETH → funds go to escrow contract
2. **Kickstart**: 10% released to founder immediately when raise finalizes
3. **Monthly Tranches**: 15% released each month for 6 months
4. **Challenge Window**: Each tranche has a 72-hour window where token holders can challenge
5. **LP Lock**: 20% of tokens paired with ETH, LP tokens locked indefinitely

### Challenge Mechanism

- Token holders with ≥0.5% of supply can challenge tranche releases
- Challengers must stake tokens to initiate
- Challenges are reviewed by the Vibestarter team (V1)
- If upheld, tranche is frozen and project may be terminated
- Backers receive proportional refunds based on token holdings

### Refund Conditions

- Fixed Goal raise doesn't meet target → full refund
- Open-Ended raise doesn't meet soft cap → full refund
- Project terminated after funding → proportional refund based on token holdings

## License

MIT

## Links

- Website: https://vibestarter.xyz
- App: https://app.vibestarter.xyz
- Documentation: https://app.vibestarter.xyz/docs
- Twitter: [@vibestarterxyz](https://x.com/vibestarterxyz)
