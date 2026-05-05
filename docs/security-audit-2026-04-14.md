# Smart Contract Security Audit — 2026-04-14

**Auditor:** Internal (Claude Opus 4.6, adversarial pass)
**Scope:** 19 Solidity files in `vibestarter-app/contracts/src/` — ~7,962 LoC, Solidity 0.8.24, via-IR, optimizer runs 50
**Baseline:** `docs/security-audit-consolidated-2026-03-27.md` (external audit, 20 findings all reported fixed), `docs/bug-hunt-findings.md` (11 internal items), Slither 0.11.5 output
**Deliverables:**
1. This report
2. `contracts/test/AuditParity2026_04.t.sol` — 7 PoC/regression tests, all passing

This audit is a clean-room review of the current source — which is ahead of deployed bytecode by 32 pending changes per `docs/pending-contract-changes.md`. No contract source was modified; all findings are paired with recommended patches and, where practical, a PoC test.

---

## 1. Executive Summary

**Overall risk assessment:** Code quality is **high** for a system of this size. All 20 findings from the external audit (3 Critical / 6 High / 5 Medium) are confirmed fixed in source with corresponding regression tests. The commit-reveal merkle root (F10), two-phase finalization (F7), staker snapshot (F4), and pro-rata underflow fix (C-01) are all correctly implemented on the mainnet path.

This audit surfaced **4 High-severity issues** (2 confined to the testnet-only contracts; 1 in cross-contract finalization/refund consistency; 1 in LP rescue/relock liveness contributed by a third hardening pass — see §11), **1 confirmed Medium-severity boundary-race bug** in treasury governance (first hardening pass — see §9), **2 defense-in-depth Mediums**, and **5 lower-severity recommendations**. No Critical issue was found on the mainnet path.

**Top concerns, ranked:**

| # | Finding | Severity | Where | Status |
|---|---|---|---|---|
| H-1 | Testnet escrow lacks `MAX_TIME_DRIFT` oracle guard | High (testnet) | `VibesTranchEscrowTestnet.sol:346-351` | PoC landed, not patched |
| H-2 | Testnet escrow lacks F10 commit-reveal merkle root | High (testnet) | `VibesTranchEscrowTestnet.sol:997` | PoC landed, not patched |
| **H-3** | **Cross-contract state drift enables token+ETH double-dip in deferred-finalization / emergency-refund path** | **High** | **`VibesRouterExtension._claimTokensInternal` + `VibesTranchEscrow.emergencyRefundFunded:974`** | **Patch + regressions described in Report 2 (§10); source tree has neither** |
| **H-4** | **Rescued LP state has no on-chain path back to a verified locked state — `completeLP()` permanently blocked after rescue, stranding funded campaigns** | **High** | **`VibesLPLocker.sol:207-208,227,282` + `VibesRouterExtension.completeLP:400`** | **Same finding independently confirmed by two passes (Reports 3 and 4 — §11, §12); source tree has neither patch** |
| M-1 | `completeDistribution()` lacks `nonReentrant` | Medium (defense-in-depth) | `VibesRouterExtension.sol:129` | Recommendation |
| M-2 | Treasury challenge resolvers lack `nonReentrant` | Medium (defense-in-depth) | `VibesTreasuryEscrow.sol:320,337,365,385` | Recommendation |
| M-3 | Treasury challenge window closes one block too late at exact boundary | Medium | `VibesTreasuryEscrow.sol:289` | Patch described in Report 1 (§9); source tree still shows `>` |
| L-1 | `resolveRescuedFunds()` lacks `nonReentrant` | Low | `VibesLPLocker.sol:~276` | Recommendation |
| L-2 | `VibesTokenFactory.deployToken` permissionless | Informational | `VibesTokenFactory.sol:39` | Documented — low impact |
| L-3 | `VibesStakerRewards._getStakerBalance` snapId==0 fallback | Low | `VibesStakerRewards.sol:288-294` | Dead-code hazard |
| L-4 | `VibesLPLocker.createAndLockLP` ignores `approve()` return | Informational | `VibesLPLocker.sol:162,191,210` | Use `forceApprove` |
| L-5 | `getTrancheAmount` double-division precision | Informational | `VibesTranchEscrow.sol:575-580` | Sub-wei dust |

**Methodology depth:**
- Manual line-by-line review of all 19 files across 5 domain groups (escrow/factory, router/extension/storage, vesting/treasury/LP, staking/rewards, distributor/registries/token).
- Ground-truth verification of every finding against source; **4 agent-generated findings were rejected as false positives** (see §4).
- Slither 0.11.5 run on `src/` with `--exclude-low --exclude-informational --exclude-optimization` — 86 findings triaged (25 High, 61 Medium), mostly known-pattern false positives.
- Review of the 30-file existing test suite (~620 tests, 14 fuzz, 3 invariants, 10 fork tests) to avoid duplicating coverage.
- 7 new PoC/regression tests in `test/AuditParity2026_04.t.sol` prove the two High-severity testnet findings and enforce the mainnet F10 + H-06 guards as regression.

**Verdict:** **READY FOR EXTERNAL AUDIT** for the mainnet contracts; **NOT READY for mainnet deployment of the testnet contracts** until H-1 and H-2 are patched or the testnet surface is explicitly isolated from real user funds.

---

## 2. Findings

### H-1 — Testnet escrow has no `MAX_TIME_DRIFT` guard on time oracle

**Severity:** High (scoped to testnet deployment)
**Contract:** `contracts/src/VibesTranchEscrowTestnet.sol:346-351`
**PoC tests:**
- `test_PoC_H1_TestnetAcceptsArbitraryForwardDrift` (proves the bypass)
- `test_Regression_H1_MainnetRejectsDriftBeyondMaxTimeDrift`
- `test_Regression_H1_MainnetDriftBoundaryExact`
- `test_Regression_H1_MainnetAcceptsDriftWithinWindow`

**Root cause.** `VibesTranchEscrow.sol:355-363` (mainnet) implements the audit H-06 guard:

```solidity
function _currentTime() internal view returns (uint256) {
    if (timeOracle == address(0)) return block.timestamp;
    uint256 oracleTime = ITimeOracle(timeOracle).getTime();
    require(oracleTime <= block.timestamp + MAX_TIME_DRIFT, "Oracle drift exceeded");
    return oracleTime;
}
```

The testnet variant at `VibesTranchEscrowTestnet.sol:346-351` strips the drift guard and also never declares the `MAX_TIME_DRIFT` constant:

```solidity
function _currentTime() internal view returns (uint256) {
    if (timeOracle == address(0)) return block.timestamp;
    return ITimeOracle(timeOracle).getTime();  // no bound
}
```

**Exploit path.**
1. `VibesTranchEscrowFactoryTestnet` is constructed with a `MockTimeOracle` address (always non-zero on testnet).
2. Admin of that oracle (also the deployer) calls `MockTimeOracle.setTime(block.timestamp + 365 days)` — the mock oracle has no cap on `mockTime`.
3. Every subsequent call path that uses `_currentTime()` — tranche unlocks (`claimTranche`), challenge windows (`raiseChallenge`, `claimTranche` >72h check), `raiseStart` gating, `deadline` comparison, freeze cooldowns — now sees the forward-drifted clock.
4. Founder can immediately call `claimTranche(6)` with all six tranches effectively unlocked, and all challenge windows close instantly. This collapses the entire 6-month release schedule into a single transaction on testnet.

The public incentivized testnet holds real user engagement and testnet ETH; the same admin key also controls which merkle roots are set (H-2). The testnet divergence represents a systematic degradation of the security model that mainnet users rely on for confidence in the protocol.

**Impact.**
- Tranche schedule bypass on testnet: founder can extract all 85% of raised ETH in one tx.
- Challenge window collapse on testnet: backers cannot challenge.
- If `VibesTranchEscrowTestnet` is ever accidentally deployed or reused on mainnet chainID — the Medium-severity `setUseTestnetContracts` guard on the router mitigates this, but the escrow contract itself contains no chainID check.

**Recommended remediation.**
Back-port the H-06 guard to the testnet file, keeping the 1h bound (or a tighter one — the testnet uses 24h tranches and 2h challenge windows, so even a 5-minute drift is meaningful):

```solidity
uint256 public constant MAX_TIME_DRIFT = 1 hours;

function _currentTime() internal view returns (uint256) {
    if (timeOracle == address(0)) return block.timestamp;
    uint256 oracleTime = ITimeOracle(timeOracle).getTime();
    require(oracleTime <= block.timestamp + MAX_TIME_DRIFT, "Oracle drift exceeded");
    return oracleTime;
}
```

