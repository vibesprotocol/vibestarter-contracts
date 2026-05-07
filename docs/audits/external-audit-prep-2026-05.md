# External Audit Briefing — Vibestarter Protocol

> **For:** Spearbit / Trail of Bits / Zellic / OpenZeppelin / Code4rena (whichever firm we engage)
> **Audit subject:** Vibestarter smart contract suite, mainnet-prep state.
> **Goal of this doc:** Save the audit team 1–2 days of ramp-up. We've curated the architecture, prioritized the surface area by risk, listed our own open concerns, and pointed at the existing internal review docs so the engagement focuses on the highest-leverage areas.
>
> **Contact:** vibestarter team — see engagement letter for primary contact.
> **Repository:** `vibesprotocol/vibes-protocol` (private).
> **Audit branch:** `staging` at the SHA fixed in the engagement letter — do NOT chase HEAD; we will tag a specific commit at kick-off.

---

## 1. Top of mind — please look at these first

Two contract-level findings from our internal review are explicitly flagged "requires external auditor review before landing." We've done the analysis, written PoC tests where applicable, and described mitigations, but we want a third party to confirm the threat model and recommend the cleanest fix:

### Finding A — `setFeeConfig` accepts a reverting fee recipient

**Location:** `contracts/src/VibesRouterExtension.sol:586-595`

```solidity
function setFeeConfig(
    bool _enabled,
    uint256 _flatFeeWei,
    address _recipient
) external onlyOwner {
    if (_recipient == address(0)) revert ZeroAddress();
    feesEnabled = _enabled;
    flatFeeWei = _flatFeeWei;
    feeRecipient = _recipient;
}
```

If an admin (multi-sig) sets `_recipient` to a contract that reverts on `receive()` / `fallback()`, the next `launchWithCampaign` that pays a fee will revert during fee transfer, bricking every subsequent launch until the multi-sig can re-execute `setFeeConfig` with a working recipient.

**What we want the auditor to opine on:**
1. Severity rating in the context of a multi-sig-only setter (we're considering this Medium because there's no fast-recovery path during an attack).
2. Preferred mitigation:
   - `require(_recipient.code.length == 0)` (rejects any contract; prevents Safe-as-recipient which is sometimes desirable).
   - Try-send pattern: `(bool ok, ) = _recipient.call{value: 0, gas: 2300}(""); if (!ok) revert;`.
   - Move fee transfer to a pull-based escrow (fees accumulate; recipient calls `claim`).
3. Whether a similar pattern exists on `feeRecipient` consumers in `VibesLaunchRouterV2` / Phase-2 transfer.

### Finding B — `campaignToFeeClaimer` missing from `_calculateRedeemableSupply` exclusion set

**Location:** `contracts/src/VibesTranchEscrow.sol:378-407` and `contracts/src/VibesLPLocker.sol:96, 290-298`

When LP is created via `VibesLPLocker.createAndLockLP`, an EIP-1167 clone of `VibesLPFeeClaimer` is deployed per campaign and registered in `lpLocker.campaignToFeeClaimer[campaign]`. The clone holds the LP NFT/tokens permanently and is the on-chain target for `pool.claimFees()` — the project-token side of those fees ends up in the clone's balance until anyone calls `claimer.claim()`.

`_calculateRedeemableSupply()` (used by the freeze → pro-rata redemption path) excludes:
- 0xdead (LP burn)
- `vestingContract`, `stakerRewards`, `authorizedRouter`, `lpLocker`, `treasuryContract`, `address(this)`

It does NOT subtract the per-campaign fee-claimer's project-token balance. An attacker (or a benevolent caller) who calls `pool.claimFees()` post-finalization parks project tokens inside the claimer; if `freezeCampaign` later runs, those tokens count toward the redeemable supply denominator, diluting every backer's pro-rata refund.

