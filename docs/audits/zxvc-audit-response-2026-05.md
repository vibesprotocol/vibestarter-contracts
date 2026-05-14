# Vibestarter — Response to ZXVC 2026-05 Audit

**To:** ZXVC LLC (Chance Santana-Wees)
**Re:** Vibestarter Protocol Smart Contract Security Audit, 2026-05-09
**Vibestarter remediation lead:** Ross + Claude (Opus 4.7)
**Branch:** `claude/review-audit-findings-36SM7` (private monorepo; merged to private `staging` 2026-05-14)
**Date:** 2026-05-13

> **Public repo note:** File paths cited below use the private-monorepo layout
> (`contracts/src/X.sol`, `contracts/test/Y.t.sol`). In this public mirror the
> same files live one level up (`src/X.sol`, `test/Y.t.sol`) — the source diff
> referenced by each commit hash is reproduced in the public-repo sync commit
> that introduced this document. Testnet-only files (`VibesTranchEscrowTestnet.sol`,
> `VibesFinalizationPhases.t.sol`) are intentionally absent from this mirror; the
> mainnet variant carries the same fix.

---

## Summary

Thanks for the thorough audit. We have remediated **13 of the 14 items** you raised
(11 formal findings + 2 of the 3 PoC-bundle extras). The 14th item (Extra-3, launch
signature payload binding) is **not a remediation target** under our security model:
account-level signature binding is intentional and matches how we operate the launch
flow. The Extra-3 section below walks through that decision in detail.

Every PoC in the suite you delivered has been either flipped to assert the
post-fix behaviour, or left in place where appropriate to document an
intentional design choice (Extra-3 only).

We agree with your "not production ready until High and H/M findings remediated
and re-tested" verdict and are requesting a re-audit pass on this branch before
mainnet deploy. The patches landed under time pressure are exactly where new
bugs hide; an extra set of eyes is the right control.

This document walks through each finding from your report and points to the
commit (and flipped PoC) that closes it. Commit hashes refer to the
`claude/review-audit-findings-36SM7` branch.

---

## Findings — Status Table

| # | Finding | Reviewer's reframe | Severity | Status | Commit |
|---|---|---|---|---|---|
| 1 | VIB-01 | Frozen refund denominator over-counts non-redeemable balances | High | ✅ Remediated (option a) | `15c53222` |
| 2 | VIB-02 | Ops admin can manipulate frozen refund denominator | **High** (you rated H/M; we agree this is High) | ✅ Remediated | `15c53222` |
| 3 | VIB-03 | Deployment is not fail-closed (silent broken staker rewards) | High/M | ✅ Remediated | `890f6a74` |
| 4 | VIB-04 | Staker eligibility uses current `firstStakeTime`, not snapshot | High/M | ✅ Remediated | `954668db` |
| 5 | VIB-05 | Unbounded snapshot backfill (gas-DoS) | Medium | ✅ Remediated (smaller-diff variant) | `4a7bdd37` |
| 6 | VIB-06 | Same-block stake dilution + dust rescue | Medium | ✅ Remediated (both parts) | `f7c1213d` |
| 7 | VIB-07 | Registry squat on predicted factory address | Low | ✅ Remediated | `4148967e` |
| 8 | VIB-08 | `trancheChallenged` not cleared on reject/expire | Medium | ✅ Remediated | `588288ce` |
| 9 | VIB-09 | `recordManualLPLock` accepts arbitrary pool + holder | Medium | ✅ Remediated | `0e36083f` |
| 10 | VIB-10 | Community batch claim can exceed batch total | Medium | ✅ Remediated | `4148967e` |
| 11 | VIB-11 | `claimPlatformFees` over-restricted in Frozen/Refunding | Low | ✅ Remediated | `4148967e` |
| 12 | Extra-1 | Pro-rata rounding bricks `claimPlatformFees` | — | ✅ Remediated | `973294e3` |
| 13 | Extra-2 | Legacy distributor can claim above configured totals | — | ✅ Remediated | `973294e3` |
| 14 | Extra-3 | Launch signature does not bind payload | — | ✅ Intentional — account-level binding is the design | n/a (PoC stays as documentation) |

---

## Per-Finding Detail