Add a source-of-truth diff check in CI (a test that asserts every non-timing constant matches between the two files) so future audit fixes can't silently diverge again.

---

### H-2 — Testnet escrow has no commit-reveal on refund merkle root (missing F10)

**Severity:** High (scoped to testnet deployment)
**Contract:** `contracts/src/VibesTranchEscrowTestnet.sol:997`
**PoC tests:**
- `test_PoC_H2_TestnetHasInstantSetter`
- `test_PoC_H2_TestnetMissingCommitRevealSelectors`
- `test_Regression_H2_MainnetExposesCommitRevealSelectors`

**Root cause.** The F10 audit fix added a two-step commit-reveal for setting a frozen campaign's refund merkle root on the mainnet escrow:

```
VibesTranchEscrow.sol:151-153
  bytes32 public pendingMerkleRoot;
  uint256 public merkleRootCommitTime;
  uint256 public constant MERKLE_ROOT_DELAY = 24 hours;

VibesTranchEscrow.sol:1051    commitRefundMerkleRoot(bytes32)   onlyAdmin inState(Frozen)
VibesTranchEscrow.sol:1060    finalizeRefundMerkleRoot()        inState(Frozen), requires 24h delay
VibesTranchEscrow.sol:1072    cancelPendingMerkleRoot()         onlyAdmin, resets commit
```

The testnet file has **none** of this. Instead it exposes a direct setter:

```
VibesTranchEscrowTestnet.sol:997
  function setRefundMerkleRoot(bytes32 _merkleRoot) external onlyAdmin inState(Frozen) {
      campaign.refundMerkleRoot = _merkleRoot;
  }
```

Grep confirms zero matches for `pendingMerkleRoot`, `merkleRootCommitTime`, `MERKLE_ROOT_DELAY`, `commitRefundMerkleRoot`, `finalizeRefundMerkleRoot`, or `cancelPendingMerkleRoot` in the testnet file.

**Exploit path.** On a frozen testnet campaign, a compromised or coerced admin can publish a malicious merkle root (e.g., one assigning 100% of the frozen ETH to an address they control) in a single transaction. Backers have **no window** to detect, audit, or challenge the commit before claims begin. The F10 fix was explicitly designed to prevent exactly this — the mainnet implementation enforces a 24h review window and an admin-cancellable pending root so community tooling can flag a bad root before it takes effect.

**Recommended remediation.** Port the entire F10 block from the mainnet file, including the three functions, the two storage variables, the `MERKLE_ROOT_DELAY` constant, the `NoPendingMerkleRoot` / `MerkleRootDelayNotElapsed` errors, and the `RefundMerkleRootCommitted` / `RefundMerkleRootCancelled` events. Remove `setRefundMerkleRoot` from the testnet file at the same time — the direct setter is the bypass.

---

### H-3 — Cross-contract state drift enables token+ETH double-dip in deferred-finalization / emergency-refund path

**Severity:** High — Confirmed bug (per Report 2 cross-contract analysis)
**Contracts:**
- `contracts/src/VibesRouterExtension.sol` — `_claimTokensInternal` (claim gating)
- `contracts/src/VibesTranchEscrow.sol:974` — `emergencyRefundFunded`
**Source of finding:** Second hardening pass, reproduced verbatim in §10 (Report 2).
**PoC/regression tests (per Report 2, not yet landed here):**
- `test_claimTokens_revertsWhenPhase1Deferred`
- `test_emergencyRefundFunded_revertsAfterRouterFinalizationProgress`

**Root cause.** Finalization is split across two independent state machines that must agree:
- `VibesTranchEscrow.campaign.state` — moves `Active → Funded → Completed|Frozen|Refunding` (escrow-local).
- `VibesRouterExtension.finalizationPhase[token]` — moves `None → LPComplete → FullyComplete` (router-local).

The two can drift apart: Phase 1 or Phase 2 can fail inside a try/catch (malicious receiver, out-of-gas, Aerodrome hiccup, bad vesting contract), leaving the escrow in `Funded` with the router stuck at `None` or `LPComplete`. In that drifted window, the two fund-moving gates were not defensively hardened against inconsistent states:

- `_claimTokensInternal` accepted claims on `Funded/Completed/Frozen/Refunding` regardless of router phase. Self-healing at line 323 (`if finalizationPhase == LPComplete then _executePhase2`) covers the mid-drift case, but Phase-0 (`None`) drift was not explicitly blocked — relying instead on the side effect that `backerTokensForClaims[token]` defaults to zero (and therefore `NothingToClaim` reverts).
- `emergencyRefundFunded` only checks `!lpCreated` (escrow-local); it does not consult `finalizationPhase` on the router. A clever sequence of failures could open a window where Phase 1 has advanced on the router (e.g. tokens have been pulled into router custody, `_pendingStakerAllocation` set, deposits tracked) while escrow still considers itself refundable.

**Exploit path (as described in Report 2).** Deferred/failing router phase calls + emergency admin recovery interactions could reach an inconsistent order where:
1. A user is credited tokens through a partial-Phase-2 path (or via state drift where `backerTokensForClaims` has been populated) and claims them;
2. Admin then triggers `emergencyRefundFunded` because the escrow-local `!lpCreated` guard still evaluates true;
3. The user claims their full contributor refund via `claimContributorRefund`;
4. Net position: tokens retained **and** ETH refunded.

My independent pass noted that the direct path is partially blunted today by (a) `backerTokensForClaims[token]` being unset until Phase 2 runs, and (b) the self-healing Phase 2 auto-trigger in `_claimTokensInternal`. But "partially blunted by side effects" is the wrong posture for a fund-custody contract — any refactor that populates `backerTokensForClaims` earlier, or any new admin recovery path, would open the door. Treating this as a High aligns with the precautionary principle governing two-state-machine cross-contract flows.

**Recommended remediation (per Report 2).**
1. **Claims hard-require finalization progress.** In `_claimTokensInternal`, revert if `finalizationPhase[token] == None`; require `FullyComplete` before executing the actual token transfer (keep the LPComplete self-heal auto-triggering Phase 2, but do not treat LPComplete alone as a valid claim state). This closes the conceptual gap and removes reliance on `backerTokensForClaims` defaulting to zero.
2. **Emergency refund blocks on router progress.** In `VibesTranchEscrow.emergencyRefundFunded`, consult the router's `finalizationPhase` for this token (via an ABI-stable getter) and revert if it is anything other than `None` — with a best-effort compatibility fallback for pre-migration raises. This prevents admin from rolling the escrow to `Failed` when the router has already committed to a finalization branch.

Both guards are cheap, localized, and reinforce the invariant "escrow `Funded` + router `None`" is the only state that may transition to `Failed` via emergency refund, and "router `FullyComplete`" is the only state that may transfer backer tokens.

**Status in this tree.** Neither the `_claimTokensInternal` tightening, the `emergencyRefundFunded` router-phase check, nor the two regression tests are present in the source tree reviewed here (current `_claimTokensInternal` is at `VibesRouterExtension.sol:297-363`; current `emergencyRefundFunded` at `VibesTranchEscrow.sol:974-992` checks only `!lpCreated` + solvency). Land the patches and regression tests before the mainnet deployment gate.

---

### H-4 — Rescued LP cannot transition back to a verified locked state; `completeLP()` permanently blocked after rescue

**Severity:** High — High confidence (confirmed bug, independently verified against source)
**Contracts:**
- `contracts/src/VibesLPLocker.sol:68, 79, 159-160, 207-208, 223-227, 276-282` — rescue state machine
- `contracts/src/VibesRouterExtension.sol:392-411` — `completeLP` acceptance gate
**Source of finding:** Third hardening pass, reproduced verbatim in §11 (Report 3).
**PoC/regression tests (per Report 3, not yet landed here):**
- Locker-level: success path for manual LP lock registration, revert when rescue not resolved
- Audit regression: rescued → resolved → manual lock registered → `completeLP()` unblocks tranches

**Root cause.** The F7 fix introduced a clean separation between a "real" LP lock and a "rescued" LP:

```solidity
// VibesLPLocker.sol:68, 79
mapping(address => bool) public hasLockedLP;   // true only for real onchain LP lock
mapping(address => bool) public hasRescuedLP;  // true for rescued, no real LP
```

When LP creation fails (Aerodrome reverts, transfer partial-fills, etc.) the rescue branch executes:

```solidity
// VibesLPLocker.sol:207-208
// hasLockedLP stays false for rescued campaigns — only set true for real LP locks.
hasRescuedLP[_campaign] = true;
```

`resolveRescuedFunds` (line 276) lets the owner withdraw the escrowed ETH + tokens to an off-chain address for manual LP construction, and sets `rescue.resolved = true` — but it **never touches either `hasLockedLP` or `hasRescuedLP`**:

