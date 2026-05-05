# Vibestarter Consolidated Security Audit Report

**Date:** 2026-03-27
**Target:** Vibestarter Protocol — All Solidity contracts + SIWE auth backend
**Methodology:** 4 independent adversarial review passes, cross-validated
**Posture:** All actors (founders, backers, admins) assumed hostile

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 6 |
| Medium | 5 |
| Low | 4 |
| UX | 2 |
| **Total** | **20** |

---

## Critical Findings

### C-01: Pro-Rata Excess Liability Underflow — Last Claimant Bricked

**Location:** `VibesTranchEscrow.sol:460` (liability set), `:1019` (liability decremented)

**Root Cause:** At finalization, `totalExcessRefundLiability` is set to `totalCommitted - goal` (a single aggregate value). Each user's excess is computed independently as `contrib - floor(contrib * goal / totalCommitted)`. Due to floor-division rounding, the **sum of per-user excesses exceeds the tracked liability**.

**Numeric Proof (verified):**
- Goal = 7 ETH, 3 users each contribute ~3.333 ETH (total = 10 ETH)
- Liability set: `10 - 7 = 3.000000000000000000 ETH`
- User 1 excess: `1.000000000000000001 ETH` (rounds up by 1 wei)
- User 2 excess: `1.000000000000000000 ETH`
- User 3 excess: `1.000000000000000000 ETH`
- **Sum of excesses: `3.000000000000000001 ETH` > liability by 1 wei**

The last claimant's `totalExcessRefundLiability -= excess` underflows (Solidity 0.8 checked arithmetic), permanently reverting. With N contributors, the gap can be up to N-1 wei. This also corrupts `frozenEthBalance` calculations if a freeze occurs before all excess claims.

**Impact:** Last pro-rata contributor permanently unable to claim legitimate excess ETH. Freeze accounting corruption. Trapped ETH.

**Remediation:**
1. Use `min(excess, totalExcessRefundLiability)` when decrementing: `uint256 deduction = excess > totalExcessRefundLiability ? totalExcessRefundLiability : excess; totalExcessRefundLiability -= deduction;`
2. Or: compute liability as sum of per-user excesses at finalization time (iterate contributions).
3. Add multi-user rounding-invariant fuzz tests with adversarial distributions.

---

### C-02: Single-Hash Merkle Leaves in StakerRewards and Holder Refunds

**Location:** `VibesStakerRewards.sol:236`, `VibesTranchEscrow.sol:966`

**Root Cause:** Both contracts use single-hashed Merkle leaves:
```solidity
bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount)); // 52 bytes
```
The `VibesTokenDistributorV2` correctly double-hashes (line 193), but these two do not. In a single-hash scheme, a leaf hash is indistinguishable from an intermediate node. An attacker who knows the tree structure can craft an `(address, amount)` pair matching an intermediate node hash and submit a shorter proof.

OpenZeppelin's MerkleProof documentation explicitly warns against this pattern. The 52-byte input (vs 64-byte intermediate nodes) provides partial mitigation, but violates defense-in-depth.

**Impact:** Potential unauthorized token claims from staker reward pools or fraudulent ETH extraction from frozen campaign refund pools.

**Remediation:**
1. Double-hash both: `keccak256(abi.encodePacked(keccak256(abi.encodePacked(msg.sender, amount))))`
2. Update `holder-refund-merkle.ts` `hashHolderLeaf()` to match.
3. Regenerate any existing Merkle trees.

---

### C-03: `transferFrom` Instead of `safeTransferFrom` for $VIBES Burn

**Location:** `VibesLaunchRouterV2.sol:541`

**Root Cause:**
```solidity
vibesToken.transferFrom(msg.sender, address(0xdead), launchBurnAmount);
```
Every other token transfer in the codebase uses `SafeERC20.safeTransfer/safeTransferFrom`. This sole exception means a non-standard ERC20 returning `false` on failure silently succeeds. Launches proceed without burning tokens.

