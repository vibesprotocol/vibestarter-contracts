// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VibesStaking} from "../src/VibesStaking.sol";
import {VibesToken} from "../src/VibesToken.sol";

// =========================================================================
// AUDIT REMEDIATION 2026-04 — staking snapshot read-path hardening
//
// The pre-fix implementation chose a "lazy" snapshot strategy:
//   _writeSnapshotsBeforeBalanceChange wrote only the LATEST snapshot ID
//   on each balance change, leaving intermediate snapshots blank. The view
//   _findSnapshotBalance walked forward from snapshotId+1 to currentSnapshotId
//   at read time to fill in.
//
// That walk is reachable from VibesStakerRewards.claimRewards() (state-
// changing). As snapshot count grew (one per platform raise / reward
// distribution), per-claim cost grew O(snapshotCount) on the first claim per
// raise — eventually DOS'ing claims for inactive stakers.
//
// The fix:
//   1. _writeSnapshotsBeforeBalanceChange now writes eagerly across every
//      unwritten snapshot from lastSnapshotWritten+1 to currentSnapshotId,
//      idempotent over already-written slots.
//   2. _findSnapshotBalance is O(1) on the hot path
//      (snapshotId >= lastSnapshotWritten[staker] returns current balance
//      directly), with a fallback bounded by lastSnapshotWritten — strictly
//      tighter than the pre-fix bound of currentSnapshotId — for legacy data.
//
// This suite verifies:
//   - eager backfill writes every pending snapshot before a balance change
//   - reads remain correct across long periods of staker inactivity
//   - pre-first-stake reads return 0 even after many subsequent snapshots
//   - lifecycle reads (stake → snapshots → unstake → snapshots → restake)
//     return correct historical values
//   - eager writes are idempotent over slots already populated
// =========================================================================

