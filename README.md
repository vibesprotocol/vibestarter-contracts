# Vibestarter Smart Contracts

Smart contracts for [Vibestarter](https://vibestarter.xyz) — a crowdfunding platform for vibecoded applications on Base. **Pre-mainnet snapshot for external review.**

> **STATE:** Pre-mainnet, awaiting external audit. Mirror of the contracts directory of the (private) main monorepo. Last sync recorded in the latest commit message. Off-chain code (web app, indexer, keeper) lives in the private repo and is not in scope for this review.

---

## Reading order for reviewers

1. **`docs/audits/pre-mainnet-friend-review-2026-05.md`** — short orientation: where to spend the first 2 hours, the two flagged findings to gut-check, how to flag stuff back. Start here.
2. **`docs/audits/external-audit-prep-2026-05.md`** — deeper technical brief (~530 lines): risk-ranked review priorities with file:line citations, threat model, deploy-script wiring, prior audit history. Read this when you want to drill in.
3. **`docs/smart-contracts.md`** — contract inventory, key constants, security patterns.
4. **`docs/privileged-roles.md`** — full admin/owner role table (M-1 master admin, M-3 operations admin, trusted signers, etc.).
5. **`docs/funding-mechanics.md`** — how money flows: raise types, tranche schedule, challenge system, refund conditions.
6. **`docs/pending-contract-changes.md`** — log of every contract change since the last external audit (PC-01..PC-05 + 48 numbered items).

---

## Build + test

```bash
git clone https://github.com/vibesprotocol/vibestarter-contracts
cd vibestarter-contracts
forge install                       # pulls openzeppelin-contracts + forge-std
forge test                          # ~890 tests
forge test --match-contract Audit   # all audit-derived suites
forge build --sizes                 # bytecode sizes (router under EIP-170)
```

---

## What's not in this mirror (vs full monorepo)

- `VibesTranchEscrowTestnet.sol` + factory — testnet variants for the now-closed Base Sepolia program (closed 2026-05)
- `AuditParity*` / `AuditTestnetParity*` tests — parity guards no longer relevant
- `DeployV2Testnet` contract + `RedeployPartial.s.sol` — testnet deploy entrypoints
- Off-chain code (web app, indexer, keeper, database)

`MockTimeOracle.sol` IS retained — used by ~20 mainnet unit tests for time control, never deployed (docstring is explicit).

## License

MIT
