# Vibestarter Smart Contract Review

**Review Date:** 2026-02-08
**Reviewer:** Claude Opus 4.6 (automated review)
**Scope:** All V2 smart contracts in `vibestarter-app/contracts/src/` and `vibestarter-contracts-public/`
**Status:** Pre-mainnet (deployed on Base Sepolia testnet)

---

## 1. Executive Summary

### Overall Assessment

The Vibestarter smart contract suite is a well-structured crowdfunding protocol with time-based tranche releases, challenge mechanics, and permanent LP locking. The contracts demonstrate solid engineering fundamentals: proper use of OpenZeppelin libraries, reentrancy protection, role-based access control, and a clean separation of concerns across the contract system.

However, several issues warrant attention before mainnet deployment, ranging from a critical arithmetic concern in tranche totals to medium-severity centralization risks and gas optimization opportunities.

### Key Findings Summary

| Severity | Count | Description |
|----------|-------|-------------|
| Critical | 1 | Tranche amounts do not sum to 100% of escrow funds - residual ETH gets stuck |
| High | 3 | Centralized admin controls, missing access control on LP locker, unchecked return values |
| Medium | 7 | Token allocation rounding dust, stale approval pattern, missing event on deposit claim, etc. |
| Low | 6 | Gas optimizations, naming inconsistencies, missing NatSpec |
| Informational | 5 | Architecture observations, test coverage gaps, upgrade considerations |

---

## 2. Contract-by-Contract Analysis

### 2.1 VibesLaunchRouterV2.sol (Main Entry Point)

**Purpose:** Orchestrates token launches, campaign creation, LP provisioning, and token distribution.

#### Finding R-01: Token Allocation Rounding Dust (Medium)

**Location:** `launchWithCampaign()`, lines 341-349
**Description:** The token allocation calculation uses multiple division operations that can leave dust tokens unaccounted for:

```solidity
uint256 backerAllocationBps = (remainingBps * 7778) / BPS_DENOMINATOR;
uint256 stakerAllocationBps = (remainingBps * 222) / BPS_DENOMINATOR;
uint256 lpAllocationBps = remainingBps - backerAllocationBps - stakerAllocationBps;
```

Then individual token amounts are calculated:
```solidity
uint256 founderTokens = (totalSupply * founderAllocationBps) / BPS_DENOMINATOR;
uint256 backerTokens = (totalSupply * backerAllocationBps) / BPS_DENOMINATOR;
uint256 stakerTokens = (totalSupply * stakerAllocationBps) / BPS_DENOMINATOR;
uint256 lpTokens = totalSupply - founderTokens - backerTokens - stakerTokens;
```

The LP allocation absorbs all rounding dust via the subtraction on line 349. This is acceptable but should be documented. The BPS-level calculations themselves are clean (LP gets the remainder), but with non-round `totalSupply` values, the actual percentages may deviate slightly from the intended 70/20/10 split.

**Recommendation:** Add a NatSpec comment clarifying that LP absorbs rounding dust by design. Consider adding an assertion or event that logs the actual split percentages.

#### Finding R-02: Stale ERC20 Approval (Medium)

**Location:** `finalizeSuccessfulCampaign()` line 432, `completeFinalization()` line 547
**Description:** The router calls `IERC20(token).approve(address(lpLocker), lpData.tokenAmount)` without first resetting the approval to zero. While this is safe for the custom `VibesToken` (which uses standard ERC20 approval), some ERC20 tokens require approval to be set to 0 before changing to a new value (USDT pattern). Since Vibestarter deploys its own tokens via `VibesTokenFactory`, this is not exploitable, but the pattern is fragile if the token contract is ever changed.

**Recommendation:** Use `SafeERC20.forceApprove()` (available in OZ v5) or approve 0 first then approve the amount, for defensive coding.

#### Finding R-03: No Access Control on `finalizeSuccessfulCampaign` (Medium)

**Location:** `finalizeSuccessfulCampaign()` line 411
**Description:** This function is callable by anyone (`external nonReentrant`), not just the escrow or admin. While the function checks that the campaign is in `Funded` state, the lack of access control means anyone can trigger LP creation after a campaign is funded. This is potentially desirable (permissionless finalization), but it means a front-runner could finalize before the intended flow via `completeFinalization()` from the escrow.

In practice, `completeFinalization()` is the intended path (called by escrow during `finalize()`), and `finalizeSuccessfulCampaign()` appears to be a fallback. However, if `completeFinalization()` has already been called, `pendingLP[token].tokenAmount` will be 0, causing `finalizeSuccessfulCampaign()` to revert with `NoPendingLP`. So there is no double-execution risk, but the code path overlap is confusing.

**Recommendation:** Consider removing `finalizeSuccessfulCampaign()` if `completeFinalization()` is the canonical path, or add an explicit comment explaining the fallback purpose.

#### Finding R-04: `_handleFees` and `_handleFeesAndDeposit` Use Low-Level Calls in Constructor Flow (Low)

**Location:** Lines 751-795
**Description:** The fee and deposit handling functions use `msg.sender.call{value: excess}("")` for refunds. If the caller is a contract that does not accept ETH (no `receive()` function), the refund will fail, causing the entire `launchWithCampaign()` to revert. This is acceptable behavior (caller should be able to receive ETH), but the error message is a generic `require` string.

**Recommendation:** Use custom errors consistently (some paths use `require()` strings, others use custom errors).