```solidity
// VibesLPLocker.sol:282
rescue.resolved = true;  // flag on the rescue record only
```

Meanwhile, `completeLP` (router extension, line 392) is the sole on-chain path to unblock tranche claims after finalization entered the rescue branch. Its F7b onchain-proof gate requires:

```solidity
// VibesRouterExtension.sol:399-404
require(
    lpLocker.hasLockedLP(escrowAddr) && !lpLocker.hasRescuedLP(escrowAddr),
    "LP not actually locked onchain"
);
(bool locked, ) = lpLocker.verifyLPLocked(escrowAddr);
require(locked, "LP tokens not verified at dead address");
```

After a rescue, `hasLockedLP[escrow] == false` and `hasRescuedLP[escrow] == true`. Both sides of the `&&` fail. There is **no function anywhere in `VibesLPLocker`** that transitions a campaign from `(hasLockedLP=false, hasRescuedLP=true)` back to `(hasLockedLP=true, hasRescuedLP=false)`. The require is unsatisfiable for eternity.

**Exploit path / failure mode (liveness).**
1. User campaign reaches `Funded`; finalization Phase 1 enters `_executePhase1` and calls `lpLocker.createAndLockLP(...)`.
2. Aerodrome reverts mid-call (pool exists with bad reserves, token has unexpected behaviour, slippage too tight, etc.) OR token transfer is non-standard. The try/catch inside the locker falls into the rescue branch: ETH + tokens kept in the locker, `hasRescuedLP[escrow] = true`, `hasLockedLP[escrow] = false`.
3. Admin performs the intended operational recovery: calls `resolveRescuedFunds(escrow, adminWallet)` to withdraw the ETH + tokens, manually creates an Aerodrome pool off-chain, supplies liquidity, and transfers the resulting LP tokens to `0xdead` for permanent lock (the protocol's core user-facing promise).
4. Admin calls `VibesRouterExtension.completeLP(token)` to signal on-chain that tranche claims should unblock.
5. `completeLP` reverts forever on the `hasLockedLP && !hasRescuedLP` check. Neither flag can be modified. There is no setter, no admin override, no migration path.
6. Founder's `claimTranche(n)` is gated (directly or via `setLPCreated` / `verifyLPLocked`) on the locker's verification — tranches never release. Platform fees remain pending. 85% of raised ETH is stuck.

**Impact.** A funded raise in the rescue branch is *permanently illiquid*. Backers have already committed ETH; the LP exists off-chain (safely burned); but the on-chain state machine cannot acknowledge it. The protocol's operational recovery posture is broken at the worst possible moment — exactly when a campaign needed the rescue mechanism in the first place.

This is not a hypothetical: the rescue branch exists *because* LP creation is known to fail under real-world conditions (pool collisions, MEV at launch, stablecoin pauses). Every rescue today creates a potential dead campaign.

**Convergent second opinion.** A fourth independent hardening pass (Report 4, reproduced verbatim in §12) arrived at the same finding using the same protocol model and proposed a near-identical remediation. The two proposals differ only in surface naming:

| Surface | Report 3 | Report 4 |
|---|---|---|
| Function name | `registerManualLPLock(campaign, pool, lpAmount)` | `recordManualLPLock(campaign, pool, lpAmount)` |
| Event | `ManualLPLockRegistered` | `ManualLPLockRecorded` |
| Errors | `InvalidPool`, `InvalidLPAmount`, `RescueNotResolved` | `InvalidLPProof` (+ existing rescue-resolution errors) |
| Tests added | locker success path + revert-when-rescue-not-resolved | `test_recordManualLPLock_successAfterRescueResolution`, `test_recordManualLPLock_revertsWithoutDeadBalanceProof`, plus updates to `test_F1_completeLP_manualResolution` to run rescued → resolved → record → `completeLP()` end-to-end |
| Shared core | Onchain `IERC20(pool).balanceOf(0xdead) >= lpAmount` proof; requires `hasRescuedLP[_campaign]` and `rescue.resolved`; flips flags to `hasLockedLP=true`, `hasRescuedLP=false`; emits event for traceability |

Two independent passes converging on the same bug and the same structural fix is strong evidence that (a) the finding is real and not an artifact of one auditor's model, and (b) the fix shape is the correct one — proof-based manual registration gated on prior resolve + onchain dead-address balance verification. Pick one naming variant for the merged patch (either is fine — `recordManualLPLock` reads slightly more faithfully since the admin is *recording* an off-chain event, not *registering* a new lock on the AMM). Keep both sets of test names from Reports 3 and 4 if they land under the same PR — they exercise slightly different assertions (success path, revert-when-unresolved, revert-when-missing-proof, end-to-end).

**Recommended remediation (harmonized from Reports 3 and 4).** Add an owner-governed explicit state transition:

```solidity
event ManualLPLockRegistered(address indexed campaign, address indexed pool, uint256 lpAmount);
error InvalidPool();
error InvalidLPAmount();
error RescueNotResolved();

function registerManualLPLock(
    address _campaign,
    address _pool,
    uint256 _lpAmount
) external onlyOwner {
    // Rescue must exist and have been resolved
    RescueInfo storage rescue = rescues[_campaign];
    if (!hasRescuedLP[_campaign]) revert NoRescueForCampaign();
    if (!rescue.resolved) revert RescueNotResolved();

    // Pool must be a real contract with code
    if (_pool == address(0) || _pool.code.length == 0) revert InvalidPool();
    if (_lpAmount == 0) revert InvalidLPAmount();

    // Onchain proof: the LP tokens we're claiming to have locked must actually
    // be held at 0xdead on the pool contract.
    require(
        IERC20(_pool).balanceOf(DEAD_ADDRESS) >= _lpAmount,
        "LP not verifiably at dead address"
    );

    // Transition state: clear rescued flag, set locked flag, record the pool.
    hasRescuedLP[_campaign] = false;
    hasLockedLP[_campaign] = true;
    lockedPool[_campaign] = _pool;        // so verifyLPLocked can re-read balance
    lockedLPAmount[_campaign] = _lpAmount;

    emit ManualLPLockRegistered(_campaign, _pool, _lpAmount);
}
```

Combined with the existing `completeLP` onchain proof at `VibesRouterExtension.sol:403-404`, this gives two independent verifications (locker's own balance check + router's `verifyLPLocked`) before tranches unlock — so a compromised owner still cannot forge a lock; they can only register a lock that is already verifiably at the dead address. The registration replaces the impossible invariant ("after rescue, `hasLockedLP` stays false forever") with a reachable one ("after rescue, admin can only register a lock if the LP tokens are actually onchain at the burn address").

**Status in this tree.** The source does **not** contain `registerManualLPLock`, `ManualLPLockRegistered`, `InvalidPool`, or `InvalidLPAmount`. Confirmed by grep. Neither the locker-level regression tests nor the audit-suite update (rescued → resolved → manual lock → `completeLP`) are present. This is a live production blocker for any raise that ever enters the rescue branch. Landing the patch + regression tests is a prerequisite for mainnet deployment.

**Relationship to H-3.** H-3 and H-4 both stem from the same architectural pattern — two independent state machines (escrow/router, locker/router) communicating about finalization via state flags that can drift. H-3 closes the drift by making the router refuse to move ETH without explicit phase progress; H-4 closes the drift by giving the locker an explicit transition to reconverge with the router's expected lock state. The two fixes are complementary and should land together.

---

### M-1 — `completeDistribution()` omits `nonReentrant` (defense-in-depth)

**Severity:** Medium (defense-in-depth, not currently exploitable)
**Contract:** `contracts/src/VibesRouterExtension.sol:129`

**Analysis.** `completeDistribution` is reachable only by `escrow` or `owner` (both trusted) and operates on the launched ERC20 (which is `VibesToken` — a plain fixed-supply ERC20 with no callbacks). The internal `_executePhase2` does set `_stakerTokensTransferred[token] = true` immediately after `safeTransfer`, so a reentry would no-op the transfer branch. The `finalizationPhase[token] != LPComplete` guard at line 146 further blocks re-entry from landing in an inconsistent phase.

So today there is no live vulnerability. The concern is forward-compatibility: if any future change (e.g., supporting non-vanilla project tokens, adding ERC777-like hooks to `VibesToken`, or granting this entry point to a semi-trusted contract) lands before this annotation is added, reentrancy becomes reachable.

**Exploit path (hypothetical).** Suppose `VibesTokenFactory` is one day extended to allow founder-supplied token implementations. A malicious token could define `tokensToSend` hooks (ERC777-style) that fire during `safeTransfer` at line 174, and reenter via the escrow → router → `completeDistribution` path while `_pendingStakerAllocation[token]` is still in flux.

**Recommendation.**
```solidity
function completeDistribution(address token) external whenNotPaused nonReentrant {
```

Add a unit test showing that re-entering via a malicious staker-rewards contract (the `stakerDest.code.length > 0` branch) cannot double-trigger `_executePhase2`.

---

### M-2 — Treasury challenge-resolution functions omit `nonReentrant`

**Severity:** Medium (defense-in-depth)
**Contract:** `contracts/src/VibesTreasuryEscrow.sol:320, 337, 365, 385`

**Analysis.** `upholdChallengeRework`, `upholdChallengeMalicious`, `rejectChallenge`, and `expireChallengeIfNeeded` all perform `token.safeTransfer(...)` after state mutations. State is written before every transfer, so reentry cannot corrupt the challenge state machine — any reentrant call hits `if (activeChallenge.state != ChallengeState.Pending) revert`. The treasury holds the launched `VibesToken`, which has no hooks, so reentrancy is not reachable today.

`upholdChallengeMalicious` additionally calls `VibesVesting.freeze()`. Freeze is not reentrant (no external calls), so that leg is safe.

**Recommendation.** Add `nonReentrant` to all four functions. Cost is one SLOAD per call; benefit is defense against future token changes. This matches the `nonReentrant` pattern already applied to `executeProposal` and `raiseChallenge`.

---

### M-3 — Treasury challenge window closes one block too late at exact boundary

**Severity:** Medium — High confidence (confirmed bug)
**Contract:** `contracts/src/VibesTreasuryEscrow.sol:289` (close), `:265` (execute)
**Source of finding:** Follow-on hardening pass, recorded verbatim in §9 (Report 1).
**PoC/regression test:** `test_raiseChallenge_revertsAtExactWindowBoundary` (to be landed alongside the patch — see §9). Not yet present in the tree reviewed here.

**Root cause.** The two gates at the challenge boundary are not complementary. Let `windowEnd = currentProposal.timestamp + CHALLENGE_WINDOW`:

```solidity
// executeProposal (line 265)
if (block.timestamp < currentProposal.timestamp + CHALLENGE_WINDOW) revert ChallengeWindowOpen();

// raiseChallenge (line 289)
if (block.timestamp > windowEnd) revert ChallengeWindowClosed();
```

At exactly `t == windowEnd`:
- `executeProposal`: `t < windowEnd` is false → **does not revert** → execution allowed.
- `raiseChallenge`: `t > windowEnd` is false → **does not revert** → challenge allowed.

Both are simultaneously callable in the same block. Compare the escrow's tranche path (`VibesTranchEscrow.sol:649,785`), which deliberately uses asymmetric `<=` / `>=` to guarantee exactly-one of claim/challenge is valid per-block — the treasury path does not mirror that invariant.

**Exploit path / failure mode.**
1. Founder creates a proposal at block `B₀`.
2. Anyone (founder included) warps / waits until `block.timestamp == timestamp(B₀) + CHALLENGE_WINDOW` (72h mainnet, 2h testnet).
3. Two valid state transitions exist at that block: `executeProposal()` → withdraws up to 10% of treasury balance to founder; or `raiseChallenge(reason)` → proposal enters `Challenged`.
4. Transaction ordering (MEV, private mempool, sequencer discretion) decides which lands. If the founder's `executeProposal` wins the block, a challenger who had prepared and was relying on a full 72h window loses their opportunity.

Real-world severity hinges on who controls the last block: the Base sequencer today orders by priority fee, so a founder willing to pay a bribe can pre-empt a same-block challenger. Worse, a founder observing a pending challenge in the mempool can race-submit `executeProposal` with a higher priority fee to bypass it.

**Recommended remediation (per Report 1).** Close the window at `>=`, matching the tranche-escrow pattern:

```diff
-        if (block.timestamp > windowEnd) revert ChallengeWindowClosed();
+        if (block.timestamp >= windowEnd) revert ChallengeWindowClosed();
```

After the patch, at `t == windowEnd`: execute is valid, challenge reverts — single clean handoff. The `timeUntilExecutable` view at line 466 already uses `>=`, so this change aligns `raiseChallenge` with the existing getter.

Land the attached regression test `test_raiseChallenge_revertsAtExactWindowBoundary` (see §9) so future refactors can't silently flip the boundary back.

**Status in this tree.** The source at `VibesTreasuryEscrow.sol:289` still uses `>`. The patch was described in the follow-on hardening pass (Report 1) but has not been merged into the source reviewed here. Rolling this finding forward into the mainnet deployment blocker list is strongly recommended.

---

### L-1 — `VibesLPLocker.resolveRescuedFunds()` lacks `nonReentrant`

**Severity:** Low
**Contract:** `contracts/src/VibesLPLocker.sol:~276`

The function sends ETH to an `owner`-chosen recipient via low-level `call`. A malicious recipient (only reachable if owner cooperates) could reenter `setAuthorizedRouter`. This is self-griefing territory since the caller already is/trusts the owner, but adding `nonReentrant` costs nothing.

---

### L-2 — `VibesTokenFactory.deployToken` is permissionless

**Severity:** Informational
**Contract:** `contracts/src/VibesTokenFactory.sol:39`

The factory lets anyone deploy a `VibesToken`. This does not spoof any founder attribution — the resulting token has the caller-specified `recipient` as initial holder and is not tied to `VibesRegistry` or the router's `tokenToEscrow` mapping. Only routers registered with the registry can launch campaigns using a token. The only risk is gas spam (event log bloat). If policy tightens later, add `onlyRouter` gating.

---

### L-3 — `VibesStakerRewards._getStakerBalance` has a snapId==0 fallback that reads current balance

**Severity:** Low
**Contract:** `contracts/src/VibesStakerRewards.sol:288-294`

```solidity
if (snapId > 0) {
    balance = IVibesStakingSnapshot(stakingContract).balanceAtSnapshot(snapId, staker);
} else {
    balance = IVibesStakingReadOnly(stakingContract).stakedBalance(staker);  // current, not snapshot
}
```

The comment says this is a "backwards compatibility" branch for pre-F4 raises. Since the F4-enabled source has never been deployed yet (see `docs/pending-contract-changes.md`), there will never be a raise in production with `raiseSnapshotId == 0`: every call to `notifyReward` (line 162) invokes `takeSnapshot()` which returns a non-zero id.

The branch is therefore dead code — and dead code that reads a *different* balance source is exactly the kind of thing that becomes an exploit after a seemingly unrelated refactor. Either:
- Remove the branch entirely and let the call revert for snapId==0 raises, OR
- Replace it with `revert NoSnapshotForRaise();` so it fails loudly rather than silently reading current balance.

---

### L-4 — `VibesLPLocker.createAndLockLP` ignores `approve()` return values

**Severity:** Informational
**Contract:** `contracts/src/VibesLPLocker.sol:162-163, 191-193, 210`

Three `IERC20(_token).approve(...)` calls ignore the return value. For the current `VibesToken` (always returns true) this is harmless. For arbitrary project tokens it's not. Use OZ `SafeERC20.forceApprove`.

---

### L-5 — `getTrancheAmount` double-division precision

**Severity:** Informational
**Contract:** `contracts/src/VibesTranchEscrow.sol:575-580`

```solidity
uint256 escrowAmount = (effectiveRaised * 8500) / BPS_DENOMINATOR;
return (escrowAmount * KICKSTART_BPS) / BPS_DENOMINATOR;
```

Slither flags this as divide-before-multiply. The precision loss is at most sub-wei per tranche for realistic raise sizes (100+ ETH). Can be collapsed to `(effectiveRaised * 8500 * KICKSTART_BPS) / (BPS_DENOMINATOR * BPS_DENOMINATOR)` for zero-loss math, but the economic impact is negligible. No change required.

---

## 3. Findings rejected as false positives (with evidence)

**FP-1 — "Clone `initialize()` can be front-run" (ESC-002 from escrow agent).** `VibesTranchEscrowFactory.createEscrow` is `onlyRouter` (line 146) and performs `cloneDeterministic + initialize` atomically in one transaction (lines 160-163, 177). Before that transaction executes, the clone address has no code. An external `initialize` call to the predicted address fails because there is no contract to call. After the factory's transaction executes, the clone is already initialized and any second call reverts with `AlreadyInitialized`. Not exploitable.

**FP-2 — "Challenge window boundary off-by-one" (ESC-006).** `VibesTranchEscrow.sol:649` claim check uses `<=` (must be strictly past window) and `raiseChallenge` uses `>=` (window closes at the mark). The two conditions are complementary, not conflicting. Same-block bypass is impossible.

**FP-3 — "Cross-function reentrancy between `batchDistribute` and `claimPendingEth`" (DIST-003).** Both functions are `nonReentrant` (`VibesTokenDistributorV2.sol:229, 284`). OpenZeppelin `ReentrancyGuard` uses a contract-level lock, so reentry from either into the other is blocked. `hasClaimed[recipient] = true` is set on line 250 *before* any external call, and `pendingEthRefunds` is set only on ETH send failure (line 267) — there is no path where a malicious recipient's fallback can double-claim.

**FP-4 — "Uninitialized state variables in VibesRouterStorage" (Slither 11 findings).** All flagged variables (`feesEnabled`, `flatFeeWei`, `vibesToken`, `tokenToTreasury`, `useTestnetContracts`, `trustedLaunchSigner`, `tokenToEscrow`, `launchBurnAmount`, `tokenToVesting`, `tokenToDistributor`, `operationsAdmin`) are populated by explicit setters (`setFeeConfig`, `setVibesToken`, etc.) or filled during launch flow. This is the intended delegatecall storage layout. Not a bug.

**FP-5 — Slither 45 `incorrect-equality` + 5 `arbitrary-send-eth` + 2 `uninitialized-local`.** Known Slither false-positive patterns. `== 0` balance checks are legitimate guards; `arbitrary-send-eth` flags every admin-configurable payout (feeRecipient, platformWallet, founder) which is intentional; `actualETH`/`actualTokens` in `VibesLPLocker` are assigned via function-call destructuring.

---

## 4. Test additions

| File | Tests | What's proved |
|---|---|---|
| `contracts/test/AuditParity2026_04.t.sol` | 7 | H-1 testnet drift bypass + mainnet regression; H-2 testnet missing commit-reveal + mainnet regression |
| `contracts/test/VibesTreasuryEscrow.t.sol` (additions, see §9) | 1 | M-3 exact-boundary challenge window regression (`test_raiseChallenge_revertsAtExactWindowBoundary`) |
| `contracts/test/VibesFinalizationPhases.t.sol` (additions, see §10) | 2 | H-3 Phase-0 claim blocking (`test_claimTokens_revertsWhenPhase1Deferred`); H-3 emergency refund blocking after router progress (`test_emergencyRefundFunded_revertsAfterRouterFinalizationProgress`) |
| `contracts/test/VibesLPLocker.t.sol` + audit regression (additions, see §11 and §12) | 3+ | H-4 locker success path after rescue resolution (`test_recordManualLPLock_successAfterRescueResolution`); H-4 revert without dead-address proof (`test_recordManualLPLock_revertsWithoutDeadBalanceProof`); H-4 updated end-to-end rescued→resolved→recorded→`completeLP()` (`test_F1_completeLP_manualResolution`); plus Report 3's locker revert-when-rescue-not-resolved variant |

```
test_PoC_H1_TestnetAcceptsArbitraryForwardDrift          [PASS]  PoC: testnet accepts 365-day drift
test_Regression_H1_MainnetRejectsDriftBeyondMaxTimeDrift [PASS]  Regression: mainnet reverts
test_Regression_H1_MainnetAcceptsDriftWithinWindow       [PASS]  Regression: 30-min drift accepted
test_Regression_H1_MainnetDriftBoundaryExact             [PASS]  Regression: exact 1h accepted, 1h+1s reverts
test_PoC_H2_TestnetHasInstantSetter                      [PASS]  Selector probe: testnet has direct setter
test_PoC_H2_TestnetMissingCommitRevealSelectors          [PASS]  Selector probe: commit/finalize/cancel absent
test_Regression_H2_MainnetExposesCommitRevealSelectors   [PASS]  Mainnet exposes pendingMerkleRoot/commitTime/DELAY
```

All 7 pass on current source; H-1/H-2 regression tests will begin to fail only if the findings are patched — at which point the PoC tests themselves need to be updated (flip the assertion direction) to track the fix.

**Coverage gaps not closed in this pass (recommended follow-up work):**

1. `EscrowInvariants.t.sol` (planned in the audit plan but not written): ETH conservation, tranche monotonicity, excess refund ceiling, challenge window asymmetry, merkle commit delay. Foundry invariant runner with depth 50, 1000 runs, handler with bounded actions.
2. `RouterInvariants.t.sol`: allocation BPS sums to 10000; nonce monotonicity; delegatecall storage read consistency between router and extension paths.
3. `fuzz/RefundCEI.t.sol`: fuzz reentrant receiver against `claimContributorRefund` / `claimExcessRefund`; prove `nonReentrant` + hasClaimed ordering holds under all input shapes.
4. `fuzz/StakerRewardsDoS.t.sol`: escalate `claimMultiple` array size up to the documented 100-entry cap.
5. `VibesRouterExtension.t.sol` additions: direct tests for M-1 (`completeDistribution` reentrancy under malicious staker-rewards contract); `adminRetryFinalization` idempotence across partial-phase states.
6. `VibesTreasuryEscrow.t.sol` additions: M-2 regression under malicious token; adversarial proposal cycling at cooldown boundary; challenge double-resolve negative tests.
7. `VibesLPLocker.t.sol` additions: L-1 regression; `setAuthorizedRouter` swap mid-`createAndLockLP`; fee-on-transfer token → rescue path.

The existing suite already has strong coverage of F4, F7, F10, C-01, C-02, H-01, H-06, M-1/M-2/M-3 audit fixes via `AuditSecurityTests.t.sol`, `SecurityAuditFixes.t.sol`, `VibesTranchEscrowEdgeCases.t.sol`, `CrossContractInvariant.t.sol`, `VibesFinalizationPhases.t.sol`, and `TermsSignatureVerification.t.sol` — no duplication needed there.

---

## 5. Static analysis triage (Slither 0.11.5)

86 findings on `src/` at `--exclude-low --exclude-informational --exclude-optimization`.

| Check | Count | Disposition |
|---|---|---|
| Medium/incorrect-equality | 45 | False positive — balance `== 0` and mapping default-value checks |
| High/uninitialized-state | 11 | False positive — storage populated by admin setters + launch flow |
| High/reentrancy-eth | 9 | False positive — each call site has `nonReentrant` or is guarded by state flags set before transfer |
| Medium/unused-return | 6 | L-4 (approve return) + canClaim return intentionally destructured |
| High/arbitrary-send-eth | 5 | False positive — admin-configurable payouts are the design |
| Medium/divide-before-multiply | 4 | L-5 — sub-wei precision, no economic impact |
| Medium/reentrancy-no-eth | 4 | False positive — same as reentrancy-eth (all guarded) |
| Medium/uninitialized-local | 2 | False positive — destructured from function returns |

Zero confirmed exploits from Slither. All true findings (L-4, L-5) are Low/Informational and overlap with manual findings.

Halmos and Echidna were out of scope for this pass. Recommended for the pre-mainnet external audit.

---

## 6. Assumptions and trust boundaries

For the verdict in §1 to hold, the following must be true — they cannot be verified from source alone and should be asserted by operations/infrastructure:

1. **Admin keys** (`platform admin` on router, `admin` on factories/escrows/treasury/LP locker) are held in hardware wallets or a multisig with explicit two-step transfer flows. Leaks of any admin key on any contract break the entire protocol's security guarantees.
2. **`trustedLaunchSigner` private key** is held off-chain by the backend service described in `docs/auth-patterns.md`. If it leaks, anyone can launch campaigns bypassing frontend gating — although the founder-deposit payment still gates launch, so financial loss is bounded.
3. **Time oracle** (`MockTimeOracle`): on mainnet, the factory is deployed with `timeOracle = address(0)` (`VibesTranchEscrow.sol:356` fast-path). If an operator ever sets a non-zero time oracle on mainnet, the H-06 drift guard is the only line of defense and it assumes `block.timestamp` from the L2 sequencer is honest. Base sequencer honesty is a Coinbase trust assumption.
4. **Aerodrome router/factory immutability**: `VibesLPLocker` calls fixed addresses. If Aerodrome's core contracts are upgraded to misbehave (e.g., add transfer fees, change `addLiquidityETH` semantics), LP locking could fail in ways not handled by the try/catch rescue path.
5. **Project tokens are vanilla ERC20**: every escrow/refund/vesting/treasury/staking path assumes the launched token has no transfer hooks, no fee-on-transfer, no rebase, and returns true on standard calls. `VibesTokenFactory` enforces this today by always deploying `VibesToken`. M-1 and M-2 become relevant if this assumption is ever relaxed.
6. **Merkle generation** for refund roots (frozen path) and backer token distribution is done off-chain by the admin. The 24h F10 delay (mainnet) is the community's window to detect a malicious root. Testnet has no such window (H-2).
7. **72h challenge window** assumes Base sequencer censorship does not sustain for >72h. Canonical fallback via L1 is possible but would stretch the effective window.
8. **Router extension is never swapped out**: `extension` is immutable on `VibesLaunchRouterV2`. A re-deploy of the router for any reason requires deploying new token/escrow/vesting contracts linked to it.

**Out of scope for this review:**
- Off-chain backend (API routes, signer rotation, database consistency)
- Frontend (wallet integration, signature generation, claim UX)
- Indexer / keeper / cron automation
- `TestnetSwap.sol` beyond noting it is intentionally testnet-only and contains an owner drain function by design

---

## 7. Deployment readiness verdict

**Mainnet contracts (`VibesTranchEscrow`, `VibesLaunchRouterV2`, `VibesRouterExtension`, `VibesRouterStorage`, `VibesTranchEscrowFactory`, `VibesToken`, `VibesTokenFactory`, `VibesTokenDistributorV2`, `VibesVesting`, `VibesTreasuryEscrow`, `VibesLPLocker`, `VibesStaking`, `VibesStakerRewards`, `VibesRegistry`, `VibesIdentityRegistry`, `MockTimeOracle`):**

**NOT READY** — revised from "ready for further review" to reflect the H-4 rescue-lock liveness bug contributed by the third follow-on pass (§11). H-4 is a confirmed protocol-breaking liveness issue: any raise that ever enters the LP rescue branch becomes permanently illiquid because the locker has no on-chain path to transition back from `hasRescuedLP=true` to `hasLockedLP=true`, and `VibesRouterExtension.completeLP()`'s hard gate at line 400 therefore can never be satisfied. The rescue branch is not hypothetical — it exists precisely because Aerodrome LP creation is known to fail under adversarial mainnet conditions. Every rescue today creates a campaign whose ETH is stuck.

Outstanding blockers for mainnet deployment:
1. **H-4** — land a proof-based manual LP lock recording function in `VibesLPLocker` (harmonized from Reports 3 and 4; see §11 and §12) with the onchain dead-address proof and state transition. Pick one naming variant (`recordManualLPLock` or `registerManualLPLock`). Land all locker unit regressions from both reports (`test_recordManualLPLock_successAfterRescueResolution`, `test_recordManualLPLock_revertsWithoutDeadBalanceProof`, Report 3's revert-when-rescue-not-resolved) plus the updated end-to-end `test_F1_completeLP_manualResolution`.
2. **H-3** — land `_claimTokensInternal` phase hard-require and `emergencyRefundFunded` router-phase guard (Report 2 / §10) with both regression tests.
3. **H-1 / H-2** — port `MAX_TIME_DRIFT` and the F10 commit-reveal from `VibesTranchEscrow.sol` to `VibesTranchEscrowTestnet.sol`. Add a CI parity diff check.
4. **M-3** — treasury challenge window close `>` → `>=` (Report 1 / §9) with regression.

After those land, run the full Foundry suite (unit + fuzz + invariants, all 32 test files) plus Slither in CI and triage any new findings. Only then should external audit (Spearbit / Trail of Bits / OpenZeppelin / Zellic / Code4rena) be scheduled. All documented prior findings remain verifiably fixed; the remaining Medium findings in this report (M-1, M-2) are defense-in-depth annotations that can ship alongside or shortly after. Structurally sound but fund-safety blockers exist in the current tree.

**Testnet contracts (`VibesTranchEscrowTestnet`, `VibesTranchEscrowFactoryTestnet`):**

**NOT READY** — patch H-1 and H-2 before the next public incentivized testnet cohort. Both are straightforward back-ports from the mainnet file. Add a CI diff test asserting the non-timing portions of the two files remain in sync.

**`TestnetSwap.sol`:** out of scope, testnet-only, owner-drainable by design.

---

## 8. Appendix — ground-truth log

Every finding in §2 was verified against source. The audit scratch summary:

| Claim | Source evidence |
|---|---|
| Mainnet has `MAX_TIME_DRIFT` | `VibesTranchEscrow.sol:90` constant, `:361` require |
| Testnet lacks `MAX_TIME_DRIFT` | grep returns no match in `VibesTranchEscrowTestnet.sol` |
| Mainnet has F10 commit-reveal | `VibesTranchEscrow.sol:151-153, 1051, 1060, 1072` |
| Testnet lacks F10 | grep returns no match for `pendingMerkleRoot` etc. in testnet file |
| Testnet has instant setter | `VibesTranchEscrowTestnet.sol:997` |
| `completeDistribution` has no `nonReentrant` | `VibesRouterExtension.sol:129` (modifier list omits `nonReentrant`) |
| Treasury resolvers have no `nonReentrant` | `VibesTreasuryEscrow.sol:320, 337, 365, 385` (modifier list omits `nonReentrant`) |
| Factory `createEscrow` is `onlyRouter` | `VibesTranchEscrowFactory.sol:146` |
| Clone init is atomic with creation | `VibesTranchEscrowFactory.sol:160-177` same transaction |
| `batchDistribute` has `nonReentrant` | `VibesTokenDistributorV2.sol:229` |
| `claimPendingEth` has `nonReentrant` | `VibesTokenDistributorV2.sol:284` |
| `hasClaimed` set before transfer in batch | `VibesTokenDistributorV2.sol:250, then 255/261` |

All tests added in this pass reside in `contracts/test/AuditParity2026_04.t.sol` and pass on the unmodified source tree as of 2026-04-14.

---

## 9. Supplemental — Follow-on hardening pass (Report 1)

The following report was contributed by a separate hardening pass on the treasury challenge lifecycle. It identifies M-3 (see §2 above) and describes a patch + regression test. Included verbatim for traceability.

### Summary
Performed a focused security hardening pass on the treasury challenge lifecycle and identified a confirmed boundary-condition bug in `VibesTreasuryEscrow.raiseChallenge`: at exactly `proposal.timestamp + CHALLENGE_WINDOW`, a challenge could still be raised due to `>` instead of `>=`, while `executeProposal` already considered the proposal executable (`block.timestamp <` ... check). This creates a same-boundary ordering race. Patched by changing the close condition to `>=`.

Added a deterministic regression test `test_raiseChallenge_revertsAtExactWindowBoundary` to prove challenges are rejected at the exact boundary (72h), preventing execution/challenge race ambiguity at boundary time.

Scope note: the pass mapped and reviewed the primary fund-handling contracts and challenge/finalization flows (router/extension, tranche escrow, treasury escrow, staking rewards, vesting, LP locker), and then implemented the above high-confidence fix. Full dynamic verification was limited by missing local security tooling binaries in that environment.

### Security Report (delta-focused)

**1) Executive Summary**
- Overall risk (for this pass): One Medium severity, High confidence bug confirmed and patched in treasury proposal challenge timing semantics.
- Top concern fixed: Boundary race at challenge window end in treasury governance flow.
- Depth: Manual review + targeted regression hardening; static/dynamic tooling execution was attempted but blocked by missing binaries.

**2) Findings**