**Why we haven't fixed it yet:** the cleanest fix touches the `setLockedAddresses` signature, which is called from the router during `_executePhase2`. We want the auditor to confirm:
1. Severity (we're calling it Medium grief — slow leak, not a one-shot drain).
2. Whether reading `lpLocker.campaignToFeeClaimer(address(this))` inside `_calculateRedeemableSupply()` is the right shape, vs. having the router push the address at finalization (mirrors how `treasuryContract` is wired today).
3. Whether any other "tokens that aren't really circulating" pools we missed (e.g. queued claims in the staker rewards contract).

A PoC test sketch is at `contracts/test/Audit2026_04_Findings.t.sol` — extend rather than re-derive.

---

## 2. Scope

### In scope (audit these)

All Solidity files under `contracts/src/` **except the explicitly out-of-scope ones below**. Source-of-truth inventory: `docs/smart-contracts.md` § "Contract Inventory".

**Core protocol (must audit):**
- `VibesLaunchRouterV2.sol` — main entry, EIP-712 launch signature, two-phase finalization
- `VibesRouterExtension.sol` — admin surface, `_executePhase1` / `_executePhase2`, fee config, rescue
- `VibesRouterStorage.sol` — shared storage layout (read alongside the two above)
- `VibesTranchEscrow.sol` — ETH escrow, contributions, tranches, challenges, refunds, freeze, F10 commit-reveal
- `VibesTranchEscrowFactory.sol` — EIP-1167 factory + per-factory two-step admin
- `VibesTreasuryEscrow.sol` — token treasury, proposal-based withdrawals, treasury challenges
- `VibesTokenDistributorV2.sol` — merkle-based token + ETH refund distribution
- `VibesVesting.sol` — 6mo cliff + 12mo linear founder vesting
- `VibesLPLocker.sol` — Aerodrome LP creation, permanent burn-to-0xdead, rescue path, `recordManualLPLock` (H-4)
- `VibesLPFeeClaimer.sol` — per-campaign fee-routing clone (NEW since prior audit)

**Staking + rewards:**
- `VibesStaking.sol` — VIBES staking, request-based unstake cooldown, F4 balance snapshots
- `VibesStakerRewards.sol` — accumulator-pattern reward distribution, snapshot reads

**Token + identity:**
- `VibesToken.sol` — fixed-supply ERC20 (small, but please check for surprises)
- `VibesTokenFactory.sol` — token deployer
- `VibesRegistry.sol` — provenance registry (origin capsules)
- `VibesIdentityRegistry.sol` — ERC-8004 agent registry (NEW since prior audit)

**Community rewards (NEW since prior audit, PC-02 / PC-03 / PC-04):**
- `VibesCommunityRewards.sol` — timelocked merkle-batch distributor (post-cliff)
- `VibesCommunityRewardsFactory.sol` — EIP-170-driven external factory

**Deploy script:**
- `contracts/script/DeployV2.s.sol` (mainnet branch) — wiring sequence is itself a security-relevant artifact; missing a step (e.g. `setSnapshotAuthorized`) bricks finalization. Validate the sequence matches the on-chain dependencies in `_executePhase1` / `_executePhase2`.

### Out of scope (skip these)

- `VibesTranchEscrowTestnet.sol`, `VibesTranchEscrowFactoryTestnet.sol` — testnet variants only; `setUseTestnetContracts` is hard-blocked on chain 8453 (`VibesRouterExtension.sol:695-698`). Audit the parity-guard test (`AuditTestnetParityGuard2026_04.t.sol`) only insofar as it confirms security constants are mirrored.
- `MockTimeOracle.sol`, `TestnetSwap.sol` — testnet utilities, not deployed on mainnet.
- Off-chain code (`apps/web/`, `packages/indexer/`, `packages/keeper/`) — audited separately under web-app review. Auditor may flag interface assumptions but is not expected to audit Next.js/TypeScript.

### Out-of-scope assumptions

- **OpenZeppelin v5** primitives (`ReentrancyGuard`, `Ownable2Step`, `SafeERC20`, `Pausable`, `ECDSA`, `EIP712`, `Clones`) — assume correct, unless misused.
- **Aerodrome DEX** is treated as a trusted external contract. We assume `IAerodromeRouter.addLiquidityETH` and `IAerodromePool.claimFees` behave per their public interface. Confirm via `LPForkTest.t.sol` (mainnet fork test).
- Solidity `^0.8.20` (compiled `0.8.24`); arithmetic-overflow protection assumed.

---

## 3. Architecture in 90 seconds

```
                 ┌────────────────────┐
                 │ VibesLaunchRouterV2│  ← onlyOwner = M-1 Safe (mainnet)
                 │  (+RouterExtension)│  ← operationsAdmin = M-3 Safe
                 │   delegatecall     │
                 └─────────┬──────────┘
                           │ launchWithCampaign(EIP-712-gated)
            ┌──────────────┼──────────────────────────────────────┐
            │              │                                      │
            ▼              ▼                                      ▼
   ┌────────────────┐ ┌──────────────┐                  ┌──────────────────────┐
   │VibesTokenFactor│ │TranchEscrowFa│                  │   Aerodrome DEX      │
   │     y          │ │ctory (proxy) │                  │ (trusted external)   │
   └────────┬───────┘ └──────┬───────┘                  └─────────▲────────────┘
            ▼                ▼                                    │
   ┌────────────────┐ ┌──────────────────┐ Phase-1 LP creation   │
   │  VibesToken    │ │ TranchEscrow     │────────────┐           │
   │ (fixed-supply) │ │   (EIP-1167      │            │           │
   └────────────────┘ │    clone)        │            ▼           │
                      │                  │   ┌─────────────────┐  │
                      │ • contributions  │   │ VibesLPLocker   │──┘ addLiquidityETH
                      │ • tranches (T0-6)│   │  • burns LP NFT │
                      │ • challenges     │   │  • deploys per- │
                      │ • F10 merkle     │   │    campaign     │
                      │ • freeze + redeem│   │ VibesLPFeeClaim │
                      └────────┬─────────┘   │    -er clone    │
                               │             └─────────────────┘
                  Phase-2 distribution
                               ▼
   ┌──────────────┐  ┌──────────────────┐  ┌─────────────────┐
   │ VibesVesting │  │VibesTreasuryEscr │  │ VibesStakerRew  │
   │ (founder 6+12│  │ ow (proposal-    │  │ ards (accumul.- │
   │  mo)         │  │  based, treasury │  │  pattern,       │
   └──────────────┘  │  challenges)     │  │  F4 snapshots)  │
                     └──────────────────┘  └────────┬────────┘
                                                    │ takeSnapshot()
                                                    ▼
                                          ┌──────────────────┐
                                          │  VibesStaking    │
                                          │ (VIBES, 7d cool- │
                                          │  down, request-  │
                                          │  based unstake)  │
                                          └──────────────────┘

(separate trees, deployed once each:)
   VibesRegistry           — provenance "origin capsule" registry
   VibesIdentityRegistry   — ERC-8004 agent identity (independent)
   VibesCommunityRewards   — per-launch via Factory; cliff + merkle batches
   VibesTokenDistributorV2 — per-launch; merkle-based token + ETH refund
```

**Two-phase finalization (critical path):**
1. **Phase 1 (`_executePhase1`)**: LP creation only — escrow ETH for LP gets transferred, locker creates Aerodrome pool, locks LP, deploys per-campaign fee claimer clone. Sets `finalizationPhase = LPComplete`.
2. **Phase 2 (`_executePhase2`)**: Token distribution — vesting transfer, treasury wire-up, staker-rewards `notifyReward` (which atomically calls `staking.takeSnapshot()`), founder deposit refund. Sets `finalizationPhase = FullyComplete`.

The split exists because the original 12-call inline finalization OOG'd at ~1.6M gas on Base (testnet incident, two raises stuck). Phase 1 is ~800K, Phase 2 ~400K. Each phase is idempotent and admin-retriable; tokens distribute in Phase 2 and are gated by `finalizationPhase == FullyComplete` (H-3 cross-contract guard).

**Deeper architecture:** `docs/smart-contracts.md` (234 lines, full inventory + relationships).

---

## 4. Trust model

Full role table: `docs/privileged-roles.md`. TL;DR for the auditor:

| Role | Wallet | Set how | Can move user funds? | Key powers |
|---|---|---|---|---|
| **M-1 Master Admin** | Gnosis Safe (≥2-of-3) | Router constructor → `transferOwnership` to Safe post-deploy | **Yes** | `pause`, `setEscrowFactory`, `setLPLocker`, `setStakerRewardsContract`, `setFeeConfig`, `setTrustedLaunchSigner`, `rescueETH`, `rescueERC20`, `transferOwnership`, `setOperationsAdmin` |
| **M-2 $VIBES Founder Safe** | Gnosis Safe | Off-chain for $VIBES TGE only | No (acts as launcher) | Calls `launchWithCampaign` once for the $VIBES TGE under PC-01/PC-03 admin pre-authorization |
| **M-3 Operations Admin** | Dedicated EOA | M-1 calls `setOperationsAdmin` (revocable) | No — only freeze, return stake, or burn to 0xdead | `upholdChallenge`, `rejectChallenge`, `freezeCampaign`, `commitRefundMerkleRoot` (24h timelock), `forceRefundDuringRaise`, `emergencyRefundFunded`, `adminTopUp`, treasury challenge resolvers |
| **M-4 Community Rewards Safe** | Gnosis Safe | Set per-launch via PC-03 `setCommunityAllocationForLaunch(launcher, bps, cliff, communityAdmin)` | No — admin of `VibesCommunityRewards` post-cliff | `createBatch`, `rescueBatch` after claim window |
| **Trusted launch signer** | Hardware-isolated EOA | M-1 via `setTrustedLaunchSigner` | No (pure auth) | EIP-712-signs `(founder, nonce, deadline)` to gate `launchWithCampaign` |
| **Trusted terms signer** | Same / sibling EOA | Set per-escrow at `initialize` (M-3 can rotate) | No | EIP-712-signs `(user, nonce, deadline)` to gate `contribute`, `raiseChallenge`, `supportChallenge`, `opposeChallenge`, `stake` |

**Compromise impact ranking:** M-1 > M-3 > M-2 > M-4. M-1 compromise is platform-wide fund loss (bounded by `totalReservedDeposits` guard on `rescueETH`). M-3 compromise is bounded to per-campaign freeze/burn — no wallet-controllable fund extraction.

**As of audit kickoff:** all four multisigs are still `[TBD]` in `docs/privileged-roles.md`. Deployment + signer ceremony will happen pre-mainnet but post-audit. We expect the auditor to red-flag any code path where M-3 powers are stronger than the doc claims (e.g. an admin-only function that could exfiltrate ETH).

---

## 5. Risk-ranked review priorities

Tier 1 is where we'd spend the bulk of audit hours; Tier 4 we expect the auditor to skim.

### TIER 1 — fund-flow critical paths (highest priority)

**1.1 Two-phase finalization & token-distribution race conditions**
- `VibesRouterExtension.sol:52` (`completeFinalization`), `:71` (`_executePhase1`), `:152` (`_executePhase2`)
- `VibesTranchEscrow.sol:378-407` (redeemable supply) — see Finding B above
- Specifically check:
  - **CEI ordering** in `_executePhase2`: state must mark `FullyComplete` BEFORE the founder-deposit ETH refund external call (existing fix; please verify it's still in place).
  - **Phase-1-without-phase-2 reachability**: between Phase 1 and Phase 2 the escrow has `lpCreated == true` but `finalizationPhase == LPComplete`. Token claims (`_claimTokensInternal`) hard-require `finalizationPhase == FullyComplete` per H-3. Confirm there is no Phase-2 retry path that re-runs Phase-1 transfers.
  - **`completeDistribution` reentrancy**: marked `nonReentrant`. Confirm the snapshotted `stakerRewardsContract` address can't drift between phases (we cache it in Phase 1).
  - **Idempotency**: `_stakerTokensTransferred` flag decouples transfer from `notifyReward` for retry. Confirm a partial Phase-2 with transfer-success / notify-fail re-runs safely.
  - **`adminRetryFinalization`** — admin-only retry path; verify it cannot move funds to attacker.

**1.2 EIP-712 signature verification & nonce semantics**
- `VibesLaunchRouterV2.sol:343` (`_verifyLaunchSignature`)
- `VibesTranchEscrow.sol:409-...` (`_verifyTermsSignature`) — note it's called from `contribute`, `raiseChallenge`, `supportChallenge`, `opposeChallenge`
- `VibesStaking.sol:169` (`_verifyTermsSignature` for `stake`)
- Specifically check:
  - **Nonce monotonicity** — incremented exactly once per successful verification, regardless of caller path.
  - **Replay across forks** — `block.chainid` baked into the EIP-712 domain separator. Verify constant computation; we don't recompute on chainid change post-deploy (acceptable given Base doesn't fork).
  - **Trusted-signer == address(0) bypass** — when not set, gating is disabled. Verify this is gated behind admin and audited; check if there's a path to set it to address(0) on mainnet (we don't think so, but confirm).
  - **Signature struct shape** — `TermsAcceptance(address user,uint256 nonce,uint256 deadline)` and `LaunchAuthorization(address founder,uint256 nonce,uint256 deadline)`. Hash collisions would let one signature replay as another type — verify the typehashes are distinct.

