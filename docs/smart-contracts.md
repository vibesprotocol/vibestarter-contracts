# Smart Contracts Reference

> Technical reference for all Vibestarter smart contracts.

**Solidity Version:** ^0.8.20 (compiled with 0.8.24)
**Framework:** Foundry (forge-std v1.x, OpenZeppelin v5)
**Network:** Base (Chain ID 8453) / Base Sepolia (Chain ID 84532)

---

## Contract Inventory

### Core Protocol (6 contracts)

| Contract | File | Lines | Purpose |
|----------|------|-------|---------|
| VibesLaunchRouterV2 | `src/VibesLaunchRouterV2.sol` | 1,092 | Main entry point for launches and campaigns |
| VibesTranchEscrow | `src/VibesTranchEscrow.sol` | 1,220 | ETH escrow with time-based tranche releases, commit-reveal refund merkle root |
| VibesTreasuryEscrow | `src/VibesTreasuryEscrow.sol` | 459 | Token treasury with proposal-based withdrawals |
| VibesTokenDistributorV2 | `src/VibesTokenDistributorV2.sol` | 401 | Merkle-based token + ETH refund distribution |
| VibesVesting | `src/VibesVesting.sol` | 256 | 18-month founder vesting (6mo cliff + 12mo linear) |
| VibesLPLocker | `src/VibesLPLocker.sol` | 256 | Aerodrome LP creation + permanent lock to 0xdead. `resolveRescuedFunds()` handles failed LP creation only — not an unlock mechanism. |

### Infrastructure (4 contracts)

| Contract | File | Lines | Purpose |
|----------|------|-------|---------|
| VibesTranchEscrowFactory | `src/VibesTranchEscrowFactory.sol` | 252 | EIP-1167 minimal proxy factory for escrow clones |
| VibesTokenFactory | `src/VibesTokenFactory.sol` | 50 | Deploys fixed-supply ERC20 tokens |
| VibesRegistry | `src/VibesRegistry.sol` | 213 | Immutable provenance registry — stores Origin Capsules (onchain event: `VibesCertified`) |
| VibesIdentityRegistry | `src/VibesIdentityRegistry.sol` | 205 | ERC-8004 identity registry for AI agents |

### Staking (2 contracts)

| Contract | File | Lines | Purpose |
|----------|------|-------|---------|
| VibesStaking | `src/VibesStaking.sol` | 301 | VIBES token staking with 7-day cooldown + balance snapshots (F4) |
| VibesStakerRewards | `src/VibesStakerRewards.sol` | 500 | Snapshot-based staker reward distribution (accumulator pattern) |

### Token (1 contract)

| Contract | File | Lines | Purpose |
|----------|------|-------|---------|
| VibesToken | `src/VibesToken.sol` | 99 | Minimal fixed-supply ERC20 (no mint/burn after deploy) |

### Router Internals (2 contracts)

| Contract | File | Lines | Purpose |
|----------|------|-------|---------|
| VibesRouterExtension | `src/VibesRouterExtension.sol` | — | Delegatecall extension for admin functions on VibesLaunchRouterV2 |
| VibesRouterStorage | `src/VibesRouterStorage.sol` | — | Shared storage layout for router + extension |

### Testnet Only (3 contracts)

| Contract | File | Lines | Purpose |
|----------|------|-------|---------|
| MockTimeOracle | `src/MockTimeOracle.sol` | 70 | Time manipulation for testnet (MUST NOT be used on mainnet) |
| VibesTranchEscrowTestnet | `src/VibesTranchEscrowTestnet.sol` | — | Testnet escrow variant with accelerated timings (24h tranches, 2h challenges) |
| VibesTranchEscrowFactoryTestnet | `src/VibesTranchEscrowFactoryTestnet.sol` | — | Testnet factory variant (2-day max duration, 0.001 ETH min) |

### Interfaces (3 files)

| Interface | File | Purpose |
|-----------|------|---------|
| ITimeOracle | `src/interfaces/ITimeOracle.sol` | Time oracle interface |
| IVibesLaunchRouter | `src/interfaces/IVibesLaunchRouter.sol` | Router callback interface |
| IAerodromeRouter | `src/interfaces/IAerodromeRouter.sol` | Aerodrome DEX interface |

---

## Key Constants

### VibesTranchEscrow