### VIB-01 — Frozen refund denominator includes non-redeemable balances

**Your finding:** `_calculateRedeemableSupply()` subtractive-design counts as
"redeemable" any non-excluded contract holding project tokens — Aerodrome pool
reserves, the per-campaign fee claimer, future custody addresses. Pre-existing
holders are diluted on freeze.

**Reviewer reframe (in `audit-2026-05/review.md`):** confirmed and generalised
beyond the title. The bug is denominator-design, not Aerodrome-specific. We
agree.

**Fix (option a, recommended for the mainnet timeline):**
`_calculateRedeemableSupply` now lazily reads two additional excludes from the
LP locker:
* `lpLocker.campaignToFeeClaimer(address(this))` — the per-campaign fee claimer
* `lpLocker.getLockedPosition(address(this)).pool` — the canonical Aerodrome
  pair (only when `hasLockedLP && !hasRescuedLP`; the locker's revert is
  caught by try/catch)

Both reads are guarded by `lpLocker.code.length > 0` because Solidity 0.8.x
try/catch does NOT catch ABI decoding failures on calls to EOAs — a hard
correctness gotcha we found in testing. We did NOT introduce a setter (that
would be a VIB-02-class admin manipulation surface); both addresses are looked
up from the locker, which is the single source of truth.

**Known limitation (acknowledged):** option (a) only excludes the
locker-registered canonical addresses. A random ERC-20 holder sitting on
project tokens is still counted. Your recommended end-state (option b — the
holder-only positive-list snapshot via merkle) is the right answer for
deduplicating across arbitrary custodial addresses, and we're tracking it as a
follow-up after re-audit.

**Files:** `contracts/src/VibesTranchEscrow.sol`,
`contracts/src/VibesTranchEscrowTestnet.sol` (parity)

**PoCs flipped:**
* `AerodromeIntegrationAudit::test_VIB01_canonicalAerodromePoolReservesExcludedFromDenominator`
* `Specialist3ManualAudit::test_VIB01_canonicalFeeClaimerBalanceExcludedFromDenominator`

Both use `vm.etch` + `vm.mockCall` to simulate post-LP-lock locker state without
the full rescue + manual-lock setup — same effect on the fix's behaviour,
smaller test surface.

---

### VIB-02 — Operations admin can manipulate frozen refund denominator

**Your finding:** `setLockedAddresses` and `setTreasuryContract` are
admin-callable post-launch. A compromised admin can rewire vesting/staker
addresses to a victim holder, exclude their balance from `frozenTotalSupply`,
and claim 100% of `frozenEthBalance` with a tiny holding.

**Reviewer agreement:** we accept your finding as written and have re-rated to
**High** internally (per the trust model M-3, ops admin should not have a
funds-extraction path).

**Fix:**
* New storage: `bool public lockedAddressesFinalized` (packs into the existing
  `lpCreated` slot — no layout shift).
* Both setters now `require(!lockedAddressesFinalized, "Locked")`.
* New one-shot router-only `finalizeLockedAddresses()` emits
  `LockedAddressesFinalized`.
* `VibesRouterExtension._executePhase2` calls `finalizeLockedAddresses()`
  immediately after wiring vesting / staker / treasury. Post-Phase 2, neither
  admin nor router can change the custody addresses.

We considered removing the admin auth on the setters entirely (your stronger
recommendation), but kept it because:
1. Pre-finalisation it's a legitimate recovery path for partial deploys.
2. After `finalizeLockedAddresses`, the setters revert regardless of caller.
3. The 24h commit/reveal pattern you offered as the alternative is
   inappropriate for setters that should fire once during Phase 2 and never
   again.

**Files:** `contracts/src/VibesTranchEscrow.sol`,
`contracts/src/VibesTranchEscrowTestnet.sol`,
`contracts/src/VibesRouterExtension.sol`