**Impact:** Complete bypass of burn-to-launch economic gate. Unlimited spam launches with no cost.

**Remediation:** Change to `IERC20(address(vibesToken)).safeTransferFrom(...)`.

---

## High Findings

### H-01: Challenge-Window Boundary Race — Same-Block Founder Bypass

**Location:** `VibesTranchEscrow.sol:601-602` (claim check), `:735-736` (challenge check)

**Root Cause:** At exactly `timestamp == trancheRequestedAt[T] + CHALLENGE_WINDOW`:
- `claimTranche`: `_currentTime() < claimableTime` → **false** (claim allowed)
- `raiseChallenge`: `_currentTime() > windowEnd` → **false** (challenge also allowed)

Both operations are valid in the same block. Founder can bundle/private-order `claimTranche` before a challenger's `raiseChallenge`, making the challenge revert with `TrancheAlreadyClaimed`.

**Impact:** Challenge rights probabilistically bypassed at the deadline edge.

**Remediation:** Make boundaries asymmetric: claim requires `>` (strictly after), challenge disallows at `>=` (at-or-after).

---

### H-02: Router Pause Bricks Escrow Finalization — Funds Trapped

**Location:** `VibesTranchEscrow.sol:478` → `VibesLaunchRouterV2.sol:278` (`whenNotPaused`)

**Root Cause:** `finalize()` calls `router.completeFinalization()` which is guarded by `whenNotPaused`. If the router is paused when a campaign reaches its successful end condition, the entire finalize transaction reverts. The escrow state rollback keeps the campaign in Active/Paused — it can never transition to Funded. Repeated attempts keep failing.

The backup `finalizeSuccessfulCampaign()` in the extension is ALSO behind the paused fallback (`fallback() external payable whenNotPaused`).

**Impact:** ETH and tokens permanently trapped until owner unpauses. Liveness failure under admin action or key compromise.

**Remediation:**
1. Exempt escrow-origin `completeFinalization` from pause guard, OR
2. Decouple escrow state transition from router callback (two-step: mark Funded first, then async LP/distribution), OR
3. Add try/catch around the router callback in escrow so finalization still completes.

---

### H-03: Compromised Operations Admin Can Drain Frozen Campaign Funds

**Location:** `VibesTranchEscrow.sol:867-880, 907-912, 916-920`

**Root Cause:** The operations admin (single EOA) can in sequence: `freezeCampaign()` → `setLockedAddresses()` (manipulate redeemable supply) → `setRefundMerkleRoot()` (arbitrary merkle root giving all ETH to attacker).

**Impact:** Complete drainage of remaining ETH in any frozen campaign escrow.

**Remediation:** Multi-sig + timelock on `setRefundMerkleRoot`. Lock `setLockedAddresses` after finalization. Public verification period for merkle roots.

---

### H-04: LP Rescue Path Breaks Protocol-Enforced LP Lock Guarantee

**Location:** `VibesLPLocker.sol:186-206` (rescue), `:269-289` (resolveRescuedFunds), `VibesLaunchRouterV2.sol:319-323`

**Root Cause:** When LP creation fails (MEV, slippage), the rescue path saves funds in the locker and finalization **continues as if successful** — backer claims activate, tranches begin. The locker owner can later call `resolveRescuedFunds(_campaign, _to)` sending rescued ETH+tokens to any arbitrary address. There is no onchain proof that LP was ever actually created/locked before tranche claims proceed.

**Impact:** The "LP locked indefinitely" guarantee is violated. Admin can extract funds meant for permanent LP. Token trades on Aerodrome with no backing liquidity.

**Remediation:**
1. Block tranche progression (require `lpStatus == Created`, not just `lpWithdrawn`) until LP is truly locked.
2. Gate `resolveRescuedFunds` behind timelock + multisig + onchain destination policy.
3. Add invariant: "no tranche claim unless LP verified locked at dead address."

