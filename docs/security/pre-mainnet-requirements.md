# Pre-Mainnet Security Requirements

> **Status:** BLOCKING — all items must be completed before mainnet deployment.
>
> Created: 2026-03-25. Tracks contract-level security requirements, admin key management, and timing validation.

---

## 1. Two-Tier Onchain Admin

Two distinct onchain admin roles with strict separation of powers:

### Master Admin — Gnosis Safe (multi-sig)

**Wallet:** Gnosis Safe (2-of-3 minimum, 3-of-5 recommended)
**Role:** Router `owner`. Controls infrastructure, deployment, and fund rescue.
**Key property:** Can move user funds. Requires multi-sig ceremony.

| Function | What it controls |
|----------|-----------------|
| `pause()` / `unpause()` | Emergency stop — freezes all operations |
| `setEscrowFactory()` | Which factory creates new escrows |
| `setLPLocker()` | Where LP ETH + tokens go on finalization |
| `setStakerRewardsContract()` | Where 2.5% ecosystem tokens go |
| `setFeeConfig()` | Fee recipient and amount |
| `rescueETH()` / `rescueERC20()` | Extract funds from router |
| `refundDeposit()` / `forfeitDeposit()` | Manage founder deposits |
| `transferOwnership()` | Transfer master admin role |
| `setOperationsAdmin()` | Appoint/revoke operations admin |
| `setTrustedLaunchSigner()` | Control launch gating |
| `completeLP()` | Resolve failed LP creation |
| `setFounderDepositWei()` | Change anti-spam deposit |

### Operations Admin — Dedicated EOA

**Wallet:** Hot wallet (single EOA) for fast day-to-day resolution
**Role:** New `operationsAdmin` on router. Passed to escrows + treasuries at creation.
**Key property:** Cannot move user funds to arbitrary addresses. Can only freeze, return stakes, or burn to `0xdead`.

| Function | Contract | What it does |
|----------|----------|-------------|
| `upholdChallenge()` | Escrow | Freeze campaign, return stake to challenger |
| `rejectChallenge()` | Escrow | Slash challenger 20%, allow tranche release |
| `freezeCampaign()` | Escrow | Freeze funded campaign for holder refunds |
| `setRefundMerkleRoot()` | Escrow | Enable holder refund claims |
| `pauseCampaign()` / `resumeCampaign()` | Escrow | Pause/resume active raises |
| `forceRefundDuringRaise()` | Escrow | Emergency refund during active raise |
| `setTrustedSigner()` | Escrow | Update contribution signature gating |
| `upholdChallengeRework()` | Treasury | Block proposal, return stake, cooldown |
| `upholdChallengeMalicious()` | Treasury | NUCLEAR — burn treasury, freeze vesting |
| `rejectChallenge()` | Treasury | Slash challenger 20%, allow proposal |

### Compromise Impact

| Scenario | Impact | Recovery |
|----------|--------|----------|
| **Ops admin compromised** | Can freeze campaigns, burn individual treasuries. Cannot extract funds. | Master admin calls `setOperationsAdmin(newWallet)` immediately. Damage limited to campaigns with active challenges. |
| **Master admin compromised** | Full platform compromise — fund extraction possible. | Requires multi-sig key rotation. Much harder to execute than single EOA. |
| **Both compromised** | Total loss. | Multi-sig + EOA simultaneous compromise is extremely unlikely. |

### Action Items
- [ ] Add `operationsAdmin` storage slot to `VibesRouterStorage.sol`
- [ ] Add `setOperationsAdmin()` to `VibesRouterExtension.sol` (onlyOwner)
- [ ] Update `launchWithCampaign()` to pass `operationsAdmin` (not `owner`) to treasury
- [ ] Update factory admin to use `operationsAdmin`
- [ ] Deploy Gnosis Safe on Base mainnet (2-of-3 or 3-of-5)
- [ ] Set router owner = Safe address
- [ ] Set `operationsAdmin` = dedicated hot wallet
- [ ] Document signer identities and recovery procedures