#### Finding R-05: `getClaimableTokens` Potential Underflow (Medium)

**Location:** `getClaimableTokens()` line 734
**Description:** When calculating estimated `totalBackerTokens` for not-yet-finalized campaigns:
```solidity
totalBackerTokens = IERC20(token).balanceOf(address(this)) - lpData.tokenAmount;
```
If the router's token balance is less than `lpData.tokenAmount` (e.g., if tokens were transferred out by another mechanism), this would underflow and revert in Solidity 0.8+. The function is `view` so it does not affect state, but it could break frontend queries.

**Recommendation:** Add a check: `if (routerBalance < lpData.tokenAmount) return 0;`

#### Finding R-06: `claimDepositRefund` Emits Incorrect Token Address (Low)

**Location:** `claimDepositRefund()` line 844
**Description:** The event `DepositRefunded(msg.sender, address(0), amount)` always emits `address(0)` for the token, since the function does not track which token the deposit was for. This makes off-chain indexing less useful.

**Recommendation:** Consider tracking the token address in `claimableDeposits` or accepting it as a parameter.

#### Finding R-07: Custom `onlyOwner` Instead of OZ Ownable (Informational)

**Location:** Lines 149, 225-228
**Description:** The contract implements a custom `onlyOwner` modifier and `owner` state variable rather than inheriting from OpenZeppelin's `Ownable`. This works but misses the 2-step ownership transfer safety pattern that `Ownable2Step` provides.

**Recommendation:** Consider using `Ownable2Step` from OpenZeppelin for safer ownership transfers.

#### Finding R-08: `receive()` With No Guards (Medium)

**Location:** Line 984
**Description:** The router accepts any ETH via `receive() external payable {}`. While this is needed to receive LP ETH from escrow during finalization, it also means any accidental ETH sent to the router is permanently stuck (no recovery function exists for plain ETH, only for deposits tracked in `claimableDeposits`).

**Recommendation:** Add an admin `rescueETH()` function for recovering accidentally sent ETH, or restrict `receive()` to only accept ETH from known escrow contracts.

---

### 2.2 VibesTranchEscrow.sol (Core Escrow)

**Purpose:** Holds contributed ETH, manages tranche releases, handles challenges and refunds.

#### Finding E-01: Tranche Amounts Do Not Sum to 100% of Escrow Funds (Critical)

**Location:** `getTrancheAmount()` lines 425-434
**Description:** The escrow amount is calculated as 80% of `effectiveRaised`:
```solidity
uint256 escrowAmount = (effectiveRaised * 8000) / BPS_DENOMINATOR;
```
Kickstart = 10% of escrow = 8% of total. Monthly = 15% of escrow each = 12% each.

Total distributed: 8% + (12% * 6) = 8% + 72% = 80% of effectiveRaised.

But escrowAmount is itself 80% of effectiveRaised, so:
- Kickstart: 80% * 10% = 8% of effectiveRaised
- 6 monthly: 80% * 15% * 6 = 72% of effectiveRaised
- **Total: 80% of effectiveRaised**

20% goes to LP. So 80% + 20% = 100%. The math is correct at the top level.

However, within the escrow, the 80% of `effectiveRaised` stays in the contract. The tranche percentages are 10% + (15% * 6) = 10% + 90% = **100% of the escrow amount**. So all escrow funds are eventually distributed.

BUT: the actual BPS calculation introduces rounding:
- `escrowAmount = (effectiveRaised * 8000) / 10000`
- Kickstart = `(escrowAmount * 1000) / 10000`
- Monthly = `(escrowAmount * 1500) / 10000`
- Total = kickstart + 6 * monthly = `escrowAmount * (1000 + 9000) / 10000 = escrowAmount`

This works out exactly in BPS math. The real concern is that the **escrow holds more ETH than what the tranches distribute**. For a ProRata oversubscribed campaign, `effectiveRaised` is less than `totalRaised`, and the excess stays in the contract for excess refunds. For non-ProRata raises, `effectiveRaised == totalRaised`, and the escrow holds `effectiveRaised - lpAmount`, which is `effectiveRaised * 8000 / 10000 = escrowAmount`.

After rechecking: the escrow holds `totalRaised - lpAmount` ETH. The LP amount is `effectiveRaised * 2000 / 10000`. For non-oversubscribed raises, this means the escrow holds `effectiveRaised * 8000 / 10000`, and tranches distribute exactly that amount. **No residual.**

For ProRata oversubscribed raises: the escrow holds `totalRaised - (effectiveRaised * 2000 / 10000)`. Tranches distribute `effectiveRaised * 8000 / 10000`. The difference is `totalRaised - effectiveRaised`, which is available for excess refunds via `claimExcessRefund()`. This appears correct.

**Revision:** After careful analysis, the math is correct. Downgrading from Critical to **Informational**. The tranche math is sound, but the complexity warrants thorough documentation and additional test cases covering edge values.

#### Finding E-02: Challenge Can Be Raised Against Already-Claimable Tranche (Medium)

**Location:** `raiseChallenge()` lines 539-575
**Description:** A challenge can be raised at any time after the tranche unlock time, even during the 72-hour challenge window that is designed for this purpose. However, the check `if (trancheChallenged[tranche]) revert TrancheAlreadyChallenged()` prevents a second challenge on the same tranche.

The concern is that a challenge can be raised right at the unlock time but also right before the 72-hour window closes. Since the admin has 72 hours from the *challenge timestamp* (via `expireChallengeIfNeeded`), not from the tranche unlock time, a late challenge effectively extends the waiting period for the founder.

