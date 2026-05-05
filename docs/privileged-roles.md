# Privileged Roles Documentation

> Complete mapping of all admin, owner, and founder capabilities across the Vibestarter smart contract suite.

**Last Updated:** 2026-02-24
**Scope:** All 14 contracts in `contracts/src/`

---

## Overview

The Vibestarter protocol has several privileged roles distributed across contracts. Each role has specific capabilities and trust assumptions. This document is intended for auditors and the Vibestarter team to understand the exact technical surface area of each role.

### Role Summary

| Role | Contract(s) | Transfer Method | Wallet Type |
|------|------------|-----------------|-------------|
| **Master Admin** (Router Owner) | VibesLaunchRouterV2 | Two-step (pendingOwner) | **Gnosis Safe (multi-sig)** |
| **Operations Admin** | Router → Escrow, Treasury | Set by master admin via `setOperationsAdmin()` | **Dedicated EOA** |
| Escrow Admin | VibesTranchEscrow (per clone) | Two-step (pendingAdmin) | = Operations Admin |
| Factory Admin | VibesTranchEscrowFactory | Two-step (pendingAdmin) | = Operations Admin |
| Treasury Admin | VibesTreasuryEscrow (per instance) | Two-step (pendingAdmin) | = Operations Admin |
| Registry Owner | VibesRegistry | Two-step (pendingOwner) |
| LP Locker Owner | VibesLPLocker | Two-step (pendingOwner) |
| Identity Registry Owner | VibesIdentityRegistry | OpenZeppelin Ownable |
| Staker Rewards Admin | VibesStakerRewards | Two-step (pendingAdmin) |
| Distributor Admin | VibesTokenDistributorV2 (per instance) | Immutable (set at deployment) |
| Distributor Founder | VibesTokenDistributorV2 (per instance) | Immutable (set at deployment) |
| Vesting Authorized Starter | VibesVesting (per instance) | Immutable (set at deployment) |
| Vesting Authorized Freezer | VibesVesting (per instance) | Set once by starter |

---

## 1. Master Admin / Router Owner (`VibesLaunchRouterV2.owner`)

**Expected holder:** Gnosis Safe multi-sig (2-of-3 minimum, 3-of-5 recommended)
**Key property:** Can move user funds. Requires multi-sig ceremony for all actions.

### Capabilities

| Function | Description | Risk Level |
|----------|-------------|------------|
| `pause()` / `unpause()` / `emergencyUnpause()` | Halt or resume all launches, claims, and finalization | Medium |
| `transferOwnership()` + `acceptOwnership()` | Two-step ownership transfer | Low |
| `setOperationsAdmin()` | **Appoint/revoke the operations admin (EOA)** | High |
| `setEscrowFactory()` | Change the escrow factory address | High |
| `setLPLocker()` | Change the LP locker contract | High |
| `setOpsWallet()` | Change the operations wallet (receives swept funds) | Medium |
| `setStakerRewardsContract()` | Change the staker rewards contract | Medium |
| `setFeeConfig()` | Enable/disable fees, set fee amount and recipient | Medium |
| `setFounderDepositWei()` | Change the required founder deposit amount | Low |
| `setTrustedLaunchSigner()` | Control launch signature gating | Medium |
| `refundDeposit()` | Manually refund a founder's deposit | Medium |
| `forfeitDeposit()` | Seize a founder's deposit (sent to fee recipient) | High |
| `rescueETH()` | **Withdraw ETH from router (guarded by deposit reserves)** | **Critical** |
| `rescueERC20()` | Rescue stuck ERC20 tokens (guarded by active claim/escrow/LP checks) | Medium |
| `completeLP()` | Mark rescued LP as manually resolved | Medium |

### Trust Assumptions
- The `rescueETH` function can drain all ETH above reserved deposits. A compromised owner key could steal these funds.
- **MUST be a multi-sig.** A single compromised EOA = total platform compromise.
- Timelock recommended for infrastructure changes (`setEscrowFactory`, `setLPLocker`, `setFeeConfig`).

---