**PoC flipped:**
`Specialist3ManualAudit::test_VIB02_custodySettersLockedAfterRouterFinalization`
— asserts admin AND router both blocked post-finalisation, plus the one-shot
invariant (second `finalizeLockedAddresses` reverts) and the non-router gate
(non-router can't call finalize even pre-latch).

---

### VIB-03 — Deployment completeness is not fail-closed

**Your finding:** if `staking.snapshotAuthorized(stakerRewards) == false` at
deployment, `notifyReward` reverts inside the catch in `_executePhase2`,
tokens are already in stakerRewards via `safeTransfer`, `reward.active` stays
false, and nothing rescues the stranded tokens.

**Fix — two patches, landed together:**

**Patch A — `VibesRouterExtension._executePhase2`:**
* Swap order: `notifyReward` runs BEFORE `safeTransfer`.
* Remove the `try/catch` around `notifyReward`.
* If `notifyReward` reverts (e.g., snapshot not authorised), the entire
  `_executePhase2` reverts. `finalize()`'s outer try/catch around
  `completeDistribution` defers Phase 2 via `DistributionDeferred` event,
  so the campaign stays at `LPComplete` and `adminRetryFinalization` can pick
  it up after the missed `setSnapshotAuthorized` is fixed. Invariant: tokens
  never sit in `stakerRewards` while `reward.active == false`.

**Patch B — `script/VerifyDeployment.s.sol`:**
* Replaced every `failures++` with `require(...)` so any check failure halts
  the deploy pipeline immediately (no more "FAILED: N verification(s) failed"
  log line an operator could miss).
* Ported your `DeploymentPipeline.t._assertDeploymentReady` checklist:
  - `lpLocker.authorizedRouter() == ROUTER`
  - `lpLocker.feeClaimerImplementation() != 0 && .code.length > 0`
  - `escrowFactory.lpLocker() == LP_LOCKER`
  - `escrowFactory.timeOracle() == 0 && timeOracleLocked()`
  - `router.pendingOwner() == 0` (ownership transfer accepted)
  - `router.owner() == ROUTER_OWNER` (when constant set)
  - `router.opsWallet() == OPS_WALLET` (when constant set)
  - `staking.snapshotAuthorized(stakerRewards)` (when staking constants set)
  - `stakerRewards.authorizedRouter() == ROUTER`
  - `stakerRewards.stakingContract() == STAKING`
  - `router.stakerRewardsContract() == STAKER_REWARDS`

We preserved the existing deployed-address constants per your handover and
added new `STAKING`, `STAKER_REWARDS`, `ROUTER_OWNER`, `OPS_WALLET` constants
(default `address(0)`, skip gate until operator sets them).

**Files:** `contracts/src/VibesRouterExtension.sol`,
`contracts/script/VerifyDeployment.s.sol`

**PoCs flipped (2):**
* `DeploymentPipeline::test_VIB03_missedSnapshotAuthorizationBlocksFinalizationAndProtectsTokens`
* `VibesFinalizationPhases::test_VIB03_stakerRewardsNotifyFailed_phase2DeferredAndTokensProtected`

---

### VIB-04 — Staker eligibility on snapshotted state

**Your finding:** `_getStakerBalance` checks current `firstStakeTime` against
`raise.notifiedAt`. Because `VibesStaking` resets `firstStakeTime` to 0 on
full unstake, any historical staker who fully unstaked after notification is
locked out of their reward even though `balanceAtSnapshot` still records their
pre-unstake balance.

**Fix:** dropped the `firstStakeTime` gate from both `_getStakerBalance` and
`canClaim`. `balanceAtSnapshot` is the only authoritative source — it was
taken atomically with `notifyReward` and is immutable. Stakers who never
staked or started staking after notify already have `balanceAtSnapshot == 0`
so they remain correctly excluded; the gate was redundant in addition to
being incorrect.

**Note on cache invalidation:** the `snapshotTaken` cache is unaffected
pre-mainnet (no existing data). For any post-launch raise, the cache contains
only correct values: a cached zero is correct for never-stakers and for
unstake-before-notify users; a cached non-zero is correct for historical
stakers and same-block stakers (the latter now further filtered by VIB-06's
`everFirstStakeTime` check before caching).

**Files:** `contracts/src/VibesStakerRewards.sol`

**PoCs flipped (2):**
* `Specialist3ManualAudit::test_VIB04_fullUnstakeAfterNotifyStillAllowsHistoricalClaim`
* `VibesStakerRewards::test_VIB04_snapshot_unstakeFullyThenClaim`

---

### VIB-05 — Bounded snapshot writes

**Your finding:** `_writeSnapshotsBeforeBalanceChange` iterates from
`lastSnapshotWritten[staker] + 1` up to `currentSnapshotId` unbounded. An
adversary (or legitimate snapshot-heavy raise activity) can grow the snapshot
count between a staker's actions arbitrarily, OOG'ing their next stake/unstake.

**Fix (smaller-diff variant per your handover):**
* `uint256 public constant MAX_BACKFILL_PER_CALL = 50` — bounds the eager
  backfill to ~50 SSTORE ops (~250k gas worst case).
* `_writeSnapshotsBeforeBalanceChange` now reverts with
  `SnapshotBacklogTooDeep(backlog)` if the backlog exceeds the cap, instead
  of OOG'ing.
* New public **permissionless** `catchUpSnapshots(address staker, uint256 max)`
  helper lets anyone (the staker, an agent acting for them, or a cleaner bot)
  chip away at backlog in cap-sized chunks across separate transactions.

The read invariant is preserved: `lastSnapshotWritten` advances to either
`current` (normal path) or `lastWritten + max` (catchUp path); in both cases
the range `[lastWritten+1 .. lastSnapshotWritten]` is fully populated, so
`_findSnapshotBalance`'s `snapshotId >= lastWritten → return current balance`
short-circuit remains correct.

**On the OZ `Checkpoints` end-state:** we agree this is the right shape long
term. We chose the smaller-diff variant for the mainnet timeline; the
Checkpoints refactor is tracked as a separate item for the next staking-level
upgrade. We'd love your sign-off on the bounded-write approach as a sufficient
mainnet-time mitigation.

**Files:** `contracts/src/VibesStaking.sol`

**PoC flipped:**
`Specialist3ManualAudit::test_VIB05_deepSnapshotBacklogRevertsCleanlyThenCatchUpAllowsUnstake`
— with 500 inflated snapshots, unstake reverts cleanly with
`SnapshotBacklogTooDeep(500)`; ten catchUp chunks of 50 reduce the backlog to
within the cap; unstake then succeeds.

---

### VIB-06 — Same-block stake dilution + dust rescue

**Your finding (two parts):**
1. Same-block stake counts in `totalStakedSnapshot` but is locked out via
   `firstStakeTime >= notifiedAt`, stranding 90% of the reward.
2. `rescueUnclaimable` requires `totalStakedSnapshot == 0`, so dust from
   integer-division rounding stays stranded forever when any staker exists.

**Fix — both parts:**

**Part 1 — Same-block eligibility:**
* New storage in `VibesStaking`:
  - `mapping(uint256 => uint256) public snapshotTimestamps` — block.timestamp
    of each snapshot.
  - `mapping(uint256 => uint256) public newStakeAtTimestamp` — cumulative new
    stake amount at each block.timestamp.
  - `mapping(address => uint256) public everFirstStakeTime` — first-ever stake
    timestamp, never reset on full unstake (unlike `firstStakeTime`).
* `stake()` sets `everFirstStakeTime` (once per staker, sticky) and increments
  `newStakeAtTimestamp[block.timestamp]`.
* `takeSnapshot()` records `snapshotTimestamps[id]` and stores
  `totalStaked - newStakeAtTimestamp[block.timestamp]` as the eligible total —
  same-block new stakes are excluded from the denominator.
* `VibesStakerRewards._getStakerBalance` and `canClaim` check
  `everFirstStakeTime[staker] >= snapshotTimestamps[snapId]` and return 0 if
  the staker's permanent first stake landed at or after the snapshot. Uses
  `everFirstStakeTime` (not `firstStakeTime`) so legitimate historical stakers
  who later fully unstaked still pass (preserves VIB-04's invariant).

**Part 2 — Dust rescue:**
* New storage in `VibesStakerRewards`:
  - `mapping(address => uint256) public eligibleClaimedShares` — cumulative
    `balanceAtSnapshot` of stakers who have claimed.
  - `uint256 public constant RESCUE_DELAY = 365 days` — backstop for
    never-claimers.
* `_claimInternalUnchecked` now flips `hasClaimed = true` AND increments
  `eligibleClaimedShares` even on zero-amount claims (dust path). Without
  this, dust-share stakers never increment the counter and `rescueUnclaimable`
  can never see "all eligible have claimed".
* `rescueUnclaimable` accepts three rescue conditions:
  - `totalStakedSnapshot == 0` (original — no eligible stakers existed)
  - `eligibleClaimedShares >= totalStakedSnapshot` (new — every eligible has
    claimed their share, residue is pure rounding dust)
  - `block.timestamp > reward.notifiedAt + RESCUE_DELAY` (new — backstop for
    stakers who never come back)

**Files:** `contracts/src/VibesStaking.sol`,
`contracts/src/VibesStakerRewards.sol`

**PoCs flipped (2):**
* `audit/EconomicMechanicsAudit::test_VIB06_sameBlockStakerExcludedFromBothEligibilityAndDenominator`
  — asserts: snapshot total excludes same-block staker's 900 ether; pre-existing
  staker takes 100% of the reward; same-block staker reverts
  `NoStakeAtSnapshot` on claim; nothing stranded.
* `FundFlowAudit::test_VIB06_stakerRewardRoundingDustIsRescuable`
  — asserts: each staker's share rounds to zero, `hasClaimed` flips, admin
  rescues the stranded dust via `rescueUnclaimable`.

---

### VIB-07 — Registry pre-deploy squatting

**Your finding:** an attacker who pre-computes a CREATE/CREATE2 address can
call `register()` before the factory deploys, locking in attacker-chosen
provenance.

**Fix (one-line):** added
`require(token.code.length > 0, "Token has no code");` to
`VibesRegistry._register`. The legitimate factory path always deploys the
token before calling `registerFromRouter`, so it's unaffected; an attacker
calling on a predicted address (with no code yet) now reverts.

**Files:** `contracts/src/VibesRegistry.sol`

**PoC flipped:**
`Specialist3ManualAudit::test_VIB07_registryRejectsPreDeploySquatting`

---

### VIB-08 — Challenge slot cleanup

**Your finding:** `trancheChallenged` mapping is set true on `raiseChallenge`
but never cleared on `rejectChallenge` / auto-expire — a collusive first
challenger can lock a tranche's only challenge slot.

**Fix:** set `trancheChallenged[tranche] = false` after state transition in
both `VibesTranchEscrow.rejectChallenge` and `_expireChallengeIfNeeded`. Same
fix mirrored in `VibesTranchEscrowTestnet` for parity.

The per-challenger `CHALLENGE_COOLDOWN` + `lastChallengeTime` already prevent
a single challenger from spamming; this fix prevents one bad-faith challenger
from indefinitely blocking *all* other challengers on the same tranche.

**Files:** `contracts/src/VibesTranchEscrow.sol`,
`contracts/src/VibesTranchEscrowTestnet.sol`

**PoC flipped:**
`audit/EconomicMechanicsAudit::test_VIB08_collusiveChallengeDoesNotConsumeSlotAfterReject`
— after admin reject, the slot is released; a second legitimate challenger
can raise a fresh challenge within the still-open 72h window.

---

### VIB-09 — Canonical pool + clone bytecode check on `recordManualLPLock`

**Your finding:** `recordManualLPLock` accepts any non-zero address with code
as `_pool` and `_feeClaimer` — an attacker (compromised owner) can record an
arbitrary ERC-20 as the "pool" and a bespoke contract with a transfer/withdraw
surface as the "holder" (the `WithdrawableLPHolder` PoC), defeating both the
LP-locked-indefinitely property and the soulbound-LP claimer assumption.

**Fix — two new gates:**
1. **Canonical pool check:** require
   `_pool == IAerodromeRouter(aerodromeRouter).poolFor(rescue.token, weth, false, factory)`.
   Same lookup the auto-lock path uses; volatile pool only (`stable = false`),
   which is the only pool kind the protocol ever creates.
2. **EIP-1167 clone bytecode check:** new internal `_isCloneOfImplementation`
   verifies that `_feeClaimer`'s deployed bytecode is exactly the 45-byte
   minimal-proxy runtime that `Clones.clone()` produces with
   `feeClaimerImplementation` as the implementation slot.

The DEAD_ADDRESS path (`_feeClaimer == address(0)`) is unchanged.

**Files:** `contracts/src/VibesLPLocker.sol`

**PoC flipped:**
`AerodromeIntegrationAudit::test_VIB09_manualLockRejectsNonCanonicalPool`
— the auditor's `WithdrawableLPHolder` attack is blocked at the canonical-pool
gate before it reaches the clone check.

---

### VIB-10 — Community batch aggregate cap

**Your finding:** `VibesCommunityRewards.claim` has a per-recipient
`hasClaimed` guard but no aggregate cap. A malicious / sloppy operator
committing a merkle root whose leaf-sum exceeds the declared `batch.totalAmount`
could drain more than the batch budget.

**Fix:**
```solidity
require(b.claimedAmount + amount <= b.totalAmount, "Exceeds batch total");
```
before the `claimedAmount += amount` increment.

**Files:** `contracts/src/VibesCommunityRewards.sol`

**PoCs flipped (3 — same bug from three angles):**
* `audit/EconomicMechanicsAudit::test_VIB10_communityRewardsClaimRespectsDeclaredBatchTotal`
* `FundFlowAudit::test_VIB10_communityRewardsOverClaimRevertsCleanly`
* `SignatureAdminAudit::test_VIB10_communityRewardsClaimRespectsDeclaredBatchTotal_signatureAdminPath`

---

### VIB-11 — Platform fees claimable after freeze

**Your finding:** `claimPlatformFees` reverts in `Frozen` and `Refunding`
states, but freeze accounting already excludes `pendingPlatformFees` from
`frozenEthBalance`, so paying out post-freeze does not touch holder refund
funds. The guard was over-restrictive — fees could get permanently stranded
if a campaign was frozen between tranche claims.

**Fix:** scoped the state guard to `Failed` only (where the entire balance is
owed back to contributors and platform fees shouldn't have accrued anyway).
Same fix mirrored in `VibesTranchEscrowTestnet`.

**Files:** `contracts/src/VibesTranchEscrow.sol`,
`contracts/src/VibesTranchEscrowTestnet.sol`

**PoC flipped:**
`Specialist3ManualAudit::test_VIB11_platformFeesStillClaimableAfterFreeze`

---

### Extra-1 — Pro-rata rounding bricks `claimPlatformFees`

**Your bundled PoC** (`EconomicMechanicsAudit::test_AUDIT_ProRataExcessRoundingCanOverstatePlatformFeeLiability`):
pro-rata per-account refund floors over-paid the aggregate liability by 2 wei,
leaving `address(this).balance` 2 wei below `pendingPlatformFees`; the
unconditional `transfer(pendingPlatformFees)` then reverted "Fee transfer
failed" and the fees stayed permanently stranded.

**Fix (option B from your bundle, two lines):**
```solidity
uint256 fees = pendingPlatformFees;
uint256 bal = address(this).balance;
if (fees > bal) fees = bal;       // cap at actual balance
require(fees > 0, "No pending fees");
pendingPlatformFees = 0;          // zero out regardless
```

The platform wallet receives what's actually in the contract; the rounding
residue is dropped (no holder has a claim on it). Same fix mirrored in
`VibesTranchEscrowTestnet`.

**Files:** `contracts/src/VibesTranchEscrow.sol`,
`contracts/src/VibesTranchEscrowTestnet.sol`

**PoC flipped:**
`audit/EconomicMechanicsAudit::test_Extra1_proRataRoundingDoesNotBrickPlatformFees`

---

### Extra-2 — Legacy distributor aggregate cap

**Your bundled PoC**: `VibesTokenDistributorV2.claim` lacks the same aggregate
caps you flagged in VIB-10 — a merkle leaf with amounts exceeding the
configured `totalTokens` / `totalEthRefunds` would drain beyond budget.

**Fix:** added two requires before the existing increments:
```solidity
require(totalTokensClaimed + tokenAmount <= totalTokens, "Exceeds totalTokens");
require(totalEthClaimed + ethRefund <= totalEthRefunds, "Exceeds totalEthRefunds");
```

We note this is the deprecated distributor path (router migration replaces it
for new raises), so it's defence-in-depth on a sunset surface, not the
primary money path.

**Files:** `contracts/src/VibesTokenDistributorV2.sol`

**PoC flipped:**
`FundFlowAudit::test_Extra2_legacyDistributorEnforcesConfiguredTotals`

---

### Extra-3 — Launch signature payload binding

**Your bundled PoC**
(`SignatureAdminAudit::test_POC_launchAuthorizationDoesNotBindLaunchPayload`):
the current `LAUNCH_TYPEHASH` binds only the founder + nonce + deadline, not
the launch payload (capsule, proof, raise terms). A signature can authorise
the holder to launch any payload they like, within protocol bounds.

**Status:** ✅ Intentional — account-level binding is the design.

After review with the product side, account-level binding is the correct
primitive for the security model we operate. The trusted signer attests
*"this address is authorised to launch a raise"* — it does not attest to
the specific raise content. The trust gate is **who** is launching, not
**what** they launch. Concretely:

* **Phase 1 (mainnet launch and shortly after) — invited launchers.**
  A small curated set of founder wallets are explicitly invited by the
  Vibestarter team. The off-chain signer service refuses to issue a launch
  signature unless the requesting wallet is on this invite list. Once
  invited, founders launch whatever they want within protocol bounds — they
  are trusted because we vetted *them*, not their specific raise.

* **Phase 2 (gradual public opening) — per-launcher gates + post-launch
  moderation.** The launcher allowlist is loosened (or removed) in favour
  of automated gates (Sybil score, ToS acceptance, completed onboarding,
  potentially stake-to-launch) plus app-layer moderation tooling: admin
  hide/unhide of campaigns, banned-domain and content filters at draft
  submission, community reporting, permaban escalation for repeat
  offenders. Still per-launcher trust, just with different gates.

Per-payload binding is the right primitive for a different security model:
*"this specific raise was reviewed and approved."* That's a per-raise
review pipeline (founder submits draft → admin reviews → admin approves →
signer signs over payload-hash → only that exact payload can land
on-chain). It scales poorly (every raise blocks on an admin click), and
it's not the moderation model we want. Phase 2's "moderation" means
post-launch — bad raises get hidden after the fact, not pre-screened.

**Why this matters for the trust analysis:**

* A compromised trusted-signer key in our model lets the attacker mint
  launch signatures for ANY wallet that the off-chain signer would issue
  for. Mitigation: short `sigDeadline` (1 hour today, dropping to ~5
  minutes), rate-limited signer service, key rotation via
  `setTrustedLaunchSigner` if key compromise is suspected.

* A compromised allowlist (someone gets onto the invite list who
  shouldn't) lets them launch one bad raise. Mitigation: pre-launch
  off-chain review of the invitee, post-launch hide via `Campaign.isHidden`,
  permaban via `Permaban.create` (which the signer route already honours
  before any other check at `/api/terms/sign` line 51).

Neither failure mode is improved by binding the payload to the signature —
in both cases the attacker controls the payload anyway.

**The PoC stays in place** as documentation of the design choice. It
correctly demonstrates that the contract does not bind the payload; it
does NOT demonstrate a bug under our model.

**What changes in the code as a result:** none in the contracts. We are
ALSO landing the Phase 1 launcher-invite gate at the signer-service layer
(separate commit on `staging`, not on this audit branch): a new
`AllowlistUser.launcherInvited` boolean that admins explicitly toggle, and
a check in `/api/terms/sign` that refuses to mint a launch signature
unless the wallet is invited. That's the product-side hardening that
makes the account-level model robust in the curated phase.

---

**Re-audit ask on this item:** please review the security model framing
above and the trade-offs we've articulated. If you disagree — i.e., you
think per-payload binding is required even under a per-launcher trust
model — we'd want to hear the threat model that drives that conclusion
and reconsider. Otherwise, treat Extra-3 as documenting an intentional
design choice and remove it from the blocking-findings list for the
re-audit pass.

---

## Operational readiness (outside the code remediation scope)

These items from your handover are not code patches but are required for your
"production ready" verdict. None block the code remediation; we're tracking
them with their respective owners:

1. **Re-audit pass on the patches** — *this engagement.* We're requesting a
   pass on the diff between `staging` and this branch before mainnet deploy.
2. **Bug bounty live before mainnet** — Immunefi / Cantina scope, owner: ops.
3. **Onchain timelock on master admin** — April audit's U-9, still open;
   tracked as a separate contract change.
4. **Monitoring + alerts pre-mainnet** — indexer in `packages/indexer/`; we
   subscribe to `StakerRewardsNotifyFailed`, `LockedAddressesFinalized`,
   `ManualLPLockRecorded`, `CampaignFrozen`, ownership transfer events on
   the privileged contracts.
5. **Operational runbooks** — LP rescue, refund-root generation, freeze
   decision tree, deployment rollback. Owner: ops.
6. **Slither detailed run** — scheduled in our regression sweep before
   mainnet sign-off.

---

## Verification

Each fix was verified against:
* The flipped PoC asserting the post-fix behaviour
* The broader test surface that touches the modified files

Test counts at the end of the remediation pass (Windows host with retry-on-
solc-crash; results are deterministic when compilation completes):

| Suite | Tests | Status |
|---|---|---|
| ZXVC PoC suite (your 40 baseline tests, mix of flipped + intentionally-unchanged) | 40 | ✅ all green |
| AuditFixes (existing 2026-04 audit fixes regression) | 51 | ✅ |
| SecurityAuditFixes | 17 | ✅ |
| E2EScenarios | 14 | ✅ |
| FullLifecycleIntegration | 16 | ✅ |
| VibesFinalizationPhases | 27 | ✅ |
| VibesTranchEscrow | 64 | ✅ |
| VibesTranchEscrowTestnet | 77 | ✅ |
| Audit2026_04_Findings | 6 | ✅ |
| AuditTestnetParityFinal2026_04 | 16 | ✅ |
| AuditRemediation2026_04 | 12 | ✅ |
| VibesStakerRewards | 47 | ✅ |
| VibesStaking | 28 | ✅ |
| VibesLPLocker | 30 | ✅ |
| AuditStakingSnapshotHardening2026_04 | 5 | ✅ |
| AdminSecurity | 8 | ✅ |
| DeploymentPipeline | 9 | ✅ |
| DeploymentStatefulInvariants | 4 | ✅ (auditor's expected 524,288 calls/invariant pending the deep fuzz pass) |
| MathRoundingAnalysis | 8 | ✅ (4096-fuzz pass pending) |
| Specialist3ManualAudit | 7 | ✅ |
| AerodromeIntegrationAudit | 2 | ✅ |
| audit/EconomicMechanicsAudit | 5 | ✅ |
| FundFlowAudit | 3 | ✅ |
| SignatureAdminAudit | 2 | ✅ |

The deep fuzz pass and the full multi-suite invariant run (with the auditor's
expected `FOUNDRY_INVARIANT_RUNS=512 FOUNDRY_INVARIANT_DEPTH=1024`) are
scheduled to run on a Linux host before re-audit hand-off; Windows
`solc 0.8.24` is too unstable on our remediation host to run them reliably
inline.

---

## What we'd like from the re-audit

1. Verify each remediation against the corresponding finding.
2. Confirm option (a) is sufficient for VIB-01 in the mainnet timeline, with
   option (b) tracked as a follow-up.
3. Confirm the bounded-write variant is sufficient for VIB-05 in the mainnet
   timeline, with the OZ Checkpoints refactor tracked as a follow-up.
4. Sanity-check VIB-06's same-block exclusion mechanism — we used
   `everFirstStakeTime` because `firstStakeTime` is reset on full unstake and
   we wanted to preserve VIB-04's invariant. We'd appreciate confirmation that
   this composition is sound.
5. **Review the Extra-3 framing.** We are not remediating Extra-3 — account-
   level binding is the design under our per-launcher-trust security model
   (Phase 1: curated invite-only launchers; Phase 2: public + post-launch
   moderation). The Extra-3 section above walks through the threat model.
   If you disagree — i.e., per-payload binding is required regardless of
   trust model — please tell us the specific threat that drives that
   conclusion so we can reconsider.
6. Any additional findings the patches surface (the patches under time
   pressure are exactly where new bugs land).

Thanks again for the audit. We're available for any follow-up questions on
the patches — the per-commit messages document the design choices in detail,
and our reviewer notes in `audit-2026-05/review.md` capture the per-finding
agreement / disagreement before remediation.

— Vibestarter team
