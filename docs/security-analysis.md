# Vibestarter Protocol — Security Analysis Report

**Date:** 2026-02-24
**Scope:** All 14 smart contracts in `contracts/src/` (~4,807 lines of Solidity)
**Solidity Version:** ^0.8.20 (compiled with 0.8.24)
**Framework:** Foundry (forge-std, OpenZeppelin v5)

---

## 1. Executive Summary

The Vibestarter smart contract suite demonstrates strong security fundamentals: ReentrancyGuard on all ETH-handling contracts, SafeERC20 for token operations, two-step admin transfers (with one exception), and custom errors for gas-efficient reverts. The primary risks are centralization-related (admin trust surface) rather than exploitable vulnerabilities.

**Findings Summary:**

| Severity | Count | Description |
|----------|-------|-------------|
| Critical | 0 | No critical exploitable vulnerabilities found |
| High | 5 | Admin trust surface, cross-contract atomicity risk, rescue function scope, **MEV LP DoS (EA-1, fixed)**, **admin refund drain (EA-2, fixed)** |
| Medium | 5 | One-step ownership, supportChallenge access, token ERC20 compliance, challenge window timing, **platform fee push DoS (EA-3, fixed)** |
| Low | 5 | Rounding dust, gas optimizations, event-only functions, documentation gaps |
| Informational | 6 | Best practices, testnet-only code, naming conventions |

---

## 2. Automated Static Analysis

### 2.1 Tool Installation Status

**Slither:** Installed and run on 2026-02-24. See Section 2.2 for actual findings.

```bash
pip install slither-analyzer solc-select
solc-select install 0.8.24 && solc-select use 0.8.24
cd contracts && slither . --solc-remaps "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/"
```

**Aderyn:** Not yet run — requires Rust/Cargo toolchain, which is not installed in this environment. Install and run when available:

```bash
cargo install aderyn
cd contracts && aderyn .
```

### 2.2 Actual Slither Findings (Run 2026-02-24)

#### New Findings (not in manual audit)

**S1. CEI Violation in `VibesTokenDistributorV2.batchDistribute()` — Low/Informational**

Slither flagged `reentrancy-eth` in `batchDistribute()`. While `hasClaimed[addr]` is correctly set before each `.call{value:}`, the aggregate state variables (`totalEthClaimed`, `totalPendingEthRefunds`, `totalTokensClaimed`) are updated *after* the ETH transfer:

```solidity
(bool success, ) = recipient.call{value: refund}("");
// ...
totalEthClaimed += ethAmount;         // written AFTER transfer ← CEI violation
totalPendingEthRefunds += ...;
totalTokensClaimed += tokenAmount;
```

**Risk:** Direct reentrancy is blocked by `nonReentrant`, so this cannot be exploited by a malicious `receive()`. The aggregated totals can be temporarily stale during batch execution, but since the per-address `hasClaimed` guard prevents double-claims, the practical risk is negligible.

**Recommendation:** Reorder to write all state before the `.call{}` (pure CEI), or document the architectural justification in NatSpec.

**Status:** Acknowledged — mitigated by `nonReentrant` + per-address guard. No code change required at this time.

---

**S2. Missing Zero-Check on `timeOracle` in Several Functions — Informational**

Slither's `missing-zero-check` detector flagged the `timeOracle` parameter in:
- `VibesTranchEscrow.initialize()` — `_timeOracle` can be `address(0)`
- `VibesTranchEscrowFactory` constructor and `setTimeOracle()` — same
- `VibesRouterExtension.refundDeposit()` — internally references timeOracle

**Analysis:** This is a **false positive**. `address(0)` is valid and intentional — when `timeOracle == address(0)`, the contract falls back to `block.timestamp`. This is the mainnet configuration (no mock needed). Testnet uses `MockTimeOracle`.

**Status:** False positive — no action required.

---

#### Confirmed Findings (matching manual audit analysis)

**`reentrancy-eth` detector:** 23 instances flagged. All are protected by `nonReentrant` or restricted to trusted callers. See full table below in Section 7.

