# Security Testing Plan — Vibestarter

**Date:** 2026-02-21 (original), updated 2026-03-23
**Status:** Pre-launch security audit — **Auth migration note:** Privy was fully replaced by RainbowKit + SIWE (iron-session) in Feb 2026. All Privy references below are historical.
**Scope:** All API endpoints, database access, auth flows, scoring logic, cron jobs, smart contract interaction layer

---

## Executive Summary

After a thorough codebase audit of 70+ API routes, authentication modules, database schema, scoring logic, cron jobs, and smart contract integration, this document identifies **every attack surface** and defines end-to-end tests to verify each one.

The findings are organized by severity. Each section includes:
- What the vulnerability is
- Why it matters
- What the test verifies
- Which files are affected

---

## P0 — CRITICAL (Must fix before any real users)

### 1. Database Credentials Committed to Git

**Files:**
- `.env.production` (line 2) — live Supabase DATABASE_URL with password
- `.env.staging` (lines 2-5) — DATABASE_URL, AUTH_SECRET, GITHUB_CLIENT_SECRET, TWITTER_CLIENT_SECRET, Vercel OIDC token

**Risk:** Anyone with repo access (or if the repo was ever public/forked) has full read/write access to the production database. The `.env.staging` also contains GitHub and Twitter OAuth client secrets.

**Action Required:**
1. Rotate ALL exposed credentials immediately (Supabase password, GitHub OAuth, Twitter OAuth, AUTH_SECRET)
2. Remove `.env.production` and `.env.staging` from the repo
3. Add them to `.gitignore`
4. Purge from git history with `git filter-repo` or BFG
5. Move all secrets to Vercel environment variables (dashboard only)

**Test:** `SEC-CRED-001` — Verify no secret files are committed

---

### 2. Wallet Auth Has No Signature Verification — Header Spoofing

**Files:**
- `apps/web/src/lib/auth.ts` — `requireWalletAuth()` only checks header presence
- `apps/web/src/lib/adminAuth.ts` — `requireOffChainAdmin()` only checks header value

**Risk:** ~~The `x-wallet-address` header is a plain string set by the frontend Privy SDK. There is **zero cryptographic verification** that the caller actually controls the wallet.~~ **FIXED (Feb 2026):** Privy was replaced by RainbowKit + SIWE (iron-session). All routes now use `requireWalletAuth()` or `requireStrongWalletAuth()` which verify the SIWE session. The original risk was:

```bash
# Impersonate any user
curl -H "x-wallet-address: 0xVICTIM..." /api/account

# Impersonate admin
curl -H "x-wallet-address: 0x91f3ACF393dE794E7291FBF36DFc408Da617cfF0" /api/admin/inspect
```

This means:
- Any person can act as any user (edit their profile, post updates, claim tranches)
- Any person can act as admin (reset users, moderate campaigns, view all data)
- All authorization in the app is effectively decorative

**Tests:**
- `SEC-AUTH-001` — Verify header-only auth is rejected (negative test documenting the gap)
- `SEC-AUTH-002` — Verify admin endpoints reject non-admin wallets
- `SEC-AUTH-003` — Verify admin endpoints reject spoofed admin wallet headers (demonstrates the vulnerability)
- `SEC-AUTH-004` — Verify founder-only endpoints reject non-founder wallets

---

### 3. Contribution Endpoint Has No Auth Check

**File:** `apps/web/src/app/api/campaigns/[id]/contribute/route.ts`

**Risk:** The POST handler never calls `requireWalletAuth()`. The wallet comes from the request body, not from an authenticated session. Anyone can:
- Record fake contributions for any wallet
- Inflate campaign totalRaised
- Create backer records for wallets that never contributed

**Tests:**
- `SEC-CONTRIB-001` — Verify contributions can be recorded without any auth header (documents the gap)
- `SEC-CONTRIB-002` — Verify contributions with fabricated txHash are accepted (no onchain verification)
- `SEC-CONTRIB-003` — Verify a user can record contributions for a different wallet

---

### 4. No Onchain Transaction Verification

**Files:**
- `apps/web/src/app/api/campaigns/[id]/contribute/route.ts` — accepts any txHash
- `apps/web/src/app/api/campaigns/[id]/tranches/[tid]/claim/route.ts` — accepts any txHash
- `apps/web/src/app/api/campaigns/[id]/tranches/[tid]/challenge/route.ts` — no bond verification

**Risk:** The database records contributions, tranche claims, and challenges without ever checking that corresponding onchain transactions actually occurred. An attacker could:
- Record phantom contributions (fake txHash, inflated amounts)
- Mark tranches as PAID without actually claiming onchain
- Submit challenges without staking the required tokens