**[MEDIUM | High confidence | Confirmed bug | Patched] Treasury challenge window closes one block too late at exact boundary**

- Affected: `VibesTreasuryEscrow.raiseChallenge`
- Why it matters: At exact window boundary, `executeProposal` and `raiseChallenge` could both be valid in the same block depending on ordering, creating governance ambiguity and mempool race surface for treasury withdrawals.
- Failure mode / reproduction path:
  1. Founder creates proposal.
  2. Warp to exact `proposal.timestamp + CHALLENGE_WINDOW`.
  3. Before patch, `raiseChallenge` accepted because condition was `>` not `>=`.
  4. `executeProposal` was also callable at boundary (`<` guard no longer true).
- Minimal fix direction: Use `>= windowEnd` in `raiseChallenge` to close at exact boundary and align with execution semantics.
- Test coverage status: Previously likely missed exact-boundary test; now explicitly covered by regression test.

**3) Test Additions**
- Added: `test_raiseChallenge_revertsAtExactWindowBoundary` (unit regression).
- Remaining blind spot in that environment:
  - Could not run Foundry test suite/fuzz/invariants locally due missing `forge`.
  - Could not run Slither due missing binary.

**4) Assumptions and Trust Boundaries (key)**
- Admin compromise remains high-impact by design across escrow/treasury challenge outcomes and freeze controls.
- Router-extension delegatecall model assumes immutable trusted extension address and strict owner operational hygiene.
- Token behavior assumptions (fee-on-transfer/rebase/callback tokens) still require execution-backed adversarial tests in CI to fully validate all fund paths.

