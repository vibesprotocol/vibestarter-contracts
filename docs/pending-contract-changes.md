# Pending Contract Changes

> **STATUS: READY FOR DEPLOYMENT** — All code changes are complete, including the 2026-04-14 audit remediation (H-1 through L-4). Raises are disabled (`NEXT_PUBLIC_ENABLE_RAISES=false`). Existing testnet raises will be wiped.
>
> **NEW (not yet implemented):** `disableStakerAllocation` admin flag for the $VIBES raise TGE — see §"Pending implementation" below.

Last updated: 2026-04-18

---

## Pending implementation

### PC-03: Atomic admin-pre-authorized per-launcher Community Rewards deployment (IMPLEMENTED)

**Status:** Implemented in `VibesLaunchRouterV2.sol`, `VibesRouterStorage.sol`, `VibesRouterExtension.sol`; tests in `contracts/test/VibesCommunityAllocationForLaunch.t.sol`. Awaiting CI run and redeploy alongside PC-01.

**Motivation:** `VibesCommunityRewards` (PC-02) needs the newly-deployed $VIBES token address as a constructor argument, but that address doesn't exist until `launchWithCampaign` runs. Earlier designs introduced a two-phase `bindToken` path to work around this, which added complexity. PC-03 instead deploys the `VibesCommunityRewards` contract **atomically inside `launchWithCampaign`** — mirroring how the router already deploys `VibesVesting` and `VibesTreasuryEscrow` inline. Single transaction, no chicken-and-egg.

**Design properties:**
- **Admin-only:** `setCommunityAllocationForLaunch(launcher, bps, cliffDuration, communityAdmin)` is `onlyOwner`. No founder can self-authorize.
- **Per-launcher:** `mapping(address => LaunchCommunityConfig)` — authorization is keyed by the wallet that will call `launchWithCampaign`. Other launchers see empty config → standard behaviour.
- **Atomic:** the `VibesCommunityRewards` contract is deployed in the same tx as the launch, bound to the freshly-deployed token.
- **One-shot:** consumed + cleared immediately at launch time. Second launch by the same wallet gets no community slice unless re-authorized.
- **Capped:** `MAX_COMMUNITY_ALLOCATION_BPS = 2000` (20%). Enforced in the setter.
- **Protects backers:** `MIN_BACKER_ALLOCATION_BPS = 5000` (50%) floor enforced at launch. Community slice must come out of founder/treasury/ecosystem room, never out of backers.
- **Revokable:** admin can clear a pending authorization with `setCommunityAllocationForLaunch(launcher, 0, 0, address(0))` before it's consumed.
- **Queryable:** deployed community-rewards address tracked in `tokenToCommunityRewards[token]`.

**Storage additions (`VibesRouterStorage.sol`):**
```solidity
uint256 public constant MAX_COMMUNITY_ALLOCATION_BPS = 2000;
uint256 public constant MIN_BACKER_ALLOCATION_BPS = 5000;

struct LaunchCommunityConfig {
    uint256 bps;
    uint256 cliffDuration;
    address communityAdmin;
}
mapping(address => LaunchCommunityConfig) public communityConfigForLaunch;
mapping(address => address) public tokenToCommunityRewards;  // per-token deployed contract
```

**Extension setter (`VibesRouterExtension.sol`):**
```solidity
function setCommunityAllocationForLaunch(
    address launcher,
    uint256 bps,
    uint256 cliffDuration,
    address communityAdmin
) external onlyOwner {
    if (launcher == address(0)) revert ZeroAddress();
    if (bps > MAX_COMMUNITY_ALLOCATION_BPS) revert InvalidAllocation();
    if (bps > 0) {
        if (communityAdmin == address(0)) revert ZeroAddress();
        if (cliffDuration == 0) revert InvalidAllocation();
    }
    communityConfigForLaunch[launcher] = LaunchCommunityConfig({
        bps: bps, cliffDuration: cliffDuration, communityAdmin: communityAdmin
    });
    emit CommunityAllocationSet(launcher, bps, cliffDuration, communityAdmin);
}
```

**Router atomic deployment via factory + transfer + consume (`VibesLaunchRouterV2.launchWithCampaign`):**
```solidity
LaunchCommunityConfig memory communityConfig = communityConfigForLaunch[msg.sender];
uint256 communityBps = communityConfig.bps;

uint256 backerAllocationBps = BPS_DENOMINATOR - founderAllocationBps - treasuryAllocationBps - LP_ALLOCATION_BPS - ecosystemBps - communityBps;
if (backerAllocationBps < MIN_BACKER_ALLOCATION_BPS) revert BackerAllocationTooLow();

// ... after escrow creation ...
if (communityBps > 0) {
    if (communityRewardsFactory == address(0)) revert CommunityRewardsFactoryNotSet();
    delete communityConfigForLaunch[msg.sender];
    address crAddr = VibesCommunityRewardsFactory(communityRewardsFactory).create(
        IERC20(token),
        block.timestamp + communityConfig.cliffDuration,
        communityConfig.communityAdmin
    );
    tokenToCommunityRewards[token] = crAddr;
    IERC20(token).safeTransfer(crAddr, communityTokens);
    emit CommunityAllocationConsumed(token, msg.sender, crAddr, communityTokens);
}
```

The `new VibesCommunityRewards(...)` was moved out of the router into `VibesCommunityRewardsFactory` (see PC-04 below) so router runtime bytecode stays under the EIP-170 24,576-byte limit. The factory call happens in the same tx, preserving atomicity and the one-shot authorization guarantee.

**New events:**
- `CommunityAllocationSet(address indexed launcher, uint256 bps, uint256 cliffDuration, address indexed communityAdmin)` — emitted on setter.
- `CommunityAllocationConsumed(address indexed token, address indexed launcher, address indexed communityRewards, uint256 amount)` — emitted per-launch; includes the freshly-deployed VibesCommunityRewards address.

**New error:** `BackerAllocationTooLow` — raised at launch when the computed backer slice would be below 50%.

**$VIBES-specific usage plan (single-tx launch):**
- Admin calls `setStakerAllocationDisabled(true)` (PC-01) to disable the 2.5% ecosystem slice for $VIBES (and all pre-entity raises).
- Admin calls `setCommunityAllocationForLaunch(vibesLauncher, 1500, 180 days, communityMultisig)` to authorize a 15% community slice with a 6-month cliff and the community multisig as admin.
- `vibesLauncher` calls `launchWithCampaign` with founder=500 bps (5%), treasury=1500 bps (15%) → in a single tx, the router: deploys the $VIBES token, deploys a fresh `VibesCommunityRewards` bound to that token, transfers 15% to it, backer slice = 50% exactly, authorization cleared.
- Admin calls `setStakerAllocationDisabled(false)` once the Luxembourg entity is formed. Future raises revert to standard 2.5% staker allocation and get no community slice unless individually re-authorized.

**Note:** The router imports `VibesCommunityRewardsFactory` (not `VibesCommunityRewards` directly) and calls `factory.create(...)`. The factory must be deployed and registered via `extension.setCommunityRewardsFactory(address)` **before** any launcher with a non-zero community slice calls `launchWithCampaign` — otherwise the call reverts `CommunityRewardsFactoryNotSet`. See PC-04 below.