**Tests:**
- `SEC-ONCHAIN-001` — Verify contribute accepts non-existent txHash
- `SEC-ONCHAIN-002` — Verify tranche claim accepts non-existent txHash
- `SEC-ONCHAIN-003` — Verify the amount in the DB matches what was sent (not verified against chain)

---

### 5. Cron Endpoints Have No/Weak Auth

**Files:**
- `apps/web/src/app/api/cron/allowlist-sybil/route.ts` — **ZERO auth** — completely open
- `apps/web/src/app/api/cron/allowlist-referrals/route.ts` — likely same
- `apps/web/src/app/api/cron/allowlist-follow-check/route.ts` — likely same
- `apps/web/src/app/api/cron/enrichment/route.ts` — checks `CRON_SECRET` **but bypasses if env var is unset**

**Risk:** Anyone can trigger sybil checks, referral crediting, follow verification, and enrichment jobs by simply hitting the URL. The enrichment cron's auth is bypassed when `CRON_SECRET` is not set (line 15: `if (cronSecret && authHeader !== ...)`).

**Tests:**
- `SEC-CRON-001` — Verify sybil cron accepts unauthenticated requests
- `SEC-CRON-002` — Verify enrichment cron bypasses auth when CRON_SECRET is unset
- `SEC-CRON-003` — Verify enrichment cron rejects wrong bearer token when CRON_SECRET is set

---

## P1 — HIGH (Should fix before launch)

### 6. Admin Wallet Addresses Are Public Knowledge

**File:** `apps/web/src/lib/adminAuth.ts` (lines 26-29)

**Risk:** The admin wallet addresses are hardcoded in the source code. Combined with issue #2 (no signature verification), anyone who reads the source can impersonate admin by sending:
```
x-wallet-address: 0x91f3ACF393dE794E7291FBF36DFc408Da617cfF0
```

**Tests:**
- `SEC-ADMIN-001` — Verify all admin endpoints check admin auth
- `SEC-ADMIN-002` — Verify /api/admin/inspect returns full DB records (data exposure scope)
- `SEC-ADMIN-003` — Verify /api/admin/reset-user performs cascading deletes
- `SEC-ADMIN-004` — Verify /api/admin/campaigns/[id]/moderate can modify campaign content

---

### 7. Allowlist Status Endpoint Has No Auth

**File:** `apps/web/src/app/api/allowlist/status/route.ts`

**Risk:** Anyone can query any wallet's allowlist data by passing it as a query parameter. Exposes:
- Level assignment
- Composite score (exact number)
- Sybil flag status
- Referral code (can be used by others)
- Quest completion status
- X username linkage

**Tests:**
- `SEC-ALLOWLIST-001` — Verify status endpoint returns data for any wallet without auth
- `SEC-ALLOWLIST-002` — Verify composite score and level are exposed
- `SEC-ALLOWLIST-003` — Verify sybil flag status is exposed
- `SEC-ALLOWLIST-004` — Verify referral code is exposed (allows theft of referrals)

---

### 8. Scoring System Fully Reverse-Engineerable

**File:** `apps/web/src/lib/allowlist-scoring.ts`

**Risk:** Despite comments saying "Formula and weights are internal — never exposed to users", the entire scoring engine is in the shared package with exact thresholds:
- Level thresholds: STARTER_5 >= 300, STARTER_4 >= 200, STARTER_3 >= 130, STARTER_2 >= 60, STARTER_1 >= 0
- All component weights (Ethos: 0-50, Wallet Age: 0-25, TX Count: 0-20, DeFi: 5, ENS: 5)
- Referral point values (3, 1.5 per bracket)
- Quest point values (SHARE_CARD: 15, COMPLETE_PROFILE: 5, etc.)

Users can calculate exactly how to maximize their level.

**Tests:**
- `SEC-SCORE-001` — Verify level thresholds are exported and accessible
- `SEC-SCORE-002` — Verify scoring weights are deterministic and predictable
- `SEC-SCORE-003` — Verify composite score is returned in status API response

---

### 9. Referral System Is Gameable With Multiple Wallets

**Files:**
- `apps/web/src/app/api/allowlist/signup/route.ts` (step 1, lines 98-106)

**Risk:** Self-referral prevention only checks `referrer.wallet !== wallet`. An attacker with multiple wallets (trivial to create) can:
1. Sign up Wallet A, get referral code
2. Sign up Wallet B using Wallet A's referral code
3. Repeat with Wallets C, D, E... to farm referral points
4. Each referral gives 3 points (first 10), boosting level significantly

The 48-hour credit delay (cron) is the only speed bump, but doesn't prevent the attack.

**Tests:**
- `SEC-REFERRAL-001` — Verify self-referral is blocked (same wallet)
- `SEC-REFERRAL-002` — Verify cross-wallet referral is allowed (documents gaming vector)
- `SEC-REFERRAL-003` — Verify referral count impacts level calculation