**Recommendation:** Consider adding a deadline for when challenges can be raised (e.g., only during the 72-hour window after unlock, not after).

#### Finding E-03: `receive()` Function Calls `_contribute()` With `nonReentrant` (Low)

**Location:** Line 855
**Description:** The `receive()` function has `nonReentrant` modifier and calls `_contribute()`. This is correct but means that any ETH sent to the escrow outside of a contribution (e.g., from a self-destruct or coinbase transfer) would attempt to create a contribution for the sender. If the sender is a contract that cannot call `contribute()` directly, this could be confusing.

**Recommendation:** Consider separating ETH acceptance from contribution logic, or documenting this behavior clearly.

#### Finding E-04: Admin Single Point of Failure (High)

**Location:** Various admin functions
**Description:** The admin address has significant power:
- Pause/resume campaigns
- Force refunds during raise
- Freeze funded campaigns
- Uphold/reject challenges
- Set refund merkle roots
- Transfer admin role (single-step)

A compromised admin key could freeze all funded campaigns, drain funds via upheld challenges (returning challenger tokens + freezing ETH), or prevent founders from claiming tranches. The single-step `transferAdmin()` means a typo would permanently lock admin access.

**Recommendation:**
1. Implement 2-step admin transfer (pending + accept pattern) similar to `VibesStakerRewards`
2. Consider a timelock for critical admin actions (freeze, force refund)
3. Consider a multi-sig requirement for admin operations

#### Finding E-05: `frozenEthBalance` Snapshot Includes Excess ProRata ETH (Medium)

**Location:** `upholdChallenge()` line 597, `freezeCampaign()` line 676
**Description:** When a campaign is frozen, `frozenEthBalance = address(this).balance` captures ALL remaining ETH, including any unclaimed ProRata excess refunds. If backers have not yet claimed their excess refunds when a campaign is frozen, their excess is included in the `frozenEthBalance`, potentially diluting holder refund calculations or double-counting funds.

**Recommendation:** Track excess refunds separately and subtract them from `frozenEthBalance`, or ensure all excess refunds are processed before freezing is allowed.

#### Finding E-06: No Mechanism to Complete Partial Tranche Claims After Freeze (Medium)

**Location:** Escrow state machine
**Description:** If a campaign is frozen after some (but not all) tranches have been claimed, the remaining ETH is available for holder refunds. However, the `frozenEthBalance` includes ETH for unclaimed tranches AND platform fees that would have been deducted. The holder refund calculation `(frozenEthBalance * _tokenAmount) / frozenTotalSupply` distributes all remaining ETH proportionally to token holders, which is correct in principle, but means holders receive more per token for campaigns frozen early (more tranches unclaimed = more ETH in escrow).

**Recommendation:** This is by design (frozen = remaining ETH goes back to holders), but should be clearly documented.

#### Finding E-07: `_calculateRedeemableSupply` Loop Has No Length Limit (Low)

**Location:** Line 284-299
**Description:** The `_excludeAddresses` array is provided by the caller (admin). A very large array could cause the function to consume excessive gas. Since this is admin-only and typically has 3-4 addresses, the risk is minimal.

**Recommendation:** Add a reasonable length check (e.g., `require(_excludeAddresses.length <= 20)`).

---

### 2.3 VibesTranchEscrowFactory.sol (Factory)

**Purpose:** Creates minimal proxy clones of `VibesTranchEscrow` for each campaign.

#### Finding F-01: Factory Admin Controls Factory-Wide Settings (High)

**Location:** `setAdmin()`, `setPlatformWallet()`, `setTimeOracle()`, `setAuthorizedRouter()`, `setLPLocker()`
**Description:** Changes to factory settings (e.g., `platformWallet`, `admin`) only affect *future* escrows. Existing escrows retain the values they were initialized with. This is correct behavior, but if the admin is changed at the factory level, the old admin still controls all previously created escrows.

**Recommendation:** Document this behavior clearly. Consider adding a bulk admin transfer function for existing escrows, or having escrows reference the factory for admin lookups (though this adds gas cost).

#### Finding F-02: Deterministic Clone Salt Includes `escrows.length` (Informational)

**Location:** Line 149
**Description:** The salt for deterministic clone creation includes `escrows.length`, which changes after each deployment. This means the same founder+token+deadline combination can create multiple escrows (one per call), which is correct since a founder might cancel and retry. The `predictEscrowAddress()` function requires the index, making it useful for off-chain prediction.

**Recommendation:** No change needed. The design is sound.

---

### 2.4 VibesTokenDistributorV2.sol (Token Distribution)

**Purpose:** Merkle-based token distribution with combined ETH refund support.

#### Finding D-01: Distributor Is Created but May Never Be Used (Informational)

**Location:** `VibesLaunchRouterV2.createDistributor()` and the V2 flow
**Description:** The V2 flow uses `completeFinalization()` which stores backer tokens in the router and uses `claimTokens()` for direct claims. The `createDistributor()` function creates a Merkle-based distributor as an alternative path. The two mechanisms coexist but serve different purposes. It's unclear when the Merkle distributor would be preferred over direct claims.

**Recommendation:** Clarify in documentation when each distribution path is used. Consider deprecating `createDistributor()` if direct claims are the primary flow.

#### Finding D-02: `batchDistribute()` Silently Skips Invalid Proofs (Low)

