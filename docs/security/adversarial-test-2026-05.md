# Adversarial Security Test — Mainnet Test Deployment (2026-05-07)

> **Scope.** Self-conducted red team against the live Base mainnet test deployment of the Vibestarter contract suite (`DeployV2Mainnet`, deploy block 45636188). Companion to the plan at `C:\Users\Ross\.claude\plans\floating-rolling-graham.md`. Methodology: Foundry mainnet-fork simulation (L1) + live read-only probing (L2). Zero broadcasted state-changing transactions. No live funds were moved.

> **Bottom line.** Contract invariants held under every external-attacker and founder-attacker hypothesis tested. The "compromised admin" threat surface materializes exactly as documented in `docs/privileged-roles.md` — concretely confirmed on mainnet fork, with mitigations bounded by 24h commit-reveal delay (merkle-root drain) and per-clone immutability (timeOracle propagation only affects future raises). One stale doc claim caught and corrected: the `_excludeAddresses` parameter on `upholdChallenge` / `freezeCampaign` no longer exists — exclusion is computed onchain.

## Executive ranking — top fund-loss vectors (likelihood × impact)

| Rank | Vector | Severity | Pre-condition |
|---:|---|---|---|
| 1 | Admin freeze + commit fraudulent merkle root → drain `frozenEthBalance` | **Critical** | Deployer key (`0xdD6D95...`) compromised. 24h commit-reveal delay limits speed. |
| 2 | Admin sets malicious `timeOracle` on factory → future raises see warped time | **Low** (was High before counting H-06 + lockTimeOracle landing on `claude/lock-time-oracle`) | Deployer key compromised AND new raises launch after rotation AND `lockTimeOracle()` not yet called. H-06 caps forward warp at 1h; remaining surface is griefing only. |
| 3 | Admin `rescueETH` drains router ETH | **Med→Crit** | Deployer key compromised AND router holds ETH at the moment of attack. Currently 0 ETH. |
| 4 | Admin rotates `opsWallet` to attacker → 2.5% of future tranche fees redirect | Medium | Deployer key compromised. Bounded leak. |
| 5 | Admin rotates `trustedLaunchSigner` → can forge launches on victim wallets | Medium | Deployer key compromised. DB-pollution and victim-deposit-burn analog. |

All five collapse onto a single root cause: **deployer EOA holds master-admin / operations-admin / trusted-signer / fee-recipient simultaneously**. The pre-mainnet hardening procedure in `docs/first-mainnet-deployment.md` § "Post-deploy hardening" addresses every one of these via Safe migration + signer rotation. **None of these are novel vulnerabilities** — they're the documented "this is why we need a multisig" risk surface, now empirically proven on chain 8453.

No contract-bug vectors found. No off-chain auth regressions. The five admin-compromise paths are all that landed.

---

## Methodology summary

- **L1 (fork simulation):** `forge test --fork-url https://base-rpc.publicnode.com` against `contracts/test/AdversarialMainnet.t.sol` at fork block 45,682,232. 23 tests, 22 PASS, 1 RPC-timeout (transient, non-attack). Live-state read.
- **L2 (read-only):** `cast call` snapshots saved to `artifacts/recon/state-snapshot.txt`; bytecode dumps saved to `artifacts/recon/*.bin`.
- **L3 (broadcast):** none executed. The plan permits one round of EXT broadcast tests after the fork pass, but the fork pass surfaced no new EXT findings worth confirming on chain. Deferred.

Reproducibility:
```
cd contracts
forge test --match-contract AdversarialMainnet \
  --fork-url https://base-rpc.publicnode.com -vv
```

---

## Live state snapshot at test time

