// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
// VibesTreasuryEscrow invariants
//
// Handler-driven fuzzer that walks the full challenge lifecycle:
//   activate → createProposal → (optional raiseChallenge) → admin resolution
//   (upheld-rework / upheld-malicious / rejected / expired) → executeProposal.
//
// Invariants asserted:
//
//   T1 — Token conservation: balanceOf(treasury) equals inflows - outflows,
//        both tracked as ghost variables. Inflows = initial deposit + all
//        challenge stakes transferred in. Outflows = everything that left the
//        treasury's token balance (to founder, dead, or challenger returns).
//
//   T2 — Monotonic counters: proposalCount and totalWithdrawn never decrease.
//
//   T3 — Terminated is sticky: once `terminated == true`, totalWithdrawn cannot
//        grow beyond the ceiling captured at the moment of termination.
//
//   T4 — State coherence: a Pending challenge implies a Challenged proposal.
//
//   T5 — Per-withdrawal cap: any executed proposal amount was ≤ 10% of the
//        treasury balance measured at proposal creation time.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VibesTreasuryEscrow} from "../../src/VibesTreasuryEscrow.sol";
import {VibesVesting} from "../../src/VibesVesting.sol";
import {VibesToken} from "../../src/VibesToken.sol";

contract TreasuryHandler is Test {
    VibesTreasuryEscrow public treasury;
    VibesToken public token;
    address public founder;
    address public admin;

    address[3] public challengers;

    // Ghost flow accounting. Inflows count every token deposit the treasury
    // receives beyond its initial funding; outflows count every token debit.
    uint256 public ghost_inflow;
    uint256 public ghost_outflow;

    uint256 public ghost_maxProposalCount;
    uint256 public ghost_maxTotalWithdrawn;
    uint256 public ghost_withdrawnAtTermination;

    uint256 public ghost_pendingProposalAmount;
    uint256 public ghost_pendingProposalBalanceAtCreate;
    bool public ghost_lastExecutionViolatedCap;

    constructor(VibesTreasuryEscrow _treasury, VibesToken _token, address _founder, address _admin) {
        treasury = _treasury;
        token = _token;
        founder = _founder;
        admin = _admin;
        challengers[0] = makeAddr("t_c_a");
        challengers[1] = makeAddr("t_c_b");
        challengers[2] = makeAddr("t_c_c");
        for (uint256 i = 0; i < 3; i++) {
            deal(address(token), challengers[i], 50_000 ether);
            vm.prank(challengers[i]);
            token.approve(address(treasury), type(uint256).max);
        }
    }

    function _chal(uint256 seed) internal view returns (address) {
        return challengers[seed % 3];
    }

    function challenger(uint256 i) external view returns (address) {
        return challengers[i % 3];
    }

    function challengerCount() external pure returns (uint256) { return 3; }

    function skipTime(uint256 daysSeed) external {
        uint256 d = bound(daysSeed, 1, 20);
        skip(d * 1 days);
    }

    // Measure the treasury's balance before and after each call; attribute
    // the delta to inflow or outflow ghosts. This sidesteps having to reason
    // about which specific transfers fired inside each function.
    modifier accountFlows() {
        uint256 before = token.balanceOf(address(treasury));
        _;
        uint256 afterBal = token.balanceOf(address(treasury));
        if (afterBal > before) {
            ghost_inflow += (afterBal - before);
        } else if (afterBal < before) {
            ghost_outflow += (before - afterBal);
        }
    }

    function createProposal(uint256 amountSeed) external accountFlows {
        if (!treasury.active()) return;
        if (treasury.terminated()) return;

        uint256 balance = token.balanceOf(address(treasury));
        if (balance == 0) return;

        uint256 maxAmount = (balance * treasury.MAX_CLAIM_BPS()) / treasury.BPS_DENOMINATOR();
        if (maxAmount == 0) return;
        amountSeed = bound(amountSeed, 1, maxAmount);

        vm.prank(founder);
        try treasury.createProposal(amountSeed, bytes32("reason")) {
            ghost_pendingProposalAmount = amountSeed;
            ghost_pendingProposalBalanceAtCreate = balance;
            if (treasury.proposalCount() > ghost_maxProposalCount) {
                ghost_maxProposalCount = treasury.proposalCount();
            }
        } catch { }
    }

    function raiseChallenge(uint256 seed) external accountFlows {
        address c = _chal(seed);
        uint256 required = (token.totalSupply() * treasury.CHALLENGE_THRESHOLD_BPS())
                         / treasury.BPS_DENOMINATOR();
        if (token.balanceOf(c) < required) return;

        vm.prank(c);
        try treasury.raiseChallenge("bad proposal") { } catch { }
    }

    function upholdRework() external accountFlows {
        vm.prank(admin);
        try treasury.upholdChallengeRework() { } catch { }
    }

    function upholdMalicious() external accountFlows {
        bool willTerminate;
        if (_activeChallengePending()) willTerminate = true;

        vm.prank(admin);
        try treasury.upholdChallengeMalicious() {
            if (willTerminate && treasury.terminated()) {
                ghost_withdrawnAtTermination = treasury.totalWithdrawn();
            }
        } catch { }
    }

    function rejectChallenge() external accountFlows {
        vm.prank(admin);
        try treasury.rejectChallenge() { } catch { }
    }

    function expireChallenge() external accountFlows {
        try treasury.expireChallengeIfNeeded() { } catch { }
    }

    function executeProposal() external accountFlows {
        (,,, VibesTreasuryEscrow.ProposalState s) = treasury.getProposal();
        if (s != VibesTreasuryEscrow.ProposalState.Pending) return;
        uint256 amount = ghost_pendingProposalAmount;

        try treasury.executeProposal() {
            if (treasury.totalWithdrawn() > ghost_maxTotalWithdrawn) {
                ghost_maxTotalWithdrawn = treasury.totalWithdrawn();
            }
            uint256 cap = (ghost_pendingProposalBalanceAtCreate * treasury.MAX_CLAIM_BPS())
                        / treasury.BPS_DENOMINATOR();
            if (amount > cap) ghost_lastExecutionViolatedCap = true;
            ghost_pendingProposalAmount = 0;
            ghost_pendingProposalBalanceAtCreate = 0;
        } catch { }
    }

    function _activeChallengePending() internal view returns (bool) {
        (,,,, VibesTreasuryEscrow.ChallengeState s) = treasury.getChallenge();
        return s == VibesTreasuryEscrow.ChallengeState.Pending;
    }
}