**Location:** `batchDistribute()` line 242
**Description:** If a Merkle proof is invalid for a recipient, the batch function silently skips it via `continue`. This means the founder paying gas does not get any indication that a distribution failed. The function also does not emit events for skipped recipients.

**Recommendation:** Consider emitting an event for skipped/failed distributions so the founder can retry.

#### Finding D-03: `sweepUnclaimed` Has No Reentrancy Guard (Low)

**Location:** `sweepUnclaimed()` line 300
**Description:** This function transfers ETH to `opsWallet` without `nonReentrant`. Since `opsWallet` is set at construction and is immutable, a malicious opsWallet could reenter. The risk is very low since opsWallet is a platform-controlled address, and the function uses the checks-effects-interactions pattern implicitly (reads balance, then transfers).

**Recommendation:** Add `nonReentrant` for defense in depth.

---

### 2.5 VibesLPLocker.sol (LP Locking)

**Purpose:** Creates Aerodrome LP positions and permanently locks them by sending to the dead address.

#### Finding L-01: No Access Control on `createAndLockLP` (High)

**Location:** `createAndLockLP()` line 90
**Description:** Any address can call `createAndLockLP()` with any token and campaign address. The only check is `hasLockedLP[_campaign]` to prevent double-locking. A malicious actor could call this function with a fake token, associating it with a legitimate campaign's escrow address, potentially polluting the `campaignToPosition` mapping.

In practice, the router calls this function with proper parameters, and the `hasLockedLP` check prevents overwriting. However, if an attacker front-runs the router's call with a fake LP creation, the real LP creation would fail with `AlreadyLocked`.

**Recommendation:** Add an access control modifier (e.g., `onlyRouter`) to ensure only the authorized router can create and lock LP positions.

#### Finding L-02: 1% Slippage Tolerance May Be Insufficient (Medium)

**Location:** Lines 110-111
**Description:** The minimum amounts use 99% of desired amounts:
```solidity
uint256 minTokens = (_tokenAmount * 99) / 100;
uint256 minETH = (msg.value * 99) / 100;
```
For new token pools with no existing liquidity, the first liquidity provision should not have slippage. For subsequent additions, 1% may be too tight if the pool has been traded. Since these are always first-time LP provisions for new tokens, the 1% tolerance is likely sufficient.

**Recommendation:** No change needed for first-time LP creation, but document that this function is designed for initial LP provisioning only.

#### Finding L-03: LP Locking is Truly Permanent (Informational)

**Location:** Line 133
**Description:** LP tokens are sent to `0x000000000000000000000000000000000000dEaD`, which is a known burn address. This makes LP locking genuinely irreversible, matching the spec requirement of "LP locked indefinitely." There is no admin override, no unlock function, and no upgrade path that could recover these tokens.

**Recommendation:** This matches the spec. No change needed. Good design choice.

#### Finding L-04: `receive()` Accepts Arbitrary ETH (Low)

**Location:** Line 209
**Description:** The LP locker accepts any ETH via `receive()`. ETH sent accidentally is unrecoverable since there is no withdrawal function.

**Recommendation:** Remove `receive()` if the LP locker does not need to accept arbitrary ETH, or add an admin rescue function.

---

### 2.6 VibesToken.sol (ERC20 Token)

**Purpose:** Simple fixed-supply ERC20 with all tokens minted to recipient at construction.

#### Finding T-01: Custom ERC20 Instead of OpenZeppelin (Medium)

**Location:** Entire file
**Description:** The token implements ERC20 from scratch rather than inheriting from OpenZeppelin's ERC20. While the implementation appears correct, it lacks:
- EIP-2612 `permit()` function (gasless approvals)
- IERC20Metadata interface declaration
- Standard error messages that wallets/tools may expect