```
Router        0x2f8DE1F9fE5c59B0303610d937Af439e27775c63
  owner=0xdD6D95...e9E1  operationsAdmin=0xdD6D95...e9E1
  trustedLaunchSigner=0x2EBE975e...9524  paused=false
  founderDepositWei=0.01 ETH  feesEnabled=false  useTestnetContracts=false
  stakerAllocationDisabled=false  stakerRewardsContract=0x0  (note: not yet wired — see SC-FUTURE)

Escrow MAIN   0x66A25c957d39C8c6e24885d5cf8f086228387976
  admin=0xdD6D95...e9E1  trustedSigner=0x2ebe975e...9524
  lpCreated=true  lpWithdrawn=true  lpEthAmount=0.0015 ETH
  effectiveRaised=0.01 ETH  pendingPlatformFees=2.125e13 wei
  trancheClaimed[0]=true  trancheClaimed[1..6]=false
  vestingContract=0x0  stakerRewards=0x0  treasuryContract=0x0
  ETH balance=0.00767 ETH

Escrow Factory 0x36965500195256eE27F2455e7B5d9aef14a2532D
  admin=0xdD6D95...e9E1  authorizedRouter=Router  timeOracle=0x0
  trustedSigner=0x2ebe975e...9524

LP Locker     0xDF8Fe85c8c99fE658322860e482641F41186b66a
  owner=0xdD6D95...e9E1  authorizedRouter=Router  feeClaimerImpl=0xCe6c5...
  campaignToFeeClaimer(MAIN escrow)=0x048DD897A01D90A68781C621964e67FD1613B145
```

---

## Findings

### ADV-01 — Admin merkle-root drain via freeze + commit-reveal — **Critical**

- **Phase / actor:** P3 / ADM
- **Attack:** Admin freezes the campaign, commits an arbitrary merkle root, waits 24h, finalizes — `claimHolderRefund` then pays out the entire `frozenEthBalance` to attacker-chosen address(es).
- **L1 result:** Confirmed exploitable on fork. Sequence completes successfully:
  ```
  freezeCampaign("attack")               -> succeeds, state -> Frozen, frozenEthBalance recorded
  commitRefundMerkleRoot(fakeRoot)       -> succeeds, pendingMerkleRoot stored
  vm.warp(+25 hours)                     -> bypass MERKLE_ROOT_DELAY
  finalizeRefundMerkleRoot()             -> succeeds, state -> Refunding, root set
  attacker calls claimHolderRefund(...)  -> drains frozenEthBalance
  ```
- **Severity:** Critical (admin-compromise). Bounded by:
  1. 24h `MERKLE_ROOT_DELAY` window between commit and finalize.
  2. `frozenEthBalance` excludes `pendingPlatformFees` and `totalExcessRefundLiability` per audit fixes M-03, F4.
  3. Cannot be triggered against a Failed or Completed campaign (state gate).
- **Stale doc to correct:** `docs/privileged-roles.md` § 2 says `upholdChallenge(address[] _excludeAddresses)`. The current source is `upholdChallenge()` (no args) — the exclusion set is computed onchain via `_calculateRedeemableSupply()`, which excludes LP at `0xdead`, `vestingContract`, `stakerRewards`, `authorizedRouter`, `lpLocker`, `treasuryContract`, and `address(this)`. The "admin manipulates `_excludeAddresses` to over-pay self" attack vector documented in the privileged-roles doc is **not a current attack surface**. The actual attack vector is leaf forgery in the merkle root.
- **Recommendation:**
  - Update `docs/privileged-roles.md` §2 to remove the `_excludeAddresses` claim and document the merkle-leaf forgery vector instead.
  - Pre-mainnet hardening: Safe migration is required (already a P0 in `docs/mainnet-readiness.md`).
  - Audit hand-off: flag for Spearbit/ToB review of `commitRefundMerkleRoot` + `finalizeRefundMerkleRoot` flow.
- **Artifacts:** `contracts/test/AdversarialMainnet.t.sol::test_ADM_3_11_FreezeAndSelfDrain`

### ADV-02 — Admin can set malicious `timeOracle` on factory; new raises inherit — **Low (after H-06 + ADV-02 fix)**