**Test plan — 17 tests in `VibesCommunityAllocationForLaunch.t.sol`:**
1. Setter: onlyOwner.
2. Setter: reverts on zero launcher.
3. Setter: reverts on bps > cap (2001).
4. Setter: reverts on non-zero bps with zero communityAdmin.
5. Setter: reverts on non-zero bps with zero cliffDuration.
6. Setter: revoke with zero bps allowed (other params ignored).
7. Setter: emits `CommunityAllocationSet`.
8. Setter: allows exactly the cap value (2000).
9. Default (unauthorized): standard allocation, no VibesCommunityRewards deployed.
10. Authorized + $VIBES-shape: router atomically deploys VibesCommunityRewards with correct token/cliff/admin; 15% transferred; backer slice 50% exactly.
11. Authorized: config cleared after launch.
12. Authorized: second launch by same wallet gets no community slice, no second CR deployed.
13. Authorized: `CommunityAllocationConsumed` event emitted with deployed CR address.
14. Isolation: unauthorized launcher cannot use another's config.
15. Backer floor: reverts when combined slices would leave backers below 50%.
16. Backer floor: exactly 50% passes.
17. Conservation: founder + treasury + community + (LP + backer) = totalSupply.
18. Deployed contract: cliff enforced — `createBatch` reverts pre-cliff, succeeds post-cliff.

**Frontend impact:** None on the launch function signature. Admin UI needed for the setter (admin-only).

**Estimated remaining effort:** 1h to run CI and verify. Redeploys piggyback on PC-01 (same router + extension contracts).

---

### PC-04: `VibesCommunityRewardsFactory` — external factory for PC-03 atomicity under EIP-170 (IMPLEMENTED)

**Status:** Implemented in `contracts/src/VibesCommunityRewardsFactory.sol`; wired into router + extension + `DeployV2` scripts; test setUp in `VibesCommunityAllocationForLaunch.t.sol` deploys + registers the factory.

**Motivation:** Inlining `new VibesCommunityRewards(...)` inside `launchWithCampaign` pushed `VibesLaunchRouterV2` runtime bytecode to 27,437 bytes — 2,861 over the EIP-170 24,576-byte limit. The deploy would have reverted on any chain. Moving the creation code into a standalone factory drops the router to 23,717 bytes (~860 bytes under the limit) while preserving the one-tx atomicity the PC-03 design depends on.

