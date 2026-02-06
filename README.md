# Vibestarter Smart Contracts

Smart contracts for [Vibestarter](https://vibestarter.xyz) - a crowdfunding platform for vibecoded applications on Base.

## Overview

Vibestarter enables founders to raise funds for AI-collaborative software projects with built-in backer protection through time-released funding and community challenge mechanisms.

## Contracts

### Core Contracts (V2 - Production)

| Contract | Description |
|----------|-------------|
| `VibesLaunchRouterV2.sol` | Main entry point for launching raises with campaign params |
| `VibesTranchEscrow.sol` | Per-raise escrow with time-based fund release (6-month schedule) |
| `VibesTranchEscrowFactory.sol` | Factory for deploying escrow clones (EIP-1167) |
| `VibesTokenDistributorV2.sol` | Merkle-based token distribution to backers |
| `VibesVesting.sol` | Founder token vesting with optional cliff |
| `VibesLPLocker.sol` | Locks liquidity pool tokens indefinitely on Aerodrome |
| `VibesStaking.sol` | VIBE token staking with lock periods |
| `VibesStakerRewards.sol` | Reward distribution for VIBE stakers |

### Supporting Contracts

| Contract | Description |
|----------|-------------|
| `VibesRegistry.sol` | Provenance registry (ERC-8004 capsule hashes) |
| `VibesToken.sol` | ERC20 token template for project tokens |
| `VibesTokenFactory.sol` | Factory for deploying project tokens |

### Legacy Contracts (V1 - Deprecated)

V1 milestone-based contracts are in `src/legacy/`. They are **not deployed in production** and contain known unpatched vulnerabilities. See [`src/legacy/README.md`](src/legacy/README.md) for details.

### Key Parameters

```solidity
// Fund release schedule
uint256 constant VIBESTART_PERCENT = 10;   // 10% released immediately
uint256 constant TRANCHE_PERCENT = 15;      // 15% per monthly tranche
uint256 constant NUM_MONTHLY_TRANCHES = 6;
uint256 constant TRANCHE_INTERVAL = 30 days;
uint256 constant CHALLENGE_WINDOW = 72 hours;

// Graduated challenge bonds (% of token supply)
uint256 constant EARLY_THRESHOLD = 25;     // 0.25% (tranches 0-2)
uint256 constant MID_THRESHOLD = 50;       // 0.50% (tranches 3-4)
uint256 constant LATE_THRESHOLD = 100;     // 1.00% (tranches 5-6)

// Token distribution
uint256 constant BACKER_ALLOCATION = 70;    // 70% to backers
uint256 constant LIQUIDITY_ALLOCATION = 20; // 20% to LP (locked indefinitely)
uint256 constant MAX_FOUNDER_ALLOCATION = 10; // Up to 10% to founder (vested)

// Founder vesting
uint256 constant VESTING_DURATION = 365 days;
// Optional cliff: 0, 30, 60, or 90 days

// Platform fees
uint256 constant PLATFORM_FEE = 250;        // 2.5% (in basis points)
```

## Security

- Contracts use battle-tested [OpenZeppelin](https://openzeppelin.com/) libraries (Pausable, ReentrancyGuard, SafeERC20)
- All contract code is verified on [Basescan](https://basescan.org/)
- Reentrancy guards on all state-changing functions
- Per-raise contract isolation (each raise deploys its own escrow)
- Emergency pause on router for critical security situations (cannot move funds)
- LP tokens flow directly to locker — no owner withdrawal capability

## Deployments

### Base Sepolia (Testnet)

Active development and testing network. Verified contract addresses available on Basescan.

### Base Mainnet

Production deployment on Base (Ethereum L2). Verified contract addresses available on Basescan.

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

1. **Launch**: Founder deploys raise via router (token + escrow created atomically)
2. **Contribution**: Backers contribute ETH → funds go to escrow contract
3. **Finalization**: Raise succeeds → LP created and locked, tokens distributed
4. **Kickstart**: 10% released to founder immediately at finalization
5. **Monthly Tranches**: 15% released each month for 6 months
6. **Challenge Window**: Each tranche has a 72-hour window where token holders can challenge
7. **LP Lock**: 20% of tokens paired with ETH on Aerodrome, LP tokens locked indefinitely

### Challenge Mechanism

- Graduated bond thresholds: 0.25% (early), 0.50% (mid), 1.00% (late tranches)
- Challengers must stake tokens to initiate during the 72-hour window
- Challenges are reviewed by the Vibestarter team
- If upheld: campaign frozen, backers receive proportional refunds based on token holdings
- If rejected: challenger loses 20% of stake (burned), remainder returned

### Refund Conditions

- Fixed Goal raise doesn't meet target → full refund
- Open-Ended raise doesn't meet soft cap → full refund
- Campaign frozen after funding → proportional refund based on token holdings at snapshot

### Scheduled Raises

- Founders can schedule a future start date (up to 30 days out)
- Contributions are blocked until the raise start time
- Deadline is relative to the raise start (max 30 days duration)

## License

MIT

## Links

- Website: https://vibestarter.xyz
- App: https://app.vibestarter.xyz
- Documentation: https://app.vibestarter.xyz/docs
- Twitter: [@vibestarterxyz](https://x.com/vibestarterxyz)
