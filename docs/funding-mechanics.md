# Funding Mechanics

> How money flows through Vibestarter — from backer contribution to founder payout and refunds.

---

## Raise Types

### Fixed Goal
- **Hard cap:** Must reach `goal` or campaign fails
- **Refund:** Full ETH refund if goal not met by deadline
- **Behavior:** Contributions accepted up to `goal`, campaign auto-succeeds when goal is reached

### Open-Ended
- **No hard cap:** Keep whatever is raised
- **Soft cap (optional):** If set, campaign fails if `totalRaised < softCap` at deadline
- **Behavior:** Contributions accepted until deadline, then finalized with whatever was raised

### Pro-Rata
- **Hard cap:** `goal` is the hard cap
- **Oversubscription:** Backers can commit more than the goal
- **Fair allocation:** Each backer gets `(their commitment / total committed) * goal` worth of tokens
- **Excess refund:** Oversubscribed backers receive the difference back via `claimExcessRefund()`
- **Behavior:** Contributions accepted until deadline, then allocated proportionally

---

## Token Allocation

When a campaign is launched via `VibesLaunchRouterV2.launchWithCampaign()`, the total token supply is distributed:

| Allocation | Percentage | Recipient | Notes |
|-----------|------------|-----------|-------|
| Backer Tokens | 65–82.5% | Backers (via router claims) | Proportional to contribution |
| LP Tokens | 15% | Permanently locked in Aerodrome LP | Sent to 0xdead (irrecoverable). If LP creation fails, ETH+tokens enter a rescue mapping; admin resolves via manual LP creation — rescued funds are NOT locked LP tokens. |
| Founder Tokens | 0–7.5% | Founder vesting contract | 6-month cliff + 12-month linear |
| Treasury Tokens | 0–17.5% | Treasury escrow | Proposal-based withdrawal |
| Staker Rewards | 2.5% | VIBES stakers | Merkle-based distribution |

The exact split depends on the founder's configuration at launch time.

---

## Tranche Schedule

Funds release by **TIME**, not milestones. After a campaign is successfully funded:

| Tranche | Timing | Amount | Cumulative |
|---------|--------|--------|------------|
| Kickstart (T0) | Immediately after finalization | 10% of escrow | 10% |
| Month 1 (T1) | 30 days after funding | 15% of escrow | 25% |
| Month 2 (T2) | 60 days after funding | 15% of escrow | 40% |
| Month 3 (T3) | 90 days after funding | 15% of escrow | 55% |
| Month 4 (T4) | 120 days after funding | 15% of escrow | 70% |
| Month 5 (T5) | 150 days after funding | 15% of escrow | 85% |
| Month 6 (T6) | 180 days after funding | 15% of escrow | 100% |

**Escrow amount** = 85% of total raised (15% goes to LP creation at finalization).

### Tranche Claim Process

1. **Founder requests tranche** via `requestTranche(trancheIndex)` — starts 72-hour challenge window
2. **72-hour challenge window** — backers can raise a challenge
3. **If no challenge:** Founder calls `claimTranche(trancheIndex)` after window expires
4. **If challenged:** Admin reviews and either upholds (freezes campaign) or rejects (slashes challenger)

### Platform Fee on Tranches

Each tranche payout has a 2.5% platform fee deducted:
- Founder receives: `trancheAmount * 97.5%`
- Platform receives: `trancheAmount * 2.5%`

---

## Challenge System

### Who Can Challenge

Backers who hold a minimum amount of project tokens can challenge a tranche request. The threshold is **graduated** based on the tranche number:

| Tranches | Required Holdings | Rationale |
|----------|------------------|-----------|
| T0-T2 (Early) | 0.25% of supply | Lower barrier — backers have less data |
| T3-T4 (Mid) | 0.50% of supply | Standard threshold |
| T5-T6 (Late) | 1.00% of supply | Higher barrier — founder has track record |

### Challenge Flow