---

### 10. Tranche Claim Has No Status Gate

**File:** `apps/web/src/app/api/campaigns/[id]/tranches/[tid]/claim/route.ts`

**Risk:** The endpoint checks if the tranche is already PAID but does NOT verify the tranche is in a claimable state (APPROVED or REQUESTED with expired challenge window). A founder could mark a tranche as PAID even if it's in UNREQUESTED or FORFEITED status.

**Tests:**
- `SEC-TRANCHE-001` — Verify UNREQUESTED tranche can be marked as PAID (documents the gap)
- `SEC-TRANCHE-002` — Verify FORFEITED tranche can be marked as PAID (documents the gap)
- `SEC-TRANCHE-003` — Verify any status except PAID is accepted for update

---

## P2 — MEDIUM (Should address before scaling)

### 11. No Rate Limiting on Any Endpoint

**Risk:** No rate limiting exists on any API route. Attackers can:
- Brute-force allowlist signups
- Spam contribution records
- Flood cron endpoints
- Enumerate all wallets via status endpoint
- DoS the scoring calculation (which calls 5 external APIs per request)

**Tests:**
- `SEC-RATE-001` — Verify rapid repeated requests are all accepted
- `SEC-RATE-002` — Verify step 4 scoring triggers external API calls (potential for abuse/cost)

---

### 12. Public Endpoints Expose Sensitive Data

**Files:**
- `/api/campaigns/[id]/contribute` GET — lists all contributions with wallet addresses
- `/api/campaigns/[id]/top-backers` GET — shows top contributors
- `/api/backings/recent` GET — public feed of all backing activity
- `/api/campaigns` GET — all campaigns
- `/api/legal/status` GET — legal acceptance status by wallet (no auth)
- `/api/metrics` GET — platform-wide metrics
- `/api/staking/stats` GET — staking statistics

**Risk:** Wallet addresses, contribution amounts, and activity patterns are publicly queryable. Combined with the allowlist status endpoint, an attacker can build a complete profile of any user.

**Tests:**
- `SEC-DATA-001` — Verify contributions are publicly listable without auth
- `SEC-DATA-002` — Verify legal status is queryable for any wallet
- `SEC-DATA-003` — Verify wallet addresses are included in public responses

---

### 13. Campaign Update/Edit Has Weak Ownership Check

**Files:**
- `apps/web/src/app/api/campaigns/[id]/updates/route.ts`
- `apps/web/src/app/api/campaigns/[id]/route.ts` (PUT)

**Risk:** If these endpoints rely on the spoofable `x-wallet-address` header for founder verification, any user can post updates to any campaign or edit campaign details.

**Tests:**
- `SEC-CAMPAIGN-001` — Verify campaign PUT checks founder ownership
- `SEC-CAMPAIGN-002` — Verify campaign updates POST checks founder ownership
- `SEC-CAMPAIGN-003` — Verify non-founder wallet is rejected

---

### 14. Allowlist Signup Step Enforcement Is Loose

**File:** `apps/web/src/app/api/allowlist/signup/route.ts`

**Risk:** Step enforcement uses `signupStep < N` checks but:
- Step 3 (`handleStep3`) only checks `signupStep < 2` — should check `< 3`
- Step 6 (`handleStep6`) checks `signupStep < 5` — skips the step 5 card sharing gate
- Steps use `Math.max(user.signupStep, N)` which prevents backward movement but doesn't enforce linear progression

**Tests:**
- `SEC-STEP-001` — Verify step 6 can be reached without completing step 5 card share
- `SEC-STEP-002` — Verify step skipping is possible via direct API calls
- `SEC-STEP-003` — Verify step 3 follow prompt can be skipped

---

## P3 — LOW (Track for future hardening)

### 15. X Account Verification Gaps

**Risk:**
- X account age check (30 days) relies on Twitter API data which may be unavailable
- Follower count check (10 followers) can be gamed with follower services
- `skipTwitter` option in step 2 bypasses all X verification

**Tests:**
- `SEC-TWITTER-001` — Verify skipTwitter bypasses all X checks
- `SEC-TWITTER-002` — Verify null X profile data (API failure) is handled

---

### 16. Legal Acceptance Signature Can Be Replayed

**File:** `apps/web/src/app/api/legal/accept/route.ts`

**Risk:** The signature message format is deterministic based on agreement type + version + content hash. If a user signs once, the same signature is valid forever (no nonce or timestamp).

**Tests:**
- `SEC-LEGAL-001` — Verify signature format is deterministic
- `SEC-LEGAL-002` — Verify duplicate acceptance is handled

---

### 17. Demo/Debug Endpoints in Production

**Files:**
- `/api/demo/backers` — demo data endpoint
- Debug flags: `DEBUG_BYPASS_FOLLOW_CHECK`, `DEBUG_ALLOWLIST_WALLETS`