| Constant | Value | Description |
|----------|-------|-------------|
| `KICKSTART_BPS` | 1000 (10%) | Kickstart tranche size |
| `MONTHLY_BPS` | 1500 (15%) | Monthly tranche size |
| `PLATFORM_FEE_BPS` | 250 (2.5%) | Fee deducted from each tranche |
| `CHALLENGE_THRESHOLD_BPS` | 50 (0.5%) | Legacy default — actual threshold is graduated: 25 (0.25%) for T0-T2, 50 (0.5%) for T3-T4, 100 (1%) for T5-T6 via `getChallengeThreshold()` |
| `CHALLENGE_SLASH_BPS` | 2000 (20%) | Slash on rejected challenge |
| `TRANCHE_DURATION` | 30 days | Time between monthly tranches |
| `CHALLENGE_WINDOW` | 72 hours | Window for backers to challenge |
| `MIN_CONTRIBUTION` | 0.01 ether | Minimum ETH per contribution |
| `BPS_DENOMINATOR` | 10000 | Basis point divisor |
| `NUM_MONTHLY_TRANCHES` | 6 | Number of monthly tranches |
| `MERKLE_ROOT_DELAY` | 24 hours | Commit-reveal delay before merkle root is finalized (F10) |
| `MAX_TIME_DRIFT` | 1 hours | Max drift allowed in `_currentTime()` oracle reads (audit fix H-06) |

### VibesTranchEscrowTestnet (post-audit 2026-04-15)

Mirrors `VibesTranchEscrow` constants except timing. **All security constants (`MAX_TIME_DRIFT`, `MERKLE_ROOT_DELAY`) are identical** to mainnet — enforced in CI by `AuditTestnetParityGuard2026_04.t.sol`.

| Constant | Value | Description |
|----------|-------|-------------|
| `TRANCHE_DURATION` | 24 hours | Accelerated (vs. 30 days on mainnet) |
| `CHALLENGE_WINDOW` | 2 hours | Accelerated (vs. 72 hours on mainnet) |
| `CHALLENGE_COOLDOWN` | 2 hours | Accelerated (vs. 7 days on mainnet) |
| `MIN_CONTRIBUTION` | 0.001 ether | Accelerated (vs. 0.01 ether on mainnet) |
| `MAX_TIME_DRIFT` | 1 hours | Identical to mainnet (audit fix H-1, 2026-04-15) |
| `MERKLE_ROOT_DELAY` | 24 hours | Identical to mainnet F10 commit-reveal (audit fix H-2, 2026-04-15) |

### VibesVesting

| Constant | Value | Description |
|----------|-------|-------------|
| `CLIFF` | 180 days | 6-month cliff (0% vested during cliff) |
| `VESTING_DURATION` | 365 days | 12-month linear vesting after cliff |

### VibesStaking

| Constant | Value | Description |
|----------|-------|-------------|
| `UNSTAKE_COOLDOWN` | 7 days | Cooldown before unstaking |

### VibesTranchEscrowFactory

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_RAISE_DURATION` | 30 days | Maximum active fundraising period |
| `MAX_SCHEDULE_WINDOW` | 30 days | How far ahead a raise can be scheduled |

---

## Contract Relationships

```
VibesLaunchRouterV2 (main entry point)
├── VibesTokenFactory (deploys tokens)
├── VibesRegistry (registers provenance)
├── VibesTranchEscrowFactory (creates escrow clones)
│   └── VibesTranchEscrow (EIP-1167 clones)
│       ├── Contributions (ETH in)
│       ├── Tranches (ETH out to founder)
│       ├── Challenges (backer disputes)
│       └── Refunds (ETH back to backers)
├── VibesLPLocker (creates + locks LP on Aerodrome)
├── VibesVesting (founder token vesting)
├── VibesTreasuryEscrow (treasury token management)
├── VibesTokenDistributorV2 (merkle-based token distribution)
└── VibesStakerRewards (staker token distribution)