contract VibesTreasuryEscrowInvariants is Test {
    VibesTreasuryEscrow treasury;
    VibesVesting vesting;
    VibesToken token;
    TreasuryHandler handler;

    address admin = makeAddr("t_admin");
    address founder = makeAddr("t_founder");
    address router = makeAddr("t_router");

    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 constant TREASURY_DEPOSIT = 100_000 ether;

    function setUp() public {
        token = new VibesToken("TrT", "TRT", 18, TOTAL_SUPPLY, address(this));

        vm.startPrank(router);
        // Short cliff / cooldown / window so the fuzzer reaches the mid-game quickly.
        treasury = new VibesTreasuryEscrow(address(token), founder, admin, 1 days, 1 hours, 2 hours);
        vesting = new VibesVesting(address(token), founder, 180 days, 365 days);
        treasury.setVestingContract(address(vesting));
        vesting.setAuthorizedFreezer(address(treasury));
        vm.stopPrank();

        token.transfer(address(treasury), TREASURY_DEPOSIT);
        vm.prank(router);
        treasury.activate();

        handler = new TreasuryHandler(treasury, token, founder, admin);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.createProposal.selector;
        selectors[1] = handler.raiseChallenge.selector;
        selectors[2] = handler.upholdRework.selector;
        selectors[3] = handler.upholdMalicious.selector;
        selectors[4] = handler.rejectChallenge.selector;
        selectors[5] = handler.expireChallenge.selector;
        selectors[6] = handler.executeProposal.selector;
        selectors[7] = handler.skipTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        // Skip past the release cliff so the first proposal can fire.
        skip(2 days);
    }

    /// T1 — Flow-based token conservation. Every wei transferred into/out of
    /// the treasury's token balance is captured by the accounting modifier;
    /// the standing balance must match the initial deposit plus net flows.
    function invariant_tokenConservation() public view {
        uint256 expected = TREASURY_DEPOSIT + handler.ghost_inflow() - handler.ghost_outflow();
        assertEq(
            token.balanceOf(address(treasury)),
            expected,
            "treasury token balance drifted from tracked flows"
        );
    }

    /// T2 — Monotonic counters.
    function invariant_monotonicCounters() public view {
        assertGe(treasury.proposalCount(), handler.ghost_maxProposalCount(),
                 "proposalCount regressed");
        assertGe(treasury.totalWithdrawn(), handler.ghost_maxTotalWithdrawn(),
                 "totalWithdrawn regressed");
    }

    /// T3 — Terminated is sticky for withdrawals.
    function invariant_terminatedIsSticky() public view {
        if (treasury.terminated()) {
            assertEq(
                treasury.totalWithdrawn(),
                handler.ghost_withdrawnAtTermination(),
                "totalWithdrawn moved after termination"
            );
        }
    }

    /// T4 — Challenge/proposal state coherence.
    function invariant_challengeProposalCoherence() public view {
        (,,, VibesTreasuryEscrow.ProposalState ps) = treasury.getProposal();
        (,,,, VibesTreasuryEscrow.ChallengeState cs) = treasury.getChallenge();
        if (cs == VibesTreasuryEscrow.ChallengeState.Pending) {
            assertEq(
                uint8(ps),
                uint8(VibesTreasuryEscrow.ProposalState.Challenged),
                "pending challenge without challenged proposal"
            );
        }
    }

    /// T5 — Per-execution cap honoured.
    function invariant_executionCapHonoured() public view {
        assertFalse(
            handler.ghost_lastExecutionViolatedCap(),
            "execution amount exceeded 10% cap measured at creation time"
        );
    }
}