contract AuditStakingSnapshotHardening2026_04Test is Test {
    VibesStaking staking;
    VibesToken vibesToken;

    address staker = makeAddr("staker");
    address snapper = makeAddr("snapper");

    uint256 constant TOTAL_SUPPLY = 10_000_000 ether;
    uint256 constant STAKE_AMOUNT = 100_000 ether;

    function setUp() public {
        vibesToken = new VibesToken("VIBES", "VIBES", 18, TOTAL_SUPPLY, address(this));
        staking = new VibesStaking(address(vibesToken), address(0));
        staking.setSnapshotAuthorized(snapper, true);

        vibesToken.transfer(staker, STAKE_AMOUNT * 5);
        vm.prank(staker);
        vibesToken.approve(address(staking), type(uint256).max);
    }

    // ---------- helpers ----------

    function _takeSnapshots(uint256 n) internal returns (uint256 lastId) {
        vm.startPrank(snapper);
        for (uint256 i = 0; i < n; i++) {
            lastId = staking.takeSnapshot();
        }
        vm.stopPrank();
    }

    function _stake(uint256 amount) internal {
        vm.prank(staker);
        staking.stake(amount, 0, 0, "");
    }

    function _fullUnstake() internal {
        vm.prank(staker);
        staking.requestUnstake();
        vm.warp(block.timestamp + 8 days);
        uint256 bal = staking.stakedBalance(staker);
        vm.prank(staker);
        staking.unstake(bal);
    }

    // ---------- tests ----------

    /// @notice Pre-stake balance (0) is eagerly written to every snapshot since
    ///         lastSnapshotWritten[staker] when the user first stakes.
    function test_eagerBackfill_writesAllPendingSnapshots_onFirstStake() public {
        _takeSnapshots(5);

        // Pre-stake: no entries written yet
        for (uint256 i = 1; i <= 5; i++) {
            assertFalse(
                staking.snapshotBalanceWritten(i, staker),
                "should be unwritten before first stake"
            );
        }

        _stake(STAKE_AMOUNT);

        // Post-stake: every snapshot 1..5 must carry the pre-stake balance (0)
        for (uint256 i = 1; i <= 5; i++) {
            assertTrue(
                staking.snapshotBalanceWritten(i, staker),
                "should be eagerly populated post-stake"
            );
            assertEq(
                staking.balanceAtSnapshot(i, staker),
                0,
                "pre-stake balance was 0"
            );
        }
        assertEq(staking.lastSnapshotWritten(staker), 5);
    }

    /// @notice Balance at snapshots taken BEFORE a staker's first stake should
    ///         be 0 even after many subsequent snapshots without balance changes.
    function test_balanceAtSnapshot_returnsZero_forSnapshotsBeforeFirstStake() public {
        _takeSnapshots(50); // ids 1..50, no stakes yet
        _stake(STAKE_AMOUNT); // eagerly writes 0 to 1..50, lastWritten=50

        for (uint256 i = 1; i <= 50; i++) {
            assertEq(staking.balanceAtSnapshot(i, staker), 0);
        }

        // Snapshots taken AFTER the stake, with no further balance change,
        // resolve to current balance via the O(1) hot path.
        _takeSnapshots(10); // ids 51..60
        for (uint256 i = 51; i <= 60; i++) {
            assertEq(staking.balanceAtSnapshot(i, staker), STAKE_AMOUNT);
        }
    }

    /// @notice After stake, long inactivity does not require a forward walk —
    ///         all subsequent snapshots resolve to the current balance via the
    ///         lastSnapshotWritten fast path.
    function test_balanceAtSnapshot_longInactivity_doesNotWalk() public {
        _stake(STAKE_AMOUNT);   // pre-stake currentSnapshotId is 0, no eager writes
        _takeSnapshots(100);    // ids 1..100, no further balance change

        // lastSnapshotWritten should still be 0 (no eager write was triggered after
        // the snapshots, since no balance change has occurred).
        assertEq(staking.lastSnapshotWritten(staker), 0);

        // All 100 reads return the staked amount via the hot path
        // (snapshotId >= lastSnapshotWritten). No forward walk through 100 slots.
        for (uint256 i = 1; i <= 100; i++) {
            assertEq(staking.balanceAtSnapshot(i, staker), STAKE_AMOUNT);
        }
    }

    /// @notice Lifecycle: stake → snapshots → unstake → snapshots → restake.
    ///         Each phase's snapshots must reflect the balance at that time.
    function test_balanceAtSnapshot_correctAcrossLifecycle() public {
        _takeSnapshots(2);          // ids 1, 2 — no stake yet
        _stake(STAKE_AMOUNT);       // eager writes 0 to 1, 2; lastWritten=2; balance=STAKE_AMOUNT
        _takeSnapshots(3);          // ids 3, 4, 5 — balance unchanged at STAKE_AMOUNT

        _fullUnstake();             // eager writes STAKE_AMOUNT to 3, 4, 5; lastWritten=5; balance=0

        _takeSnapshots(2);          // ids 6, 7 — balance is 0
        _stake(STAKE_AMOUNT * 2);   // eager writes 0 to 6, 7; lastWritten=7; balance=STAKE_AMOUNT*2

        // Pre-stake era
        assertEq(staking.balanceAtSnapshot(1, staker), 0);
        assertEq(staking.balanceAtSnapshot(2, staker), 0);
        // Staked era
        assertEq(staking.balanceAtSnapshot(3, staker), STAKE_AMOUNT);
        assertEq(staking.balanceAtSnapshot(4, staker), STAKE_AMOUNT);
        assertEq(staking.balanceAtSnapshot(5, staker), STAKE_AMOUNT);
        // Unstaked era
        assertEq(staking.balanceAtSnapshot(6, staker), 0);
        assertEq(staking.balanceAtSnapshot(7, staker), 0);
        // Current balance reflects the new stake amount
        assertEq(staking.stakedBalance(staker), STAKE_AMOUNT * 2);
    }

    /// @notice Eager writes must skip already-populated slots so that a
    ///         partial-state contract (e.g. pre-fix data + new code) is not
    ///         clobbered when the user next changes their balance. Each
    ///         snapshot must record the balance at the time of the snapshot,
    ///         not the balance at the time of the most recent eager loop.
    function test_eagerWrite_isIdempotent_overAlreadyWrittenSlots() public {
        _takeSnapshots(3);
        _stake(STAKE_AMOUNT); // eager writes 0 to 1..3; lastWritten=3; balance=STAKE_AMOUNT

        _takeSnapshots(2); // ids 4, 5 — staker held STAKE_AMOUNT through both

        // Trigger another balance change — eager loop must skip 1..3 (already
        // populated with 0) and write the pre-change balance (STAKE_AMOUNT) to
        // the new slots 4, 5.
        _stake(STAKE_AMOUNT);

        assertEq(staking.balanceAtSnapshot(1, staker), 0, "slot 1 must remain 0");
        assertEq(staking.balanceAtSnapshot(2, staker), 0, "slot 2 must remain 0");
        assertEq(staking.balanceAtSnapshot(3, staker), 0, "slot 3 must remain 0");
        assertEq(staking.balanceAtSnapshot(4, staker), STAKE_AMOUNT, "slot 4 = pre-change balance");
        assertEq(staking.balanceAtSnapshot(5, staker), STAKE_AMOUNT, "slot 5 = pre-change balance");
    }
}