VibesStaking (independent — VIBES token staking)
VibesIdentityRegistry (independent — ERC-8004 agent registry)
```

---

## Security Patterns Used

| Pattern | Where | Notes |
|---------|-------|-------|
| ReentrancyGuard (OpenZeppelin) | 8 contracts | All ETH-handling contracts |
| SafeERC20 (OpenZeppelin) | 7 contracts | All token-transfer contracts |
| Checks-Effects-Interactions | All ETH transfers | State updated before `.call{value:}` (CEI fix applied to `_executePhase2` deposit refund) |
| Balance snapshots | VibesStaking | Lazy per-user snapshots for accurate reward distribution (F4) |
| Commit-reveal timelock | VibesTranchEscrow + VibesTranchEscrowTestnet | 24hr delay between committing and finalizing refund merkle root (F10). Testnet parity landed 2026-04-15 (H-2). |
| Proof-based LP-lock recording | VibesLPLocker.recordManualLPLock | After rescue resolution, admin records a manually-created LP lock; requires `IERC20(pool).balanceOf(0xdead) >= lpAmount` onchain proof before flipping state from rescued → locked. Closes the tranche-progression deadlock (H-4, 2026-04-15). |
| Cross-contract finalization guards | VibesTranchEscrow + VibesRouterExtension | `_claimTokensInternal` hard-requires `finalizationPhase == FullyComplete`; `emergencyRefundFunded` queries router `finalizationPhase(token) == 0` via try/catch. Prevents token+ETH double-dip via state drift (H-3, 2026-04-15). |
| Oracle time-drift guard | VibesTranchEscrow + VibesTranchEscrowTestnet | `require(oracleTime <= block.timestamp + MAX_TIME_DRIFT)` where `MAX_TIME_DRIFT = 1 hours`. H-06 audit fix; testnet parity landed 2026-04-15 (H-1). |
| Two-step admin/owner transfer | Escrow, Treasury, LP Locker, Router | Prevents accidental ownership loss |
| Two-tier admin separation | Router → Escrow, Treasury | Master admin (multi-sig) controls infrastructure; operations admin (EOA) handles day-to-day resolution |
| EIP-1167 Minimal Proxy | VibesTranchEscrowFactory | Gas-efficient escrow deployment |
| Merkle Proof verification | Distributor, StakerRewards, Escrow | Efficient claim verification |
| Custom errors | Most contracts | Gas-efficient reverts |
| Dead address locking | LP tokens, slashed tokens | Sent to 0xdead (irrecoverable) |
| Pausable | Router | Emergency stop capability |

---

## Onchain Admin Roles

Two distinct admin roles with strict separation of powers:

### Master Admin (Router `owner`)

**Wallet type:** Gnosis Safe (multi-sig, 2-of-3 minimum)
**Set by:** Router constructor → `transferOwnership()` to Safe post-deploy
**Can move user funds:** Yes — via `rescueETH()`, `rescueERC20()`, infrastructure swaps

Controls: `pause/unpause`, `rescueETH/rescueERC20`, `setEscrowFactory`, `setLPLocker`, `setStakerRewardsContract`, `setFeeConfig`, `setFounderDepositWei`, `setOperationsAdmin`, `transferOwnership`, `completeLP`, `refundDeposit/forfeitDeposit`, `setTrustedLaunchSigner`

### Operations Admin (Router `operationsAdmin`)

**Wallet type:** Dedicated EOA (hot wallet for fast resolution)
**Set by:** Master admin via `setOperationsAdmin(address)`. Revocable at any time.
**Can move user funds:** No — can only freeze campaigns, return stakes, or burn to `0xdead`

Passed to new escrows and treasuries as their `admin` at campaign creation (falls back to `owner` if not set).

Controls:
- **Escrow:** `upholdChallenge`, `rejectChallenge`, `freezeCampaign`, `commitRefundMerkleRoot` + `cancelPendingMerkleRoot`, `pauseCampaign/resumeCampaign`, `forceRefundDuringRaise`, `emergencyRefundFunded`, `adminTopUp`, `setTrustedSigner`
- **Treasury:** `upholdChallengeRework`, `upholdChallengeMalicious`, `rejectChallenge`

> Full details: `docs/security/pre-mainnet-requirements.md`

---

## Deployment

### Testnet (Base Sepolia)

```bash
cd contracts
cp .env.example .env
# Edit .env with PRIVATE_KEY, BASE_SEPOLIA_RPC_URL, BASESCAN_API_KEY
# Set USE_MOCK_AERODROME=true, USE_TIME_ORACLE=true

forge script script/DeployV2.s.sol:DeployV2 \
    --rpc-url base_sepolia \
    --broadcast \
    --verify
```

### Mainnet (Base)

```bash
# Ensure USE_MOCK_AERODROME=false, USE_TIME_ORACLE=false
# Verify timeOracle = address(0) in deployment output

forge script script/DeployV2.s.sol:DeployV2 \
    --rpc-url base \
    --broadcast \
    --verify
```

---

## Related Documentation

- [Security Analysis](./security-analysis.md) — Full security review with findings
- [Privileged Roles](./privileged-roles.md) — All admin capabilities
- [Funding Mechanics](./funding-mechanics.md) — How funds flow through the system
- [Test Coverage](./test-coverage-analysis.md) — Test inventory and how to run