**`arbitrary-send-eth`:** Flagged `feeRecipient` calls in `VibesLaunchRouterV2`. These are admin-controlled addresses (set via `setFeeConfig()`), consistent with the H2/H3 centralization findings documented in Section 3.

**`calls-loop`:** Flagged in `batchDistribute`, `batchClaimTokens`, and `_excludeAddresses` iteration. All intentional batch operations; gas cost documented and within Base L2 limits (see `GasBenchmarks.t.sol`).

**`incorrect-exp`:** Flagged in `@openzeppelin/contracts/utils/math/Math.sol`. **False positive** — this is in the OZ library, not protocol code.

**`low-level-calls`:** All `.call{value:}` instances use correct success checks. No `.transfer()` or `.send()` usage.

**`missing-zero-check` (non-timeOracle):** Zero-address checks are present in all constructors and setter functions. The pre-existing `VibesRegistry.transferOwnership()` single-step pattern has been fixed (see M1).

### 2.3 `reentrancy-eth` Full Instance Table

| Contract | Function | Protected | Notes |
|----------|----------|-----------|-------|
| VibesTranchEscrow | `finalize` | `nonReentrant` | LP ETH to router |
| VibesTranchEscrow | `claimTranche` | `nonReentrant` | Fee + founder payout |
| VibesTranchEscrow | `claimContributorRefund` | `nonReentrant` | Refund to msg.sender |
| VibesTranchEscrow | `claimHolderRefund` | `nonReentrant` | Merkle-verified refund |
| VibesTranchEscrow | `claimExcessRefund` | `nonReentrant` | Pro-rata excess |
| VibesLaunchRouterV2 | `_handleFees` | Called within `nonReentrant` | Fee + excess refund |
| VibesLaunchRouterV2 | `_handleFeesAndDeposit` | Called within `nonReentrant` | Fee + deposit + excess |
| VibesLaunchRouterV2 | `finalizeSuccessfulCampaign` | `nonReentrant` | Deposit refund |
| VibesLaunchRouterV2 | `completeFinalization` | **No lock** (intentional) | Called by trusted escrow only |
| VibesLaunchRouterV2 | `refundDeposit` | `onlyOwner` | Manual deposit refund |
| VibesLaunchRouterV2 | `forfeitDeposit` | `onlyOwner` | Deposit forfeiture |
| VibesLaunchRouterV2 | `rescueETH` | `onlyOwner` | Emergency rescue |
| VibesLPLocker | `createAndLockLP` | `nonReentrant` | ETH excess refund |
| VibesTokenDistributorV2 | `claim` | `nonReentrant` | ETH refund |
| VibesTokenDistributorV2 | `batchDistribute` | `nonReentrant` | Batch ETH refunds — see S1 |
| VibesTokenDistributorV2 | `claimPendingEth` | `nonReentrant` | Pull-based ETH claim |
| VibesTokenDistributorV2 | `sweepUnclaimed` | `onlyAdmin` | Sweep to ops wallet |

**`centralization-risk` detector:** See Section 4 (Privileged Roles).

**`solc-version` detector:** Contracts use `^0.8.20` pragma, compiled with 0.8.24. Acceptable — benefits from built-in overflow/underflow protection.

---

## 3. Manual Review Findings

### H1. Admin-Controlled `_excludeAddresses` Can Manipulate Refund Calculations

**Severity:** High
**Contracts:** `VibesTranchEscrow.sol` lines 668, 749
**Functions:** `upholdChallenge()`, `freezeCampaign()`

**Description:**
When a campaign is frozen (via challenge upheld or direct admin freeze), the admin passes `_excludeAddresses` which is used to calculate `frozenTotalSupply` — the denominator in all holder refund calculations:

```solidity
frozenTotalSupply = _calculateRedeemableSupply(_excludeAddresses); // line 678, 757
```

Each holder's refund is: `ethRefund = (frozenEthBalance * _tokenAmount) / frozenTotalSupply`

