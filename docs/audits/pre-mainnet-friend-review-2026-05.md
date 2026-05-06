# Pre-Mainnet Friend Review — Vibestarter

> Quick orientation for the folks doing a pre-mainnet sanity check on the contracts. Thanks for taking the time — this is the last set of eyes before we deploy to Base mainnet, so anything you flag is high-value even if you don't write it up formally.

---

## What you're looking at

Vibestarter is a crowdfunding platform for AI / "vibecoded" apps on Base. Funds release on a **time schedule** — 10% kickstart + 15% × 6 monthly tranches — not gated by milestones. Backers can challenge each tranche payout on a 72-hour window. LP is created on Aerodrome and burned to `0xdead`. EIP-712 sigs from a trusted backend signer gate launches and contributions.

We ran an incentivized testnet on Base Sepolia for ~3 months; it's now closed, contracts are heavily reworked, and we're prepping the mainnet deploy.

**What we want from you:** a sanity check focused on fund-flow paths. We're not expecting a formal report — Slack / Telegram / DM works for whatever you find. Even "I poked at X, looks fine" is useful.

---

## If you've got 2 hours

Open these three files side by side:

1. **`contracts/src/VibesTranchEscrow.sol`** (~1,335 lines) — the per-campaign ETH escrow. Contributions in, tranches out, refunds, freeze, commit-reveal merkle root. The biggest contract and the highest-value target.
2. **`contracts/src/VibesRouterExtension.sol`** (~841 lines) — admin surface + the two-phase finalization (`_executePhase1` LP creation + `_executePhase2` distribution). The split is there because the original 12-call inline finalization OOG'd at ~1.6M gas during testnet — please confirm the Phase 2 retry path can't double-spend.
3. **`contracts/src/VibesLPLocker.sol`** (~524 lines) — Aerodrome LP creation, permanent burn, rescue path. The `recordManualLPLock` admin path requires onchain proof (`IERC20(pool).balanceOf(0xdead) >= lpAmount`); we'd love a check that we can't fake that proof.

Then skim:
- **`docs/audits/external-audit-prep-2026-05.md`** §5 ("Risk-ranked review priorities") — gives the file:line breakdown of where the highest-leverage 20–30% of the surface area is.

---

## If you've got a day

Add these:

