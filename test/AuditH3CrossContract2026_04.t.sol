// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =========================================================================
// AUDIT REMEDIATION 2026-04 — H-3 cross-contract regression
//
// Two regressions for the H-3 patch (token+ETH double-dip via state drift between
// VibesRouterExtension._claimTokensInternal and VibesTranchEscrow.emergencyRefundFunded):
//
//   test_H3_emergencyRefund_blocksAfterRouterPhaseProgress
//      simulates a router whose finalizationPhase[token] returns non-zero (LPComplete or
//      FullyComplete); admin's emergencyRefundFunded must revert "Router finalization
//      progressed" rather than rolling state to Failed.
//
//   test_H3_emergencyRefund_succeedsWhenRouterPhaseZero
//      same setup but router reports phase=0 — emergency refund proceeds normally.
// =========================================================================

import {Test} from "forge-std/Test.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {VibesToken} from "../src/VibesToken.sol";

/// Router that records lpCreated=false (rescue path) AND exposes a settable finalizationPhase.
/// Used to exercise the H-3 cross-contract guard inside emergencyRefundFunded.
contract H3MockRouter {
    mapping(address => uint8) public phase;
    function completeFinalization(address) external {
        // Intentionally do NOT call setLPCreated — simulates rescue-branch escrow state.
    }
    function completeDistribution(address) external {}
    function setPhase(address token, uint8 p) external { phase[token] = p; }
    function finalizationPhase(address token) external view returns (uint8) { return phase[token]; }
    receive() external payable {}
}

contract AuditH3CrossContract is Test {
    VibesTranchEscrow impl;
    VibesTranchEscrowFactory factory;
    MockTimeOracle oracle;
    VibesToken token;
    H3MockRouter router;

    address admin = makeAddr("admin");
    address platformWallet = makeAddr("platform");
    address founder = makeAddr("founder");
    address backer1 = makeAddr("backer1");
    address backer2 = makeAddr("backer2");
    address lpLocker = makeAddr("lpLocker");

    uint256 constant GOAL = 5 ether;

    function setUp() public {
        vm.startPrank(admin);
        oracle = new MockTimeOracle();
        oracle.setRealTimeMode(true);
        vm.stopPrank();

        router = new H3MockRouter();
        impl = new VibesTranchEscrow();

        factory = new VibesTranchEscrowFactory(
            address(impl), admin, platformWallet, address(oracle),
            address(router), lpLocker, address(0)
        );

        vm.prank(founder);
        token = new VibesToken("H3", "H3", 18, 1_000_000 ether, founder);

        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);
    }

    function _createAndFund() internal returns (VibesTranchEscrow esc) {
        vm.prank(address(router));
        esc = VibesTranchEscrow(payable(factory.createEscrow(
            founder,
            address(token),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 7 days,
            0
        )));

        vm.prank(backer1);
        esc.contribute{value: GOAL}(0, 0, "");

        skip(8 days);
        esc.finalize();
        // Router did NOT call setLPCreated → escrow is Funded, lpCreated=false (rescue path)
    }

    function test_H3_emergencyRefund_blocksAfterRouterPhaseProgress() public {
        VibesTranchEscrow esc = _createAndFund();

        // Mark router as having advanced past Phase 1 (LPComplete = 1).
        router.setPhase(address(token), 1);

        vm.prank(admin);
        vm.expectRevert(bytes("Router finalization progressed"));
        esc.emergencyRefundFunded();

        // FullyComplete (phase=2) also blocks.
        router.setPhase(address(token), 2);
        vm.prank(admin);
        vm.expectRevert(bytes("Router finalization progressed"));
        esc.emergencyRefundFunded();
    }

    function test_H3_emergencyRefund_succeedsWhenRouterPhaseZero() public {
        VibesTranchEscrow esc = _createAndFund();

        // Router phase is None (default 0) → emergency refund proceeds.
        // Need to top-up the LP-forwarded ETH first to satisfy F3 solvency check.
        uint256 lpAmt = esc.getLPAmount();
        vm.deal(admin, lpAmt);
        vm.prank(admin);
        esc.adminTopUp{value: lpAmt}();

        vm.prank(admin);
        esc.emergencyRefundFunded();

        VibesTranchEscrow.Campaign memory c = esc.getCampaign();
        assertEq(uint8(c.state), uint8(VibesTranchEscrow.CampaignState.Failed));
    }
}