A compromised admin could manipulate this by:
- **Including too many addresses** → lower `frozenTotalSupply` → each token redeems for more ETH → early claimants drain the pool
- **Including too few addresses** → higher `frozenTotalSupply` → each token redeems for less ETH → ETH remains trapped

**Mitigation (Recommended):**
- Admin key should be a multisig (3-of-5 minimum)
- Validate `_excludeAddresses` off-chain before submitting
- Consider computing `_excludeAddresses` onchain using a registry of known non-redeemable addresses
- `frozenTotalSupply` is immutable after the call (cannot be re-frozen), limiting the attack window

**Cross-reference:** BETA-TEST-REPORT H2

---

### H2. `rescueETH` Can Drain Founder Deposits and LP ETH in Transit

**Severity:** High
**Contract:** `VibesLaunchRouterV2.sol` line 1057
**Function:** `rescueETH()`

**Description:**
The owner-only `rescueETH` function can withdraw any ETH from the router contract, including:
1. Founder deposits tracked in `tokenDeposits` mapping
2. ETH forwarded by escrow during finalization (before LP creation)
3. Any ETH accumulated from fees

The code acknowledges this limitation (line 1062-1063 comment) but provides no guardrails:

```solidity
// Note: tokenDeposits are tracked per-token; a full accounting would require
// iterating all active tokens. For safety, limit rescue to excess ETH only.
require(amount <= totalBalance, "Insufficient balance"); // This check is always true
```

**Mitigation (Recommended):**
- Track total reserved ETH (sum of all `tokenDeposits`) and subtract from available rescue amount
- Or: add a `totalReservedETH` counter that increments/decrements with deposits

**Cross-reference:** BETA-TEST-REPORT H3

---

### H3. `finalize()` + `completeFinalization()` Atomicity Risk

**Severity:** High
**Contracts:** `VibesTranchEscrow.sol` line 344-386, `VibesLaunchRouterV2.sol` line 585-667
**Functions:** `finalize()`, `completeFinalization()`

**Description:**
During finalization, the escrow sends 20% of raised ETH to the router (line 370) and sets `lpWithdrawn = true` (line 368) before calling `completeFinalization()` on the router (line 380). If `completeFinalization()` reverts after the ETH transfer succeeds:

1. The escrow's state shows `lpWithdrawn = true` and `CampaignState.Funded`
2. The ETH sits in the router contract with no LP created
3. The `finalize()` function itself reverts (the entire transaction is atomic)

**However**, because this is all in one transaction, if `completeFinalization()` reverts, the entire `finalize()` call reverts — including the ETH transfer and the `lpWithdrawn` flag. So the atomicity is actually correct.

**Residual risk:** If the escrow's `finalize()` succeeds but the `completeFinalization()` call has an `lpLocker` that silently fails (accepts ETH but returns zero LP), the escrow would believe LP was created when it wasn't.

**Mitigation:** The `lpLocker.createAndLockLP()` has a `if (lpAmount == 0) revert LPCreationFailed()` check (LPLocker:150), which prevents silent LP creation failure.

**Cross-reference:** BETA-TEST-REPORT H6. **Status: Mitigated by transaction atomicity and explicit revert checks.**

---

### M1. One-Step Ownership Transfer in VibesRegistry

**Severity:** Medium
**Status: ✅ Fixed (2026-02-24)**
**Contract:** `VibesRegistry.sol`
**Function:** `transferOwnership()`

**Description:**
`VibesRegistry` previously used a one-step ownership transfer, unlike all other contracts which already used two-step patterns:
- Router: `pendingOwner` + `acceptOwnership`
- Factory: `pendingAdmin` + `acceptAdmin`
- LPLocker: `pendingOwner` + `acceptOwnership`
- Escrow: `pendingAdmin` + `acceptAdmin`
- Treasury: `pendingAdmin` + `acceptAdmin`
- StakerRewards: `pendingAdmin` + `acceptAdmin`

**Fix Applied:** `VibesRegistry.sol` now uses two-step ownership. See Section 5.1 for the implementation.