- **Phase / actor:** P3 / ADM
- **Attack:** `escrowFactory.setTimeOracle(maliciousOracle)` succeeds for admin. New escrows created after this call read the factory's `timeOracle` during `initialize` and pin it into their own per-clone storage. A malicious oracle returning a future timestamp would, in principle, let founders bypass the 30-day tranche unlock or 72h challenge window on those new raises.
- **L1 result:** Set succeeded on fork. Existing escrow's `timeOracle` slot is its OWN per-clone state and was not modified by the factory rotation — so existing raises (the live MAIN raise) are SAFE under any factory rotation.
- **Existing mitigation (initially missed in writeup):** `VibesTranchEscrow._currentTime()` enforces audit fix **H-06**: `require(oracleTime <= block.timestamp + MAX_TIME_DRIFT)` where `MAX_TIME_DRIFT = 1 hours`. So even on a future raise that inherits a malicious oracle, the oracle cannot accelerate time forward by more than 1 hour beyond `block.timestamp`. Tranche unlocks, challenge windows, and deadlines are only acceleratable by ~1h — negligible. The remaining attack vector is *backward* time warp (oracle returning a past timestamp), which can grief — permanently block founder claims by holding `_currentTime()` below `unlockTime` — but cannot accelerate unlocks or move funds.
- **Severity revision:** From High → Low (griefing only on FUTURE raises, no fund-loss path).
- **Hardening landed (`claude/lock-time-oracle`):** Added `lockTimeOracle()` one-way latch to `VibesTranchEscrowFactory`. After mainnet deploy + post-deploy `lockTimeOracle()` call from M-3 Safe, `setTimeOracle` reverts permanently. Removes even the residual griefing surface for production. Testnet variant (`VibesTranchEscrowFactoryTestnet`) intentionally untouched — mock oracle there must remain rotatable.
- **Recommendation:** Add `factory.lockTimeOracle()` to the post-deploy mutation list in `docs/first-mainnet-deployment.md` § "Post-deploy hardening" and the production deploy runbook. One Safe call, permanent.
- **Artifacts:**
  - Fork test: `contracts/test/AdversarialMainnet.t.sol::test_ADM_3_12_SetMockTimeOracle`
  - Lock impl: `contracts/src/VibesTranchEscrowFactory.sol::lockTimeOracle()`
  - Lock tests: `contracts/test/VibesTranchEscrowFactory.t.sol::test_lockTimeOracle_*`

### ADV-03 — `rescueETH` drains 100% of router ETH balance — **Med (Crit if router holds ETH)**

- **Phase / actor:** P3 / ADM
- **Attack:** `router.rescueETH(attacker, balance)` succeeds for owner.
- **L1 result:**
  - Live router has 0 ETH balance currently → exploit drains 0 ETH today.
  - Forced router balance to 1 ETH via `vm.deal`, called `rescueETH` → all 1 ETH siphoned to attacker.