**1.3 Pro-rata refund accounting (F1, F3, F6)**
- `VibesTranchEscrow.sol:1157` (`claimContributorRefund`)
- `VibesTranchEscrow.sol:1216` (`claimExcessRefund`)
- `VibesTranchEscrow.sol:996` (`emergencyRefundFunded`)
- `VibesTranchEscrow.sol:1037` (`adminTopUp`)
- Specifically check:
  - **Double-refund prevention**: prior excess claims subtracted from contributor refund liability (F1).
  - **Solvency guard**: `emergencyRefundFunded` requires `address(this).balance >= totalLiability` before state→Failed (F3). Same guard applies to `freezeCampaign` zero-supply fallthrough (F-1 from 2026-04-16).
  - **`frozenEthBalance` underflow**: safe subtraction (F6). Verify all subtractions in challenge upholds use the safe path.
  - **Pro-rata proportional rounding**: dust accumulation behavior on small contributions; confirm `BPS_DENOMINATOR=10000` rounding bias favors the protocol (rounds down on backers, never overpays).

**1.4 LP rescue / lock state machine (F7, H-4)**
- `VibesLPLocker.sol` — full file
- `VibesRouterExtension.sol` — `completeLP`
- Specifically check:
  - **`hasRescuedLP` vs `hasLockedLP`** — rescue paths set the rescue flag, NOT the lock flag. Views (`getLockedPosition`, `verifyLPLocked`, `getInitialPrice`) return correct data on rescued campaigns.
  - **`createAndLockLP` double-call** — checks both flags before proceeding.
  - **`recordManualLPLock`** (H-4) — admin records a manually-created LP lock; requires `IERC20(pool).balanceOf(0xdead) >= lpAmount` on-chain proof. Verify there's no path to falsify this (e.g. attacker pre-burns pool tokens to 0xdead, then claims a fake "lock").
  - **`completeLP`** in router-extension — requires `lpLocker.verifyLPLocked()` returns true before flipping `pendingLP` state.
  - **`forceApprove`** (L-4) — three approve sites switched to `SafeERC20.forceApprove` for USDT-like tokens. Verify no remaining `approve()`.
  - **`VibesLPFeeClaimer` per-campaign clone** — soulbound, no transfer/withdraw/rescue/admin. Verify the clone has zero attack surface beyond `claim()` routing.

