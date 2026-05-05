# Test Coverage Analysis

> Inventory of all test suites, coverage assessment, and how to run tests.

**Last Updated:** 2026-04-04

---

## Test Suite Summary

| Category | Files | Tests |
|----------|-------|-------|
| Smart Contracts (Foundry) | 30 | **~620+** (includes new edge case tests) |
| Shared Package (Vitest) | varies | 215 (7 suites) |
| Web App (Vitest) | varies | 545 (37 suites, 111 new tests in 10 files) |

---

## Smart Contract Tests

### How to Run

```bash
# All contract tests (from vibestarter-app root)
pnpm run test:contracts

# Or directly in contracts/
cd contracts && forge test -vv

# Very verbose (traces on failure)
forge test -vvvv

# Specific suite (use --match-path, not --match-contract, for reliability)
forge test --match-path "test/VibesTranchEscrowTest.t.sol" -v

# Specific test
forge test --match-test test_SingleContributor_FullFlow -v

# Gas report
forge test --gas-report
```

> **Windows / Memory Note:** Running the full `forge test` on Windows may hit a `bad_alloc` (OOM) error when solc compiles all 28 test files simultaneously. **Workaround:** run suites individually with `--match-path`, or run `pnpm run test:contracts` from the monorepo root (which uses Turborepo's file-level caching to avoid re-compilation).

### Test File Inventory

| File | Tests | Purpose | Priority |
|------|-------|---------|----------|
| `FullLifecycleIntegration.t.sol` | 16 | End-to-end: launch → contribute → finalize → claim → tranches | P0 |
| `AllocationFuzz.t.sol` | 15 | Fuzz testing: token allocation math, BPS calculations, invariants | P1 |
| `GasBenchmarks.t.sol` | 10 | Gas profiling for key operations | P1 |
| `VibesTranchEscrow.t.sol` | 56 | Core escrow: contributions, finalization, tranches, challenges, refunds | P0 |
| `VibesLaunchRouterV2.t.sol` | 46 | Router: launches, campaigns, deposits, fees, claims | P0 |
| `VibesTokenDistributorV2.t.sol` | 32 | Token distribution: merkle claims, ETH refunds | P1 |
| `VibesTranchEscrowFactory.t.sol` | 25 | Factory: clone creation, initialization, proxy pattern | P1 |
| `VibesRegistry.t.sol` | 18 | Registry: token registration, router authorization | P2 |
| `VibesLPLocker.t.sol` | 25 | LP locker: creation, locking to 0xdead, rescue tracking (F7), Aerodrome integration | P1 |
| `VibesVesting.t.sol` | 31 | Vesting: 6-month cliff, 12-month linear, freeze | P1 |
| `VibesStaking.t.sol` | 18 | Staking: stake, unstake, cooldown, multiple stakers | P2 |
| `VibesIdentityRegistry.t.sol` | 13 | Identity: registration, batch, URI management | P2 |
| `VibesStakerRewards.t.sol` | 27 | Staker rewards: snapshot-based claims, batch claims, F4 gaming prevention | P1 |
| `VibesTreasuryEscrow.t.sol` | 69 | Treasury: proposals, challenges, 4 outcomes | P1 |
| `LPTradeSimulation.t.sol` | 15 | LP trading: DEX simulations, price impact | P2 |
| `CrossLayerMerkle.t.sol` | 11 | Cross-contract merkle proof validation | P1 |
| `VibesToken.t.sol` | 14 | Token: ERC20 basics, transfer, approve | P2 |
| `E2EScenarios.t.sol` | — | End-to-end scenario tests | P0 |
| `AuditFixes.t.sol` | — | Previous audit fix validation | P1 |
| `SecurityAuditFixes.t.sol` | — | Security audit fix validation | P1 |
| `VibesTranchEscrowEdgeCases.t.sol` | — | Edge cases in escrow logic | P1 |
| `VibesDistributorEdgeCases.t.sol` | — | Edge cases in distribution | P1 |
| `VibesFinalizationPhases.t.sol` | — | Two-phase finalization (Phase 1: LP, Phase 2: distribution) | P0 |
| `VibesVestingFreeze.t.sol` | — | Vesting freeze logic | P1 |
| `TermsSignatureVerification.t.sol` | — | Terms signature (EIP-712) verification | P1 |
| `LPForkTest.t.sol` | — | Base mainnet fork tests for LP | P2 |
| `VibesTranchEscrowTestnet.t.sol` | — | Testnet escrow variant tests | P2 |
| `VibesTranchEscrowFactoryTestnet.t.sol` | — | Testnet factory variant tests | P2 |
| `AuditSecurityTests.t.sol` | 14 | Reentrancy exploits, state machine adversarial, F10 commit-reveal | P0 |
| `CrossContractInvariant.t.sol` | 5 | ETH conservation, token invariants, treasury→vesting→staker chain, campaign isolation | P0 |
| **Total** | **~600+** | 30 test files | |

### Test Mocks

| Mock | File | Purpose |
|------|------|---------|
| MockAerodromeRouter | `test/mocks/MockAerodromeRouter.sol` | Simulates Aerodrome DEX router |
| MockAerodromePool | `test/mocks/MockAerodromePool.sol` | Simulates Aerodrome LP pool |
| MockTimeOracle | `src/MockTimeOracle.sol` | Time manipulation for testing |

---

## Coverage Assessment

### Well-Covered Areas

- **Tranche lifecycle:** Full path from contribute → finalize → request → challenge → claim
- **Challenge system:** Raise, uphold, reject, expire, graduated thresholds
- **Refund paths:** Contributor refund (failed), excess refund (pro-rata), holder refund (frozen)
- **Token allocation math:** Fuzz-tested BPS calculations, allocation sums
- **Vesting:** Cliff, linear, freeze, release timing
- **Integration:** Cross-contract flows from router through escrow to LP locker

### Coverage Gaps

| Gap | Risk | Status |
|-----|------|--------|
| `batchDistribute` with malicious recipient contracts | Medium | **CLOSED** — covered by `VibesDistributorEdgeCases.t.sol` (reentrancy, gas guzzler, batch limit, pending ETH pull) |
| `claimHolderRefund` edge cases (last claimant rounding) | Low | **CLOSED** — covered by `VibesTranchEscrowEdgeCases.t.sol` (dust invariant, single holder, 3-holder rounding) |
| `completeFinalization` revert scenarios | High | **CLOSED** — covered by `VibesFinalizationPhases.t.sol` and `AuditSecurityTests.t.sol` |
| Treasury escrow `upholdChallengeMalicious` → vesting freeze chain | Medium | **CLOSED** — covered by `CrossContractInvariant.t.sol` (test 3: treasury→vesting→staker chain) |
| Gas limits on large `_excludeAddresses` arrays | Low | Open (addresses array was removed; `_calculateRedeemableSupply()` uses fixed set) |
| Concurrent `contribute` race conditions | Medium | Open — not testable in Foundry (single-threaded), boundary tests exist |
| Reentrancy exploit tests | Medium | **CLOSED** — covered by `AuditSecurityTests.t.sol` (claimContributorRefund, claimExcessRefund) |
| State machine adversarial transitions | Medium | **CLOSED** — covered by `AuditSecurityTests.t.sol` (6 tests) |
| Cross-contract ETH conservation invariant | High | **CLOSED** — covered by `CrossContractInvariant.t.sol` (test 1) |
| Staker rewards gaming (stake increase after notification) | High | **CLOSED** — F4 snapshot fix + 4 tests in `VibesStakerRewards.t.sol` |
| Token revert / blacklist tests | Medium | **CLOSED** — covered by `VibesDistributorEdgeCases.t.sol` (MockRevertingERC20, MockBlacklistERC20) |

### Audit Fix Tests (2026-04-04)

The April 4 audit introduced 31 new tests across 4 files:

| Test File | Tests | Covers |
|-----------|-------|--------|
| `VibesTranchEscrowEdgeCases.t.sol` | +13 | F1 double-refund, F2 admin top-up, F3 solvency guard, F5 LP gating, F6 underflow |
| `VibesLPLocker.t.sol` | +2 | F7 rescue tracking, view function corruption |
| `VibesStakerRewards.t.sol` | +4 | F4 snapshot-based rewards, gaming prevention, multi-raise independence |
| `AuditSecurityTests.t.sol` | +14 | Reentrancy, state machine adversarial, F10 commit-reveal |
| `CrossContractInvariant.t.sol` | +5 | ETH conservation, token invariants, treasury→vesting→staker, campaign isolation, pro-rata freeze |
| `AuditFixes.t.sol` | updated | 2 tests updated for F10 commit-reveal pattern |
| `E2EScenarios.t.sol` | updated | 1 test updated for F10 commit-reveal pattern |

### Security Audit Test Fixes (2026-02-24)

The security audit introduced three code changes that required corresponding test updates:

| Test File | Change | Reason |
|-----------|--------|--------|
| `VibesRegistry.t.sol` | `test_transferOwnership()` split into 3 tests covering two-step flow | M1 fix: `transferOwnership()` now sets `pendingOwner` only |
| `VibesLaunchRouterV2.t.sol` | `test_transferOwnership()` split into 2 tests | Router extension also uses two-step ownership |
| `VibesTranchEscrowFactory.t.sol` | `test_setAdmin()` split into 2 tests | Factory also uses two-step admin transfer |
| `VibesTreasuryEscrow.t.sol` | `test_supportChallenge()` — gives caller a token balance | M2 fix: requires token holder |
| `VibesVesting.t.sol` | Added `_initialize()` helper with `vm.prank(router)` | L11 fix: `initializeAmount()` now restricted to `authorizedStarter` |
| `FullLifecycleIntegration.t.sol` | Fixed expected vesting balance from 10% to 7.5% | Assertion used wrong bps (1000 vs 750) |
| `LPTradeSimulation.t.sol` | Reduced "absurd buy" from 1000 ETH to 90 ETH | trader1 only has 100 ETH in setUp |

### Deferred Items

- **Aderyn:** Requires Rust toolchain. See `docs/security-analysis.md` Section 2.1 for install command.
- **Coverage report:** `forge coverage` available but not run yet. Run with:
  ```bash
  cd contracts && forge coverage
  ```

---

## Shared Package Tests

### How to Run

```bash
pnpm test
# or
pnpm --filter @vibes/shared test
```

### Test File Inventory (10 suites)

| File | Purpose | Coverage |
|------|---------|----------|
| `allowlist-scoring.test.ts` | Scoring functions for starter levels | Full — all components, brackets, levels |
| `capsule.test.ts` | Capsule creation, validation, attestation | Full |
| `cross-layer-merkle.test.ts` | TypeScript ↔ Solidity merkle compatibility | Full — pro-rata and fixed goal |
| `erc8004.test.ts` | Agent identity registry constants/mappings | Full |
| `hashing.test.ts` | Text normalization, JSON canonicalization, hashing | Full |
| `holder-refund-merkle.test.ts` | Frozen campaign refund merkle trees | Full — includes C-02 audit validation |
| `merkle.test.ts` | Token distribution merkle trees | Full |
| `performance.test.ts` | Benchmarks for merkle operations at scale | Performance only |
| `staker-rewards-merkle.test.ts` | Staker reward distribution trees | Moderate |
| `testnet-constants.test.ts` | Timing constants for testnet vs mainnet | Full |

### Shared Package Gaps

| Module | Status | Notes |
|--------|--------|-------|
| `contracts/addresses.ts` | **Untested** | `getAddresses()` function has chain ID validation logic with no tests |
| `types.ts` (Zod schemas) | **Partial** | Only `getTimingConstants` tested; `CapsuleSchema`, `AgentReferenceSchema` etc. not directly tested |
| `contracts/enums.ts` | **Untested** | Labels/colors constants — low risk |

---

## Web App Tests

### How to Run

```bash
pnpm --filter web test
```

### Test File Inventory (~40 suites)

#### API Route Tests (16 files)

| File | Purpose |
|------|---------|
| `siwe-auth.test.ts` | SIWE sign-in, nonce, session lifecycle, CSRF |
| `auth-dual-mode.test.ts` | SIWE + header fallback, feature flag gating |
| `account-link.test.ts` | Social account linking/unlinking (Twitter, GitHub) |
| `account-sync.test.ts` | First-visit social identity sync, race conditions |
| `campaign-contribute.test.ts` | Contribution recording, duplicate prevention, hard cap |
| `tranche-request.test.ts` | Founder payout requests, eligibility, challenge window setup |
| `tranche-challenge.test.ts` | Backer/holder challenges, window validation, bonds |
| `tranche-claim.test.ts` | Mark tranches paid, onchain verification |
| `legal-accept.test.ts` | Signature verification, bulk acceptance |
| `dexscreener.test.ts` | Token market data fetching, pair selection |
| `metrics.test.ts` | Performance metric collection, rate limiting |

#### Component Tests (7 files)

| File | Purpose |
|------|---------|
| `backers-modal.test.tsx` | Modal rendering, sorting, empty state |
| `funding-progress.test.tsx` | Progress bar for all raise types |
| `founder-share-card.test.tsx` | Campaign metadata display, status badges |
| `action-success-panel.test.tsx` | Success notification, explorer links |
| `token-hud.test.tsx` | Market data display, loading states |
| `token-card.test.tsx` | Token details, certified badge |
| `action-button.test.tsx` | Button states, disabled logic, variants |

#### Hook Tests (6 files)

| File | Purpose |
|------|---------|
| `useWalletAddress.test.ts` | Lowercase normalization, disconnect handling |
| `useLegalAcceptance.test.ts` | Message signing, localStorage caching |
| `useOnboarding.test.ts` | Modal state, per-wallet isolation |
| `useVibesStaking.test.ts` | Format staked amounts, cooldown timers |
| `countdown-timer.test.ts` | Oracle time caching, near-deadline warnings |
| `mock-trading.test.ts` | Demo data injection |

#### Lib/Security Tests (11+ files)

| File | Purpose |
|------|---------|
| `campaign-utils.test.ts` | Token value calculations |
| `raise-page-types.test.ts` | ETH/account formatting, Ethos color mapping |
| `viem-client.test.ts` | RPC client creation, memoization |
| `testnet-env-derivation.test.ts` | Environment label logic, feature flags |
| `server-timing.test.ts` | Performance metric collection |
| `allowlist-scoring-extended.test.ts` | Graduated scoring (DeFi, identity, Talent, etc.) |
| `admin-access-control.test.ts` | Admin route authorization |
| `cron-endpoint-auth.test.ts` | Cron endpoint authentication |
| `challenge-onchain-verification.test.ts` | Challenge verification against contract |
| `public-data-exposure.test.ts` | Sensitive data leak prevention |
| `bundle-budget.test.ts` | Bundle size limits |

---

## Recommended Test Improvements

### Priority 1 — High-Risk Untested Areas

These areas handle money, auth, or security and have **zero test coverage**.

#### 1. Web3 Contract Interaction Hooks
**Risk: High** — These hooks execute onchain transactions with real ETH.

| Hook | What to Test |
|------|-------------|
| `use-launch-hooks.ts` | Launch creation tx parameters, error handling on revert |
| `use-challenge-hooks.ts` | Challenge bond calculation, window validation before tx |
| `use-token-claim-hooks.ts` | Merkle proof submission, double-claim prevention |
| `use-vesting-hooks.ts` | Release eligibility checks, cliff enforcement |
| `use-lp-locker-hooks.ts` | LP position queries, lock status |
| `useChainAssertedWriteContract.ts` | Chain ID assertion before signing, wrong-network handling |

**Suggested approach:** Mock viem/wagmi, test that hooks construct correct calldata and handle revert/success states properly.

#### 2. External API Integrations
**Risk: Medium-High** — Failures here cause silent data corruption or broken allowlists.

| Module | What to Test |
|--------|-------------|
| `ethos.ts` | Score fetching, timeout handling, malformed response |
| `basescan-api.ts` | Transaction history parsing, rate limit handling |
| `twitter-api.ts` | OAuth token refresh, profile data extraction |
| `gitcoin-passport-api.ts` | Stamp verification, score thresholds |
| `pinata.ts` | IPFS upload/retrieval, CID validation |

**Suggested approach:** Mock HTTP responses (success, timeout, malformed, rate-limited). Verify retry logic and graceful degradation.

#### 3. Critical API Routes (Untested)
**Risk: High** — These routes modify state or handle financial operations.

| Route | What to Test |
|-------|-------------|
| `campaigns/[id]/refund` | Refund eligibility, double-refund prevention, amount calculations |
| `campaigns/[id]/milestone/*` | Milestone proof submission and verification |
| `allowlist/*` (8 routes) | Invite validation, access checks, score computation, referral codes |
| `applications/*` | Campaign application submission, approval flow |

#### 4. Auth & Session Edge Cases
**Risk: High** — Auth bypass = platform compromise.

| Module | What to Test |
|--------|-------------|
| `auth.ts` / `auth-siwe.ts` | Session expiry, token replay, concurrent sessions |
| `adminAuth.ts` | Admin privilege escalation, role validation |
| `cron-auth.ts` | CRON_SECRET validation, timing attacks |
| `siwe-session.ts` | Session store consistency, cookie security flags |

### Priority 2 — Business Logic Without Coverage

#### 5. Allowlist & Scoring Pipeline
**Risk: Medium** — Incorrect scoring affects who can participate in raises.

| Module | What to Test |
|--------|-------------|
| `allowlist-jobs.ts` | Job queue processing, retry on failure, idempotency |
| `enrichment-queue.ts` | Enrichment ordering, stale data handling |
| `quest-credit.ts` | Credit calculation, double-award prevention |

#### 6. Campaign State Management
**Risk: Medium** — State bugs can lock funds or show wrong UI.

| Module | What to Test |
|--------|-------------|
| `campaign-reindex.ts` | Reindexing correctness, partial failure recovery |
| `pending-transactions.ts` | Tx tracking, timeout handling, status reconciliation |
| `chain-verify.ts` | Onchain state verification against DB state |

#### 7. Notification & Rate Limiting
**Risk: Low-Medium** — Failures cause spam or missed notifications.

| Module | What to Test |
|--------|-------------|
| `rate-limit.ts` | Rate limit enforcement, window expiry, key isolation |
| `notifications.ts` | Delivery, deduplication, mute handling |
| `circuit-breaker.ts` | Open/half-open/closed states, reset timing |

### Priority 3 — UI & UX Correctness

#### 8. Critical User Flow Components
**Risk: Medium** — Bugs here mislead users about financial state.

| Component Area | Count | What to Test |
|----------------|-------|-------------|
| Portfolio views | ~8 components | Holdings display, pending refund amounts, claim button states |
| Campaign cards | ~6 variants | Status badges, funding percentages, time remaining |
| Onboarding/Join flow | ~5 steps | Step progression, validation, wallet connection gates |
| Tranche indicators | ~3 components | Challenge window countdown, claim eligibility |

#### 9. Data Fetching Hooks
**Risk: Low-Medium** — Stale/incorrect data in UI.

| Hook | What to Test |
|------|-------------|
| `useRealtimeCampaign.ts` | Polling interval, stale data handling |
| `useCachedCampaignDetail.ts` | Cache invalidation, fallback behavior |
| `useNotifications.ts` | Unread count, mark-as-read |
| `usePortfolioDashboard.ts` | Aggregation correctness, loading states |

### Smart Contract Remaining Gaps

| Gap | Risk | Suggested Test |
|-----|------|----------------|
| `batchDistribute` with malicious recipients | Medium | Fuzz test with contracts that revert/consume gas on `receive()` |
| `claimHolderRefund` last-claimant rounding | Low | Test: all N claimants claim; verify sum ≤ balance and dust ≤ N wei |
| Token revert / blacklist tests | Medium | Test with ERC20 that reverts on `transfer()` to specific addresses |
| Gas limits on large contributor sets | Low | Benchmark `contribute` / `claimTokens` with 500+ contributors |

---

## Coverage by Layer (Summary)

| Layer | Estimated Coverage | Verdict |
|-------|-------------------|---------|
| Smart Contracts | **~95%** | Strong — all 18 contracts tested, malicious recipient + dust + token revert tests added |
| Shared Package | **~85%** | Good — all core logic tested, minor gaps in address/schema validation |
| Web API Routes | **~20%** | Weak — 16 of ~95 routes tested; critical financial routes untested |
| Web Hooks | **~20%** | Improved — 10 of ~60 hooks tested; all Web3 transaction hooks now covered |
| Web Components | **~5%** | Minimal — 7 of ~150+ components tested |
| Web Utilities | **~25%** | Improved — 17 of ~75 files tested; auth, rate-limit, circuit-breaker, chain-verify now covered |

**Overall recommendation:** The smart contract layer is well-covered. The biggest return on investment is in **Priority 1** items — Web3 hooks, critical API routes, and auth edge cases — where bugs directly risk user funds or platform security.

---

## Test Locations

```
contracts/test/                          # Foundry tests (~600+ tests, 30 files)
├── FullLifecycleIntegration.t.sol
├── AllocationFuzz.t.sol
├── GasBenchmarks.t.sol
├── VibesTranchEscrow.t.sol
├── VibesLaunchRouterV2.t.sol
├── VibesTokenDistributorV2.t.sol
├── VibesTranchEscrowFactory.t.sol
├── VibesRegistry.t.sol
├── VibesLPLocker.t.sol
├── VibesVesting.t.sol
├── VibesStaking.t.sol
├── VibesIdentityRegistry.t.sol
├── VibesStakerRewards.t.sol
├── VibesTreasuryEscrow.t.sol
├── LPTradeSimulation.t.sol
├── CrossLayerMerkle.t.sol
├── VibesToken.t.sol
├── E2EScenarios.t.sol
├── AuditFixes.t.sol
├── SecurityAuditFixes.t.sol
├── VibesTranchEscrowEdgeCases.t.sol
├── VibesDistributorEdgeCases.t.sol
├── VibesFinalizationPhases.t.sol
├── VibesVestingFreeze.t.sol
├── TermsSignatureVerification.t.sol
├── LPForkTest.t.sol
├── VibesTranchEscrowTestnet.t.sol
├── VibesTranchEscrowFactoryTestnet.t.sol
├── AuditSecurityTests.t.sol
├── CrossContractInvariant.t.sol
└── mocks/
    ├── MockAerodromeRouter.sol
    └── MockAerodromePool.sol

packages/shared/src/__tests__/          # Shared package tests (10 suites, 215 tests)
├── allowlist-scoring.test.ts
├── capsule.test.ts
├── cross-layer-merkle.test.ts
├── erc8004.test.ts
├── hashing.test.ts
├── holder-refund-merkle.test.ts
├── merkle.test.ts
├── performance.test.ts
├── staker-rewards-merkle.test.ts
└── testnet-constants.test.ts

apps/web/src/__tests__/                 # Web app tests (~40 suites, 434 tests)
├── api/                                # API route tests (16 files)
├── components/                         # Component tests (7 files)
├── hooks/                              # Hook tests (6 files)
├── lib/                                # Utility tests (11+ files)
└── security/                           # Security-specific tests
```