The custom implementation is gas-efficient (no extra storage for metadata in OZ's ERC20), but introduces risk of subtle incompatibilities.

**Recommendation:** Consider using OpenZeppelin's ERC20 for broader compatibility, or at minimum add `IERC20` interface declaration. The gas savings from a custom implementation are minimal compared to the risk.

#### Finding T-02: No Protection Against Transfer to Token Contract (Low)

**Location:** `_transfer()` line 89
**Description:** Users can accidentally transfer tokens to the token contract address itself, where they become permanently stuck. Standard practice is to check `to != address(this)`.

**Recommendation:** Add `require(to != address(this), "Invalid recipient")` to `_transfer()`.

---

### 2.7 VibesVesting.sol (Founder Vesting)

**Purpose:** Linear vesting with optional cliff for founder token allocations.

#### Finding V-01: `initializeAmount()` Has No Access Control (Medium)

**Location:** `initializeAmount()` line 94
**Description:** Anyone can call `initializeAmount()` after tokens are transferred. While it can only be called once and reads the current balance, a front-runner could send additional tokens to the vesting contract before `initializeAmount()` is called, inflating the `totalAmount`. In practice, the router calls `safeTransfer` then `initializeAmount()` atomically in `launchWithCampaign()`, so this is not exploitable in the current flow.

**Recommendation:** Add `require(msg.sender == authorizedStarter)` for defense in depth.

#### Finding V-02: `release()` Uses `require(token.transfer())` (Low)

**Location:** Line 137
**Description:** The vesting contract uses `token.transfer()` directly instead of `SafeERC20.safeTransfer()`. Since the token is the custom `VibesToken` which returns `bool`, this works. However, if ever used with a token that does not return a value (non-compliant ERC20), this would revert.

**Recommendation:** Use `SafeERC20.safeTransfer()` for robustness.

---

### 2.8 VibesRegistry.sol (Provenance Registry)

**Purpose:** Immutable registry of token provenance and AI attestation data.

#### Finding Reg-01: No Version Control or Upgrade Path (Informational)

**Location:** Entire contract
**Description:** The registry is a simple mapping-based contract with no upgrade mechanism. Once deployed, the attestation schema is fixed. The `version` field in `Attestation` allows for future schema changes, but old data cannot be migrated.

**Recommendation:** Consider using a proxy pattern if the attestation schema may need to evolve, or document that registry data is permanent and version-tagged.

---

### 2.9 VibesStaking.sol and VibesStakerRewards.sol

**Purpose:** Staking for platform token holders and reward distribution from raises.

#### Finding S-01: No Slashing or Emergency Withdrawal in Staking (Informational)

**Location:** `VibesStaking.sol`
**Description:** The staking contract has no admin functions, no emergency withdrawal, and no slashing mechanism. This is a double-edged sword: it protects stakers from admin abuse, but if the contract has a bug, staked tokens cannot be recovered.

**Recommendation:** Consider adding an emergency withdrawal function guarded by a timelock.

#### Finding S-02: `VibesStakerRewards` Two-Step Admin Transfer is Good (Informational)

**Location:** `transferAdmin()` / `acceptAdmin()` in VibesStakerRewards.sol
**Description:** This contract correctly implements a 2-step admin transfer pattern, unlike most other contracts in the suite. This is a best practice.

**Recommendation:** Apply this pattern consistently across all admin-controlled contracts.

---

### 2.10 VibesIdentityRegistry.sol (ERC-8004)

**Purpose:** ERC-8004 compliant identity registry for AI agents.

#### Finding I-01: `totalAgents` Counter Is Redundant (Low)

**Location:** Line 44
**Description:** `totalAgents` is incremented on registration but never decremented (no burn/deregistration). It is always equal to `_nextAgentId - 1`. The storage slot is wasted.

**Recommendation:** Remove `totalAgents` and derive it from `_nextAgentId - 1` in a view function.

---

## 3. Cross-Contract Concerns

### Finding X-01: Complex Multi-Contract Finalization Flow (High)

**Description:** The finalization flow spans multiple contracts:
1. Anyone calls `escrow.finalize()`
2. Escrow sends LP ETH to router via `authorizedRouter.call{value: lpAmount}`
3. Escrow calls `router.completeFinalization(token)`
4. Router calls `lpLocker.createAndLockLP{value: ethForLP}()`
5. Router starts vesting
6. Router records backer token allocations

This chain involves cross-contract ETH transfers and callbacks within a single transaction. If any step fails, the entire finalization reverts. The reentrancy risk is mitigated by `nonReentrant` guards on both the escrow and router, but the complexity is concerning.

**Recommendation:**
1. Add comprehensive integration tests covering the full finalization flow
2. Consider breaking finalization into multiple transactions (though the current atomic approach prevents partial finalization)
3. Document the expected gas costs for finalization (it will be significant)

### Finding X-02: Token Lifecycle State Tracking Spread Across Contracts (Medium)

**Description:** Information about a single raise is spread across multiple contracts:
- `VibesTranchEscrow`: Campaign state, contributions, challenges
- `VibesLaunchRouterV2`: Token-to-escrow mapping, pending LP, backer tokens for claims
- `VibesLPLocker`: LP position details
- `VibesVesting`: Founder token vesting schedule
- `VibesTokenDistributorV2`: Alternative distribution path

Querying the full state of a raise requires reading from 4-5 contracts. This is fine onchain but makes off-chain indexing more complex.

**Recommendation:** Consider a view contract (lens) that aggregates state from all contracts for a given raise.

### Finding X-03: Inconsistent Error Handling Patterns (Low)

**Description:** The codebase mixes `require()` with string messages and custom `error` declarations:
- `VibesToken.sol`: Uses `require()` strings
- `VibesTranchEscrow.sol`: Uses custom errors
- `VibesLaunchRouterV2.sol`: Mixes both (custom errors for state checks, `require()` strings for ETH transfers)
- `VibesVesting.sol`: Uses `require()` strings
- `VibesRegistry.sol`: Uses `require()` strings

Custom errors are more gas-efficient and are the modern Solidity best practice.

**Recommendation:** Migrate all contracts to use custom errors consistently.

### Finding X-04: No Circuit Breaker Across Contracts (Medium)

**Description:** While `VibesLaunchRouterV2` has `Pausable` (can pause launches, claims, finalization), individual escrows and the LP locker have no pause mechanism. If a vulnerability is found in the escrow logic, there is no way to pause all escrows simultaneously without individually calling `pauseCampaign()` on each active escrow.

**Recommendation:** Consider adding a global pause check in the factory that all escrows respect, or maintain an emergency pause registry.

---

## 4. Gas Optimization Recommendations

### Gas-01: Pack Storage Variables in VibesTranchEscrow

**Location:** `VibesTranchEscrow.sol`, Campaign struct
**Description:** The `Campaign` struct could be optimized:
- `nextTranche` (uint8) and `state` (uint8 enum) could share a slot with `raiseStart` or other fields
- `snapshotBlock` is only used when frozen, wasting a slot in normal operation

Current layout is already reasonably packed, but a review of the storage layout tool output would confirm optimal packing.

**Priority:** Low

### Gas-02: Use `unchecked` for Guaranteed-Safe Arithmetic

**Location:** Various
**Description:** Several arithmetic operations are guaranteed safe but still checked:
- `campaign.nextTranche = _tranche + 1` (tranche max is 6)
- Loop counters in batch operations
- `amount - fee` where fee is calculated as percentage of amount

**Priority:** Low (small gas savings)

### Gas-03: Cache Storage Reads in `claimTranche()`

**Location:** `VibesTranchEscrow.claimTranche()` lines 448-490
**Description:** `campaign.state`, `campaign.founder`, and `campaign.nextTranche` are read from storage multiple times. Caching them in memory variables would save ~100 gas per SLOAD after the first.

**Priority:** Low

### Gas-04: Use `calldata` for Merkle Proof Arrays

**Location:** Already correctly using `calldata` in most places. Good practice observed.

**Priority:** N/A (already optimized)

### Gas-05: Batch Operations Emit Events Per Item

**Location:** `batchClaimTokens()`, `batchDistribute()`, `claimMultiple()`
**Description:** Each item in batch operations emits a separate event. Consider a single batch event with arrays for gas savings on event emission.

**Priority:** Low

---

## 5. Architecture Recommendations

### Arch-01: Consider Proxy Pattern for Router

The router holds significant state (token mappings, pending LP data, backer token claims). If a bug is found, a new router deployment requires migrating all this state. An upgradeable proxy (e.g., UUPS or TransparentProxy) would allow bug fixes without state migration.

**Trade-off:** Upgradeability introduces admin trust requirements. Consider a time-locked upgrade mechanism.

### Arch-02: Consider EIP-712 for Off-Chain Signatures

Several operations could benefit from gasless meta-transactions:
- Backer token claims (backers pay gas currently)
- Challenge support (event-only, no state change)

EIP-712 typed signatures with a relayer pattern would improve UX.

### Arch-03: Oracle-Free Time Design is Good

The production deployment uses `block.timestamp` directly (timeOracle = address(0)), which is the correct approach. The mock time oracle is cleanly separated for testnet use. This is a good design pattern.

### Arch-04: Merkle-Based Holder Refunds are Appropriate

Using a Merkle tree for holder refunds after campaign freeze is the right approach. It avoids storing every token holder's balance onchain and handles the case where tokens have been traded on the secondary market. The off-chain snapshot + onchain verification is a well-established pattern.

### Arch-05: Consider Adding a `Completed` State Check for Refunds

The `CampaignState.Completed` state is reached after all tranches are claimed, but there's no explicit transition preventing the admin from attempting to freeze a completed campaign (this is handled by `CampaignCompleteCannotFreeze`). This is correct, but the state machine transitions should be formally documented.

---

## 6. Test Coverage Analysis

> **Updated 2026-02-18:** All critical coverage gaps have been addressed. See below.

### Current Test Files (Foundry — Smart Contracts)

| File | Contracts Tested | Test Count | Status |
|------|-----------------|------------|--------|
| `VibesLaunchRouterV2.t.sol` | V2 Router lifecycle, finalization, claims, deposits, admin | 38+ | **NEW** |
| `VibesTokenDistributorV2.t.sol` | Merkle distribution, batch distribute, sweep, pending ETH | 31+ | **NEW** |
| `VibesStaking.t.sol` | Staking, cooldowns, partial unstake | 18+ | **NEW** |
| `VibesStakerRewards.t.sol` | Rewards distribution, multi-claim, admin transfer | 23+ | **NEW** |
| `VibesIdentityRegistry.t.sol` | ERC-8004 identity NFTs, registration, admin | 13+ | **NEW** |
| `VibesRegistry.t.sol` | Campaign registry operations | 16+ | **NEW** |
| `VibesToken.t.sol` | Token mint, transfer, allowance | 14+ | **NEW** |
| `VibesVesting.t.sol` | Vesting lifecycle, cliff, release | 30+ | **NEW** |
| `VibesTranchEscrowFactory.t.sol` | Factory deployment, escrow creation | 24+ | **NEW** |
| `VibesTranchEscrow.t.sol` | TranchEscrow core (contribute, claim, challenge, freeze) | ~35 | Existing |
| `VibesLPLocker.t.sol` | LP locking and unlock prevention | ~15 | Existing |

### Current Test Files (Vitest — Shared Package & Web App)

| File | Scope | Test Count | Status |
|------|-------|------------|--------|
| `packages/shared/src/__tests__/allowlist-scoring.test.ts` | Level scoring engine | 40+ | **NEW** |
| `packages/shared/src/__tests__/hashing.test.ts` | Hash utilities | 44 | **NEW** |
| `packages/shared/src/__tests__/merkle.test.ts` | Merkle tree utilities | 38 | **NEW** |
| `packages/shared/src/__tests__/capsule.test.ts` | Capsule attestation | Various | **NEW** |
| `packages/shared/src/__tests__/erc8004.test.ts` | ERC-8004 utilities | Various | **NEW** |
| `apps/web/src/__tests__/auth-wallet-flows.test.ts` | Auth + wallet integration | Various | **NEW** |
| `apps/web/src/__tests__/wallet-disconnect-reconnect.test.ts` | Wallet lifecycle | Various | **NEW** |
| `apps/web/src/__tests__/wallet-social-sync.test.ts` | Wallet + social sync | Various | **NEW** |
| `apps/web/src/__tests__/auth-middleware.test.ts` | Auth middleware | Various | **NEW** |
| `apps/web/src/__tests__/account-link.test.ts` | Account linking | Various | **NEW** |
| `apps/web/src/__tests__/account-sync.test.ts` | Account sync | Various | **NEW** |
| `apps/web/src/__tests__/legal-accept.test.ts` | Legal acceptance API | Various | **NEW** |
| `apps/web/src/__tests__/useOnboarding.test.ts` | Onboarding hook | Various | **NEW** |
| `apps/web/src/__tests__/useWalletAddress.test.ts` | Wallet address hook | Various | **NEW** |
| `apps/web/src/__tests__/useLegalAcceptance.test.ts` | Legal acceptance hook | Various | **NEW** |

### Coverage Gaps — Resolved

| Gap | Original Status | Current Status |
|-----|----------------|----------------|
| ~~No V2 Router integration tests~~ | Critical | **RESOLVED** — `VibesLaunchRouterV2.t.sol` (38+ tests) |
| ~~No end-to-end finalization test~~ | Critical | **RESOLVED** — full lifecycle tests in router test file |
| ~~No VibesTokenDistributorV2 tests~~ | Critical | **RESOLVED** — `VibesTokenDistributorV2.t.sol` (31+ tests) |
| ~~No VibesStaking tests~~ | High | **RESOLVED** — `VibesStaking.t.sol` (18+ tests) |
| ~~No VibesStakerRewards tests~~ | High | **RESOLVED** — `VibesStakerRewards.t.sol` (23+ tests) |
| ~~No VibesIdentityRegistry tests~~ | Medium | **RESOLVED** — `VibesIdentityRegistry.t.sol` (13+ tests) |
| No VibesVesting tests for V2 flow | Medium | **PARTIALLY RESOLVED** — `VibesVesting.t.sol` (30+ tests) covers deferred start |

### Remaining Gaps

- Adversarial/reentrancy-focused tests (P4 in test plan)
- ProRata oversubscription with freeze + unclaimed excess edge case (depends on P1-07 fix)
- Challenge at exact 72-hour boundary (depends on P2-08 fix)

### How to Run Tests

```bash
# Smart contracts (Foundry)
cd vibestarter-app && pnpm run test:contracts

# Shared package (Vitest)
pnpm --filter @vibes/shared test

# Web app (Vitest)
pnpm --filter web test
```

---

## 7. Spec Compliance Summary

| Requirement | Status | Notes |
|------------|--------|-------|
| 10% immediate + 15% monthly x 6 | PASS | `KICKSTART_BPS=1000`, `MONTHLY_BPS=1500`, `NUM_MONTHLY_TRANCHES=6` |
| 72-hour challenge window | PASS | `CHALLENGE_WINDOW = 72 hours`, enforced before tranche claim |
| LP locked indefinitely | PASS | LP tokens sent to 0xdead, no recovery mechanism |
| 2.5% platform fee | PASS | `PLATFORM_FEE_BPS = 250`, deducted at each tranche claim |
| Token split: 70% backer, 20% LP, 10% founder (max) | PASS | Dynamic calculation with `founderAllocationBps` up to 1000 |
| Fixed Goal: all-or-nothing | PASS | `_checkFundingSuccess` requires `totalRaised >= goal` |
| Open-Ended: keep what raised | PASS | Optional soft cap, succeeds if contributions > 0 and soft cap met |
| Pro-Rata: proportional allocation | PASS | `effectiveRaised` caps at goal, excess refundable |
| Refunds for failed raises | PASS | `claimContributorRefund()` returns full contribution |
| Holder refunds after freeze | PASS | Merkle-based with proportional ETH distribution |
| Fees only on successful raises | PASS | Fees deducted per tranche claim, not upfront |
| Challenge: 0.5% token threshold | PARTIAL | Graduated thresholds (0.25% early, 0.5% mid, 1% late) - deviates from spec but is an improvement |
| Challenge: 20% slash on rejection | PASS | `CHALLENGE_SLASH_BPS = 2000` |
| Founder vesting: 12 months | PASS | `DEFAULT_VESTING_DURATION = 365 days` with optional cliff |

---

## 8. Summary of Recommendations by Priority

### Must Fix Before Mainnet

1. **Add V2 router integration tests** - The most critical gap. The V2 router is the deployed contract but has no test coverage.
2. **Add access control to `VibesLPLocker.createAndLockLP()`** - Prevent front-running of LP creation.
3. **Implement 2-step admin transfer in `VibesTranchEscrow`** - Single-step transfer is risky for the most critical admin role.

### Should Fix Before Mainnet

4. Fix `getClaimableTokens()` potential underflow (R-05)
5. Add ETH rescue function to router (R-08)
6. Consider global pause mechanism across escrows (X-04)
7. Migrate to consistent custom errors across all contracts (X-03)

### Nice to Have

8. Use `Ownable2Step` for router ownership
9. Use OpenZeppelin ERC20 for VibesToken
10. Add lens/aggregator view contract
11. Add `unchecked` blocks for safe arithmetic
12. Add EIP-2612 permit support to token

---

*This review was conducted as a read-only analysis. No code modifications were made. The findings are based on manual code review and do not constitute a formal security audit. A professional audit by a reputable firm is recommended before mainnet deployment.*

---

## Post-Review Changes (2026-03 to 2026-04)

> **This section documents all changes made AFTER the original review (2026-02-08).** An agent reviewing contracts should verify these changes are correctly implemented.

### Review Scope for Next Reviewer

All contracts in `contracts/src/` have changed since the Feb 2026 review. The full list of changes is in `docs/pending-contract-changes.md`. Key areas that need fresh review:

#### 1. EIP-712 Nonce Replay Protection (Added 2026-04-01)

**Files:** `VibesTranchEscrow.sol`, `VibesTranchEscrowTestnet.sol`, `VibesStaking.sol`, `VibesRouterStorage.sol`, `VibesLaunchRouterV2.sol`

**Review checklist:**
- [ ] `TERMS_TYPEHASH` matches `"TermsAcceptance(address user,uint256 nonce,uint256 deadline)"` in all 3 contracts
- [ ] `LAUNCH_TYPEHASH` matches `"LaunchAuthorization(address founder,uint256 nonce,uint256 deadline)"` in router
- [ ] `_verifyTermsSignature()` checks `nonce == nonces[user]` BEFORE deadline check
- [ ] `_verifyTermsSignature()` increments `nonces[user]++` AFTER successful verification
- [ ] `_verifyLaunchSignature()` checks `nonce == launchNonces[founder]` and increments
- [ ] Nonce is included in `structHash` encoding: `keccak256(abi.encode(TYPEHASH, user, nonce, deadline))`
- [ ] Function is `internal` (not `internal view`) since it mutates state
- [ ] Bypass mode still works: `trustedSigner == address(0)` returns early, nonce not incremented
- [ ] `InvalidNonce()` error defined and used

#### 2. Security Audit Fixes (2026-02 to 2026-03)

**Review checklist:**
- [ ] Pro-Rata: `_checkFundingSuccess()` uses `totalRaised >= goal` (not `> 0`)
- [ ] Order-independent claims: `initialBackerTokens[token]` snapshot used in `claimTokens()`
- [ ] Deposit tracking: `totalReservedDeposits` prevents `rescueETH()` draining deposits
- [ ] Division-by-zero: `frozenTotalSupply > 0` guards in `_challengeSucceeded()` and `emergencyFreeze()`
- [ ] Goal validation: `goal > 0` required for FixedGoal and ProRata
- [ ] LP rescue: `completeLP()` function, `LPStatus` enum, `lpStatus` mapping
- [ ] `rescueERC20()`: blocks tokens with active escrows or pending LP
- [ ] `createDistributor()`: always reverts with `DistributorDisabled()`
- [ ] Challenge window boundary: claim `<=`, challenge `>=`
- [ ] try/catch on `completeFinalization` (H-02)
- [ ] `lpCreated` flag blocks tranche claims until LP verified (H-04)
- [ ] `MAX_TIME_DRIFT = 1 hours` on mainnet escrow only (H-06)
- [ ] `canClaim()` in StakerRewards uses double-hash (fixed 2026-04-01)
- [ ] `safeTransferFrom` for $VIBES burn (C-03)
- [ ] Locked address overlap validation in `setLockedAddresses` (M-02)
- [ ] `frozenEthBalance` subtracts `pendingPlatformFees` (M-03)
- [ ] LP slippage 0.5% in LPLocker (M-04)
- [ ] Batch size limit `<= 100` on `batchDistribute` and `claimMultiple` (L-01)
- [ ] Treasury single challenge: `proposalChallengeResolved` (F6, L-04)

#### 3. Economic & Admin Changes

**Review checklist:**
- [ ] LP allocation: `ETH_TO_LP_BPS = 1500` (15%)
- [ ] Founder deposit: `founderDepositWei = 0.01 ether`
- [ ] `operationsAdmin` exists on router storage, `setOperationsAdmin()` on extension
- [ ] `setUseTestnetContracts()` has `require(block.chainid != 8453)` guard
- [ ] Challenge cooldown: `CHALLENGE_COOLDOWN = 7 days` (mainnet), `2 hours` (testnet)
- [ ] $VIBES burn feature-flagged: `vibesToken = address(0)`, `launchBurnAmount = 0`

#### 4. ABI / Frontend Alignment

**Review checklist:**
- [ ] `escrow.ts` ABI matches contract: `contribute(uint256 nonce, uint256 deadline, bytes signature)`
- [ ] `router.ts` ABI matches contract: `launchWithCampaign` has 19 inputs
- [ ] `supporting.ts` ABI matches contract: `stake(uint256 amount, uint256 nonce, uint256 deadline, bytes signature)`
- [ ] `contribution-form.tsx` inline ABI matches (has nonce/deadline/signature inputs + args)
- [ ] All hooks pass bypass defaults: `BigInt(0), BigInt(0), '0x'`
- [ ] `terms-signer.ts` includes nonce in EIP-712 typed data
- [ ] `/api/terms/sign` returns `{ signature, deadline, nonce }`

#### 5. Original Review Findings Status

| Finding | Status | Notes |
|---------|--------|-------|
| R-01 Rounding dust | Unchanged | LP absorbs dust by design |
| R-02 Stale approval | Unchanged | Safe for VibesToken |
| R-03 No access control on finalize | Unchanged | Intentionally permissionless |
| R-05 getClaimableTokens underflow | **Fixed** | `initialBackerTokens` snapshot |
| R-08 No ETH rescue | **Fixed** | `rescueETH()` added with deposit guard |
| X-04 Global pause | **Fixed** | Router pause + `whenNotPaused` on fallback |
| Ownable2Step | **Fixed** | Two-step ownership on all contracts |