---

### H-05: EIP-712 Terms Signature Lacks Nonce — Replay Within Same Escrow

**Location:** `VibesTranchEscrow.sol:221, 375-389`

**Root Cause:** `TermsAcceptance(address user, uint256 deadline)` has no nonce. A single signature is valid for both `contribute()` and `raiseChallenge()` unlimited times until deadline.

**Impact:** Unauthorized challenge actions using contribution-intended signatures. Griefing vector.

**Remediation:** Add nonce field to typehash. Track per-user nonces. Or separate typehashes per action.

---

### H-06: Malicious Time Oracle Nullifies All Challenge Windows

**Location:** `VibesTranchEscrow.sol:331-336`, `VibesTranchEscrowFactory.sol` (factory-controlled `timeOracle`)

**Root Cause:** Factory admin controls `timeOracle` for all new escrows. A compromised factory admin sets a malicious oracle returning future timestamps. All tranche unlock times and challenge windows are bypassed — founder claims tranches immediately, challengers see windows as already expired.

**Impact:** Complete nullification of challenge protections and tranche pacing for all new campaigns.

**Remediation:** Hard-disable custom oracle on mainnet (enforce `address(0)` in factory for production). Add sanity bound: `require(oracleTime <= block.timestamp + MAX_DRIFT)`.

---

## Medium Findings

### M-01: SIWE Chain ID Validation Bypass via JavaScript Falsy Check

**Location:** `apps/web/src/app/api/auth/siwe/verify/route.ts:93`

**Root Cause:**
```typescript
if (siweMessage.chainId && siweMessage.chainId !== env.chainId) {
```
If `chainId` is `undefined`/`0`/`NaN`, the check is skipped entirely. A crafted SIWE message omitting the Chain ID line bypasses chain validation.

**Impact:** Cross-chain/cross-deployment session hijacking.

**Remediation:** Change to `if (siweMessage.chainId !== env.chainId)` — reject if missing OR mismatched.

---

### M-02: Redeemable-Supply Double Counting Can Brick Freeze Path

**Location:** `VibesTranchEscrow.sol:348-373, 907-912`

**Root Cause:** `setLockedAddresses` accepts arbitrary addresses from admin/router. `_calculateRedeemableSupply` sums excluded balances without deduplication. If overlapping or high-balance addresses are set, `excludedBalance` can exceed `totalSupply`, clamping redeemable supply to 0. `freezeCampaign`/`upholdChallenge` then revert on `require(frozenTotalSupply > 0)`.

**Impact:** Governance/challenge safety valve bricked for funded campaigns.

**Remediation:** Deduplicate excluded addresses. Add sanity checks. Lock addresses once at finalization.

---

### M-03: Pending Platform Fees Inflate Frozen ETH Balance

**Location:** `VibesTranchEscrow.sol:789, 875`

**Root Cause:** `frozenEthBalance = address(this).balance - totalExcessRefundLiability` includes accrued `pendingPlatformFees`. Fee withdrawal blocked in Frozen/Refunding state, so fees are absorbed into holder refund pool.

**Impact:** Platform permanently loses earned fees on frozen campaigns. Incorrect accounting.

**Remediation:** Subtract `pendingPlatformFees` from `frozenEthBalance`.

---

### M-04: Aerodrome LP Creation Sandwich Attack (1% Slippage)

**Location:** `VibesLPLocker.sol:166-167`

**Root Cause:** 1% slippage tolerance + 5-minute deadline on `addLiquidityETH`. MEV bots/sequencer can extract up to 1% of LP value per finalization.

**Impact:** ~0.15 ETH extractable per 100 ETH campaign. Cumulative across all campaigns.

**Remediation:** Tighter slippage (0.3-0.5%). Private submission mechanism. Price oracle check.

---

### M-05: `setUseTestnetContracts` in Mainnet Bytecode

**Location:** `VibesRouterExtension.sol:352-354`