**5) Deployment Readiness Verdict**
- READY FOR FURTHER REVIEW
- Rationale: one concrete bug fixed and regression added, but local static/dynamic tool execution was not possible here; before mainnet-candidate status, run full Foundry (unit/fuzz/invariants) + Slither in CI and triage all findings.

### Integration note (this review)
At the time this consolidated audit was written, the `>` → `>=` patch described above and the `test_raiseChallenge_revertsAtExactWindowBoundary` regression were not yet present in the source tree reviewed here (`VibesTreasuryEscrow.sol:289` still shows `>`, no matching test found). The finding is nevertheless accepted as a **confirmed Medium-severity bug** (M-3, §2) — the logic analysis is reproduced on the current source and holds. Apply the patch and land the regression before mainnet deployment; the overall verdict in §7 is held at READY FOR FURTHER REVIEW pending that landing plus the full Foundry + Slither CI pass described above.

---

## 10. Supplemental — Cross-contract state consistency pass (Report 2)

The following report was contributed by a separate hardening pass on the core fund-custody pipeline (launch → escrow funding/finalization → LP/distribution → claims/refunds/tranches/treasury). It identifies H-3 (see §2 above) and describes a patch + regression tests. Included verbatim for traceability.

### Executive Summary
A full smart-contract-focused audit pass was completed over the core fund custody pipeline (launch → escrow funding/finalization → LP/distribution → claims/refunds/tranches/treasury) and identified one confirmed High-severity fund-safety issue in cross-contract failure handling. The issue allowed a path toward token + ETH double-dipping during deferred finalization / emergency rollback conditions. The fix is committed and regression coverage was added.