**1.5 Snapshot-based staker rewards (F4)**
- `VibesStaking.sol:197` (`setSnapshotAuthorized`), `:206` (`takeSnapshot`), `:223` (`balanceAtSnapshot`), `:289` (`_writeSnapshotsBeforeBalanceChange`)
- `VibesStakerRewards.sol:156` (`notifyReward`), `:271` (`_getStakerBalance`)
- Specifically check:
  - **Snapshot authorization** — `staking.setSnapshotAuthorized(stakerRewards, true)` MUST be called post-deploy or `notifyReward` reverts on every finalization. The deploy script does this; confirm there is no path where a launch finalizes against an unauthorized stakerRewards.
  - **`firstStakeTime` eligibility** — anti-exploit: prevents a backer who didn't stake before finalization from siphoning rewards.
  - **`_getStakerBalance` snapId==0 fail-closed** (L-3) — old code had a current-balance fallback that re-introduced F4. Verify `revert NoSnapshotForRaise()` is the only path.
  - **Snapshot lazy-write semantics** in `_writeSnapshotsBeforeBalanceChange` — stake/unstake writes the staker's balance to all snapshots since their last action. Confirm no state that could let a staker's snapshot balance be inflated post-snapshot.
  - **`canClaim` double-hash** (audit-fix C-02) — leaf hash MUST match `_claimInternal`'s. Both should use double-hash now.