## 1b. Operations Admin (`VibesLaunchRouterV2.operationsAdmin`)

**Expected holder:** Dedicated EOA (hot wallet) for fast day-to-day operations
**Set by:** Master admin via `setOperationsAdmin(address)`. Revocable at any time.
**Key property:** Cannot move user funds to arbitrary addresses. Can only freeze, return stakes, or burn to `0xdead`.

The operations admin is passed to new escrows and treasuries as their `admin` at campaign creation time. Falls back to `owner` if not set.

### Capabilities (inherited by Escrow Admin + Treasury Admin)

| Function | Contract | Description | Risk Level |
|----------|----------|-------------|------------|
| `upholdChallenge()` | Escrow | Freeze campaign, return challenger stake | High |
| `rejectChallenge()` | Escrow | Slash challenger 20%, allow tranche release | Medium |
| `freezeCampaign()` | Escrow | Freeze funded campaign for holder refunds | High |
| `setRefundMerkleRoot()` | Escrow | Enable holder refund claims via merkle proof | High |
| `pauseCampaign()` / `resumeCampaign()` | Escrow | Pause/resume active raises | Medium |
| `forceRefundDuringRaise()` | Escrow | Emergency refund during active raise | High |
| `setTrustedSigner()` | Escrow | Update contribution signature gating | Medium |
| `upholdChallengeRework()` | Treasury | Block proposal, return stake, cooldown | Medium |
| `upholdChallengeMalicious()` | Treasury | **NUCLEAR — burn treasury, freeze vesting** | **Critical** |
| `rejectChallenge()` | Treasury | Slash challenger 20%, allow proposal | Medium |

### Trust Assumptions
- If compromised: attacker can freeze campaigns and burn individual treasuries, but **cannot extract funds**.
- Master admin can revoke immediately via `setOperationsAdmin(newAddress)`.
- Does NOT have access to any router owner function (rescue, pause, infrastructure).

---

## 2. Escrow Admin (`VibesTranchEscrow.admin`)

**Expected holder:** Vibestarter team multisig (same admin set on all escrow clones via factory)

### Capabilities

| Function | Description | Risk Level |
|----------|-------------|------------|
| `pauseCampaign()` | Temporarily halt contributions (Active state only) | Medium |
| `resumeCampaign()` | Resume contributions after pause | Low |
| `forceRefund()` | Kill campaign during raise, enable contributor refunds | High |
| `freezeCampaign()` | Freeze a funded campaign — blocks all remaining tranches | **Critical** |
| `setRefundMerkleRoot()` | Set merkle root for holder refunds (Frozen → Refunding transition) | **Critical** |
| `upholdChallenge()` | Uphold a pending challenge — freezes campaign | **Critical** |
| `rejectChallenge()` | Reject a challenge — slashes challenger 20% | High |
| `transferAdmin()` + `acceptAdmin()` | Two-step admin transfer | Low |

### Challenge Review Capabilities (Detailed)

When a backer raises a challenge against a tranche request, the admin has a 72-hour window to review. The admin's technical capabilities during this window:

1. **Uphold Challenge** (`upholdChallenge(address[] _excludeAddresses)`)
   - Freezes the entire campaign permanently
   - Returns the challenger's staked tokens in full
   - Sets `frozenEthBalance` and `frozenTotalSupply` for holder refund calculations
   - **`_excludeAddresses` parameter** directly controls the refund denominator — addresses in this array have their token balances excluded from `frozenTotalSupply`, meaning each remaining token redeems for proportionally more ETH
   - Admin must then call `setRefundMerkleRoot()` to enable holder refunds

2. **Reject Challenge** (`rejectChallenge()`)
   - Slashes 20% of the challenger's staked tokens (burned to `0xdead`)
   - Returns 80% of the challenger's staked tokens
   - Founder can now claim the tranche (challenge window has passed)

3. **Take No Action** (let 72 hours expire)
   - Anyone can call `expireChallengeIfNeeded()` after the window
   - Full challenger stake is returned (no slash)
   - Founder can proceed to claim the tranche