---

## 2. Remove `setUseTestnetContracts` from Mainnet

**`setUseTestnetContracts(bool)` MUST be removed from the mainnet deployment.**

If called on mainnet with `true`, it would:
- Set vesting cliff to 6 days (instead of 180 days) — founder token dump within a week
- Set treasury cooldown to 2 hours — rapid treasury drain proposals
- Set treasury challenge window to 2 hours — backers have no time to respond

This function has no legitimate use on mainnet. The testnet toggle only exists for development acceleration.

### Action Items
- [ ] Remove `setUseTestnetContracts()` from `VibesRouterExtension.sol`
- [ ] Remove `useTestnetContracts` storage variable from `VibesRouterStorage.sol`
- [ ] Hardcode mainnet values in `VibesLaunchRouterV2.sol` (remove ternaries)
- [ ] Deploy mainnet router without this function

---

## 3. Timelock on Infrastructure Changes

The following owner functions should have a **24-48 hour delay** before taking effect:

| Function | Risk | Why Timelock |
|----------|------|-------------|
| `setEscrowFactory()` | Replaces all future escrows | Community can verify new factory isn't malicious |
| `setLPLocker()` | Replaces LP creation target | LP funds are 15% of all raised ETH |
| `setStakerRewardsContract()` | Redirects ecosystem tokens | 2.5% of all campaign tokens |
| `setFeeConfig()` | Changes fee recipient | All launch fees |
| `setFounderDepositWei()` | Changes deposit requirement | Anti-spam mechanism |

Functions that should remain **instant** (emergency use):
- `pause()` / `unpause()` — emergency stop needs to be immediate
- `rescueETH()` / `rescueERC20()` — stuck fund recovery
- Challenge resolution (`upholdChallenge`, `rejectChallenge`) — 72-hour windows require timely action

### Implementation Options
1. **OpenZeppelin TimelockController** — wrap the Safe as executor, set 24h delay
2. **Custom timelock in router** — `proposeChange()` → 24h wait → `executeChange()`
3. **Defender Relayer** — OZ Defender for automated proposal monitoring + alerts

---

## 4. Event Monitoring & Alerts

**All admin functions must emit events, and those events must be monitored.**

### Critical Events to Monitor
- `OwnershipTransferred` — ownership change initiated
- `Paused` / `Unpaused` — emergency stop
- `EscrowFactoryUpdated` — infrastructure swap
- `LPLockerUpdated` — infrastructure swap
- `FeeConfigUpdated` — fee recipient change
- `CampaignFrozen` — campaign freeze (any reason)
- `ChallengeUpheld` / `ChallengeRejected` — dispute resolution
- `TreasuryTerminated` — nuclear option (treasury burned)
- `RefundMerkleRootSet` — enables refund claims
- `ETHRescued` / `ERC20Rescued` — fund extraction

### Action Items
- [ ] Set up Tenderly alerts on all `onlyOwner` and `onlyAdmin` function calls
- [ ] Telegram/Discord webhook for immediate notification
- [ ] Weekly digest of all admin actions for audit trail

---

## 5. Rescue Function Safeguards

### `rescueETH(to, amount)`
**Current guard:** Cannot drain `totalReservedDeposits` (founder deposits).
**Risk:** All other ETH in the router is extractable.
**Recommendation:** Add event logging. Consider requiring multi-sig for amounts above a threshold.

### `rescueERC20(token, to, amount)`
**Current guards:**
- Blocks if token has pending backer claims (`backerTokensForClaims > 0`)
- Blocks if token has active escrow (`tokenToEscrow != address(0)`)
- Blocks if token has pending LP (`pendingLP.tokenAmount > 0`)

**Risk:** After campaign completion, when all claims are processed and escrow cleared, the guards may no longer apply. Stale tokens could be drained.
**Recommendation:** These guards are adequate for the current design. Ensure accounting is never prematurely cleared.