**Tests Updated:** `VibesRegistry.t.sol` — `test_transferOwnership()` replaced with:
- `test_transferOwnership_setsPendingOwner()` — verifies step 1 only sets `pendingOwner`
- `test_acceptOwnership_completesTransfer()` — verifies step 2 completes the transfer
- `test_acceptOwnership_revertsNotPending()` — verifies non-pending callers are rejected

---

### M2. `supportChallenge` Has No Access Control

**Severity:** Medium
**Status: ✅ Fixed (2026-02-24)**
**Contracts:** `VibesTranchEscrow.sol`, `VibesTreasuryEscrow.sol`
**Function:** `supportChallenge()`

**Description:**
Anyone could call `supportChallenge()` to emit `ChallengeSupported` events, even addresses holding zero project tokens, enabling event log pollution and misleading onchain challenge support signals.

**Fix Applied:** Both contracts now require the caller to hold at least 1 token. See Section 5.2 for the implementation.

**Tests Updated:**
- `VibesTreasuryEscrow.t.sol` — `test_supportChallenge()` now transfers 1 token to `stranger` before the call (previously assumed anyone could support; updated to reflect token-holder requirement)

---

### M3. Custom ERC20 Token May Cause Compatibility Issues

**Severity:** Medium
**Contract:** `VibesToken.sol`

**Description:**
`VibesToken` is a hand-rolled ERC20 implementation that does NOT inherit OpenZeppelin's ERC20. Key differences:
1. No `permit()` function (ERC-2612)
2. No `DOMAIN_SEPARATOR` (EIP-712)
3. No `increaseAllowance()` / `decreaseAllowance()`
4. No ERC-165 `supportsInterface()`
5. `name` and `symbol` are not `immutable` (storage strings, not immutable — but set only in constructor)

The `SafeERC20` library is used by other contracts to interact with `VibesToken`, which handles the return value correctly. However, `VibesToken.transfer()` always returns `true` (line 67-68) and reverts on failure (Solidity 0.8+ overflow checks on line 93), so SafeERC20 isn't strictly needed but provides defense-in-depth.

**Risk:** Third-party integrations expecting EIP-2612 or ERC-165 compliance may fail. LP pools on Aerodrome may not support `permit()` optimizations.

**Recommendation:** Document that `VibesToken` is a minimal ERC20 without permit support. Consider migrating to OpenZeppelin ERC20 for future versions.

---

### M4. Challenge Window Timing Inconsistency Between Escrow and Treasury

**Severity:** Medium
**Contracts:** `VibesTranchEscrow.sol`, `VibesTreasuryEscrow.sol`

**Description:**
In `VibesTranchEscrow`, the challenge window uses the time oracle:
```solidity
uint256 windowEnd = trancheRequestedAt[tranche] + CHALLENGE_WINDOW;
if (_currentTime() > windowEnd) revert ChallengeWindowClosed(); // line 629
```

In `VibesTreasuryEscrow`, the challenge window uses `block.timestamp` directly:
```solidity
uint256 windowEnd = currentProposal.timestamp + CHALLENGE_WINDOW;
if (block.timestamp > windowEnd) revert ChallengeWindowClosed(); // line 244
```

On testnet with `MockTimeOracle`, the escrow's challenge window can be manipulated via `advanceTime()`, but the treasury's cannot. On mainnet (where `timeOracle = address(0)`), both use `block.timestamp` and behave identically.

**Risk:** On testnet, challenge window behavior differs between the two contracts, which could cause confusion during testing.

**Recommendation:** Consider adding time oracle support to `VibesTreasuryEscrow` for consistency, or document this as a known testnet-only inconsistency.

---

### L1. Rounding Dust Trapped in Escrow After All Tranches Claimed

**Severity:** Low
**Contract:** `VibesTranchEscrow.sol`