Given environment limits (`forge` unavailable), the Foundry suite could not be executed in that session, so the result is not deployment-ready without CI execution.

### PHASE 1 — System Mapping (Architecture / Trust Boundaries)
- Core launch path: `VibesLaunchRouterV2.launchWithCampaign` deploys token, creates escrow, sets pending LP/backer/staker allocations, and optionally deploys vesting + treasury escrow.
- Escrow (`VibesTranchEscrow`) is the ETH custody/state-machine hub for contributions, finalization, tranche release, challenges, and refunds.
- Router split-finalization model:
  - Phase 1: LP creation / rescue state
  - Phase 2: vesting/treasury/staker/backer distribution
  - tracked by `finalizationPhase`.
- Treasury escrow has its own proposal/challenge lifecycle and can burn treasury + freeze vesting on malicious-upheld challenge.
- Staker rewards depend on staking snapshots taken at reward notification time.

### PHASE 2 — Threat Model (Protocol-Specific)
Evaluated for:
- Malicious backers/founders exploiting cross-contract timing/state skew.
- Deferred/failing router phase calls + emergency admin recovery interactions.
- Reentrancy and CEI violations around ETH/token transfers.
- Compromised privileged role blast radius (owner/admin/ops admin).
- Insolvency/accounting drift in pro-rata + refund paths.
- Challenge/griefing windows and state-liveness.
- "Rescue mode" behavior consistency (LP rescued but funded state maintained).