**Risk:** If these endpoints or flags are active in production, they provide bypass mechanisms.

**Tests:**
- `SEC-DEBUG-001` — Verify demo endpoints exist
- `SEC-DEBUG-002` — Verify debug flags can alter behavior

---

## Test Implementation Plan

### Test File Structure
```
apps/web/src/__tests__/security/
├── auth-header-spoofing.test.ts       # SEC-AUTH-*
├── admin-access-control.test.ts       # SEC-ADMIN-*
├── contribution-auth-gap.test.ts      # SEC-CONTRIB-*, SEC-ONCHAIN-*
├── cron-endpoint-auth.test.ts         # SEC-CRON-*
├── allowlist-data-exposure.test.ts    # SEC-ALLOWLIST-*, SEC-SCORE-*
├── referral-gaming.test.ts            # SEC-REFERRAL-*
├── tranche-status-gate.test.ts        # SEC-TRANCHE-*
├── public-data-exposure.test.ts       # SEC-DATA-*
├── campaign-ownership.test.ts         # SEC-CAMPAIGN-*
├── signup-step-enforcement.test.ts    # SEC-STEP-*
└── credential-exposure.test.ts        # SEC-CRED-*
```

### Test Approach
All tests use Vitest with mocked Prisma (matching existing test patterns). Tests document both:
1. **What currently works** (existing protections)
2. **What currently fails** (security gaps that need fixing)

Tests that document vulnerabilities are marked with `// VULNERABILITY:` comments and use `it.todo()` or explicit failure documentation so the issues are visible in test output.

### Running Tests
```bash
# Run all security tests
pnpm --filter web test -- --testPathPattern="security"

# Run specific category
pnpm --filter web test -- --testPathPattern="security/auth"
```

---

## Recommended Fix Priority

| Priority | Issue | Effort | Impact |
|----------|-------|--------|--------|
| **IMMEDIATE** | Rotate exposed credentials (#1) | 1h | Prevents DB compromise |
| **P0** | ~~Add Privy server-side token verification (#2)~~ **FIXED** — SIWE (iron-session) replaced Privy, Feb 2026 | — | Auth fully resolved |
| **P0** | Add `requireWalletAuth()` to contribute endpoint (#3) | 30m | Prevents fake contributions |
| **P0** | Add onchain tx verification for contributions (#4) | 1-2d | Prevents phantom contributions |
| **P0** | Add CRON_SECRET check to all cron endpoints (#5) | 1h | Prevents unauthorized triggers |
| **P1** | Add auth to allowlist status endpoint (#7) | 30m | Prevents data scraping |
| **P1** | Move scoring thresholds server-side (#8) | 2h | Reduces gaming |
| **P1** | Add Sybil-resistance to referrals (#9) | 1d | Prevents referral farming |
| **P1** | Add tranche status validation (#10) | 1h | Prevents premature claims |
| **P2** | Add rate limiting (middleware) (#11) | 1d | Prevents abuse |
| **P2** | Add auth to public data endpoints (#12) | 2h | Reduces exposure |
| **P2** | Fix step enforcement logic (#14) | 1h | Prevents step skipping |

---

## Pre-Mainnet Audit Scope Additions (March 2026 White-Hat Audit Response)

### XSS Penetration Testing

**Status:** Not yet executed
**Priority:** Pre-mainnet

Server-side sanitization exists (`sanitizeDescription()` in `lib/markdown-utils.ts`, image URL whitelist to Vercel Blob, no `dangerouslySetInnerHTML`), but no manual penetration test has validated the full pipeline.

**Test targets:**
- Campaign title, description, milestone text
- Founder bio (account settings)
- Challenge reason text
- Any other founder-supplied free-text fields

**Test payloads:**
- `<script>alert(1)</script>`
- `<img src=x onerror=alert(1)>`
- Markdown links with `javascript:` protocol
- Unicode/encoding bypasses (e.g., `&#x6A;avascript:`)
- Nested/malformed HTML tags

**Verify rendered output on:**
- Campaign detail page (`/raises/[txHash]`)
- Campaign cards on homepage and browse pages
- Founder profile display
- Challenge details in admin panel

### V1→V2 Pattern Inheritance Review

**Status:** Not yet executed
**Priority:** Pre-mainnet

No `src/legacy/` directory exists in the current repo and no V1 contracts are present. However, as a pre-mainnet audit diligence item, the V2 architecture should be reviewed for any patterns carried forward from the original prototype.

**Focus areas:**
- Fund release logic (tranche calculations, escrow release paths)
- Access control patterns (admin, founder, contributor permissions)
- Reentrancy patterns (CEI compliance, nonReentrant usage)
- Token distribution logic (Merkle tree, claim mechanics)