**Description:**
Tranche amounts are calculated as:
```solidity
uint256 escrowAmount = (effectiveRaised * 8000) / BPS_DENOMINATOR; // 80%
// Kickstart: (escrowAmount * 1000) / 10000 = 10% of 80%
// Monthly: (escrowAmount * 1500) / 10000 = 15% of 80%
```

Total: 10% + (15% * 6) = 100% of `escrowAmount`. But integer division may leave 1-2 wei of dust after all 7 tranches are claimed. This dust is permanently locked in the escrow contract.

Additionally, the platform fee (2.5%) is deducted from each tranche, so the founder receives 97.5% of each tranche amount. The total BPS allocation is: 10% + (15% * 6) = 100%, but the actual ETH distribution is: (80% * 97.5%) + (80% * 2.5%) + 20% LP = ~100% minus rounding.

**Impact:** Negligible. Maximum dust per campaign is a few wei.

---

### L2. `expireChallengeIfNeeded` Is Permissionless With No Incentive

**Severity:** Low
**Contracts:** `VibesTranchEscrow.sol` line 710, `VibesTreasuryEscrow.sol` line 334

**Description:**
Both `expireChallengeIfNeeded()` functions are permissionless — anyone can call them. While this is intentional (allows anyone to unblock a stuck challenge), there is no gas refund or incentive for the caller. If no one calls this function, a challenge can remain in "Pending" state indefinitely after the 72-hour window.

**Note:** The founder is incentivized to call this (to unblock their tranche). Frontends should also call this automatically.

---

### L3. No Maximum Array Length Check on `_excludeAddresses`

**Severity:** Low
**Contract:** `VibesTranchEscrow.sol` lines 668, 749

**Description:**
The `_excludeAddresses` parameter in `upholdChallenge()` and `freezeCampaign()` has no maximum length. An admin could pass an extremely large array causing the transaction to run out of gas. This is only callable by the admin (trusted role) so the risk is low.

---

### L4. `batchDistribute` Silently Skips Invalid Proofs

**Severity:** Low
**Contract:** `VibesTokenDistributorV2.sol` line 245

**Description:**
In `batchDistribute()`, if a Merkle proof is invalid, the entry is silently skipped (`continue`) rather than reverting. While this is intentional (allows partial batch success), it means an incorrect proof array could cause legitimate recipients to be skipped without any error indication.

**Recommendation:** Emit an event when a proof is skipped for debugging purposes.

---

### L5. `receive()` Function in VibesTranchEscrow Allows Direct ETH Sends as Contributions

**Severity:** Low
**Contract:** `VibesTranchEscrow.sol` line 942

**Description:**
The `receive()` function routes direct ETH transfers through `_contribute()`:
```solidity
receive() external payable nonReentrant {
    _contribute(msg.sender, msg.value);
}
```

This means any direct ETH transfer (including accidental sends) is treated as a contribution. If someone accidentally sends ETH to an escrow after the campaign is funded, the transaction will revert due to `InvalidState` — but during the Active state, any ETH transfer becomes a contribution.

---

### I1. Testnet-Only `MockTimeOracle` Must Not Be Used in Production

**Severity:** Informational
**Contract:** `MockTimeOracle.sol`

The `MockTimeOracle` allows the admin to arbitrarily set, advance, or rewind time. If accidentally deployed on mainnet, the admin could bypass challenge windows, accelerate tranche unlocks, or manipulate vesting schedules.

**Verification:** Ensure `timeOracle = address(0)` in all mainnet deployment scripts.

---

### I2. `VibesToken` Name and Symbol Are Not Immutable

**Severity:** Informational
**Contract:** `VibesToken.sol` lines 22-23

`name` and `symbol` are `string public` (stored in storage) rather than `string public immutable`. While they can only be set in the constructor, using storage strings costs more gas for reads than immutable bytes32 alternatives.

---

### I3. `VibesIdentityRegistry` Uses Manual String Conversion

**Severity:** Informational
**Contract:** `VibesIdentityRegistry.sol` lines 176-204

The `_toString()` and `_toHexString()` helper functions duplicate functionality available in OpenZeppelin's `Strings` library, which is already a dependency.