```
Founder requests tranche
    → 72h Challenge Window opens
        → Backer raises challenge (stakes tokens)
            → Other holders can supportChallenge()
            → Admin reviews within 72h
                → Uphold: Campaign frozen, stake returned
                → Reject: Challenger slashed 20%, 80% returned
                → No action: Challenge expires, stake returned
        → No challenge raised
            → Founder claims tranche after 72h
```

### Challenger Slash Mechanics

When a challenge is **rejected**:
- 20% of staked tokens → burned to `0xdead`
- 80% of staked tokens → returned to challenger

This discourages frivolous challenges while still allowing legitimate concerns.

### Challenger Cooldown

Each address is subject to a **7-day cooldown** after raising a challenge (2 hours on testnet). This prevents a single actor from serially challenging every tranche to grief founders or predictably burn token supply. Different addresses can still challenge different tranches independently.

### Challenge Support

Token holders can call `supportChallenge()` to emit events supporting the challenge, providing additional context for the admin's review. This is event-only (no state changes) and requires holding at least some project tokens.

---

## Refund Paths

### 1. Contributor Refund (Failed Campaign)

**When:** Campaign reaches deadline without meeting its goal (FixedGoal) or soft cap (OpenEnded).

**Who:** Any address in the `contributions` mapping.

**Amount:** Full ETH contribution amount.

**Function:** `claimContributorRefund()`

**Flow:**
```
Backer → claimContributorRefund() → ETH returned via .call{value:}
```

### 2. Holder Refund (Frozen Campaign)

**When:** Campaign was funded but later frozen (challenge upheld or admin freeze).

**Who:** Any address holding project tokens (verified via merkle proof).

**Amount:** Proportional to token holdings: `(frozenEthBalance * tokenAmount) / frozenTotalSupply`

**Function:** `claimHolderRefund(tokenAmount, merkleProof)`

**Flow:**
```
Admin freezes campaign
    → Admin sets refund merkle root (off-chain snapshot)
    → Token holder burns tokens to 0xdead
    → Token holder submits merkle proof
    → ETH refund proportional to burned tokens
```

### 3. Excess Refund (Pro-Rata Oversubscription)

**When:** Pro-Rata campaign was oversubscribed.

**Who:** Any backer whose commitment was partially refunded.

**Amount:** `contribution - (contribution * goal / totalCommitted)`

**Function:** `claimExcessRefund()`

**Flow:**
```
Pro-Rata campaign finalized
    → Each backer's effective allocation calculated
    → Excess = original contribution - allocated amount
    → Backer claims excess via claimExcessRefund()
```

### 4. Treasury Proposal Refund

**When:** Treasury challenge upheld as "malicious" — all treasury tokens burned.

**Who:** Not a direct ETH refund. Treasury tokens are burned to 0xdead. Founder vesting is frozen (unvested tokens burned).

---

## Escrow Flow Diagram

```
Backer contributes ETH
    → VibesTranchEscrow holds ETH
    → Campaign reaches goal/deadline
    → finalize() called
        → 15% ETH → Router → LP Locker (locked to 0xdead)
        → 85% ETH stays in escrow for tranches
        → Tokens distributed:
            - Backer tokens → Router (for claims)
            - Founder tokens → VibesVesting
            - Treasury tokens → VibesTreasuryEscrow
            - Staker tokens → VibesStakerRewards
            - Platform tokens → ops wallet
    → Tranches release over 6 months:
        → T0: 10% (immediate after finalization)
        → T1-T6: 15% each (monthly, 72h challenge window)
    → Each tranche:
        → 97.5% to founder
        → 2.5% to platform wallet
```

---

## Fee Structure

| Fee | Amount | When | Recipient |
|-----|--------|------|-----------|
| Platform token fee | 0.5% of supply | At launch | Platform ops wallet |
| Tranche platform fee | 2.5% of each tranche | At each tranche claim | Platform wallet |
| Founder deposit | 0.05 ETH (configurable) | At campaign launch | Refunded after successful finalization |
| Launch fee (optional) | Configurable | At launch (if enabled) | Fee recipient |

### Founder Deposit

Founders must deposit ETH when launching a campaign. This deposit is:
- **Refunded** after successful finalization via `completeFinalization()`
- **Forfeitable** by the router owner if the founder abandons the campaign