**Root Cause:** Code comment says "REMOVE FOR MAINNET" but function exists. Compromised owner toggling to `true` gives all new campaigns 6-day cliffs and 2-hour challenge windows.

**Impact:** Complete collapse of economic security for all new campaigns.

**Remediation:** Remove function from mainnet extension. Or: `require(block.chainid != 8453)`.

---

## Low Findings

### L-01: `batchDistribute` Unbounded Array — Gas Grief DoS

**Location:** `VibesTokenDistributorV2.sol:224-277`

No length limit on `recipients[]`. Malicious recipient contracts can consume gas. `claimMultiple` in StakerRewards has same issue.

**Remediation:** Add `require(recipients.length <= 100)`.

---

### L-02: SIWE `uri` Not Validated Against Canonical App URL

**Location:** `apps/web/src/app/api/auth/siwe/verify/route.ts`

Domain and chain validated, but `uri` is not checked. Weakens statement binding.

**Remediation:** Enforce `siweMessage.uri === env.appUrl`.

---

### L-03: Backup `finalizeSuccessfulCampaign` Missing Rescue Pattern + Locked Addresses

**Location:** `VibesRouterExtension.sol:47-122`

Missing: try/catch LP rescue, `lpStatus` tracking, `setLockedAddresses` call, access control. Never tested.

**Remediation:** Align with `completeFinalization` or remove.

---

### L-04: `canExecuteProposal` View Ignores `proposalChallengeResolved`

**Location:** `VibesTreasuryEscrow.sol:439-445`

Returns false during challenge window even when proposal is immediately executable after challenge rejection.

**Remediation:** Add `if (proposalChallengeResolved) return (true, "")` before timestamp check.

---

## UX Findings

### U-01: Holder Refund Requires Token Approval Before Claiming

**Location:** `VibesTranchEscrow.sol:978`

Two-step process during crisis scenario. Opaque ERC20 revert if not approved.

**Remediation:** Add clear error message. Frontend batch approve+claim.

---

### U-02: Router `receive()` Accepts Arbitrary ETH Without Event

**Location:** `VibesLaunchRouterV2.sol:610`

Silent ETH absorption. No accounting.

**Remediation:** Emit event or restrict to known callers.

---

## Priority Remediation Order

| Priority | ID | Fix Effort | Blocks Mainnet? |
|----------|----|-----------|-----------------|
| 1 | C-01 | Low (3 lines) | **Yes** |
| 2 | C-03 | Trivial (1 line) | **Yes** |
| 3 | H-01 | Low (2 lines) | **Yes** |
| 4 | H-02 | Medium (architectural) | **Yes** |
| 5 | M-01 | Trivial (1 line) | **Yes** |
| 6 | C-02 | Medium (redeploy) | **Yes** |
| 7 | H-04 | Medium (state gating) | **Yes** |
| 8 | H-05 | Medium (redeploy) | Recommended |
| 9 | H-03 | Medium (multisig) | Recommended |
| 10 | H-06 | Low (remove oracle) | **Yes** |
| 11 | M-05 | Trivial (remove fn) | **Yes** |
| 12 | M-02 | Low (dedup) | Recommended |
| 13-20 | Rest | Low | No |

---

## Test Coverage Gaps Identified

The following scenarios have **zero test coverage** across the entire test suite:

1. **Same-block boundary conditions** (`timestamp == deadline`) for challenge/claim race
2. **Paused router + finalization** integration path
3. **Backup `finalizeSuccessfulCampaign`** — never tested at all
4. **Reentrancy attack simulations** — `nonReentrant` modifier present but never tested against attack contracts
5. **Multi-user pro-rata rounding invariants** — no fuzz tests with adversarial distributions
6. **Malicious time oracle** — no test with attacker-controlled oracle returning future timestamps
7. **LP rescue → tranche claim progression** without actual LP lock
8. **Duplicate locked addresses** in `setLockedAddresses`