**1.6 F10 commit-reveal merkle root timelock**
- `VibesTranchEscrow.sol:1108` (`commitRefundMerkleRoot`)
- `VibesTranchEscrow.sol:1117` (`finalizeRefundMerkleRoot`)
- Plus `cancelPendingMerkleRoot`
- Specifically check:
  - **24h elapsed-time enforcement** — `MERKLE_ROOT_DELAY` is `1 hours` on testnet too (H-2 parity). Audit the parity-guard test.
  - **Cancel race** — admin can cancel a pending root; verify there's no race where finalize and cancel could both succeed.
  - **Off-chain root generation** — out of scope for the audit, but the on-chain code should make root substitution post-commit impossible. Confirm.

**1.7 Treasury escrow challenge resolvers (M-1, M-2, M-3)**
- `VibesTreasuryEscrow.sol` — full file, ~528 lines
- Specifically check:
  - **`upholdChallengeMalicious`** — NUCLEAR option, burns treasury tokens to 0xdead and freezes the linked vesting contract. Verify it can't be triggered via re-entrancy through a malicious treasury-token.
  - **`upholdChallengeRework`, `rejectChallenge`, `expireChallengeIfNeeded`** — all `nonReentrant` (M-1, M-2). Verify the boundary-close of challenge windows uses `>=` not `>` (M-3 fix).
  - **`resolveRescuedFunds`** — `nonReentrant` (L-1). Verify admin-only and bounded-scope.

### TIER 2 — newly-introduced surface area (not yet audited)

PC-01 through PC-05 + the LP fee claimer all landed AFTER the 2026-04-15 internal audit remediation. They have unit tests but have never seen external review.

**2.1 PC-01 — `setStakerAllocationDisabled` global flag**
- `VibesRouterExtension.sol:634`, `VibesLaunchRouterV2.launchWithCampaign` allocation math
- Confirm: token conservation when flag is true (founder + treasury + LP + 0 staker + backer = totalSupply). The 2.5% slice flows into backers when disabled — verify no double-counting.
- Confirm: no path where a launch starts with flag=true but completes with flag=false (or vice versa) due to a mid-launch admin toggle.

**2.2 PC-03 / PC-04 — atomic per-launcher community rewards**
- `VibesRouterExtension.sol:661` (`setCommunityAllocationForLaunch`)
- `VibesLaunchRouterV2.launchWithCampaign` — community deploy + transfer + clear sequence
- `VibesCommunityRewardsFactory.sol:create`
- `VibesCommunityRewards.sol` — full file (cliff, batches, rescueBatch)
- Confirm:
  - **One-shot consumption** — `delete communityConfigForLaunch[msg.sender]` BEFORE the external `factory.create(...)` call (CEI). A second `launchWithCampaign` from the same wallet must NOT re-use the config.
  - **Backer floor (50%)** — `MIN_BACKER_ALLOCATION_BPS = 5000` enforced in launch path even when community slice is non-zero.
  - **Factory permissionless `create`** — anyone can deploy a `VibesCommunityRewards` standalone. Verify the factory's address is unprivileged from the protocol's perspective (a stray deploy is harmless).
  - **Cliff immutability** — `unlockTime` set in constructor; admin cannot accelerate.

**2.3 PC-05 — Combined founder+treasury cap raised to 20%**
- `VibesRouterStorage.MAX_FOUNDER_PLUS_TREASURY_BPS = 2000`
- Confirm the `MAX_FOUNDER_ALLOCATION_BPS (750)` and `MAX_TREASURY_ALLOCATION_BPS (1750)` per-slice caps still bind, even with the combined cap raised.

**2.4 `VibesLPFeeClaimer`** — full file (157 lines)
- Confirm:
  - Soulbound design — no transfer, no withdraw, no admin functions.
  - `claim()` correctly routes WETH side to `feeRecipient` and project-token side to treasury (or burns if treasury is terminated/unset).
  - The `pool()` immutable matches the campaign's pool — used by `recordManualLPLock` to validate.
  - Reentrancy — `claim()` calls into Aerodrome's pool; verify no callback reentry.
  - Pre-deployed clone behavior — the rescue-recovery path passes a pre-deployed claimer to `recordManualLPLock`; verify the validation of `claimer.pool() == _pool` and `claimer.campaign() == _campaign` is sufficient.

**2.5 `VibesIdentityRegistry`** (ERC-8004) — full file
- New since prior audit. Treat as low-risk (no fund flows) but confirm no admin override that could de-anonymize / reassign identities held by users.

### TIER 3 — admin surface, infrastructure swaps

**3.1 `setEscrowFactory` / `setLPLocker` / `setStakerRewardsContract`**
- `VibesRouterExtension.sol:597, 602, ~610`
- These swap critical infrastructure WITH NO TIMELOCK. Recommended remediation is OZ TimelockController or equivalent (`docs/security/pre-mainnet-requirements.md` §3). We have **not** implemented it; we want the auditor to recommend the cleanest pattern given our existing two-step ownership and the M-1 multi-sig.

**3.2 `rescueETH` / `rescueERC20`**
- `VibesRouterExtension.sol:796, 818`
- Existing guards:
  - `rescueETH`: cannot drain `totalReservedDeposits`.
  - `rescueERC20`: blocks if token has pending backer claims, active escrow (`tokenToEscrow != 0`), or pending LP (`pendingLP.tokenAmount > 0`).