---

### I4. Consistent Error Naming Convention Not Followed

**Severity:** Informational

Some contracts use custom errors (`error OnlyAdmin()`) while internal validation uses `require()` strings (`require(msg.sender == authorizedStarter, "Only authorized starter")`). This inconsistency exists within `VibesVesting.sol`, `VibesLPLocker.sol`, and `VibesRegistry.sol`. Custom errors are more gas-efficient.

---

### I5. `completeFinalization` Security Architecture Documentation

**Severity:** Informational
**Contract:** `VibesLaunchRouterV2.sol` line 585

The `completeFinalization()` function deliberately omits the `nonReentrant` modifier. The code comment explains this (line 582-583), but the reasoning should be expanded for auditors:

**Call chain:** `escrow.finalize()` [escrow nonReentrant] → `router.completeFinalization()` [no lock]
**Why no lock:** Adding `nonReentrant` would cause revert when called via `claimTokens()` → `escrow.finalize()` → `completeFinalization()`, because the router's lock is already held by `claimTokens()`.
**Security:** Protected by `msg.sender == escrowAddr` check (line 590), which ensures only the registered escrow can call this function.

**Cross-reference:** BETA-TEST-REPORT C5. **Status: The auto-finalize path works correctly because `completeFinalization` has no `nonReentrant` and the locks are on different contracts.**

---

### I6. `sweepUnclaimed` Correctly Protects Pending ETH Refunds

**Severity:** Informational
**Contract:** `VibesTokenDistributorV2.sol` line 306-328

The H8 finding from BETA-TEST-REPORT has been fixed. The `sweepUnclaimed()` function now correctly excludes `totalPendingEthRefunds` from the sweepable amount (line 314-316).

**Cross-reference:** BETA-TEST-REPORT H8. **Status: Fixed.**

---

## 4. Privileged Roles Summary

See `docs/privileged-roles.md` for the full privileged roles documentation.

---

## 5. Proposed Code Fixes

### 5.1 Two-Step Ownership for VibesRegistry (M1)

**File:** `contracts/src/VibesRegistry.sol`

```solidity
// Add state variable
address public pendingOwner;

// Replace transferOwnership
function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "Invalid owner");
    pendingOwner = newOwner;
}

// Add acceptOwnership
function acceptOwnership() external {
    require(msg.sender == pendingOwner, "Not pending owner");
    owner = pendingOwner;
    pendingOwner = address(0);
}
```

### 5.2 Token-Holder Check on `supportChallenge` (M2)

**File:** `contracts/src/VibesTranchEscrow.sol`

```solidity
function supportChallenge(string calldata _additionalContext) external inState(CampaignState.Funded) {
    if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();
    require(IERC20(campaign.token).balanceOf(msg.sender) > 0, "Not a token holder");
    emit ChallengeSupported(msg.sender, uint8(activeChallenge.tranche), _additionalContext);
}
```

**File:** `contracts/src/VibesTreasuryEscrow.sol`

```solidity
function supportChallenge(string calldata _context) external onlyActive {
    if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();
    require(token.balanceOf(msg.sender) > 0, "Not a token holder");
    emit ChallengeSupported(msg.sender, proposalCount, _context);
}
```

---

## 6. BETA-TEST-REPORT Cross-Reference

| Finding | Severity | Status | Notes |
|---------|----------|--------|-------|
| C5: claimTokens auto-finalize reentrancy | Critical | **Works correctly** | `completeFinalization` intentionally omits `nonReentrant`; different contract locks |
| H2: Admin `_excludeAddresses` manipulation | High | **Acknowledged (design trade-off)** | Document as centralization risk; recommend multisig |
| H3: `rescueETH` can drain deposits | High | **Acknowledged (design trade-off)** | Document; recommend tracking reserved ETH |
| H6: finalize + completeFinalization atomicity | High | **Mitigated** | Transaction atomicity ensures all-or-nothing; LP creation has explicit revert |
| H8: sweepUnclaimed takes pending refunds | High | **Fixed** | `totalPendingEthRefunds` now excluded from sweep |