### PHASE 3 — Manual Audit Findings

**Finding 1 — High (Confirmed, Patched per Report 2)**

- Title: Deferred finalization + emergency refund path could enable token+ETH double-dip.
- Affected flow: `VibesRouterExtension._claimTokensInternal` + `VibesTranchEscrow.emergencyRefundFunded`.
- Why it matters: In deferred/failure modes, claims and emergency contributor refunds could become reachable in inconsistent order, allowing users to potentially retain claimed tokens and later reclaim ETH (or enabling unsafe rollback attempts after finalization progress).
- Patch:
  - Claims now hard-require finalization progress:
    - revert if `finalizationPhase == None`
    - require `FullyComplete` before claim transfer.
  - Emergency funded refund now blocks if router finalization has progressed (phase != 0), with best-effort compatibility fallback.
- Regression tests added:
  - `test_claimTokens_revertsWhenPhase1Deferred`
  - `test_emergencyRefundFunded_revertsAfterRouterFinalizationProgress`
- Status: Patched (per Report 2).

### PHASE 4 — Static/Automated Analysis
Attempts to run the test/tooling stack in that environment were blocked: Foundry is not installed (`forge: command not found`), and external installer access was blocked. Static/fuzz/invariant execution could not be completed in-session.

### PHASE 5 — Test Expansion
Added focused adversarial regressions in `VibesFinalizationPhases.t.sol` for:
- Phase-0 deferred finalization claim blocking.
- Emergency refund rejection after finalization progression in rescued-LP path.

### PHASE 6 — Patching Summary
Implemented minimal localized fixes:
- Router claim gating tightened to avoid claims pre-finalization.
- Escrow emergency rollback now guarded against progressed router finalization.

### PHASE 7 — Final Security Report

**1) Overall Risk Assessment** — Improved, but not fully validated in that environment due inability to run test suite/static tooling.

**2) Findings** — High / Confirmed / Patched: token+ETH double-dip risk in deferred-finalization/emergency interactions (details above).

**3) Test Additions** — 2 new deterministic regression tests in finalization suite.

**4) Assumptions / Trust Boundaries**
- Router/escrow deployment wiring is correct and immutable expectations hold.
- Owner/admin/op-admin key security remains critical.
- Finalization rescue/manual resolution procedures are operationally disciplined.

**5) Deployment Readiness Verdict** — READY FOR FURTHER REVIEW (not mainnet candidate yet from that run) — because runtime validation (forge tests/fuzz/invariants/slither) was blocked in that environment.

### Integration note (this review)
At the time this consolidated audit was written, neither the claim-gating tightening in `_claimTokensInternal`, nor the `emergencyRefundFunded` router-phase guard, nor the two regression tests (`test_claimTokens_revertsWhenPhase1Deferred`, `test_emergencyRefundFunded_revertsAfterRouterFinalizationProgress`) were present in the source tree reviewed here. Current source shows:
- `VibesRouterExtension.sol:297-363` — `_claimTokensInternal` with state-machine-based gating + self-healing Phase 2 auto-trigger, but no explicit `finalizationPhase != None` revert and no `FullyComplete` hard-require.
- `VibesTranchEscrow.sol:974-992` — `emergencyRefundFunded` checks only `!lpCreated` and solvency; it does not consult the router's `finalizationPhase`.

My independent pass on the current source observed that the direct double-dip path is blunted today by (a) `backerTokensForClaims[token]` defaulting to zero before Phase 2 (making a Phase-0 claim revert with `NothingToClaim`), and (b) the LPComplete self-heal forcing Phase 2 to run before a claim returns tokens. However, both mitigations are structural side effects rather than explicit guards. The explicit guards described in Report 2 are the correct defensive posture for a fund-custody contract, remove reliance on cross-contract accident, and prevent regression from any future refactor that populates `backerTokensForClaims` earlier or introduces another admin recovery path. The finding is therefore accepted as a **confirmed High-severity bug** (H-3, §2). Land the patches and regression tests before the mainnet deployment gate.

---

## 11. Supplemental — LP rescue/relock liveness pass (Report 3)

The following report was contributed by a separate hardening pass on the fund-critical finalization / rescue path. It identifies H-4 (see §2 above) and describes a patch + regression tests. Included verbatim for traceability.

### Summary
Performed a deep manual review of the fund-critical finalization/rescue path and identified a confirmed high-severity liveness/fund-access issue in the rescued-LP flow: `completeLP()` requires `hasLockedLP == true` and `hasRescuedLP == false`, but rescued campaigns were only ever marked `hasRescuedLP == true` with no on-chain transition back to a verifiable locked state. This could permanently strand campaigns in rescued state and block tranche progression.

Patched `VibesLPLocker` by adding `registerManualLPLock(...)` to explicitly register a manually-created LP lock after rescue resolution, with hard checks (rescue must exist + be resolved, nonzero pool/LP amount, and proof that LP is actually at dead address). This restores a safe on-chain path to satisfy `completeLP()`'s verification requirements.

Added new event/error surfaces for observability and stronger validation: `ManualLPLockRegistered`, `InvalidPool`, and `InvalidLPAmount`.

Expanded regression tests:
- Added locker tests for successful manual LP registration and revert path when rescue wasn't resolved.
- Updated the audit regression flow to execute rescued → resolved → manual lock registered → `completeLP()` so the test now matches the real trust/verification path.

### Findings (confirmed)