- Confirm:
  - `pendingLP.tokenAmount > 0` guard does NOT have the `escrowAddr == address(0)` bypass that F8 closed.
  - The `Failed/Frozen/Refunding` state override (item #20) doesn't open a path to drain tokens that backers can still claim.

**3.3 `setUseTestnetContracts` mainnet block**
- `VibesRouterExtension.sol:695-698`: `require(block.chainid != 8453)`.
- Trivial but critical — confirm it's literal `8453`, not a state variable or storage-derived value.

**3.4 Two-step admin/owner across all contracts**
- `VibesTranchEscrow.transferAdmin` / `acceptAdmin`, factory, treasury, LP locker, router, staker rewards
- Confirm the pendingAdmin slot can't be set to address(0) and accept by anyone.

**3.5 `factory.lockTimeOracle()` one-way latch (added 2026-05-07)**
- `VibesTranchEscrowFactory.sol::lockTimeOracle()` — admin-only, single-shot, sets `bool timeOracleLocked = true`. After this call, `setTimeOracle` reverts permanently.
- Motivation: surfaced by self-conducted adversarial test (`docs/security/adversarial-test-2026-05.md` § ADV-02). On mainnet there's no operational reason to ever rotate the time source post-deploy — `timeOracle = address(0)` (= `block.timestamp`) is the production answer. The lock removes the rotation attack surface entirely. Existing audit fix H-06 (`MAX_TIME_DRIFT = 1 hours` upper bound) caps forward warp on the unlocked path, so the residual surface is griefing-only on FUTURE raises — but the lock removes even that.
- Pre-mainnet runbook: post-deploy Safe call to `factory.lockTimeOracle()`, gated on `factory.timeOracle() == address(0)` pre-condition. Documented in `docs/first-mainnet-deployment.md` § "Post-deploy hardening" item 5.
- Auditor ask:
  - Confirm the latch is genuinely one-way (no path to flip back to `false`).
  - Confirm there's no escrow-side path that re-derives `timeOracle` from the factory after lock (per-clone state is read once during `initialize`; we believe nothing else reads from factory storage post-init).
  - Sanity-check that the testnet variant (`VibesTranchEscrowFactoryTestnet.sol`) is intentionally unaffected — testnet needs to be able to rotate the mock oracle for fast-forwarding; the lock would brick that.

### TIER 4 — lower priority but worth a skim

- `VibesRegistry.sol` — provenance-only, no fund flows. Confirm `VibesCertified` event is well-formed.
- `VibesTokenDistributorV2.sol` — only used by certain raise types; CEI ordering on `batchDistribute` is a known low-severity Slither hit (totals updated after `.call`); confirm `nonReentrant` + `hasClaimed` still bind.
- `VibesTokenFactory.sol` — `deployToken` is permissionless (L-2, deferred). Confirm spam-grief is the only reachable harm.
- `VibesToken.sol` — fixed-supply ERC20. Skim for any non-standard behavior.

---

## 6. Threat model

**In-scope adversary capabilities:**
1. **Backer with intent to extract** — can contribute, claim, request refunds, raise/support/oppose challenges, vote on treasury proposals.
2. **Founder with intent to extract** — can launch, request tranches, claim vesting, propose treasury withdrawals.
3. **External MEV searcher** — can sandwich any public tx on Base. Particular concern: LP creation (existing fix EA-1: `validateNoSandwich` invariant in `addLiquidityETH`).
4. **Compromised M-3 (operations admin)** — can freeze any campaign, commit a malicious refund merkle root (24h delayed by F10), reject challenges. CANNOT extract funds to controlled addresses.
5. **Front-runner of admin txs** — see "admin tx visibility" below.

**Out-of-scope adversaries:**
- Compromised M-1 multi-sig (3 simultaneous key compromises) — accepted as residual risk.
- Compromise of the Base sequencer — out of scope.
- L1 reorg deeper than ~1 epoch — accepted; we don't operate on probabilistic finality assumptions for fund-moving txs.

**Key invariants (these MUST hold):**
1. **Token conservation per launch:** `founder + treasury + LP + staker + backer = totalSupply` (holds when staker disabled with `staker = 0`, slice absorbed into backer). Tested in `CrossContractInvariant.t.sol`.
2. **ETH conservation per escrow:** `totalRaised = sum(refunded) + sum(tranches paid) + frozenBalance + lpEthSent + platformFees`.
3. **No double-claim:** for any (campaign, user, kind), `claim*` succeeds at most once.
4. **No double-refund** between excess and contributor refund paths (F1).
5. **`finalizationPhase` monotonicity:** `None → LPComplete → FullyComplete`, never decreases.
6. **`hasLockedLP` ⊕ `hasRescuedLP`** — never both true for the same campaign.
7. **F10:** `pendingMerkleRoot != 0 ⇒ block.timestamp >= merkleRootCommitTime + MERKLE_ROOT_DELAY` before `finalizeRefundMerkleRoot` succeeds.
8. **Snapshot freshness:** for any (raise, staker), `_getStakerBalance` reads from `raiseSnapshotId[raise]`, never current balance (L-3 closed the fallback).

If you find a path that breaks any of these, we want to know — these are our hard floor.

---

## 7. Prior audit history (don't redo this work)

Three internal audit cycles + one external. We want fresh eyes, but please skim these so the engagement isn't spent rediscovering closed findings.

| Date | Doc | What it covers | Status |
|---|---|---|---|
| 2026-03-27 | `docs/security-audit-consolidated-2026-03-27.md` (334 lines) | First external pass — A-G remediation, two-tier admin separation, `setUseTestnetContracts` mainnet guard, EIP-712 signature gating | All findings closed; mapped to changes #5-#12 in `docs/pending-contract-changes.md` |
| 2026-04-04 | `docs/security-analysis.md` (579 lines) | Internal F1-F10 audit — pro-rata double-refund, `adminTopUp`, solvency guards, F4 snapshot rewards, F10 commit-reveal | All F1-F10 closed; tests in `AuditFixes.t.sol`, `AuditSecurityTests.t.sol`, `CrossContractInvariant.t.sol` |
| 2026-04-14 | `docs/security-audit-2026-04-14.md` (840 lines) | Adversarial pass — H-1 through L-4 (cross-contract finalization guards, parity drift, recordManualLPLock, defense-in-depth nonReentrant) | All closed; remediation summarized in `docs/security-remediation-2026-04-15.md` |
| 2026-04-16 | (referenced inline in `docs/pending-contract-changes.md`) | F-1 (zero-supply freeze solvency), F-2 (treasury redeemable-supply exclusion) | Both closed in 2026-04-16 work |
| Internal review pass | `docs/review-smart-contracts.md` (718 lines) | Section-by-section technical review with test references | Rolled into the engagement gate |

**Critical takeaway:** the contracts have been heavily reworked in the last 8 weeks. Anything dated before 2026-03-15 in git blame is older context; the substantive fund-safety work is all post-March.

---

## 8. Test coverage

- **Total tests:** ~1,014 (including invariants).
- **Test files:** 46 in `contracts/test/` + 4 in `contracts/test/invariants/`.
- **Largest suites:**
  - `VibesTranchEscrow.t.sol` (64 tests) + `VibesTranchEscrowEdgeCases.t.sol` (30) + `VibesTranchEscrowTestnet.t.sol` (77 — parity)
  - `VibesLaunchRouterV2.t.sol` (55)
  - `VibesTreasuryEscrow.t.sol` (69)
  - `AuditFixes.t.sol` (51) + `AuditRemediation2026_04.t.sol` + `Audit2026_04_Findings.t.sol`
  - `VibesFinalizationPhases.t.sol` (27) — Phase 1 + Phase 2 split coverage
- **Invariants:**
  - `VibesStakingInvariants.t.sol` — total stake conservation, snapshot determinism
  - `VibesTranchEscrowExtendedInvariants.t.sol` — ETH + token conservation
  - `VibesTreasuryEscrowInvariants.t.sol` — proposal-state machine
  - `VibesVestingInvariants.t.sol` — vesting math monotonicity
  - `AuditEscrowInvariants2026_04.t.sol` — consolidated post-audit invariants

**Run them:**
```bash
cd contracts && forge install
forge test                                   # all tests, default verbosity
forge test -vvv                              # with traces
forge test --match-test invariant_           # invariants only
forge test --match-contract Audit            # all audit-derived suites
forge coverage --report lcov                 # coverage (slow ~5 min)
```

**Inventory:** `docs/test-coverage-analysis.md`.

**Static analysis we've already run (results in `docs/security-analysis.md`):**
- Slither — 23 `reentrancy-eth` instances, all protected by `nonReentrant` or trusted-caller. CEI violation in `VibesTokenDistributorV2.batchDistribute` is documented & mitigated.
- Aderyn — not yet run (Rust toolchain not in our default env). Auditor welcome to run.
- Mythril — not run; auditor's call.
- Slither in CI is **NOT YET BLOCKING** — previous attempts OOM-killed the runner. We list this as an open mainnet-readiness item; auditor recommendation on a tractable subset welcome.

---

## 9. Deploy script — please review the wiring sequence

`contracts/script/DeployV2.s.sol` (mainnet branch). The wiring sequence itself is security-critical: missing any of these post-deploy calls bricks finalization on first launch, with no easy recovery once funds are in escrow.

**Required wiring** (M-1 must execute, ideally as a single Safe transaction batch):

```
router.setEscrowFactory(newFactory)
router.setOpsWallet(opsWallet)
registry.authorizeRouter(newRouter)
lpLocker.setAuthorizedRouter(newRouter)
lpLocker.setFeeClaimerImplementation(feeClaimerImpl)         ⬅ critical (createAndLockLP reverts otherwise)
router.setOperationsAdmin(M-3 Safe)
factory.setAdmin(M-3 Safe) → factory.acceptAdmin() from M-3
router.setFeeConfig(true, feeAmount, M-1 Safe)
router.setTrustedLaunchSigner(trustedSignerAddress)
router.setStakerRewardsContract(stakerRewards)
staking.setSnapshotAuthorized(stakerRewards, true)            ⬅ critical (notifyReward reverts otherwise)
router.setCommunityRewardsFactory(communityFactory)           ⬅ critical for any launch using PC-03
router.setStakerAllocationDisabled(true)                       ⬅ before $VIBES TGE only
router.setCommunityAllocationForLaunch(...)                    ⬅ before $VIBES TGE only
router.transferOwnership(M-1 Safe) → acceptOwnership() from M-1
```

**What we want the auditor to confirm:**
1. The deploy script actually emits all of these (or the Safe bundle does).
2. There is no on-chain interleaving that could let a launch start mid-wire-up.
3. The order is correct — e.g. `transferOwnership` is last, after every other setter the deployer EOA needs to call.

---

## 10. Engagement specifics — what we want from the audit

**Deliverables:**
1. A finding-by-finding report with severity (Critical / High / Medium / Low / Informational), file:line, description, PoC where reasonable, and recommended remediation.
2. A signed cover note we can commit to `docs/security/` and reference in `docs/pending-contract-changes.md`.
3. A re-audit pass on the remediation PRs (1-2 rounds expected).

**Severity rubric we use internally** (please align unless you have a strong reason):
- **Critical** — direct fund loss / unbounded fund extraction / protocol bricking with no recovery.
- **High** — bounded fund loss, recoverable fund-loss, governance compromise that could escalate.
- **Medium** — grief, denial of specific user actions, recoverable bricking, MEV-extractable value.
- **Low** — best-practice violations, gas issues, doc gaps.
- **Informational** — style, naming, optimizations.

**Communication channels:**
- Daily async standups via shared Slack channel during active audit weeks.
- Slack/Discord availability for clarifying questions; we expect to be responsive within ~4 business hours during the engagement.
- For draft findings: shared Notion or git PR comments — auditor's preference.

**Things we particularly DON'T want:**
- Re-litigation of the closed findings in §7 unless you've found a new attack surface.
- Style pass on testnet variants and mocks.
- Coverage of off-chain code (we have a separate audit for that).

**Things we DO want even if low-severity:**
- Anything that could be exploited by a single backer to recover more ETH than they contributed.
- Anything that could be exploited by a founder to claim tranches without satisfying the time-based gate.
- Anything that could let M-3 (operations admin) move funds outside the protocol's intended sinks (founder, treasury, vesting, staker rewards, 0xdead).
- Pattern-level concerns that we should harden before a $VIBES TGE goes live (high-value first launch).

---

## 11. Reading order for the auditor

If you have ~4 hours of solo ramp-up before kickoff, we suggest:

1. **This doc** (you're reading it) — 30 min.
2. `docs/funding-mechanics.md` — 20 min. How money flows; raise types; tranche schedule; challenge system.
3. `docs/smart-contracts.md` — 20 min. Inventory + relationships + constants.
4. `docs/privileged-roles.md` — 30 min. Full role table.
5. `docs/security-audit-2026-04-14.md` — 60 min. Most recent prior audit; understanding the H-1 through L-4 fixes is the fastest way to internalize the code's threat model.
6. `docs/pending-contract-changes.md` (PC-01 through PC-05 sections) — 30 min. Newly-introduced surface area not covered in any prior audit.
7. Pull `contracts/test/AuditFixes.t.sol` and `AuditRemediation2026_04.t.sol` open in your editor — 30 min. These tests encode our threat model better than prose.

After kickoff, drill into Tier 1 (§5) first.

---

## 12. Engagement metadata

| Field | Value |
|---|---|
| Solidity version | 0.8.24 (compiler), `^0.8.20` pragma |
| Framework | Foundry (forge-std v1.x) |
| Library | OpenZeppelin v5 |
| Target chain | Base mainnet (8453) |
| Total LoC (in-scope) | ~6,400 (excluding testnet variants, mocks, interfaces) |
| Total tests | ~1,014 |
| Contract count (in-scope) | 14 |
| Largest contracts | TranchEscrow (1,335), RouterExtension (841), LaunchRouter (481), StakerRewards (503), TreasuryEscrow (528) |
| Public/external functions | ~180 (rough count) |
| Estimated audit budget | 3–4 person-weeks (target firm), 6–8 person-weeks (worst-case) |
| Re-audit budget | 1 person-week per remediation round (expect 1-2 rounds) |
| Date target | Audit kickoff: TBD; report by: TBD; mainnet launch: gated on signed report |

---

## 13. Open questions we'd particularly like the auditor's view on

These are non-blockers but would significantly improve our confidence at launch:

1. **Timelock pattern for `setEscrowFactory` / `setLPLocker` / `setFeeConfig`** — recommended approach given our M-1 Safe + existing two-step ownership? OZ TimelockController or custom?
2. **Slither CI gate** — what subset of detectors should be blocking? Previous full-detector-JSON runs OOM'd the GitHub runner.
3. **Front-running of admin txs** — should `setRefundMerkleRoot` (now commit-reveal) extend the same pattern to other sensitive setters, or is current scope sufficient?
4. **`rescueETH` upper bound** — should we cap rescue amount per call (e.g. `min(balance - reserved, 50 ETH)`) to limit blast radius of a master-key compromise?
5. **PC-03 community-rewards launcher impersonation** — `setCommunityAllocationForLaunch(launcher, ...)` is keyed on the launcher's address. If the founder's wallet is later compromised, the attacker can call `launchWithCampaign` once. Is there a tighter binding pattern (e.g. require a fresh EIP-712 signature from launcher AND admin per-launch)?
6. **`rescueUnclaimable` in StakerRewards** — admin-only path to recycle unclaimable rewards. Verify no path to drain claimable rewards.

---

## 14. Final word

We've front-loaded this prep doc because the protocol surface is large and non-trivial, and because we believe an auditor's hours are better spent on Tier 1 fund-flow paths than on figuring out which contract talks to which. If anything in the architecture summary contradicts what you read in the code, **trust the code** and tell us — that drift is itself a finding.

Looking forward to the engagement.