---

## 7. Reentrancy Analysis — All External ETH Transfers

### Checks-Effects-Interactions Pattern Compliance

| Contract | Function | Pattern | Verdict |
|----------|----------|---------|---------|
| VibesTranchEscrow | `claimContributorRefund` | State updated (refundClaimed=true) BEFORE `.call{value:}` | Compliant |
| VibesTranchEscrow | `claimHolderRefund` | State updated (refundClaimedFromMerkle=true) + token burn BEFORE `.call{value:}` | Compliant |
| VibesTranchEscrow | `claimExcessRefund` | State updated (excessClaimed=true) BEFORE `.call{value:}` | Compliant |
| VibesTranchEscrow | `claimTranche` | State updated (trancheClaimed=true, nextTranche++) BEFORE `.call{value:}` | Compliant |
| VibesTranchEscrow | `finalize` | State updated (campaign.state=Funded, lpWithdrawn=true) BEFORE `.call{value:}` | Compliant |
| VibesLaunchRouterV2 | `completeFinalization` | State changes (delete pendingLP, startVesting, etc.) happen around ETH transfers | Mixed — deposit refund at end, but `nonReentrant` omitted (see I5) |
| VibesLaunchRouterV2 | `_handleFees` | Fee sent, then excess refunded | Protected by caller's `nonReentrant` |
| VibesLPLocker | `createAndLockLP` | LP tokens locked, position recorded BEFORE ETH refund | Compliant |
| VibesTokenDistributorV2 | `claim` | `hasClaimed` set BEFORE `.call{value:}` | Compliant |
| VibesTokenDistributorV2 | `batchDistribute` | `hasClaimed` set BEFORE each `.call{value:}` | Compliant |
| VibesTokenDistributorV2 | `claimPendingEth` | `pendingEthRefunds` zeroed BEFORE `.call{value:}` | Compliant |

**Conclusion:** All refund functions, challenge mechanisms, and ETH transfer paths follow the checks-effects-interactions pattern correctly. Combined with `nonReentrant` guards on all public ETH-transferring functions, the reentrancy risk is well-mitigated.

---

## 8. Recommendations for Professional Audit

1. **Run Aderyn** — Slither completed (see Section 2.2). Aderyn still pending Rust toolchain install:
   ```bash
   cargo install aderyn && cd contracts && aderyn .
   ```
2. **Address S1 (CEI in `batchDistribute`)** — Reorder state writes before `.call{}` to follow strict CEI even though `nonReentrant` mitigates direct exploit risk. This removes the finding from any future automated audit.
3. **Fuzz testing:** `AllocationFuzz.t.sol` covers token allocation math. Consider adding:
   - `claimHolderRefund` with varying `_tokenAmount` values
   - `claimExcessRefund` with edge-case `totalCommitted` / `goal` ratios
   - `batchDistribute` with malicious recipient contracts (test S1 scenario)
4. **Formal verification:** Consider Certora or Halmos for the tranche state machine (Active → Funded → Completed, with Paused/Frozen/Failed branches)
5. **Gas optimization:** The `via_ir = true` + `optimizer_runs = 50` settings suggest deployment size optimization over runtime gas. Verify this is intentional.
6. **Admin multisig:** Document the expected key management setup for all admin/owner addresses.

---

## 9. Audit Implementation Log