4. **Freeze Without Challenge** (`freezeCampaign()`)
   - Admin can freeze any funded campaign at any time, even without a pending challenge
   - Same `_excludeAddresses` trust surface as `upholdChallenge`

### Trust Assumptions
- The `_excludeAddresses` parameter in `upholdChallenge` and `freezeCampaign` directly controls how much ETH each token holder receives in refunds. A compromised admin could manipulate this to over-pay or under-pay specific holders.
- `frozenTotalSupply` is set once and cannot be changed after the call.
- **Recommendation:** Validate `_excludeAddresses` off-chain before submitting. Consider onchain registry of known non-redeemable addresses.

---

## 3. Factory Admin (`VibesTranchEscrowFactory.admin`)

**Expected holder:** Vibestarter team multisig

### Capabilities

| Function | Description | Risk Level |
|----------|-------------|------------|
| `setAdmin()` + `acceptAdmin()` | Two-step admin transfer | Low |
| `setPlatformWallet()` | Change platform fee wallet | Medium |
| `setTimeOracle()` | Change time oracle (0x0 for production, mock for testnet) | High |
| `setAuthorizedRouter()` | Change which router can create escrows | High |
| `setLPLocker()` | Change LP locker address | High |

### Trust Assumptions
- Changing `timeOracle` to a mock oracle on mainnet would allow time manipulation, bypassing challenge windows and vesting schedules.
- Changing `authorizedRouter` allows the new router to create escrow clones with arbitrary parameters.

---

## 4. Treasury Admin (`VibesTreasuryEscrow.admin`)

**Expected holder:** Vibestarter team multisig

### Capabilities

| Function | Description | Risk Level |
|----------|-------------|------------|
| `upholdChallengeRework()` | Blocks proposal, returns stake, 14-day cooldown | Medium |
| `upholdChallengeMalicious()` | **Burns ALL treasury tokens to 0xdead, freezes vesting** | **Critical** |
| `rejectChallenge()` | Slashes challenger 20% | High |
| `transferAdmin()` + `acceptAdmin()` | Two-step admin transfer | Low |

### Challenge Outcomes (Treasury)

| Outcome | Proposal | Challenger Stake | Treasury | Vesting |
|---------|----------|-----------------|----------|---------|
| **Uphold (Rework)** | Blocked, 14-day cooldown | Returned in full | Unchanged | Unchanged |
| **Uphold (Malicious)** | Blocked permanently | Returned in full | **All tokens burned** | **Frozen permanently** |
| **Rejected** | Can be executed | 20% slashed (burned), 80% returned | Unchanged | Unchanged |
| **Expired** (72h no action) | Can be executed | Returned in full | Unchanged | Unchanged |

### Trust Assumptions
- `upholdChallengeMalicious` is a nuclear option that permanently destroys the treasury and freezes all unvested founder tokens. This should only be used for clear fraud/abandonment.
- There is no way to undo a malicious challenge upheld — the action is irreversible.

---

## 5. Registry Owner (`VibesRegistry.owner`)

**Expected holder:** Vibestarter team multisig

### Capabilities

| Function | Description | Risk Level |
|----------|-------------|------------|
| `authorizeRouter()` | Allow a router to register tokens on behalf of founders | High |
| `revokeRouter()` | Remove router authorization | Medium |
| `transferOwnership()` + `acceptOwnership()` | Two-step ownership transfer | Low |

### Trust Assumptions
- Controls which routers can create provenance-verified tokens (Origin Capsules). A compromised owner could authorize malicious routers.

---

## 6. LP Locker Owner (`VibesLPLocker.owner`)

**Expected holder:** Vibestarter team multisig

### Capabilities

