// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
// VibesTranchEscrow — extended invariants (complement to AuditEscrowInvariants2026_04)
//
// The existing AuditEscrowInvariants file covers ETH conservation, tranche
// monotonicity, and a Failed-state no-op guard. This file adds properties that
// capture per-contributor correctness and state-machine legality:
//
//   E1 — Contribution ledger sums to totalRaised. For every contributor we've
//        seeded as an actor, Σ contributions[a].amount == campaign.totalRaised.
//
//   E2 — Per-contributor refund safety. A contributor's refund can never exceed
//        what they put in. We track ghost_refundedByActor per address and
//        assert ghost_refundedByActor[a] ≤ ghost_contributedByActor[a].
//
//   E3 — State monotonicity. Once campaign.state leaves Active/Paused (i.e. a
//        terminal funding outcome is reached), it cannot return to Active.
//
//   E4 — Tranche flag monotonicity. trancheClaimed[i] can only go false→true.
//
//   E5 — LP amount consistency. If state == Funded, the LP ETH (15% of
//        effectiveRaised) was forwarded out of escrow during finalize.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VibesTranchEscrow} from "../../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../../src/VibesTranchEscrowFactory.sol";
import {MockTimeOracle} from "../../src/MockTimeOracle.sol";
import {VibesToken} from "../../src/VibesToken.sol";

contract _ExtRouterStub {
    bool public callSetLPCreated = true;
    function completeFinalization(address) external {
        if (callSetLPCreated) {
            VibesTranchEscrow(payable(msg.sender)).setLPCreated();
        }
    }
    function completeDistribution(address) external {}
    receive() external payable {}
}

contract ExtendedEscrowHandler is Test {
    VibesTranchEscrow public escrow;
    VibesToken public token;
    address public founder;
    address public platformWallet;

    address[4] public actors;

    // Per-actor ghost totals so we can assert individual refund safety.
    mapping(address => uint256) public ghost_contributedBy;
    mapping(address => uint256) public ghost_refundedBy;

    // Tranche-claim monotonicity tracking.
    mapping(uint8 => bool) public ghost_seenClaimed;

    // State-monotonicity tracking. Once the state leaves the early phase
    // (Active/Paused), record the terminal outcome so we can assert no return.
    VibesTranchEscrow.CampaignState public ghost_observedTerminal;
    bool public ghost_terminalSeen;

    // Observed peak LP amount after finalize, for E5.
    uint256 public ghost_lpForwarded;

    constructor(
        VibesTranchEscrow _escrow,
        VibesToken _token,
        address _founder,
        address _platformWallet
    ) {
        escrow = _escrow;
        token = _token;
        founder = _founder;
        platformWallet = _platformWallet;
        actors[0] = makeAddr("x_a");
        actors[1] = makeAddr("x_b");
        actors[2] = makeAddr("x_c");
        actors[3] = makeAddr("x_d");
        for (uint256 i = 0; i < 4; i++) vm.deal(actors[i], 200 ether);
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i % 4];
    }

    function actorCount() external pure returns (uint256) { return 4; }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function _recordTerminalIfNeeded() internal {
        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        if (!ghost_terminalSeen) {
            if (c.state != VibesTranchEscrow.CampaignState.Active &&
                c.state != VibesTranchEscrow.CampaignState.Paused &&
                c.state != VibesTranchEscrow.CampaignState.Uninitialized) {
                ghost_observedTerminal = c.state;
                ghost_terminalSeen = true;
            }
        }
    }

    function contribute(uint256 amountSeed, uint256 actorSeed) external {
        address a = _actor(actorSeed);
        amountSeed = bound(amountSeed, 0.01 ether, 5 ether);

        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        if (c.state != VibesTranchEscrow.CampaignState.Active) return;
        if (block.timestamp >= c.deadline) return;
        if (a.balance < amountSeed) return;

        vm.prank(a);
        try escrow.contribute{value: amountSeed}(0, 0, "") {
            ghost_contributedBy[a] += amountSeed;
        } catch { }
        _recordTerminalIfNeeded();
    }

    function finalize() external {
        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        if (c.state != VibesTranchEscrow.CampaignState.Active &&
            c.state != VibesTranchEscrow.CampaignState.Paused) return;
        if (block.timestamp < c.deadline) return;

        try escrow.finalize() {
            VibesTranchEscrow.Campaign memory c2 = escrow.getCampaign();
            if (c2.state == VibesTranchEscrow.CampaignState.Funded) {
                ghost_lpForwarded = escrow.getLPAmount();
            }
        } catch { }
        _recordTerminalIfNeeded();
    }

    function skipToDeadline() external {
        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        if (block.timestamp < c.deadline) {
            skip(c.deadline - block.timestamp + 1);
        }
    }

    function claimContributorRefund(uint256 actorSeed) external {
        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        if (c.state != VibesTranchEscrow.CampaignState.Failed) return;

        address a = _actor(actorSeed);
        uint256 balBefore = a.balance;
        vm.prank(a);
        try escrow.claimContributorRefund() {
            ghost_refundedBy[a] += (a.balance - balBefore);
        } catch { }
        _recordTerminalIfNeeded();
    }

    function claimTranche(uint8 trancheId) external {
        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        if (c.state != VibesTranchEscrow.CampaignState.Funded) return;
        if (trancheId > 6) return;
        if (trancheId != c.nextTranche) return;
        if (block.timestamp < escrow.getTrancheUnlockTime(trancheId)) return;

        if (trancheId >= 1) {
            try escrow.requestTranche(trancheId) {} catch { return; }
            skip(73 hours);
        }
        try escrow.claimTranche(trancheId) {
            ghost_seenClaimed[trancheId] = true;
        } catch { }
        _recordTerminalIfNeeded();
    }
}