**Rescued LP state deadlock could freeze funded campaigns**
- Severity: High
- Confidence: High
- Affected: `VibesRouterExtension.completeLP`, `VibesLPLocker` rescue state handling.
- Why it matters: Founder tranche claims depend on LP creation being confirmed; if LP rescue cannot be transitioned to a verified lock state, funds can become operationally stuck.
- Fix direction: add explicit owner-governed registration of a verified manual lock with on-chain dead-address proof and state transition out of rescued mode.
- Status: Patched (per Report 3).

### Integration note (this review)
At the time this consolidated audit was written, none of `registerManualLPLock`, `ManualLPLockRegistered`, `InvalidPool`, or `InvalidLPAmount` were present in `VibesLPLocker.sol`. Confirmed by grep on the source tree. Neither the locker unit regressions nor the audit-suite `rescued → resolved → manual lock → completeLP()` flow update are present in `contracts/test/`.

My independent pass on the current source confirms the liveness bug end-to-end:
- `VibesLPLocker.sol:207-208, 227` — rescue branch sets `hasRescuedLP[_campaign] = true` while the comment at line 207 explicitly states "hasLockedLP stays false for rescued campaigns."
- `VibesLPLocker.sol:276-282` — `resolveRescuedFunds` only sets `rescue.resolved = true`; it does NOT touch `hasLockedLP` or `hasRescuedLP`.
- No other function in `VibesLPLocker.sol` writes to `hasRescuedLP` or flips `hasLockedLP` true for a campaign that already went through rescue.
- `VibesRouterExtension.sol:399-404` — `completeLP` requires `hasLockedLP && !hasRescuedLP`. For any rescued campaign, this is permanently false.

Therefore the finding is accepted as a **confirmed High-severity bug** (H-4, §2) and is treated as a mainnet deployment blocker in §7. The Report 3 `registerManualLPLock` patch with its dead-address balance proof is the correct remediation; it does not weaken the F7b onchain-proof guarantee (an owner cannot register a lock that isn't actually at the dead address) while closing the liveness gap. Land the patch and regression tests before the next mainnet deployment attempt.

---

## 12. Supplemental — Convergent LP rescue/relock pass (Report 4)

The following report was contributed by a fourth hardening pass. It re-derives the same H-4 finding independently and proposes a near-identical fix, which reinforces confidence that (a) the bug is real and (b) the remediation shape is correct. Included verbatim for traceability; the H-4 write-up in §2 already harmonizes the naming differences between Reports 3 and 4.

### 1) Executive Summary
A full code-walk was performed over the core fund-handling contracts and privilege surfaces, with focus on high-risk finalization/LP-lock paths. A confirmed High-severity liveness/safety bug was found and patched in the rescued-LP recovery flow that could indefinitely block tranche progression after LP rescue. The issue is now fixed with an on-chain proof-based manual lock recording path, plus regression coverage.

Foundry could not be run in that environment (`forge` missing), so dynamic confidence is limited to static/manual review and new test authoring (not execution). That means this should not be considered mainnet-ready yet.

### 2) System Mapping (Architecture / Trust Boundaries)

**Core contracts (fund-critical)**
- `VibesLaunchRouterV2` orchestrates launch + campaign setup, allocations, deposit accounting, and campaign wiring.
- `VibesRouterExtension` handles delegated admin operations, token claims, and finalization phases (LP + distribution), including rescued LP completion gatekeeping.
- `VibesTranchEscrow` handles contributions, finalization, tranche release/challenge/refund logic, LP ETH forwarding, and campaign state machine.
- `VibesLPLocker` creates/locks LP, stores rescue state, and now records proof of manual LP lock for rescued campaigns.
- `VibesTranchEscrowFactory` deploys escrow clones with admin/router/trusted signer configuration.
- `VibesTreasuryEscrow` controls treasury token vesting-by-proposal with challenge outcomes.
- `VibesStakerRewards` snapshots staking and allocates per-raise staker rewards.

**Roles / privileged surfaces**
- Router owner/admin surfaces in shared storage (`owner`, `opsWallet`, `feeRecipient`, `operationsAdmin`, etc.).
- Escrow admin can pause/freeze/uphold/reject challenges and control refund root lifecycle.
- LP locker owner controls rescue resolution and (now) manual LP-lock recording.

**Fund-flow highlights**
- Contributor ETH enters escrow; on success, LP ETH is forwarded to router then used in LP creation path.
- Token allocations are minted to router and split to vesting/treasury/pending LP/backer claim pool.
- LP rescue path (when AMM call fails) stores funds in locker rescue state for manual resolution.

### 3) Threat Model (Applied)
Modeled:
- Malicious users/backers/challengers (challenge griefing, claim-order, pro-rata edge accounting).
- Malicious/compromised privileged actor (owner/admin misuse on rescue/finalization/refund roots).
- Partial failure paths (LP creation failure, deferred finalization/distribution).
- Token-lock trust guarantee breakage (LP supposedly "locked" but unverifiable).
- Insolvency/liveness failures in multi-step rescue/recovery.

Most critical interaction: Rescued LP state ↔ router `completeLP` verification constraints.

### 4) Findings

**Finding 1 — High / High confidence / Confirmed bug (patched per Report 4)**

- Title: Rescued LP campaigns could become permanently non-resolvable for tranche unblocking
- Affected: `VibesLPLocker`, `VibesRouterExtension.completeLP`
- Why it matters: If LP creation failed and rescue path triggered, the campaign could be stuck in rescued state and fail router verification forever, blocking tranche unlock progression despite manual offchain remediation.
- Exploit/failure mode:
  1. Campaign finalization hits LP rescue (`hasRescuedLP=true`, `hasLockedLP=false`).
  2. Router `completeLP` requires `hasLockedLP && !hasRescuedLP` and verified dead-address lock.
  3. Pre-patch locker had no function to transition a rescued campaign into that verifiable locked state.
- Minimal fix direction (implemented in Report 4):
  - Added `recordManualLPLock(campaign, pool, lpAmount)` in locker:
    - Requires prior rescue + resolved funds.
    - Requires on-chain proof `deadBalance >= lpAmount`.
    - Writes locked position, flips `hasLockedLP = true`, `hasRescuedLP = false`.
  - Added `InvalidLPProof` and `ManualLPLockRecorded` for safety / traceability.
- Tests likely missed it before: yes; prior "manual resolution" test bypassed the missing transition mechanism.
- Remediation status: Patched (per Report 4).

### 5) Test Additions / Hardening
Added regression-oriented tests for the LP rescue completion path:
- `test_recordManualLPLock_successAfterRescueResolution` validates rescue → resolve → proof record → locker verification success.
- `test_recordManualLPLock_revertsWithoutDeadBalanceProof` validates proof enforcement.
- Updated `test_F1_completeLP_manualResolution` to exercise the full real recovery flow before `completeLP`.

### 6) Assumptions & Remaining Risks
- Foundry test/fuzz/invariant suites could not be executed due missing `forge`, so runtime validation is pending.
- This pass was strongest on escrow/router/LP-locker/tranche and treasury-related fund paths; still needs full tool-backed confirmation (fuzz/invariants/static analyzers) before deployment sign-off.
- Manual LP lock recording now depends on truthful pool/amount input, but hardens it with dead-address on-chain proof and router-side verification checks.

### 7) Deployment Readiness Verdict
READY FOR FURTHER REVIEW (not mainnet candidate yet).
Reason: one high-impact issue fixed, but full automated validation (tests/fuzz/static analysis) could not be executed in that environment.

### Summary
- Patched LP rescue recovery liveness/safety gap by adding an on-chain-proof manual LP lock recording path in `VibesLPLocker`, enabling rescued campaigns to satisfy router `completeLP` checks.
- Added/updated regression tests covering successful manual lock recording, invalid proof rejection, and end-to-end rescued LP completion path.
- Committed on branch: `d061df0` and created PR metadata via make_pr.

### Integration note (this review)
At the time this consolidated audit was written, none of `recordManualLPLock`, `ManualLPLockRecorded`, or `InvalidLPProof` were present in `VibesLPLocker.sol` on the tree reviewed here (grep confirms). Neither were `test_recordManualLPLock_successAfterRescueResolution`, `test_recordManualLPLock_revertsWithoutDeadBalanceProof`, nor the updated `test_F1_completeLP_manualResolution` present in `contracts/test/`. Branch `d061df0` was not checked out during review.

Reports 3 and 4 represent independent confirmations of the same underlying H-4 bug. §2 and §11 both already discuss the finding at length. This section is preserved verbatim for traceability. Pick one naming variant and land the merged patch with the union of tests from Reports 3 and 4 — they cover complementary assertions (success, revert-when-unresolved, revert-when-no-proof, end-to-end). The overall verdict in §7 remains **NOT READY** pending that landing plus the other three outstanding H/M fixes.
