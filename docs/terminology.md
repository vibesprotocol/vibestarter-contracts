# Terminology & Language Guide

> Approved language for Vibestarter communications, documentation, and UI.

---

## Approved Terms

| Use This | Not This | Reason |
|----------|----------|--------|
| Raise | ICO, token sale, offering | Legal clarity — "raise" is descriptive, not a securities term |
| Backer | Investor, buyer, purchaser | Backers support projects; they are not purchasing securities |
| Founder | Issuer, seller | The person who launched the project |
| Contribution | Investment, purchase | ETH sent to support a project |
| Token allocation | Token purchase | Tokens are allocated proportionally, not sold |
| Tranche | Milestone payment | Tranches are TIME-based, not milestone-gated |
| Challenge | Dispute, complaint | Formal onchain action with token staking |
| Escrow | Smart contract | The escrow holds funds; "smart contract" is too generic |
| Vibecoded | AI-built, AI-generated | Vibestarter's specific term for AI-assisted development |
| Origin Capsule | Verified, approved | Onchain provenance standard (onchain event: `VibesCertified`) |
| Origin capsule | Certificate, proof | The onchain provenance data structure |
| Level | Tier | Starter Card level (1-5, higher = better). Used everywhere — code, UI, and docs. Internal enum: `AllowlistLevel` with values `STARTER_1`-`STARTER_5` |
| Starter Card | Allowlist, The List | The user's identity card with level, score, and clearance label. "The List" and "allowlist" are deprecated user-facing terms — use "Starter Card" instead |

---

## Key Distinctions

### TIME-Based, Not Milestone-Based
Tranches release on a fixed time schedule (10% immediate + 15% monthly x 6). Founders do NOT need to prove milestones were completed. The community's recourse is the **challenge system**, not milestone verification.

**Correct:** "Tranche 3 unlocks 90 days after funding"
**Incorrect:** "Tranche 3 releases when milestone 3 is completed"

### LP Locked Indefinitely, Not for a Fixed Period
LP tokens are sent to the dead address (0xdead), making them permanently irrecoverable. This is NOT a time-locked position.

**Correct:** "LP is permanently locked"
**Incorrect:** "LP is locked for 12 months"

### Challenge Windows Are 72 Hours
After a founder requests a tranche, backers have exactly 72 hours to raise a challenge.

**Correct:** "72-hour challenge window"
**Incorrect:** "Challenge period" (too vague), "48-hour window" (wrong)

### Founder Tokens Vest Over 18 Months
6-month cliff (0% unlocked) + 12-month linear vesting. This is a "true delayed start" — at the 6-month mark, the founder has 0% unlocked, then tokens vest linearly from 0% to 100% over the following 12 months.

**Correct:** "6-month cliff with 12-month linear vesting (18 months total)"
**Incorrect:** "6-month cliff then 12-month unlock" (implies tokens unlock at cliff)

---

## Legal Disclaimers

### Required on All Public-Facing Pages

> Vibestarter is a crowdfunding platform. Tokens obtained through Vibestarter are utility tokens intended for use within their respective project ecosystems. Contributing to a raise is not an investment and does not constitute purchasing a security. Past performance of projects on this platform does not guarantee future results. Contributors should only contribute amounts they can afford to lose entirely.

### Required on Raise Pages

> This raise is conducted by an independent founder, not by Vibestarter. Vibestarter provides the platform infrastructure but does not endorse, guarantee, or take responsibility for the outcome of any raise. The founder's identity has been verified via X (Twitter) link, but Vibestarter cannot verify the accuracy of project claims.

### Required on Challenge/Refund Pages

> The challenge system allows token holders to flag concerns about a project's progress. Vibestarter's admin team reviews challenges and makes a determination within 72 hours. This is a platform governance mechanism, not a legal adjudication. Decisions are final onchain.

---

## Common Mistakes

| Mistake | Correction |
|---------|------------|
| Saying tokens are "bought" or "sold" | Tokens are "allocated" to backers proportional to contributions |
| Describing tranches as milestone-gated | Tranches are TIME-gated with optional challenge windows |
| Implying guaranteed returns | No returns are guaranteed; contributions may be lost |
| Calling the admin a "judge" | The admin is a platform operator reviewing challenge evidence |
| Saying LP can be "unlocked later" | LP is permanently locked to 0xdead — it cannot be recovered |
| Referring to "Vibes Protocol" in user-facing content | Use "Vibestarter" for the platform; "Vibes Protocol" is the technical layer |