contract VibesTranchEscrowExtendedInvariants is Test {
    VibesTranchEscrow impl;
    VibesTranchEscrowFactory factory;
    MockTimeOracle oracle;
    VibesToken token;
    _ExtRouterStub router;
    VibesTranchEscrow escrow;
    ExtendedEscrowHandler handler;

    address admin = makeAddr("x_admin");
    address platformWallet = makeAddr("x_platformWallet");
    address founder = makeAddr("x_founder");
    address lpLocker = makeAddr("x_lpLocker");

    function setUp() public {
        vm.startPrank(admin);
        oracle = new MockTimeOracle();
        oracle.setRealTimeMode(true);
        vm.stopPrank();

        router = new _ExtRouterStub();
        impl = new VibesTranchEscrow();
        factory = new VibesTranchEscrowFactory(
            address(impl), admin, platformWallet, address(oracle),
            address(router), lpLocker, address(0)
        );

        vm.prank(founder);
        token = new VibesToken("Ext", "EXT", 18, 1_000_000 ether, founder);

        vm.prank(address(router));
        escrow = VibesTranchEscrow(payable(factory.createEscrow(
            founder, address(token),
            VibesTranchEscrow.RaiseType.OpenEnded,
            0, 0,
            block.timestamp + 7 days,
            0
        )));

        handler = new ExtendedEscrowHandler(escrow, token, founder, platformWallet);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.contribute.selector;
        selectors[1] = handler.finalize.selector;
        selectors[2] = handler.skipToDeadline.selector;
        selectors[3] = handler.claimContributorRefund.selector;
        selectors[4] = handler.claimTranche.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// E1 — Ledger: sum of per-actor contributions equals campaign.totalRaised.
    function invariant_contributionLedger() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actor(i);
            sum += handler.ghost_contributedBy(a);
        }
        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        assertEq(sum, c.totalRaised, "sum(ghost_contributedBy) != campaign.totalRaised");
    }

    /// E2 — No contributor can receive more in refunds than they put in.
    function invariant_perContributorRefundSafety() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actor(i);
            assertLe(
                handler.ghost_refundedBy(a),
                handler.ghost_contributedBy(a),
                "contributor refunded more than they contributed"
            );
        }
    }

    /// E3 — State cannot return to Active once a terminal outcome is observed.
    function invariant_stateMonotonicity() public view {
        if (handler.ghost_terminalSeen()) {
            VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
            assertTrue(
                c.state != VibesTranchEscrow.CampaignState.Active,
                "state reverted to Active after terminal outcome"
            );
        }
    }

    /// E4 — Tranche flag monotonicity: if we observed a tranche as claimed, it stays claimed.
    function invariant_trancheFlagMonotonic() public view {
        for (uint8 t = 0; t <= 6; t++) {
            if (handler.ghost_seenClaimed(t)) {
                assertTrue(
                    escrow.trancheClaimed(t),
                    "trancheClaimed flag regressed"
                );
            }
        }
    }

    /// E5 — LP forwarding honored when funded.
    function invariant_lpForwardedWhenFunded() public view {
        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        if (c.state == VibesTranchEscrow.CampaignState.Funded ||
            c.state == VibesTranchEscrow.CampaignState.Completed) {
            assertTrue(
                escrow.lpWithdrawn(),
                "funded state reached without lpWithdrawn=true"
            );
            assertEq(
                escrow.lpEthAmount(),
                handler.ghost_lpForwarded(),
                "lpEthAmount mismatch with observed forward"
            );
        }
    }
}
