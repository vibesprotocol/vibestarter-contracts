# Invariant Tests

Handler-driven Foundry invariant tests covering the core fund-safety and
state-machine properties of the Vibes protocol contracts.

Each test file declares a `Handler` contract that bounds the fuzzer to the
admissible actions for its target contract (honouring preconditions like
state, time, balance, role), accumulates ghost-variable accounting, and the
invariant runner then asserts properties over the resulting end-states.

## Coverage summary

| File | Target | Invariants | Calls / invariant |
|---|---|---|---|
| `VibesStakingInvariants.t.sol` | `VibesStaking` | 3 | 128,000 |
| `VibesTreasuryEscrowInvariants.t.sol` | `VibesTreasuryEscrow` | 5 | 128,000 |
| `VibesTranchEscrowExtendedInvariants.t.sol` | `VibesTranchEscrow` | 5 | 128,000 |
| `VibesVestingInvariants.t.sol` | `VibesVesting` | 6 | 128,000 |
| *(pre-existing)* `AuditEscrowInvariants2026_04.t.sol` | `VibesTranchEscrow` | 3 | 128,000 |

**Total: 22 invariants × 128K calls = ~2.8M fuzz calls per run.**

All invariants pass against current `staging`.

## Invariant catalogue

### VibesStaking (S1–S3)

- **S1** — token conservation: `balanceOf(staking) == totalStaked`.
- **S2** — sum-of-balances: `Σ stakedBalance[a] == totalStaked`.
- **S3** — zero-balance cleanup: `stakedBalance == 0 ⇒ firstStakeTime == 0`
  and `unstakeRequestTime == 0` (so a re-staked position starts clean).

### VibesTreasuryEscrow (T1–T5)

- **T1** — token conservation: `balance == initial + inflow − outflow`,
  tracked via a flow-accounting modifier that attributes every balance delta
  on each call to inflow or outflow ghost counters.
- **T2** — monotonic counters: `proposalCount` and `totalWithdrawn` never
  regress.
- **T3** — terminated is sticky: once `terminated == true`, `totalWithdrawn`
  cannot grow past the ceiling observed at the moment of termination.
- **T4** — state coherence: a `Pending` challenge implies the proposal is in
  the `Challenged` state.
- **T5** — per-execution cap: any executed proposal amount was `≤ 10%` of the
  treasury balance measured at proposal creation time.

### VibesTranchEscrow — extended (E1–E5)

Complement to the existing `AuditEscrowInvariants2026_04` suite (I1 ETH
conservation, I2 tranche monotonicity, I4 no-tranche-after-failed):

- **E1** — contribution ledger: `Σ ghost_contributedBy[a] == totalRaised`.
- **E2** — per-contributor refund safety: an actor's refund cannot exceed
  what they contributed.
- **E3** — state monotonicity: once a terminal outcome is observed, the
  campaign cannot return to `Active`.
- **E4** — tranche-flag monotonicity: `trancheClaimed[i]` only goes
  false → true.
- **E5** — LP forwarding honoured: `state ∈ {Funded, Completed}` implies
  `lpWithdrawn == true` and `lpEthAmount` matches the observed forward.

### VibesVesting (V1–V6)

- **V1** — `released ≤ vestedAmount`.
- **V2** — `released` is monotonic.
- **V3** — `vestedAmount` is monotonic in time (while not frozen).
- **V4** — `vestedAmount ≤ totalAmount`.
- **V5** — once frozen, `released` cannot grow.
- **V6** — token conservation across `{beneficiary, contract, dead}`.

## Running

```bash
cd contracts

# Run every invariant suite:
forge test --match-path 'test/invariants/*'

# Run a single suite:
forge test --match-contract VibesTreasuryEscrowInvariants -vv
```

Each invariant is checked against the default `runs: 256, depth: 500`
(128,000 calls per invariant). Override with `--fuzz-runs` or `--fuzz-depth`
when hunting for deeper counterexamples.

## Extending

The handler pattern keeps the fuzzer in the admissible state space. To add a
new invariant:

1. Identify a property that must hold across all admissible state transitions.
2. If the property requires historical data (peaks, sums, per-actor totals),
   add a ghost variable in the handler and update it inside each relevant
   action.
3. Add a `function invariant_<name>() public view` on the `*Invariants`
   contract that asserts the property.
4. Run the suite locally and ensure the invariant holds (or, if it shouldn't,
   inspect the counterexample trace to distinguish a real bug from a handler
   bug).