4. **`contracts/src/VibesStaking.sol`** + **`VibesStakerRewards.sol`** — F4 snapshot system. Staker rewards read historical balance at notify-time, not current balance. Previously had a current-balance fallback that was an exploit vector; we removed it. Confirm the lazy snapshot writes in `_writeSnapshotsBeforeBalanceChange` can't be gamed.
5. **`contracts/src/VibesTreasuryEscrow.sol`** — proposal-based withdrawals from the per-campaign treasury, with backer challenges. `upholdChallengeMalicious` is the nuclear option (burns treasury tokens, freezes vesting). Confirm it can't be triggered via reentrancy through a malicious treasury-token.
6. **PC-01 / PC-03 / PC-04 / PC-05** — newly-introduced features for the $VIBES TGE (the platform's own token raise as the first launch). Documented in `docs/pending-contract-changes.md` from line 1 onwards. None of this has been externally audited yet.

---

## Two specific things I'd love your gut check on

These are findings we already know about and have analyzed, but a third opinion would help us pick the right fix:

### 1. `setFeeConfig` accepts a reverting recipient

`contracts/src/VibesRouterExtension.sol:586-595`. Admin sets a fee recipient. If the recipient is a contract that reverts on `receive()` / `fallback()`, the next `launchWithCampaign` that pays a fee will revert and brick subsequent launches until the multi-sig redoes the setter.

Mitigation options we're weighing:
- `require(_recipient.code.length == 0)` (rejects all contracts including a Safe — sometimes desirable)
- Try-send pattern: `(bool ok, ) = _recipient.call{value: 0, gas: 2300}("");`
- Pull-based fee escrow (recipient calls `claim`)

Which would you pick? Or is there a fourth option we missed?

### 2. `campaignToFeeClaimer` exclusion in `_calculateRedeemableSupply`

`contracts/src/VibesTranchEscrow.sol:378-407` and `contracts/src/VibesLPLocker.sol:96, 290-298`. When LP is created, we deploy a per-campaign `VibesLPFeeClaimer` clone that holds the LP NFT and routes Aerodrome trading fees. The project-token side of those fees ends up in the clone's balance.

`_calculateRedeemableSupply()` (used by the freeze → pro-rata redemption path) excludes 0xdead, vesting, staker rewards, router, lpLocker, treasury, and `address(this)`. It does NOT exclude the fee claimer's project-token balance. So if `pool.claimFees()` is called post-finalization, those tokens count toward the redemption denominator and dilute everyone's pro-rata refund.

Severity feels like Medium grief (slow leak, not a one-shot drain). Right call, or worse than I think? And: read `lpLocker.campaignToFeeClaimer(address(this))` lazily inside the calc, or have the router push the address at finalization (mirroring how `treasuryContract` is wired)?

### 3. Known: LP-sniping on small-softcap raises (observed empirically)

Not asking you to fix this — flagging it as a "known and accepted for now" so it doesn't surprise you. We ran a tiny smoke-test raise on Base mainnet (0.01 ETH softcap, 1B supply, 15% LP allocation = 0.0015 ETH + 150M tokens initial Aerodrome volatile-pool reserves). Within 64 blocks (~2 min) of `finalize()` confirming, two off-the-shelf sniper bots watching `PoolCreated` events on the Aerodrome factory drained ~14.6% of total supply for ~$180:

- Bot A spent 0.0099 ETH and got **130.2M MAIN** (87% of LP-side tokens) on its first buy
- Bot A spent another 0.0495 ETH for 16M more MAIN
- Bot B did a tiny round-trip and broke even

The math is just `x*y=k` against a microscopic pool — `0.0114 ETH × (150M − X) = 225,000` solves to `X = 130M`. Not a contract bug, a **liquidity-scale property** of small launches.

**Why we're shipping anyway:**
- The $VIBES TGE softcap is 100 ETH, so initial LP would be 15 ETH paired with 15% of supply. A bot with $200 buys ~0.13% of LP-side tokens, not 87%. Cost-benefit collapses for any meaningful raise size.
- We document the risk as part of the founder onboarding flow.
- Internal recommendation will be "don't launch with a softcap below ~5 ETH on mainnet" until we have a mitigation.

**What I'd love your read on:**
- Is the liquidity-scale argument sufficient, or are there second-order attacks (e.g. sandwich the LP-creation tx itself, not just frontrun the next block) we should pressure-test? The finalize tx is on the public mempool today — Base doesn't have a widely-adopted Flashbots equivalent.
- Worth investing in private-mempool submission of `finalize()` (Tenderly Web3 Gateway / similar) for v1, or wait until smaller raises become a use case?
- Is there an in-token mitigation that doesn't break composability with Aerodrome / aggregators? (Max-buy-per-wallet for first N blocks is the standard pattern but has its own downsides.)

This is exactly the kind of thing the audit-prep doc doesn't currently flag — too late-stage when it was written. Adding here for visibility.

---

## How to run things locally

```bash
git clone https://github.com/vibesprotocol/vibes-protocol
cd vibes-protocol/contracts
forge install
forge test                          # ~1,014 tests, runs in ~30s
forge test --match-contract Audit   # all audit-derived suites
forge test -vvv --match-test <name> # specific test with traces
forge build --sizes                 # check bytecode sizes (router is ~860 bytes under EIP-170)
```

The largest test suites:
- `VibesTranchEscrow.t.sol` (64 tests) + `VibesTranchEscrowEdgeCases.t.sol` (30)
- `VibesLaunchRouterV2.t.sol` (55)
- `AuditFixes.t.sol` (51) + `AuditRemediation2026_04.t.sol` + `Audit2026_04_Findings.t.sol`
- `CrossContractInvariant.t.sol` — ETH conservation, token balance invariants

If a test name doesn't make sense, ping me — many encode threat-model constraints better than the prose docs do.

---

## Stuff that's NOT worth your time

- `VibesTranchEscrowTestnet.sol` and `VibesTranchEscrowFactoryTestnet.sol` — testnet-only variants, never deployed on mainnet (`setUseTestnetContracts` is hard-blocked on chain 8453 at `VibesRouterExtension.sol:695-698`). Skim only to confirm parity drift is impossible.
- `MockTimeOracle.sol`, `TestnetSwap.sol` — mocks, not deployed on mainnet.
- Off-chain code (`apps/web/`, `packages/indexer/`, `packages/keeper/`) — separate concern, not part of this review.
- Style nits, gas micro-optimizations — not what we need from you. Fund-flow correctness matters more.

---

## What we've already had reviewed

Three internal audit cycles + one paid external pass since February:
- 2026-03-27 external pass — A-G remediation
- 2026-04-04 internal F1-F10 audit
- 2026-04-14 adversarial pass — H-1 through L-4 closed
- 2026-04-16 — F-1 (zero-supply freeze solvency) + F-2 (treasury redeemable-supply exclusion)

All findings closed; tests in `contracts/test/Audit*.t.sol`. So if you see something that looks like an obvious bug, check `docs/security-remediation-2026-04-15.md` first — it's probably already fixed and the test exists. (If you find one that *isn't* fixed despite being in that doc, that's a great find.)

---

## How to flag stuff back to me

- **Slack / Telegram / signal / DM** — whatever's easy. No formal write-up needed.
- **Severity vibe**: "this drains funds" vs "this is annoying" vs "this is just weird" is enough — I'll triage from there.
- **Reproducible test case if easy** — even a 5-line forge test that fails. If hard, prose is fine.
- **Don't** sit on something because you're not sure if it's a bug. We'd rather chase three false alarms than miss one real issue.

Thanks again — this is genuinely the last gate before we deploy real money to mainnet.