| Date | Change | Reason |
|------|--------|--------|
| 2026-02-24 | `VibesRegistry.sol` — two-step ownership | M1 fix |
| 2026-02-24 | `VibesTranchEscrow.sol` — token-holder check in `supportChallenge` | M2 fix |
| 2026-02-24 | `VibesTreasuryEscrow.sol` — token-holder check in `supportChallenge` | M2 fix |
| 2026-02-24 | NatSpec added to all 14 contracts | Documentation |
| 2026-02-24 | `VibesRouterExtension.sol` — two-step ownership (pre-existing L6 fix) | Already in codebase |
| 2026-02-24 | `VibesTranchEscrowFactory.sol` — two-step admin (pre-existing L7 fix) | Already in codebase |
| 2026-02-24 | Slither installed and run — new findings S1, S2 documented | Tooling |
| 2026-02-24 | All 18 Foundry test suites (435 tests) passing | Test fixes for audit changes |
| 2026-02-24 | `VibesLPLocker.sol` — try/catch on `addLiquidityETH`, rescue funds fallback | External audit: MEV front-running DoS (High) |
| 2026-02-24 | `VibesTranchEscrow.sol` — onchain redeemable supply (removed admin `_excludeAddresses`) | External audit: Admin refund drain centralization risk (High) |
| 2026-02-24 | `VibesTranchEscrow.sol` — platform fee pull pattern (`pendingPlatformFees` + `claimPlatformFees`) | External audit: Platform fee push DoS (Medium) |

## 10. External Audit Findings (Feb 2026)

Findings from external security review of contract bundle. Three fixes implemented:

### EA-1: MEV Front-Running LP Brick (High → Fixed)
**Contract:** `VibesLPLocker.sol`
**Issue:** Hardcoded 1% slippage on `addLiquidityETH` with no fallback. An MEV bot could pre-create the Aerodrome pool with a skewed ratio, causing the 99% min bounds to revert and permanently bricking campaign finalization.
**Fix:** Wrapped `addLiquidityETH` in `try/catch`. On failure, funds are stored in `rescuedFunds[campaign]` instead of reverting. Admin can resolve via `resolveRescuedFunds()`. The `finalize()` flow completes regardless.
**New state:** `rescuedFunds`, `hasRescuedFunds` mappings. `RescueFunds` struct. `resolveRescuedFunds()` admin function.
**Tests:** 4 new tests in `VibesLPLocker.t.sol` covering rescue, resolution, double-resolution revert, and owner-only access.

### EA-2: Admin Refund Drain Centralization Risk (High → Fixed)
**Contract:** `VibesTranchEscrow.sol`
**Issue:** `upholdChallenge()` and `freezeCampaign()` accepted an admin-supplied `_excludeAddresses` array to calculate redeemable supply. A compromised admin could manipulate this to drain refund ETH.
**Fix:** `_calculateRedeemableSupply()` now reads locked balances from known contract addresses onchain (dead address, vesting, staker rewards, router, LP locker, escrow itself). Admin input removed from function signatures. New `setLockedAddresses()` admin function sets vesting and staker rewards addresses.
**Breaking change:** `upholdChallenge()` no longer takes parameters. `freezeCampaign()` takes only `_reason` (removed `_excludeAddresses`).
**Tests:** 3 new tests covering `setLockedAddresses`, admin-only access, and frozen supply exclusion verification.

### EA-3: Platform Fee Push DoS (Medium → Fixed)
**Contract:** `VibesTranchEscrow.sol`
**Issue:** `claimTranche()` pushed the 2.5% platform fee to `platformWallet` via `.call{value: fee}`. If `platformWallet` reverted (e.g., broken multisig), the founder was blocked from claiming.
**Fix:** Converted to pull pattern. Fees accumulate in `pendingPlatformFees`. Founder's `claimTranche()` always succeeds. Separate `claimPlatformFees()` function for fee withdrawal.
**New state:** `pendingPlatformFees` uint256. `claimPlatformFees()` public function.
**Tests:** 2 new tests for pull claim and zero-fee revert. Existing tranche tests updated to check accrued fees instead of platform wallet balance.

### EA-4 through EA-6: UX Edge Cases (Informational — Not Fixed)
- **EA-4:** Staking cooldown reset on additional stake — intentional design, frontend warning recommended.
- **EA-5:** `batchDistribute` token transfer failure — ETH already uses pull pattern; token side is low-risk (standard ERC20 `safeTransfer`).
- **EA-6:** `claimMultiple` invalid proof revert — intentional fail-fast on data errors; frontend validation preferred.