### `setRefundMerkleRoot(merkleRoot)`
**Risk:** A malicious merkle root allows arbitrary refund claims.
**Recommendation:** The snapshot generation (off-chain) must be verifiable. Consider publishing the full merkle tree (not just root) so holders can verify their allocation before claiming.

---

## 6. Timing Validation Checklist

Before any contract deployment, validate ALL timing parameters maintain proportional consistency:

### Mainnet Reference Values
| Parameter | Value | Relationship |
|-----------|-------|-------------|
| Tranche interval | 30 days | Base unit |
| Tranche challenge window | 72 hours | Fixed |
| Challenger cooldown | 7 days | Fixed |
| Vesting cliff | 180 days | = 6 × tranche interval |
| Vesting duration | 365 days | = ~12 × tranche interval |
| Treasury cliff | 180 days | = 6 × tranche interval (= full tranche schedule) |
| Treasury cooldown | 14 days | Fixed |
| Treasury challenge window | 72 hours | Fixed |

### Testnet Compressed Values (30:1 ratio)
| Parameter | Value | Derivation |
|-----------|-------|-----------|
| Tranche interval | 1 day | 30 days / 30 |
| Tranche challenge window | 2 hours | Fixed (close enough to 72h/30 = 2.4h) |
| Challenger cooldown | 2 hours | Fixed (compressed for testing) |
| Vesting cliff | **6 days** | 180 days / 30 |
| Vesting duration | **12 days** | 365 days / 30 |
| Treasury cliff | **6 days** | 180 days / 30 |
| Treasury cooldown | 2 hours | Fixed (compressed for testing) |
| Treasury challenge window | 2 hours | Fixed (close enough) |

### Validation Rule
> **Any parameter that references the tranche schedule (cliffs, vesting) must maintain its ratio to the tranche interval.**
> The treasury cliff MUST equal the full tranche schedule (6 × interval).
> The vesting cliff MUST equal the full tranche schedule (6 × interval).

---

## 7. Separation of Concerns

| Role | Wallet Type | Set By | Controls | Compromise Impact |
|------|------------|--------|----------|-------------------|
| **Master Admin** | Gnosis Safe (multi-sig) | Router constructor (`owner`) | Infrastructure, rescue, pause, ops admin appointment | Platform-wide fund extraction |
| **Operations Admin** | Hot wallet (EOA) | Master admin via `setOperationsAdmin()` | Challenge resolution, freeze, merkle roots | Per-campaign freeze/burn — no fund extraction |
| **Off-Chain Admin** | EOA(s) | `ADMIN_WALLETS` env var | Content moderation, DB management | No onchain impact |
| **Keeper** | Dedicated EOA | Configured in keeper service | Auto-execute expired challenges/proposals | Limited (permissionless functions only) |
| **Launch Signer** | Dedicated EOA | Master admin via `setTrustedLaunchSigner()` | Signature gating for new launches | Can block/allow new campaigns |

**Critical design rule:** Operations admin is passed to escrows and treasuries at campaign creation. Master admin (Safe) never appears as the `admin` on individual escrows — only the ops wallet does. This means multi-sig ceremony is never needed for time-sensitive challenge resolution.

---

## 8. Known Immutable Bugs (Testnet Only)

These affect existing testnet deployments and cannot be fixed without redeployment:

| Bug | Contract | Impact | Mitigation |
|-----|----------|--------|-----------|
| Treasury cliff = 1 day | VibesTreasuryEscrow | Proposals available on day 1 | Frontend blocks until day 6 |
| Vesting cliff = 1 day | VibesVesting | Founder tokens claimable on day 1 | Frontend blocks until day 6 |
| Vesting duration = 6 days | VibesVesting | Full vest in 7 days instead of 18 | Display only — no frontend fix possible |

These are testnet-only issues. Mainnet contracts will use correct values. The frontend enforcement is a best-effort UI gate — direct contract interaction can bypass it.