| Function | Description | Risk Level |
|----------|-------------|------------|
| `setAuthorizedRouter()` | Change which router can create/lock LP | High |
| `resolveRescuedFunds(campaign, to)` | Withdraw ETH + tokens from a rescued LP attempt to an off-chain recipient for manual LP creation. `nonReentrant` since 2026-04-15 (L-1). | Medium |
| `recordManualLPLock(campaign, pool, lpAmount)` | **Added 2026-04-15 (H-4).** Transitions a rescued campaign to verified-locked state. Requires prior rescue + `rescue.resolved == true` + onchain proof `IERC20(pool).balanceOf(0xdead) >= lpAmount`. Without this call, a rescued campaign cannot complete its LP gate on the router, and founder tranche claims are permanently blocked. | Medium |
| `transferOwnership()` + `acceptOwnership()` | Two-step ownership transfer | Low |

### Trust Assumptions
- Changing `authorizedRouter` allows the new router to use the LP locker. The LP locker holds no funds itself (LP tokens are sent to 0xdead).
- `recordManualLPLock` cannot forge a lock — the owner must actually have burned LP tokens to the dead address before the onchain proof passes. The risk is bounded to the admin choosing `_lpAmount` smaller than the real burn, which only under-states the lock (no fund loss).
- `resolveRescuedFunds` transfers funds to an owner-chosen recipient off-chain. Standard multisig custody of the recipient address is the trust boundary.

---

## 7. Staker Rewards Admin (`VibesStakerRewards.admin`)

**Expected holder:** Vibestarter backend service or multisig

### Capabilities

| Function | Description | Risk Level |
|----------|-------------|------------|
| `setRewardsRoot()` | Set merkle root for a raise's staker reward distribution | High |
| `transferAdmin()` + `acceptAdmin()` | Two-step admin transfer | Low |

### Trust Assumptions
- The merkle root determines who can claim staker rewards and how much. A compromised admin could set fraudulent roots to steal staker allocations.
- Each root can only be set once per escrow (no overwrites).

---

## 8. Token Distributor Roles

### Founder (`VibesTokenDistributorV2.founder`)
| Function | Description | Risk Level |
|----------|-------------|------------|
| `setDistributionRoot()` | Set merkle root for token + ETH refund distribution (once only) | High |
| `batchDistribute()` | Push-distribute tokens to backers | Medium |

### Admin (`VibesTokenDistributorV2.admin`)
| Function | Description | Risk Level |
|----------|-------------|------------|
| `sweepUnclaimed()` | After 6 months, sweep unclaimed tokens + ETH to ops wallet | High |

### Trust Assumptions
- The founder sets the distribution merkle root, which determines backer allocations. This is typically set by the Vibestarter backend based on onchain contribution data.
- `sweepUnclaimed` protects `totalPendingEthRefunds` from being swept (H8 fix).

---

## 9. Vesting Roles

### Authorized Starter (`VibesVesting.authorizedStarter`)
- Immutable — set to the router that deploys the vesting contract
- Can call `initializeAmount()`, `startVesting()`, `setAuthorizedFreezer()`

### Authorized Freezer (`VibesVesting.authorizedFreezer`)
- Set once by the authorized starter (typically the treasury escrow)
- Can call `freeze()` — burns all unvested tokens to 0xdead, prevents future releases

---

## 10. Contracts With No Privileged Roles

| Contract | Notes |
|----------|-------|
| `VibesToken` | No admin, no mint, no burn after deployment |
| `VibesTokenFactory` | No access controls — anyone can deploy tokens |
| `VibesStaking` | No admin — permissionless stake/unstake with 7-day cooldown |
| `MockTimeOracle` | Admin-controlled but testnet-only |

---

## Key Risk Matrix

| Risk | Severity | Affected Contracts | Mitigation |
|------|----------|-------------------|------------|
| Admin key compromise | Critical | All contracts with admin/owner | Multisig + timelock |
| `_excludeAddresses` manipulation | High | VibesTranchEscrow | Off-chain validation, onchain registry |
| `rescueETH` scope | High | VibesLaunchRouterV2 | Track reserved ETH, limit rescue amount |
| Fraudulent merkle roots | High | Distributor, StakerRewards | Off-chain audit trail, merkle tree verification |
| Mock time oracle on mainnet | High | All time-dependent contracts | Verify `timeOracle = address(0)` in deployment |
| Nuclear treasury burn | High | VibesTreasuryEscrow | Multisig governance for `upholdChallengeMalicious` |