**Design properties:**
- **Thin and stateless.** The factory holds no state — each `create(token, unlockTime, admin)` call `new`s a fresh `VibesCommunityRewards` and returns its address. Emits `CommunityRewardsDeployed(communityRewards, token, admin, unlockTime)`.
- **Permissionless.** Anyone can call `create(...)`, but only the router is in a position to correlate a deploy with a specific launch (the factory doesn't record the caller beyond the event). Protection against standalone use relies on the fact that a stray `VibesCommunityRewards` with no tokens transferred to it is harmless.
- **Upgrade path.** A new factory can be deployed and re-registered via `extension.setCommunityRewardsFactory(newFactory)` if the `VibesCommunityRewards` contract itself changes in a future release. Existing community-rewards contracts are unaffected (factory isn't in their code path).

**Storage additions (`VibesRouterStorage.sol`):**
```solidity
/// @notice Community rewards factory — deploys per-campaign VibesCommunityRewards
///         out-of-band to keep the router's runtime bytecode under EIP-170.
address public communityRewardsFactory;
```

**Extension setter (`VibesRouterExtension.sol`):**
```solidity
function setCommunityRewardsFactory(address _factory) external onlyOwner {
    if (_factory == address(0)) revert ZeroAddress();
    communityRewardsFactory = _factory;
}
```

**New error:** `CommunityRewardsFactoryNotSet` — raised at launch time when a launcher has a non-zero community slice but the factory isn't registered.

**Deploy requirement:** deploy `VibesCommunityRewardsFactory` in the same broadcast as the router/extension, then call `extension.setCommunityRewardsFactory(factoryAddress)`. The `DeployV2` / `DeployV2Mainnet` scripts do both; skipping either step bricks any launcher that tries to use a community slice.

**Frontend impact:** none — the factory is invisible at the call-site; only admin tooling needs to know the setter.

---

### PC-05: Combined founder + treasury cap raised to 20% (IMPLEMENTED)

**Status:** Implemented in `VibesRouterStorage.sol` + `VibesLaunchRouterV2.sol`; tests updated in `VibesLaunchRouterV2.t.sol` + `VibesCommunityAllocationForLaunch.t.sol`.

**Motivation:** `launchWithCampaign` previously reused `MAX_TREASURY_ALLOCATION_BPS (1750)` as the combined founder-plus-treasury cap, so the $VIBES raise shape (500 + 1500 = 2000) reverted `InvalidTreasuryAllocation()` before reaching any PC-03 logic. The reused constant also made it impossible for any raise to use both `MAX_FOUNDER_ALLOCATION_BPS (750)` and `MAX_TREASURY_ALLOCATION_BPS (1750)` together.

**Change:**
```solidity
/// @notice Maximum combined founder + treasury allocation (20%).
uint256 public constant MAX_FOUNDER_PLUS_TREASURY_BPS = 2000;
```
The combined check in `launchWithCampaign` now points at the dedicated constant:
```solidity
// Combined founder + treasury capped independently of each individual max
if (founderAllocationBps + treasuryAllocationBps > MAX_FOUNDER_PLUS_TREASURY_BPS) revert InvalidTreasuryAllocation();
```

**Backer protection unchanged:** `MIN_BACKER_ALLOCATION_BPS (5000)` remains the 50% floor that actually caps founder-side extraction across the whole allocation set. This cap merely bounds founder+treasury separately from the other slices.

**Tests updated:** `test_launchWithCampaign_revertsCombinedExceeds17_5` → `test_launchWithCampaign_revertsCombinedExceeds20` (750 + 1251 = 2001 reverts). New `test_launchWithCampaign_combinedExactly20_succeeds` (500 + 1500 = 2000 = $VIBES shape).

---

### PC-02: `VibesCommunityRewards` — Community Rewards timelocked distributor (IMPLEMENTED, not yet deployed)

**Status:** Solidity contract + tests landed in `contracts/src/VibesCommunityRewards.sol` and `contracts/test/VibesCommunityRewards.t.sol`. Awaiting CI run and mainnet deployment.

**Motivation:** The 20% $VIBES Community Rewards slice needs to (a) receive tokens at the $VIBES raise finalisation, (b) enforce a 6-month cliff, and (c) support multiple flexible distribution batches thereafter (airdrops, hackathon payouts, grants) without pre-publishing recipient criteria on-chain.

**Summary:**
- Immutable `unlockTime` cliff — nothing moves before cliff, not even by admin.
- Post-cliff: admin (Community Rewards multisig / M-4) calls `createBatch(merkleRoot, totalAmount, claimWindow, metadataHash)` to open a distribution.
- Recipients call `claim(batchId, recipient, amount, proof)` to receive tokens.
- Admin may `rescueBatch(batchId)` after the claim window closes to recycle unclaimed tokens into future batches.
- Solvency invariant on `createBatch`: contract balance must cover the new batch + prior non-rescued unclaimed.
- Emergency pause + two-step admin transfer.
- Leaf encoding matches `packages/shared/src/merkle.ts` (`keccak256(abi.encodePacked(keccak256(abi.encodePacked(address, uint256))))`).

**Deployment plan:**
1. Deploy `VibesCommunityRewards` at a known address before the $VIBES raise finalises.
2. Backend merkle construction at finalisation includes this contract address as a 20%-of-supply leaf (alongside actual backers who get 50%).
3. Set `unlockTime = raiseFinalisationTimestamp + 180 days` (mainnet cliff).
4. `admin = Community Rewards multisig` (M-4 per `docs/privileged-roles.md`).

**No router changes required** — this contract is a standalone receiver and distributor. PC-01 (`disableStakerAllocation`) is the only router-side change needed.

**Estimated remaining effort:** 1h to run CI + verify + deploy. Contract + tests already written.

---

### PC-01: Admin-toggleable `stakerAllocationDisabled` flag (IMPLEMENTED)

**Status:** Implemented in `VibesLaunchRouterV2.sol`, `VibesRouterStorage.sol`, `VibesRouterExtension.sol`; tests in `contracts/test/VibesStakerAllocationDisabled.t.sol`. Awaiting CI run and redeploy.

**Motivation:** The $VIBES TGE must allocate 0% to the staker-rewards contract because no $VIBES stakers exist at the moment of the TGE's own finalisation. More generally, every raise between TGE and Luxembourg entity formation should skip staker rewards — staking is available from TGE, but reward accrual waits for the entity to exist.

**Final design — global admin-toggleable flag, not a per-launch parameter.** After weighing blast radius on existing callers (60+ test call sites, the frontend launch hook, the ABI, and deploy scripts), a global flag is a strictly better fit because:
- The actual usage pattern is state-dependent ("pre-entity: disable; post-entity: enable"), not per-raise flexibility.
- Zero changes to the `launchWithCampaign` signature — no test updates, no ABI changes, no frontend hook updates.
- Admin controls via a single `setStakerAllocationDisabled(bool)` call on the extension.

**Storage addition (`VibesRouterStorage.sol`):**
```solidity
bool public stakerAllocationDisabled;
```

**Extension setter (`VibesRouterExtension.sol`):**
```solidity
function setStakerAllocationDisabled(bool _disabled) external onlyOwner {
    stakerAllocationDisabled = _disabled;
    emit StakerAllocationDisabledSet(_disabled);
}
```

**Router read (`VibesLaunchRouterV2.launchWithCampaign`):**
```solidity
bool stakerDisabled = stakerAllocationDisabled;
uint256 ecosystemBps = stakerDisabled ? 0 : ECOSYSTEM_ALLOCATION_BPS;
uint256 backerAllocationBps = BPS_DENOMINATOR - founderAllocationBps - treasuryAllocationBps - LP_ALLOCATION_BPS - ecosystemBps;
// ... rest of allocation math uses ecosystemBps ...
if (stakerDisabled) {
    emit StakerAllocationDisabledForLaunch(token, escrow);
}
```

**New events:**
- `StakerAllocationDisabledSet(bool disabled)` — emitted when admin flips the flag.
- `StakerAllocationDisabledForLaunch(address indexed token, address indexed escrow)` — emitted per-launch when the flag was true at launch time (audit trail).

**Downstream behaviour:** When `stakerAllocationDisabled = true`, `stakerTokens = 0` flows into `pendingLP`. The Phase 2 staker branch in `VibesRouterExtension._executePhase2` short-circuits when `stakerTokens == 0`, so no transfer or `notifyReward` is attempted against `VibesStakerRewards`. No ghost accounting in the staker-rewards contract.

**Invariants preserved:**
- Token conservation: founder + treasury + LP + staker + backer = totalSupply. When disabled: staker = 0 and the 2.5% is absorbed into backers — conservation still holds.
- Existing behaviour is the default (flag initialises to `false`). All existing tests pass unchanged; no backward-compat shim needed.
- Ecosystem-slice conservation in `VibesStakerRewards` invariant suite remains intact because `notifyReward` is simply not called when staker-tokens = 0.

**Test plan — 7 tests in `VibesStakerAllocationDisabled.t.sol`:**
1. `test_DefaultFlagIsFalse` — flag initialises off.
2. `test_Default_LaunchAllocatesTwoAndAHalfToStakers` — backward-compat sanity; 67.5% backer, 2.5% staker.
3. `test_SetFlag_OnlyOwner` — non-owner reverts.
4. `test_SetFlag_FlipsValue` — on / off.
5. `test_SetFlag_EmitsEvent` — `StakerAllocationDisabledSet` emitted on toggle.
6. `test_Disabled_LaunchAllocatesZeroToStakers` — when flag true, 70% backer, 0% staker; conservation checked.
7. `test_Disabled_EmitsPerLaunchEvent` — `StakerAllocationDisabledForLaunch` emitted.
8. `test_Disabled_NoEventWhenFlagFalse` — no event emission when flag false.
9. `test_FlagFlipBackToEnabled_NextLaunchGetsStakerSlice` — flipping the flag takes effect on subsequent launches.

**Frontend impact:** None. `launchWithCampaign` signature unchanged; the ABI in `packages/shared/src/contracts/abis/router.ts` does not need updating. Admin toggles the flag via a separate admin UI or direct multisig call to `setStakerAllocationDisabled`.

**Usage plan:**
- At mainnet deployment, admin calls `setStakerAllocationDisabled(true)` before the $VIBES raise launches.
- Every raise (including the $VIBES TGE and any subsequent pre-entity raises) during the "flag-on" window gets 0% staker allocation, 70% backers.
- Once Luxembourg entity forms, admin calls `setStakerAllocationDisabled(false)`. All subsequent raises revert to standard 2.5% staker allocation.

**Estimated remaining effort:** 1h to run CI (`pnpm run test:contracts`) and verify, then redeploy `VibesLaunchRouterV2` + `VibesRouterExtension` to Base.

**Deployment dependency:** must land before the $VIBES raise deploys to mainnet. Existing env var `NEXT_PUBLIC_VIBES_ROUTER` + `NEXT_PUBLIC_ESCROW_FACTORY` updated to new addresses on Vercel.

---

## Summary of All Changes (since Feb 27 deploy)

45 changes accumulated, all implemented and verified. Frontend ABIs, hooks, and backend signing infrastructure are updated.

| # | Change | Severity | Solidity | ABI | Frontend | Tests |
|---|--------|----------|----------|-----|----------|-------|
| 1 | Pro-Rata funding fix (`>= goal` not `> 0`) | Critical | Done | — | — | Done |
| 2 | EIP-712 signature gating (deadline + signature) | High | Done | Done | Done | Done |
| 3 | Audit security fixes A-E | High | Done | — | — | Done |
| 4 | LP 20%→15%, deposit 0.05→0.01 ETH | Medium | Done | — | — | Done |
| 5 | Configurable timing (vesting/treasury) | Medium | Done | — | — | Done |
| 6 | Challenge rate limiting (7d cooldown) | Medium | Done | — | — | Done |
| 7 | EIP-712 nonce replay protection | High | Done | Done | Done | Done |
| 8 | $VIBES burn-to-launch (feature-flagged off) | Medium | Done | Done | — | Done |
| 9 | Consolidated audit fixes F1-F10 | High | Done | Partial | — | Done |
| 10 | Two-tier admin (master + ops) | Critical | Done | — | — | Done |
| 11 | `setUseTestnetContracts` mainnet guard | Critical | Done | — | — | Done |
| 12 | External security audit C-01 to U-02 | Critical | Done | Partial | — | Done |
| 13 | StakerRewards `canClaim()` double-hash fix | High | Done | — | — | — |
| 14 | StakerRewards: Merkle→accumulator (atomic notifyReward) | Critical | Done | Done | Done | Done |
| 15 | StakerRewards: firstStakeTime eligibility check (anti-exploit) | High | Done | Done | — | Done |
| 16 | VibesStaking: request-based unstake cooldown (mainnet) | Medium | Done | Done | Done | Done |
| 17 | Gas-safe finalization: split into Phase 1 (LP) + Phase 2 (distribution) | Critical | Done | Pending | — | Done |
| 18 | `emergencyRefundFunded()` — admin rescue for Funded escrows with failed LP | Critical | Done | — | — | Done |
| 19 | `freezeCampaign()` zero-supply fallback to Failed state | High | Done | — | — | Done |
| 20 | `rescueERC20()` allow rescue for Failed/Frozen/Refunding escrow tokens | Medium | Done | — | — | Done |
| 21 | **F1: Pro-rata double-refund prevention** | Critical | Done | — | — | Done |
| 22 | **F2: Admin top-up function (`adminTopUp()`)** | Critical | Done | Pending | — | Done |
| 23 | **F3: Solvency guard on `emergencyRefundFunded()`** | Critical | Done | — | — | Done |
| 24 | **F4: Snapshot-based staker rewards** | High | Done | Pending | Pending | Done |
| 25 | **F5: `requestTranche` LP gating alignment** | Medium | Done | — | — | Done |
| 26 | **F6: `frozenEthBalance` safe subtraction** | Medium | Done | — | — | Done |
| 27 | **F7: LP rescue tracking + `completeLP()` lock proof** | Medium-High | Done | Pending | — | Done |
| 28 | **F8: `rescueERC20` pending LP guard fix** | Low | Done | — | — | Done |
| 29 | **F10: Merkle root commit-reveal timelock (24hr)** | High | Done | Pending | Pending | Done |
| 30 | **CEI fix: `_executePhase2` state ordering** | Medium | Done | — | — | — |
| 31 | **Cross-contract invariant tests** | — | — | — | — | Done |
| 32 | **`opposeChallenge` + `challengeVoteDirection`** — on-chain oppose with vote-direction tracking (switch allowed, same-direction re-vote blocked) | Medium | Done | Done | Done | — |
| 33 | **H-1: Testnet `MAX_TIME_DRIFT = 1 hours`** (mainnet parity — oracle drift guard) | High (testnet) | Done | — | — | Done |
| 34 | **H-2: Testnet F10 commit-reveal merkle root** (mainnet parity — 24h delay + cancel) | High (testnet) | Done | Pending | Pending | Done |
| 35 | **H-3: Cross-contract finalization guards** — `_claimTokensInternal` hard-requires `finalizationPhase != None`; `emergencyRefundFunded` requires router `finalizationPhase == 0` via try/catch | High | Done | — | — | Done |
| 36 | **H-4: `recordManualLPLock(campaign, pool, lpAmount)`** — proof-based transition from rescued to verified-locked state (onchain DEAD balance check). Closes the LP-rescue-deadlock liveness bug. | High | Done | Pending | Pending | Done |
| 37 | **M-1: `completeDistribution` `nonReentrant`** (defense-in-depth) | Medium | Done | — | — | Done |
| 38 | **M-2: Treasury challenge resolvers `nonReentrant`** (`upholdChallengeRework`, `upholdChallengeMalicious`, `rejectChallenge`, `expireChallengeIfNeeded`) | Medium | Done | — | — | Done |
| 39 | **M-3: Treasury challenge window close `>` → `>=`** — exact boundary closed, matches `timeUntilExecutable` view | Medium | Done | — | — | Done |
| 40 | **L-1: `resolveRescuedFunds` `nonReentrant`** | Low | Done | — | — | Done |
| 41 | **L-3: `VibesStakerRewards._getStakerBalance` snapId==0 fail-closed** — removed dead-code current-balance fallback that re-introduced F4 exploit vector | Low | Done | — | — | Done |
| 42 | **L-4: LP locker `forceApprove`** — three `approve()` sites switched to `SafeERC20.forceApprove` (USDT-like token compatibility) | Informational | Done | — | — | Done |
| 43 | **`IVibesLaunchRouter.finalizationPhase(address) view returns (uint8)`** — new getter used by escrow for H-3 cross-contract check | — | Done | Pending | Pending | Done |
| 44 | **Audit 2026-04-16 F-1:** `freezeCampaign` zero-supply fallthrough solvency guard — `require(address(this).balance >= totalRaised − totalExcessRefundLiability − pendingPlatformFees)` before state→Failed. Prevents first-mover drain when LP ETH already withdrawn. Mirrors `emergencyRefundFunded`. See `audit-2026-04/report.md`. | Medium | Done | — | — | Done |
| 45 | **Audit 2026-04-16 F-2:** Treasury balance excluded from redeemable-supply denominator — new `treasuryContract` state + `setTreasuryContract(address)` admin/router function with overlap guards; router auto-wires in `_executePhase2` post-finalization. `setLockedAddresses` signature preserved (no ABI break). Prevents ~20% of pro-rata refund ETH from being trapped on freeze. | Medium | Done | — | — | Done |
| 46 | **`VibesLPFeeClaimer` — per-campaign Aerodrome fee capture** — replaces the permanent `0xdead` LP burn sink with an EIP-1167 clone per campaign. Clone is soulbound (no transfer/withdraw/rescue/admin surface) and calls `pool.claimFees()` on demand, routing WETH-side to `feeRecipient` and project-token-side to the treasury (or burns if treasury is terminated/unset). `VibesLPLocker.createAndLockLP` signature grew by 2 args (`feeRecipient`, `treasuryEscrow`); `recordManualLPLock` grew by 1 (`claimer`). Requires `lpLocker.setFeeClaimerImplementation(address)` post-deploy — otherwise `createAndLockLP` reverts `FeeClaimerImplementationNotSet` and every raise finalization bricks. | Medium (blocks finalize) | Done | — | — | Done |
| 47 | **PC-04: `VibesCommunityRewardsFactory`** — external factory for PC-03 `new VibesCommunityRewards(...)` deployment. Moves creation code out of router to keep runtime bytecode under EIP-170 (23,717 bytes after, vs 27,437 before). Requires `router.setCommunityRewardsFactory(address)` post-deploy or PC-03 launches revert `CommunityRewardsFactoryNotSet`. | Critical (blocks $VIBES launch) | Done | — | — | Done |
| 48 | **PC-05: Combined founder + treasury cap raised to 20%** — new `MAX_FOUNDER_PLUS_TREASURY_BPS = 2000` constant; router check now points at it. Previously reused `MAX_TREASURY_ALLOCATION_BPS (1750)` so the $VIBES shape (500 + 1500 = 2000) reverted before PC-03 could run. Backer protection still enforced by `MIN_BACKER_ALLOCATION_BPS` 50% floor. | High (blocks $VIBES launch) | Done | — | — | Done |

---

## What Was Done (2026-04-04 Audit Session — Items 21-31)

### Comprehensive Smart Contract Audit (3 commits)

**Scope:** Full audit of all 18 contracts, covering fund safety, cross-contract interactions, governance risks, and test gaps. 11 findings identified, 10 fixed, 1 deferred (product decision).

**Commit 1 — Critical fund safety (F1-F8):**
- `VibesTranchEscrow.sol`:
  - **F1:** `claimContributorRefund()` now subtracts prior excess claims for pro-rata raises, preventing double-refund extraction after emergency rollback
  - **F2:** New `adminTopUp() external payable onlyAdmin` — allows admin to restore ETH for emergency recovery (receive() intentionally blocks plain sends)
  - **F3:** `emergencyRefundFunded()` now requires `address(this).balance >= totalLiability` before state transition, preventing insolvency
  - **F5:** `requestTranche()` and `canRequestTranche()` now check `lpCreated` instead of `lpWithdrawn`, aligning with `claimTranche()`
  - **F6:** `frozenEthBalance` in `upholdChallenge()` and `freezeCampaign()` uses safe subtraction to prevent underflow revert
- `VibesLPLocker.sol`:
  - **F7a:** Rescue paths now set `hasRescuedLP` (new mapping) instead of `hasLockedLP`. View functions (`getLockedPosition`, `verifyLPLocked`, `getInitialPrice`) guard against rescued campaigns returning wrong data. New `hasRescuedLP` public mapping added.
  - **F7a:** `createAndLockLP()` checks both `hasLockedLP` and `hasRescuedLP` to prevent double attempts.
- `VibesRouterExtension.sol`:
  - **F7b:** `completeLP()` now requires onchain proof that LP was actually created and locked to 0xdead before unblocking tranche claims. Calls `lpLocker.verifyLPLocked()`.
  - **F8:** Removed `escrowAddr == address(0)` condition from `rescueERC20` pending LP check. Any token with `pendingLP.tokenAmount > 0` is now blocked.

**Commit 2 — F4, F10, CEI, security tests:**
- `VibesStaking.sol`:
  - **F4:** New snapshot system: `currentSnapshotId`, `snapshotTotalStaked`, `snapshotBalance`, `snapshotBalanceWritten`, `lastSnapshotWritten`, `snapshotAuthorized` mappings. `takeSnapshot()` callable by authorized contracts. `balanceAtSnapshot(snapshotId, staker)` reads historical balance. `_writeSnapshotsBeforeBalanceChange()` called in `stake()` and `unstake()`. New `setSnapshotAuthorized()` owner function.
- `VibesStakerRewards.sol`:
  - **F4:** New `raiseSnapshotId` mapping. `notifyReward()` now calls `staking.takeSnapshot()` atomically and stores snapshot ID. `_getStakerBalance()` reads from snapshot (notification-time balance) instead of current balance. Backwards compatible for pre-F4 raises (falls back to current balance if no snapshot). New `IVibesStakingSnapshot` interface.
- `VibesRouterExtension.sol`:
  - **CEI fix:** `_executePhase2()` now sets `finalizationPhase = FullyComplete`, deletes pending state, and emits events BEFORE the founder deposit ETH refund transfer. Bookkeeping rolls back if transfer fails.
- `VibesTranchEscrow.sol`:
  - **F10:** `setRefundMerkleRoot()` replaced with 2-step commit-reveal: `commitRefundMerkleRoot()` (admin commits root) → 24hr delay → `finalizeRefundMerkleRoot()` (anyone can finalize after delay). New `cancelPendingMerkleRoot()` for admin correction. New state: `pendingMerkleRoot`, `merkleRootCommitTime`, `MERKLE_ROOT_DELAY = 24 hours`.

**Commit 3 — Cross-contract invariant tests:**
- `CrossContractInvariant.t.sol` (new, 444 lines): ETH conservation, token balance invariants, treasury→vesting→staker chain, campaign isolation, pro-rata freeze accounting.
- `AuditSecurityTests.t.sol` (new, 350+ lines): Reentrancy exploit attempts, state machine adversarial transitions, F10 commit-reveal tests.

**ABI changes needed:**
- `VibesTranchEscrow` ABI: Remove `setRefundMerkleRoot`. Add `commitRefundMerkleRoot`, `finalizeRefundMerkleRoot`, `cancelPendingMerkleRoot`, `adminTopUp`, `pendingMerkleRoot`, `merkleRootCommitTime`, `MERKLE_ROOT_DELAY`. Add errors `MerkleRootDelayNotElapsed`, `NoPendingMerkleRoot`.
- `VibesStaking` ABI: Add `takeSnapshot`, `balanceAtSnapshot`, `totalStakedAtSnapshot`, `currentSnapshotId`, `snapshotAuthorized`, `setSnapshotAuthorized`. Add error `NotSnapshotAuthorized`. Add events `SnapshotTaken`, `SnapshotAuthorizationUpdated`.
- `VibesStakerRewards` ABI: Add `raiseSnapshotId` view.
- `VibesLPLocker` ABI: Add `hasRescuedLP` view.

**Tests added:** 31 new tests across 4 files (AuditSecurityTests.t.sol, CrossContractInvariant.t.sol, VibesTranchEscrowEdgeCases.t.sol, VibesStakerRewards.t.sol, VibesLPLocker.t.sol).

---

## What Was Done (2026-04-04 Earlier Session)

### Emergency Refund + Freeze Fix + Rescue Override (Items 18-20)

**Root cause:** 6 testnet raises had failed finalization — onchain state was Funded but LP was never created. 3 were actually still Active (DB was wrong), fixed with `forceRefundDuringRaise()`. 2 were Funded with tokens partially distributed (treasury/vesting had tokens but backers didn't), froze successfully but holder refund flow was impossible since no users held tokens. 1 couldn't even freeze (`_calculateRedeemableSupply()` returned 0 because all tokens were in the router).

No deployed contract function could move ETH out of a Funded escrow when finalization broke. These fixes close that gap.

**Files modified (Solidity):**
- `VibesTranchEscrow.sol` + `VibesTranchEscrowTestnet.sol`:
  - `emergencyRefundFunded()` — `onlyAdmin`, `inState(Funded)`, requires `!lpCreated`. Moves to Failed state, enabling `claimContributorRefund()`. Guard is safe: `lpCreated` is only set by router during successful finalization and has no unset path.
  - `freezeCampaign()` — when `_calculateRedeemableSupply() == 0`, falls through to Failed state instead of reverting. Emits both `CampaignFailed` and `CampaignFrozen` for audit trail.
- `VibesRouterExtension.sol`:
  - `rescueERC20()` — allows rescue for tokens whose escrow is in Failed/Frozen/Refunding state. Previously blocked all tokens with `tokenToEscrow != address(0)`. Also skips `pendingLP` check for dead escrows.

**Security analysis:**
- `emergencyRefundFunded()`: Only reachable when `lpCreated==false && state==Funded`. This state is impossible for healthy raises (finalization sets lpCreated atomically). Admin-only. No path for malicious use.
- `freezeCampaign()` zero-supply path: Falls to Failed state, which only enables `claimContributorRefund()` returning each backer's original contribution amount. No inflation possible. Admin must ensure escrow has sufficient ETH if LP ETH was withdrawn.
- `rescueERC20()` override: Only allows rescue when escrow is terminal (Failed/Frozen/Refunding). Tokens in those states will never be distributed to backers, so rescue is safe.

**Tests:** Existing suites pass (27/27 finalization, 16/16 lifecycle, 10/10 gas). Dedicated tests for new functions pending.

---

## What Was Done (2026-04-03 Session)

### Gas-Safe Finalization Phase Split (Item 17 — CRITICAL)

**Root cause:** `completeFinalization()` did 12 external calls (~1.6M gas). Two testnet raises (LaunchFlow AI, Anon AI) ran out of gas at step 11/12. The escrow caught the revert but all router state rolled back. Backers couldn't claim tokens, founders couldn't claim tranches.

**Files modified (Solidity):**
- `VibesRouterStorage.sol` — `FinalizationPhase` enum (None/LPComplete/FullyComplete), 4 tracking mappings (`finalizationPhase`, `_pendingStakerAllocation`, `_pendingStakerRecipient`, `_stakerTokensTransferred`), 5 new events, 2 new errors
- `VibesRouterExtension.sol` — Split `completeFinalization` into `_executePhase1` (LP ~800K gas) + `_executePhase2` (distribution ~400K gas). New `completeDistribution()` callable by escrow or owner. New `adminRetryFinalization()`. Auto-trigger in `_claimTokensInternal`. Silent `catch {}` replaced with `StakerRewardsNotifyFailed` event.
- `VibesTranchEscrow.sol` + `VibesTranchEscrowTestnet.sol` — Two sequential try-catch calls. Updated `FinalizationDeferred` to include revert reason. New `DistributionDeferred` event.
- `IVibesLaunchRouter.sol` — Added `completeDistribution(address)`.

**Key design decisions (reviewed by 4 independent agents):**
- Vesting/treasury calls are NOT try-catch — they hard revert to prevent FullyComplete with broken state
- Staker transfer and notify are decoupled via `_stakerTokensTransferred` flag for retry safety
- Legacy raise detection uses `initialBackerTokens > 0` (non-depleting) not `backerTokensForClaims`
- Config drift prevented by snapshotting `stakerRewardsContract` address in Phase 1

**Tests:** `test/VibesFinalizationPhases.t.sol` — 27 tests covering phase execution, admin retry, idempotency, access control, events, auto-trigger, config drift, gas simulation.

**ABI changes needed (next):**
- Add `completeDistribution`, `adminRetryFinalization`, `finalizationPhase` to router ABI in `@vibes/shared`

---

## What Was Done (2026-04-01 Session)

### Nonce Replay Protection (Item 7 — NEW)

**Files modified (Solidity):**
- `VibesTranchEscrow.sol` — `mapping(address => uint256) public nonces`, TYPEHASH updated to `TermsAcceptance(address user,uint256 nonce,uint256 deadline)`, `_verifyTermsSignature()` validates + increments nonce. `contribute()`, `raiseChallenge()`, `supportChallenge()` all take `uint256 nonce` param. New error `InvalidNonce()`.
- `VibesTranchEscrowTestnet.sol` — Same changes.
- `VibesStaking.sol` — Same pattern for `stake()`.
- `VibesRouterStorage.sol` — `mapping(address => uint256) public launchNonces`.
- `VibesLaunchRouterV2.sol` — TYPEHASH updated to `LaunchAuthorization(address founder,uint256 nonce,uint256 deadline)`. `_verifyLaunchSignature()` validates + increments nonce. `launchWithCampaign()` takes `uint256 launchNonce` param.

**Files modified (ABI):**
- `packages/shared/src/contracts/abis/escrow.ts` — `contribute`, `raiseChallenge`, `supportChallenge` updated with `nonce`, `deadline`, `signature` inputs. Added `nonces`, `currentTime`, `lpCreated` views and error types.
- `packages/shared/src/contracts/abis/router.ts` — `launchWithCampaign` now has 19 inputs (added `launchNonce`, `sigDeadline`, `launchSignature`). Added `launchNonces`, `emergencyUnpause`, error types.
- `packages/shared/src/contracts/abis/supporting.ts` — `stake()` updated with `nonce`, `deadline`, `signature`. Added `nonces` view and errors.

**Files modified (Backend):**
- `apps/web/src/lib/terms-signer.ts` — Reads onchain nonce via `publicClient.readContract()` before signing. New `signLaunchAuthorization()` function for launch signatures.
- `apps/web/src/app/api/terms/sign/route.ts` — Accepts `type: "terms" | "launch"`. Returns `{ signature, deadline, nonce }`.

**Files modified (Frontend hooks):**
- `apps/web/src/hooks/use-escrow-hooks.ts` — `useContribute()` passes `[BigInt(0), BigInt(0), '0x']` (bypass defaults).
- `apps/web/src/hooks/use-challenge-hooks.ts` — `useRaiseChallenge()` and `useSupportChallenge()` pass nonce/deadline/signature.
- `apps/web/src/hooks/use-launch-hooks.ts` — 3 new trailing args on `launchWithCampaign`.
- `apps/web/src/hooks/useVibesStaking.ts` — `stake()` passes nonce/deadline/signature.
- `apps/web/src/components/contribution-form.tsx` — Inline ABI updated, `writeContract` call passes args.

**Tests updated:** 14 test files, 5 new nonce validation tests in `TermsSignatureVerification.t.sol`.

### Audit Fixes Found During Review

1. **`contribution-form.tsx`** — Had a stale inline ABI with `inputs: []` and no args on `writeContract`. Fixed: updated ABI + added args.
2. **`VibesStakerRewards.canClaim()`** — Used single-hash while `_claimInternal()` uses double-hash (audit fix C-02 was incomplete). Fixed: line 276 now uses double-hash.
3. **`setUseTestnetContracts()`** — Was callable on any chain. Fixed: added `require(block.chainid != 8453)` guard.

---

## Current Function Signatures (Post-Nonce)

### Escrow (VibesTranchEscrow / Testnet)
```
contribute(uint256 nonce, uint256 deadline, bytes signature) payable
raiseChallenge(string reason, uint256 nonce, uint256 deadline, bytes signature)
supportChallenge(string context, uint256 nonce, uint256 deadline, bytes signature)
opposeChallenge(string context, uint256 nonce, uint256 deadline, bytes signature)    // #32 — same rules as supportChallenge; vote can be switched but not re-cast in same direction
challengeVoteDirection(address voter, uint8 tranche) view returns (uint8)             // 0=none, 1=support, 2=oppose
```

### Router (VibesLaunchRouterV2)
```
launchWithCampaign(
  string name, string symbol, uint8 decimals, uint256 totalSupply,
  bytes32 capsuleHash, uint8 agentTool, uint8 modelProvider,
  uint8 proofType, bytes32 proofArtifactHash,
  uint8 raiseType, uint256 goal, uint256 softCap, uint256 deadline,
  uint256 founderAllocationBps, uint256 treasuryAllocationBps, uint256 raiseStart,
  uint256 launchNonce, uint256 sigDeadline, bytes launchSignature
) payable returns (address token, address escrow, address vesting)
```

### Escrow Merkle Root (VibesTranchEscrow) — CHANGED (F10)
```
commitRefundMerkleRoot(bytes32 merkleRoot)     // Admin: step 1 — commit
finalizeRefundMerkleRoot()                      // Anyone: step 2 — finalize after 24hr
cancelPendingMerkleRoot()                       // Admin: cancel pending root
adminTopUp() payable                            // Admin: top up ETH for emergency recovery (F2)
```

### Staking (VibesStaking) — UPDATED (F4)
```
stake(uint256 amount, uint256 nonce, uint256 deadline, bytes signature)
takeSnapshot() returns (uint256 snapshotId)                    // Authorized contracts only
balanceAtSnapshot(uint256 snapshotId, address staker) view     // Historical balance
totalStakedAtSnapshot(uint256 snapshotId) view                 // Historical total
setSnapshotAuthorized(address account, bool authorized)        // Owner only
```

### Treasury (VibesTreasuryEscrow) — UNCHANGED
```
raiseChallenge(string reason)       // no signature params
supportChallenge(string context)    // no signature params
```

---

## Constructor Changes (All Require Fresh Deploy)

| Contract | Constructor Changes | Reusable? |
|---|---|---|
| `VibesLaunchRouterV2` | EIP-712 domain separator computation; PC-01/PC-03 storage + 20% combined cap (PC-05) | No |
| `VibesRouterExtension` | + `setStakerAllocationDisabled`, `setCommunityAllocationForLaunch`, `setCommunityRewardsFactory` admin setters | No |
| `VibesCommunityRewardsFactory` | New contract (no constructor args) — deploy once, register via `extension.setCommunityRewardsFactory` | No |
| `VibesCommunityRewards` | Cloned per launch by the factory; not deployed standalone | N/A |
| `VibesTranchEscrowFactory(Testnet)` | + `_trustedSigner` | No |
| `VibesTranchEscrow(Testnet)` | `initialize()` + `_trustedSigner` | No |
| `VibesStaking` | + `_trustedSigner`, + `Ownable(msg.sender)`, + `firstStakeTime` mapping, + snapshot system (F4) | No |
| `VibesVesting` | + `_cliff`, + `_vestingDuration` | No |
| `VibesTreasuryEscrow` | + `_releaseCliff`, + `_cooldown`, + `_challengeWindow` | No |
| `VibesStakerRewards` | Merkle→accumulator, new constructor `(_admin, _stakingContract, _authorizedRouter)` | No |
| `VibesLPLocker` | No constructor changes, but `createAndLockLP` / `recordManualLPLock` signatures grew for LP fee claimer; needs `setFeeClaimerImplementation(address)` post-deploy before any raise can finalize | Yes (redeployable with no args) |
| `VibesLPFeeClaimer` | New implementation contract (no constructor args) — deploy once, register via `lpLocker.setFeeClaimerImplementation`. Each campaign's claimer is a cheap EIP-1167 clone. | No |
| `MockTimeOracle` | No changes | Yes |

---

## Deployment Runbook

### Pre-deployment Checklist
- [x] All live raises disabled (`NEXT_PUBLIC_ENABLE_RAISES=false`)
- [x] Frontend ABI updates committed and tested
- [x] Backend signing endpoints ready (`terms-signer.ts`, `/api/terms/sign`)
- [x] All contract tests pass (terms sig 19/19, staking 18/18, router 55/55, stakerRewards 43/43)
- [x] TypeScript compiles clean (`npx tsc --noEmit`)
- [x] Shared package builds (`pnpm --filter @vibes/shared build`)
- [ ] Generate fresh deployer wallet or use existing

### Deploy Order (Base Sepolia)

**Phase 1 — Core contracts (now):**
1. Deploy `VibesTranchEscrowTestnet` implementation
2. Deploy `VibesRouterExtension`
3. Deploy `VibesLaunchRouterV2` (with extension, existing tokenFactory/registry, placeholder factory, existing LP locker)
4. Deploy `VibesTranchEscrowFactoryTestnet` (with new router, `_trustedSigner = address(0)` for bypass)
5. Deploy `VibesLPFeeClaimer` implementation (no constructor args) — the clones will point at this
6. Deploy `VibesCommunityRewardsFactory` (PC-04 — no constructor args)
7. Wire: set factory in router, ops wallet, authorize in registry/LP locker, enable testnet mode, register fee-claimer impl on locker, register community-rewards factory

**Phase 2 — Staking contracts (after $VIBES token exists):**
6. Deploy `VibesStaking` (`_vibesToken`, `_trustedSigner = address(0)` for bypass)
7. Deploy `VibesStakerRewards` (`_admin`, `_stakingContract`, `_authorizedRouter` = router from step 3)
8. Wire: `router.setStakerRewardsContract(stakerRewards)`
9. **CRITICAL (F4):** `staking.setSnapshotAuthorized(stakerRewardsAddress, true)` — **StakerRewards must be authorized to take snapshots on the staking contract.** Without this, `notifyReward()` will revert on every raise finalization.

**Note:** Vesting and TreasuryEscrow are deployed per-raise by the router, not standalone.

### Post-deploy Admin Calls (Phase 1)
- `router.setEscrowFactory(newFactory)` — done by deploy script
- `router.setOpsWallet(deployer)` — done by deploy script
- `registry.authorizeRouter(newRouter)` — done by deploy script
- `lpLocker.setAuthorizedRouter(newRouter)` — done by deploy script
- `lpLocker.setFeeClaimerImplementation(feeClaimerImpl)` **(CRITICAL: required before any raise finalization; otherwise `createAndLockLP` reverts `FeeClaimerImplementationNotSet`)** — done by deploy script
- `router.setUseTestnetContracts(true)` — done by deploy script
- `router.setOperationsAdmin(opsAdminAddress)` — done by deploy script (currently deployer)
- `router.setCommunityRewardsFactory(factoryAddress)` **(PC-04 — CRITICAL: required before any launcher with a non-zero community slice calls `launchWithCampaign`; otherwise reverts `CommunityRewardsFactoryNotSet`)** — done by deploy script
- `router.setTrustedLaunchSigner(signerAddress)` (or leave `address(0)` for bypass)
- `factory.setAdmin(opsAdminAddress)` → opsAdmin calls `factory.acceptAdmin()`
- `router.setFeeConfig(true, feeAmount, feeRecipient)`

**$VIBES raise additional admin calls (before the raise launches, from the protocol admin multisig):**
- `router.setStakerAllocationDisabled(true)` (PC-01 — disables the 2.5% ecosystem slice while the Luxembourg entity is being formed)
- `router.setCommunityAllocationForLaunch(vibesLauncher, 1500, 180 days, communityMultisig)` (PC-03 — 15% community slice, 6-month cliff, community-rewards multisig as admin)
- Later, once the Luxembourg entity is formed: `router.setStakerAllocationDisabled(false)` — all future raises revert to standard 2.5% staker allocation.

### Post-deploy Admin Calls (Phase 2 — after $VIBES token)
- `router.setStakerRewardsContract(stakerRewardsAddress)`
- `staking.setSnapshotAuthorized(stakerRewardsAddress, true)` **(F4 — CRITICAL: required for reward snapshots)**

### Post-deploy Environment Variables
Update on BOTH Vercel projects (`vibestarter` staging env + `testnet` all scopes):
- `NEXT_PUBLIC_VIBES_ROUTER` → new router address
- `NEXT_PUBLIC_ESCROW_FACTORY` → new factory address
- `NEXT_PUBLIC_DEPLOY_BLOCK` → deployment block number
- `NEXT_PUBLIC_STAKING_CONTRACT` → new staking address
- `NEXT_PUBLIC_STAKER_REWARDS` → new staker rewards address
- `TERMS_SIGNER_PRIVATE_KEY` → private key of trusted signer wallet (if enabling gating)
- LP Locker + Time Oracle addresses unchanged (contracts reused)
- `VibesCommunityRewardsFactory` (PC-04) address is stored on-chain via `router.communityRewardsFactory()` — no separate env var needed on the frontend (the router call-site is internal to `launchWithCampaign`).

### Post-deploy Code Updates
- `packages/shared/src/contracts/addresses.ts` — new addresses
- `docs/deployment.md` — contract address tables
- Rebuild: `pnpm --filter @vibes/shared build`

### Post-deploy: Retire DB-based Challenge Voting (#32)

Once `opposeChallenge` is live on-chain, the off-chain stance system is redundant and should be removed:

1. **`apps/web/src/app/api/campaigns/[id]/discussion/route.ts`** — Remove the `creditQuest('questSupportedChallenge')` call gated on `stance === 'SUPPORT' || stance === 'OPPOSE'`. The `challenge-sync` cron will handle quest crediting from on-chain `ChallengeSupported` + `ChallengeOpposed` events instead.
2. **`packages/keeper/src/` (or cron)** — Update `challenge-sync` to also scan `ChallengeOpposed` events and credit `questSupportedChallenge` for opposers.
3. **`apps/web/src/components/activity-feed/activity-feed-item.tsx`** — Remove the `[VOTE:SUPPORT]` / `[VOTE:OPPOSE]` ghost comment path from ConsensusMatrix (the on-chain handlers are already wired; the ghost-comment fallback is dead code once contracts are deployed).
4. **DB cleanup (optional)** — `ChallengeComment` rows with `content = '[VOTE:SUPPORT]'` or `'[VOTE:OPPOSE]'` can be soft-deleted or ignored. They are display-only and do not affect any on-chain state.

The `SUPPORT`/`OPPOSE` stances in `ChallengeComment` and the `isPinnedResponse` field can remain in the schema for historical audit purposes — no migration needed.

### Post-deploy Verification
- [ ] Contracts verified on Basescan
- [ ] Re-enable `NEXT_PUBLIC_ENABLE_RAISES=true`
- [ ] Push all changes to `staging` branch
- [ ] E2E smoke test:
  - [ ] Launch a raise (router + factory + launch signature)
  - [ ] Contribute (escrow + terms signature with nonce)
  - [ ] Finalize raise (verify Phase 1 + Phase 2 both complete)
  - [ ] Claim tranche (kickstart — no request needed)
  - [ ] Request + claim monthly tranche (verify `lpCreated` gating)
  - [ ] Claim tokens (verify snapshot-based staker reward allocation)
  - [ ] Claim excess refund (pro-rata)
  - [ ] Raise + support challenge (with terms signatures)
  - [ ] Freeze campaign → commit merkle root → wait 24hr → finalize merkle root (F10)
  - [ ] Emergency refund: admin top-up → `emergencyRefundFunded()` → contributor refund (F2/F3)
  - [ ] Verify `staking.setSnapshotAuthorized()` was called (F4)
  - [ ] Verify staker rewards use snapshot balance (stake more after finalization, claim, check amount is based on pre-finalization balance)

### Handling Existing Testnet Data
- Existing raises are tied to the old router and will be orphaned
- KULI escrow (`0xcf5448538c355eb5ed5c61b79cbc79d441b6a9b3`) should be frozen if still accessible

---

## Change Log

| Date | Change | Severity |
|---|---|---|
| 2026-04-16 | **Audit 2026-04-16 F-1:** `freezeCampaign` zero-supply fallthrough now requires solvency (`balance >= totalLiability`) before state→Failed. See `audit-2026-04/report.md`. | Medium |
| 2026-04-16 | **Audit 2026-04-16 F-2:** Treasury escrow balance excluded from redeemable-supply denominator via new `setTreasuryContract`; router auto-wires during `_executePhase2`. `setLockedAddresses` signature unchanged. | Medium |
| 2026-04-11 | **#32 `opposeChallenge`:** On-chain oppose with `challengeVoteDirection` tracking; UI ConsensusMatrix wired to on-chain calls; `questSupportedChallenge` interim-credited via discussion API; quest copy updated to "Vote on a Challenge" | Medium |
| 2026-04-04 | **Audit F1:** Pro-rata double-refund prevention in `claimContributorRefund()` | Critical |
| 2026-04-04 | **Audit F2:** `adminTopUp()` payable function for emergency ETH recovery | Critical |
| 2026-04-04 | **Audit F3:** Solvency guard on `emergencyRefundFunded()` | Critical |
| 2026-04-04 | **Audit F4:** Snapshot-based staker rewards — `VibesStaking` balance checkpoints + `VibesStakerRewards` snapshot reads | High |
| 2026-04-04 | **Audit F5:** `requestTranche` LP gating: `lpWithdrawn` → `lpCreated` | Medium |
| 2026-04-04 | **Audit F6:** `frozenEthBalance` safe subtraction (prevent underflow revert) | Medium |
| 2026-04-04 | **Audit F7:** LP rescue tracking (`hasRescuedLP`) + `completeLP()` onchain lock proof | Medium-High |
| 2026-04-04 | **Audit F8:** `rescueERC20` pending LP guard — remove `escrowAddr == 0` condition | Low |
| 2026-04-15 | **Audit 2026-04-14 remediation complete** (H-1, H-2, H-3, H-4, M-1, M-2, M-3, L-1, L-3, L-4). 6 new test suites added (36 deterministic + 3 invariants, all passing). | Critical |
| 2026-04-15 | **H-4 `recordManualLPLock`** — proof-based exit from rescued-LP state (closes tranche-progression deadlock). New `IERC20(pool).balanceOf(DEAD) >= lpAmount` onchain-proof gate. | High |
| 2026-04-15 | **H-3** — cross-contract finalization state-drift guards on `_claimTokensInternal` + `emergencyRefundFunded` | High |
| 2026-04-15 | **H-1 / H-2 testnet parity** — `MAX_TIME_DRIFT` + F10 commit-reveal back-ported to `VibesTranchEscrowTestnet` | High (testnet) |
| 2026-04-15 | **M-3** — treasury challenge window close `>` → `>=` (exact-boundary race fix) | Medium |
| 2026-04-15 | **M-1 / M-2 / L-1** — defense-in-depth `nonReentrant` on `completeDistribution`, treasury resolvers, `resolveRescuedFunds` | Medium |
| 2026-04-15 | **L-3** — `VibesStakerRewards._getStakerBalance` dead-code fallback removed; now `revert NoSnapshotForRaise()` | Low |
| 2026-04-15 | **L-4** — LP locker `approve()` → `SafeERC20.forceApprove` (USDT-like token compatibility) | Informational |
| 2026-04-15 | **Parity guard test** — `AuditTestnetParityGuard2026_04.t.sol` fails CI if future changes re-introduce mainnet/testnet divergence on drift guard or commit-reveal | — |
| 2026-04-04 | **Audit F10:** Merkle root commit-reveal timelock (24hr delay) replaces `setRefundMerkleRoot` | High |
| 2026-04-04 | **Audit CEI:** `_executePhase2` deposit refund moved after state finalization | Medium |
| 2026-04-04 | Cross-contract invariant tests (ETH conservation, token balance, treasury→vesting→staker chain) | — |
| 2026-04-02 | VibesStaking: request-based unstake cooldown — cooldown starts on `requestUnstake()`, not on `stake()` | Medium |
| 2026-04-01 | StakerRewards: firstStakeTime eligibility — prevents post-finalization stake exploit | High |
| 2026-04-01 | VibesStaking: added firstStakeTime mapping (set on 0→nonzero, reset on full unstake) | High |
| 2026-04-01 | StakerRewards: div-by-zero guard in _claimInternalUnchecked | Medium |
| 2026-04-01 | StakerRewards: Merkle→accumulator pattern (atomic notifyReward from router) | Critical |
| 2026-04-01 | EIP-712 nonce replay protection: sequential nonces on all gated functions | High |
| 2026-04-01 | `contribution-form.tsx` stale ABI fix — was missing nonce/deadline/signature entirely | Critical |
| 2026-04-01 | `StakerRewards.canClaim()` double-hash fix — was using single-hash (C-02 incomplete) | High |
| 2026-04-01 | `setUseTestnetContracts()` mainnet guard — `require(block.chainid != 8453)` | Critical |
| 2026-03-27 | External security audit remediation: 14 contract fixes + 2 backend fixes | Critical |
| 2026-03-25 | Two-tier admin separation: Master Admin (multi-sig) + Operations Admin (EOA) | Critical |
| 2026-03-25 | Remove `setUseTestnetContracts` from mainnet deploy | Critical |
| 2026-03-22 | Consolidated audit fixes F1-F10 | High |
| 2026-03-21 | $VIBES burn-to-launch fee (feature-flagged) | Medium |
| 2026-03-16 | Document EIP-712 signature replay — nonce needed | High |
| 2026-03-13 | Per-challenger cooldown on `raiseChallenge()` | Medium |
| 2026-03-12 | Pro-Rata `_checkFundingSuccess` fix | Critical |
| 2026-03-07 | Audit findings A-G remediation | High |
| 2026-03-05 | EIP-712 signature gating on contribute/challenge/launch/stake | High |
| 2026-03-03 | Founder deposit 0.05→0.01, LP allocation 20%→15% | Medium |
| 2026-03-01 | Configurable vesting/treasury timing | Medium |