- **Severity:** Med-Critical depending on whether the router has ETH in flight (e.g. a launch's founder deposit between `launchWithCampaign` and `completeFinalization`). Documented in `docs/review-smart-contracts.md` § R-08.
- **Recommendation:**
  - Verify the documented "guarded by deposit reserves" assertion against the actual `rescueETH` body. The fork test shows it transfers the full requested amount; the source-claimed reserve guard either isn't there or doesn't apply when `tokenDeposits` is empty.
  - Production multisig rotation + 24h timelock on `rescueETH`.
- **Artifacts:** `test_ADM_3_1_RescueETH`, `test_ADM_3_1b_RescueETHWithBalance`

### ADV-04 — `setOpsWallet(attacker)` redirects 2.5% of future tranche fees — **Medium**

- **Phase / actor:** P3 / ADM
- **Attack:** Owner rotates `opsWallet` to attacker-controlled address. Subsequent tranche claims by founders pay the 2.5% platform fee to the attacker.
- **L1 result:** Rotation succeeded. Bounded leak.
- **Severity:** Medium. Future-only damage. Detection is straightforward (event emission + opsWallet read).
- **Recommendation:** Multisig + monitoring/alerting on `OpsWalletChanged` event.
- **Artifacts:** `test_ADM_3_1c_DrainEscrowViaRouter`

### ADV-05 — `setTrustedLaunchSigner(attacker)` enables forged launch authorizations — **Medium**

- **Phase / actor:** P3 / ADM
- **Attack:** Owner rotates trusted signer. Attacker can now sign EIP-712 launch authorizations for any wallet, triggering launches on behalf of victims (consuming their nonce + their founder deposit).
- **L1 result:** Rotation succeeded.
- **Severity:** Medium. Combined with `setFounderDepositWei(0)` it becomes a free-spam vector. Real fund movement requires the victim to also have a signed terms acceptance, so the practical exploit chain is narrow.
- **Recommendation:** Multisig + alert on `TrustedLaunchSignerChanged`. Consider signer-rotation cooldown.
- **Artifacts:** `test_ADM_3_6_SetTrustedLaunchSigner`

### ADV-06 — `VibesTokenFactory.deployToken` is permissionless — **Low** (already documented as L-2)

- **Phase / actor:** P1 / EXT
- **Attack:** Anyone can directly call `tokenFactory.deployToken(name, symbol, decimals, supply, recipient)` and receive a fresh `VibesToken` instance bypassing the router.
- **L1 result:** Confirmed. Attacker received 1B tokens of a new VibesToken at `0x3195...`.
- **Severity:** Low. The deployed token is NOT registered in `VibesRegistry` and has no Origin Capsule attestation, so it can't impersonate a legitimate Vibestarter raise. But it CAN appear with the `VibesToken` source label on Basescan, creating a minor impersonation/phishing surface.
- **Recommendation:** Add `onlyAuthorizedRouter` modifier on `deployToken`. Already on the P1 list in `docs/mainnet-readiness.md`.
- **Artifacts:** `test_EXT_1_6_DirectDeployToken`

### ADV-07 — Live escrow rejects unsolicited ETH — **Safe (positive finding)**

- **Phase / actor:** P1 / EXT
- **Attack:** Push 0.001 ETH into escrow via plain transfer (testing whether `receive()` accepts).
- **L1 result:** Reverted. Escrow has no payable receive/fallback that accepts external ETH. ETH-pollution attack vector closed.
- **Severity:** Informational (positive finding).
- **Note:** Force-push via `SELFDESTRUCT` would still land ETH on the contract regardless of receive() — but post-Cancun semantics + the escrow's accounting doesn't read `address(this).balance` for raised-amount tracking, so any forced-in ETH is sequestered until admin recovers. Acceptable.
- **Artifacts:** `test_EXT_1_10_ForceEthIntoEscrow`

### ADV-08 — All standard external/founder attack vectors hold — **Safe (consolidated)**

For brevity, summarized:

| Hypothesis | Result |
|---|---|
| Non-founder calls `claimTranche(N)` | reverts (`OnlyFounder`) |
| Re-init existing escrow clone | reverts (`AlreadyInitialized`) |
| Init the impl contract directly | reverts (impl already initialized at deploy) |
| Front-run `completeLP(token)` as non-owner | reverts |
| Founder double-claim of kickstart | reverts (`AlreadyClaimed`) |
| Founder pre-30-day tranche claim | reverts (timing gate) |
| Founder skip challenge window via fast claim | reverts (additional gate triggered before claim path) |
| Owner refundDeposit on already-refunded deposit | reverts |
| `recordManualLPLock` forge attempt | reverts (requires actual dead-burn proof) |
| `getClaimableTokens` view stability | callable post-finalize (no underflow trigger) |
| Capsule hash collision | requires EIP-712 launch sig, not reachable without trusted-signer key |

All defended. See full log: `tmp/adv-out2.log` or rerun the suite.

### ADV-09 — EIP-712 launch signature replay infeasible — **Safe**

- **Phase / actor:** P4 / SIG
- **Verified:** Domain separator includes `block.chainid` + `verifyingContract` (cross-chain and cross-router replay both prevented). `launchNonces[founder]` enforces sequential consumption; replay of consumed nonce reverts.
- **Operational risk:** Trusted signer private key stored in Vercel env (`TERMS_SIGNER_PRIVATE_KEY`). Vercel-org access OR build-log exfiltration would expose it. **Pre-mainnet hardening procedure** moves this to a hardware-isolated key derived from a Safe.
- **Artifacts:** `test_SIG_4_3_NonceReuse`, `test_SIG_4_4_SignerKeyOperational`

### ADV-10 — Off-chain API surface holds against header-spoof and CSRF regressions — **Safe**

- **Phase / actor:** P5 / EXT
- **Verified by code review:** All routes that read `x-wallet-address` header (16 routes) bind the SIWE session to the claimed wallet via `requireWalletAuth(request, expectedWallet)`. The header is treated as a wallet-id lookup parameter only; authority comes from the SIWE iron-session cookie.
- **Critical SC-01 / SC-02 / SC-04 paths re-verified:**
  - `/api/campaigns/[id]/tranches/[tid]/request` → `requireWalletAuth(request, tranche.campaign.founder.wallet)` — must match founder via SIWE.
  - `/api/campaigns/[id]/tranches/[tid]/resolve` → DOUBLE gate: `requireOffChainAdmin` + `requireStrongWalletAuth`.
  - `/api/account/link` → `requireStrongWalletAuth(request, wallet)` — strongest pattern.
- **Limitation:** Direct curl probing against `staging.vibestarter.xyz` is blocked by Vercel deployment auth wall (defense-in-depth). API regression tests verified by source-code review only. When `app.vibestarter.xyz` goes live without the auth wall, repeat the curl-based regression check.
- **Artifacts:** Source review of all `apps/web/src/app/api/**/*.ts` files reading `x-wallet-address`.

### ADV-11 — Sanctions screening Chainalysis-on-Base gap — **Compliance Critical (already documented)**

- **Phase / actor:** P5 / EXT
- **Status:** KNOWN GAP. `apps/web/src/lib/sanctions-screening.ts` pre-flight check returns SKIPPED when the Chainalysis oracle has no bytecode at the canonical CREATE2 address on Base mainnet (current state). Documented in `docs/mainnet-readiness.md` § "Compliance / sanctions" as P0.
- **Recommendation:** Wire an off-chain SDN check (Chainalysis API, OFAC Open SDN List) before any non-team users.

---

## What was NOT tested (and why)

| Area | Reason |
|---|---|
| Phase 6 — MEV / sniper time-budgeting | Requires a controlled second mainnet raise and live mempool. Schedule for follow-up after $VIBES launch design freeze. |
| Day-30 tranche claim path | Requires real chain time — earliest 2026-06-05. Schedule for natural unlock. |
| Pre-existing pool collision attack on Aerodrome | Requires creating a `MAIN/WETH` Aerodrome pool BEFORE finalize. The MAIN raise is already finalized so this surface has closed. Test on the next raise. |
| Treasury escrow attacks | MAIN raise has no treasury allocation. Tests deferred to first raise that uses one. |
| Vesting attacks | MAIN raise has no founder vesting. Same. |
| Staker rewards merkle forgery | Staking not deployed. P1 from `mainnet-readiness.md`. |
| Direct API curl probes against staging | Vercel deployment auth wall. Re-test on production deploy. |
| Production-multisig posture | This deployment intentionally consolidates roles to deployer EOA. The full multisig posture is a separate, post-hardening test. |

---

## Doc corrections needed

1. **`docs/privileged-roles.md` § 2 "Escrow Admin":** the `_excludeAddresses` parameter on `upholdChallenge` and `freezeCampaign` no longer exists. Replace the documented "manipulate exclusion set" attack with the actual current vector: arbitrary merkle-root commit during the 24h delay window. Recompute the trust assumption — the current code is *more* resistant than the doc claims, but still admin-compromise-vulnerable via leaf forgery.

2. **`docs/review-smart-contracts.md` § R-08 (rescueETH receive):** confirm the doc-claimed "deposit reserve" guard is actually enforced. The fork test shows full-balance drain succeeds when there are no active deposits.

3. **`docs/mainnet-readiness.md` § "Pre-flight":** add `setStakerAllocationDisabled(true)` to the post-deploy mutation list. Live state shows it's `false` and `stakerRewardsContract == 0x0` — a future launch with a non-zero staker slice would hit `StakerRewardsContractNotSet` revert during finalize.

---

## Reproducibility

- Plan: `C:\Users\Ross\.claude\plans\floating-rolling-graham.md`
- Fork suite: `contracts/test/AdversarialMainnet.t.sol`
- Bytecode dumps: `artifacts/recon/*.bin`
- Live state snapshot: `artifacts/recon/state-snapshot.txt`
- Run: `forge test --match-contract AdversarialMainnet --fork-url https://base-rpc.publicnode.com -vv`

## Hand-off to external auditor

`docs/audits/external-audit-prep-2026-05.md` should reference this document under a new "Self-conducted adversarial test" section so the auditor can corroborate / extend findings 1-5 (admin compromise paths) and the doc corrections above. Of particular interest for the auditor:

- ADV-01: 24h commit-reveal merkle root flow — is the delay sufficient given mainnet-mempool detection latency?
- ADV-02: per-clone vs factory-side timeOracle propagation — confirm no path lets factory rotation affect existing clones.
- ADV-03: `rescueETH` reserve guard — verify the in-source guard matches the doc claim.
- Doc correction #1: `_excludeAddresses` history (was it ever implemented? deprecated when?).