---

## Operational Multisigs (off-chain role assignments)

Beyond the on-chain role holders above, three operational multisigs govern the platform at the organisational level. These are distinct Safes on Base; each has a specific purpose and cosigner set. Cosigner names / addresses are recorded below once the multisigs are deployed.

### M-1: Platform Operations Multisig

- **Purpose:** receives 2.5% ETH tranche fees + 0.5% token-side launch fees from all raises. Holds platform operational funds.
- **Type:** Safe (Gnosis) on Base. 2-of-3 threshold.
- **Cosigners:** `[TBD]`, `[TBD]`, `[TBD]`.
- **Scope:** pays for infra, contractors, audits, gas, legal/accounting once applicable. No personal distributions pre-entity per `docs/compliance/decisions-log.md` D10.
- **Address:** `[TBD — deployed pre-mainnet]`.

### M-2: $VIBES Raise Founder Wallet

- **Purpose:** receives tranche payouts (97.5% of each tranche) from Vibestarter's own raise, the $VIBES TGE. Must be fresh — no prior personal activity.
- **Type:** Safe (Gnosis) on Base. 2-of-3 threshold.
- **Cosigners:** `[TBD]`, `[TBD]`, `[TBD]`.
- **Scope:** holds raise proceeds on-chain per D10. No off-chain conversion / transfer / personal receipt in the pre-entity window. Proceeds assigned to the to-be-formed Luxembourg entity on formation.
- **Address:** `[TBD — deployed pre-mainnet]`.

### M-3: Protocol Admin Multisig (Operations Admin role)

- **Purpose:** acts as the on-chain Operations Admin across router, escrow, treasury, and factory contracts. Adjudicates challenges per `docs/challenge-standards.md`.
- **Type:** Safe (Gnosis) on Base. 2-of-3 (or 3-of-5) threshold.
- **Cosigners:** `[TBD]`, `[TBD]`, `[TBD]` (+`[TBD]`, `[TBD]` if 3-of-5).
- **Designated adjudicator for $VIBES raise challenges:** `[TBD — named non-founder cosigner]`. Founder is recused.
- **Address:** `[TBD — deployed pre-mainnet]`. This address is registered as `operationsAdmin` on the router via `setOperationsAdmin()`.

### M-4: Community Rewards Multisig

- **Purpose:** `admin` of `VibesCommunityRewards` contract. Post-6-month cliff, creates distribution batches (merkle roots) for airdrops, hackathons, grants, etc. Distributes at team discretion per `docs/tokenomics.md` §3 and `/vibes-raise-terms` §4.
- **Type:** Safe (Gnosis) on Base. 2-of-3 threshold.
- **Cosigners:** `[TBD]`, `[TBD]`, `[TBD]`. Recommend cosigner overlap with M-3 limited to at most one seat to avoid over-concentration.
- **Address:** `[TBD — deployed pre-mainnet]`.
- **On-chain powers:** `createBatch`, `rescueBatch`, `setPaused`, `transferAdmin`. **Cannot** release tokens before cliff; **cannot** bypass the merkle-proof gate on claims. Must respect the solvency invariant on batch creation.

### Separation of concerns

| Concern | Multisig |
|---|---|
| Platform fee receipts | M-1 |
| $VIBES raise founder payouts | M-2 |
| On-chain admin (challenges, moderation) | M-3 |
| Community Rewards distribution (post-6m cliff) | M-4 |

No single cosigner should hold simultaneous authority across M-2 + M-3 (founder wallet + admin) nor across M-3 + M-4 (admin + post-cliff community distribution), to maintain minimum credible separation. The founder personally may cosign M-1 and M-2; must be recused from M-3 adjudication of $VIBES raise challenges; and should hold at most one seat on M-4.

Cosigner identities are recorded here once confirmed. Cosigner rotation (adding / removing a signer) is itself a M-N operation requiring the threshold — no unilateral changes.
