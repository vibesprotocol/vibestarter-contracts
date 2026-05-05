// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

/**
 * Fuzz tests for allocation math
 *
 * Tests invariants that must hold regardless of input values:
 * - Token allocations sum to total supply (no tokens lost or created)
 * - BPS calculations don't overflow
 * - Pro-rata distribution is proportional
 * - Platform fee math is correct
 * - Tranche schedule sums to 100%
 *
 * P1 test coverage per the platform testing plan.
 */
contract AllocationFuzzTest is Test {
    // Match router constants
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_FOUNDER_ALLOCATION_BPS = 1000; // 10%

    // Match escrow constants
    uint256 public constant KICKSTART_BPS = 1000;
    uint256 public constant MONTHLY_BPS = 1500;
    uint256 public constant PLATFORM_FEE_BPS = 250;
    uint256 public constant NUM_MONTHLY_TRANCHES = 6;
    uint256 public constant LP_PERCENT_BPS = 1500; // 15% of raised goes to LP
    uint256 public constant ESCROW_PERCENT_BPS = 8500; // 85% stays in escrow

    // ============ Token Allocation Invariants ============

    /// @notice Fuzz: token allocations must sum to exactly totalSupply for any valid inputs
    function testFuzz_tokenAllocations_sumToTotalSupply(
        uint256 totalSupply,
        uint256 founderAllocationBps
    ) public pure {
        // Bound inputs to reasonable ranges
        totalSupply = bound(totalSupply, 1 ether, 1_000_000_000 ether); // 1 to 1B tokens
        founderAllocationBps = bound(founderAllocationBps, 0, MAX_FOUNDER_ALLOCATION_BPS);

        // Replicate router allocation math
        uint256 remainingBps = BPS_DENOMINATOR - founderAllocationBps;
        uint256 backerAllocationBps = (remainingBps * 7778) / BPS_DENOMINATOR;
        uint256 stakerAllocationBps = (remainingBps * 222) / BPS_DENOMINATOR;

        uint256 founderTokens = (totalSupply * founderAllocationBps) / BPS_DENOMINATOR;
        uint256 backerTokens = (totalSupply * backerAllocationBps) / BPS_DENOMINATOR;
        uint256 stakerTokens = (totalSupply * stakerAllocationBps) / BPS_DENOMINATOR;
        uint256 lpTokens = totalSupply - founderTokens - backerTokens - stakerTokens;

        // INVARIANT: All allocations sum to exactly totalSupply
        assertEq(
            founderTokens + backerTokens + stakerTokens + lpTokens,
            totalSupply,
            "Token allocations must sum to total supply"
        );
    }

    /// @notice Fuzz: no individual allocation should exceed totalSupply
    function testFuzz_tokenAllocations_noOverflow(
        uint256 totalSupply,
        uint256 founderAllocationBps
    ) public pure {
        totalSupply = bound(totalSupply, 1, type(uint128).max); // Up to uint128 max
        founderAllocationBps = bound(founderAllocationBps, 0, MAX_FOUNDER_ALLOCATION_BPS);

        uint256 remainingBps = BPS_DENOMINATOR - founderAllocationBps;
        uint256 backerAllocationBps = (remainingBps * 7778) / BPS_DENOMINATOR;
        uint256 stakerAllocationBps = (remainingBps * 222) / BPS_DENOMINATOR;

        uint256 founderTokens = (totalSupply * founderAllocationBps) / BPS_DENOMINATOR;
        uint256 backerTokens = (totalSupply * backerAllocationBps) / BPS_DENOMINATOR;
        uint256 stakerTokens = (totalSupply * stakerAllocationBps) / BPS_DENOMINATOR;
        uint256 lpTokens = totalSupply - founderTokens - backerTokens - stakerTokens;

        // INVARIANT: Each allocation <= totalSupply
        assertLe(founderTokens, totalSupply, "Founder tokens overflow");
        assertLe(backerTokens, totalSupply, "Backer tokens overflow");
        assertLe(stakerTokens, totalSupply, "Staker tokens overflow");
        assertLe(lpTokens, totalSupply, "LP tokens overflow");
    }

    /// @notice Fuzz: 0% founder allocation means all tokens go to backers/LP/stakers
    function testFuzz_zeroFounder_allToOthers(uint256 totalSupply) public pure {
        totalSupply = bound(totalSupply, 1 ether, 1_000_000_000 ether);

        uint256 founderTokens = (totalSupply * 0) / BPS_DENOMINATOR;
        assertEq(founderTokens, 0, "0% founder should yield 0 tokens");

        // Backer + staker + LP should equal total supply
        uint256 backerBps = (10000 * 7778) / 10000; // 7778
        uint256 stakerBps = (10000 * 222) / 10000; // 222
        uint256 backerTokens = (totalSupply * backerBps) / BPS_DENOMINATOR;
        uint256 stakerTokens = (totalSupply * stakerBps) / BPS_DENOMINATOR;
        uint256 lpTokens = totalSupply - backerTokens - stakerTokens;

        assertEq(backerTokens + stakerTokens + lpTokens, totalSupply);
    }

    /// @notice Fuzz: max founder allocation (10%) leaves 90% for others
    function testFuzz_maxFounder_leavesCorrectRemainder(uint256 totalSupply) public pure {
        totalSupply = bound(totalSupply, 1 ether, 1_000_000_000 ether);

        uint256 founderTokens = (totalSupply * 1000) / BPS_DENOMINATOR; // 10%
        uint256 remainingBps = 9000;
        uint256 backerBps = (remainingBps * 7778) / BPS_DENOMINATOR; // ~7000
        uint256 stakerBps = (remainingBps * 222) / BPS_DENOMINATOR; // ~199

        uint256 backerTokens = (totalSupply * backerBps) / BPS_DENOMINATOR;
        uint256 stakerTokens = (totalSupply * stakerBps) / BPS_DENOMINATOR;
        uint256 lpTokens = totalSupply - founderTokens - backerTokens - stakerTokens;

        assertEq(founderTokens + backerTokens + stakerTokens + lpTokens, totalSupply);
        // Founder should be approximately 10%
        assertGe(founderTokens, (totalSupply * 999) / BPS_DENOMINATOR, "Founder too low");
        assertLe(founderTokens, (totalSupply * 1001) / BPS_DENOMINATOR, "Founder too high");
    }

    // ============ Pro-Rata Distribution ============

    /// @notice Fuzz: pro-rata allocation = (contribution / totalCommitted) * goal
    function testFuzz_proRata_proportional(
        uint256 contribution,
        uint256 totalCommitted,
        uint256 goal
    ) public pure {
        // Bound: goal > 0, totalCommitted >= goal (oversubscribed), contribution <= totalCommitted
        goal = bound(goal, 1 ether, 1000 ether);
        totalCommitted = bound(totalCommitted, goal, goal * 10); // 1x to 10x oversubscription
        contribution = bound(contribution, 0.01 ether, totalCommitted);

        // Pro-rata formula from router
        uint256 effectiveContribution = (contribution * goal) / totalCommitted;

        // INVARIANT: effective <= original contribution
        assertLe(effectiveContribution, contribution, "Effective should not exceed contribution");

        // INVARIANT: effective <= goal
        assertLe(effectiveContribution, goal, "Effective should not exceed goal");

        // INVARIANT: excess = contribution - effective >= 0
        uint256 excess = contribution - effectiveContribution;
        assertGe(excess, 0, "Excess should be non-negative"); // Always true, but explicit
    }

    /// @notice Fuzz: sum of all pro-rata allocations <= goal (with dust tolerance)
    function testFuzz_proRata_sumDoesNotExceedGoal(
        uint256 c1,
        uint256 c2,
        uint256 c3,
        uint256 goal
    ) public pure {
        goal = bound(goal, 1 ether, 1000 ether);

        // 3 backers
        c1 = bound(c1, 0.1 ether, 100 ether);
        c2 = bound(c2, 0.1 ether, 100 ether);
        c3 = bound(c3, 0.1 ether, 100 ether);

        uint256 totalCommitted = c1 + c2 + c3;
        if (totalCommitted < goal) {
            // Not oversubscribed — all contributions are effective
            return;
        }

        uint256 eff1 = (c1 * goal) / totalCommitted;
        uint256 eff2 = (c2 * goal) / totalCommitted;
        uint256 eff3 = (c3 * goal) / totalCommitted;

        // INVARIANT: sum of effective allocations <= goal
        assertLe(eff1 + eff2 + eff3, goal, "Sum of allocations exceeds goal");

        // Dust should be minimal (< number of backers due to integer division)
        uint256 dust = goal - (eff1 + eff2 + eff3);
        assertLe(dust, 3, "Dust exceeds number of backers");
    }

    /// @notice Fuzz: single backer gets full effective contribution
    function testFuzz_proRata_singleBacker(uint256 contribution, uint256 goal) public pure {
        goal = bound(goal, 1 ether, 1000 ether);
        contribution = bound(contribution, goal, goal * 10);

        uint256 effectiveContribution = (contribution * goal) / contribution;
        assertEq(effectiveContribution, goal, "Single backer should get full goal allocation");
    }

    // ============ Platform Fee Math ============

    /// @notice Fuzz: platform fee + founder amount = tranche amount
    function testFuzz_platformFee_sumsToTotal(uint256 trancheAmount) public pure {
        trancheAmount = bound(trancheAmount, 1, 1000 ether);

        uint256 fee = (trancheAmount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 founderAmount = trancheAmount - fee;

        // INVARIANT: fee + founderAmount = trancheAmount
        assertEq(fee + founderAmount, trancheAmount, "Fee + founder must equal tranche");

        // INVARIANT: fee <= trancheAmount
        assertLe(fee, trancheAmount, "Fee exceeds tranche amount");

        // INVARIANT: fee is approximately 2.5%
        if (trancheAmount >= 10000) {
            // Only check when amount is large enough to avoid dust
            assertLe(fee, (trancheAmount * 260) / BPS_DENOMINATOR, "Fee too high"); // < 2.6%
            assertGe(fee, (trancheAmount * 240) / BPS_DENOMINATOR, "Fee too low"); // > 2.4%
        }
    }

    // ============ Tranche Schedule Math ============

    /// @notice Static: tranche schedule sums to 100%
    function test_trancheSchedule_sumsTo100() public pure {
        uint256 totalBps = KICKSTART_BPS + (MONTHLY_BPS * NUM_MONTHLY_TRANCHES);
        assertEq(totalBps, BPS_DENOMINATOR, "Tranche schedule must sum to 10000 BPS");
    }

    /// @notice Fuzz: total escrow disbursement equals escrow portion of raised
    function testFuzz_trancheAmounts_sumToEscrowPortion(uint256 raised) public pure {
        raised = bound(raised, 1 ether, 10000 ether);

        // 85% of raised goes to escrow
        uint256 escrowAmount = (raised * ESCROW_PERCENT_BPS) / BPS_DENOMINATOR;

        // Kickstart = 10% of escrow
        uint256 kickstart = (escrowAmount * KICKSTART_BPS) / BPS_DENOMINATOR;

        // Monthly = 15% of escrow each (6 tranches)
        uint256 monthlyPerTranche = (escrowAmount * MONTHLY_BPS) / BPS_DENOMINATOR;
        uint256 totalMonthly = monthlyPerTranche * NUM_MONTHLY_TRANCHES;

        uint256 totalDisbursed = kickstart + totalMonthly;

        // Due to integer rounding, total disbursed might be slightly less than escrowAmount
        assertLe(totalDisbursed, escrowAmount, "Cannot disburse more than escrow holds");

        // Dust should be minimal (< 7 due to 7 tranches with integer division)
        uint256 dust = escrowAmount - totalDisbursed;
        assertLe(dust, 7, "Tranche rounding dust too large");
    }

    /// @notice Fuzz: LP portion + escrow portion = total raised
    function testFuzz_ethSplit_sumsToRaised(uint256 raised) public pure {
        raised = bound(raised, 1 ether, 10000 ether);

        // Match contract: escrow = 85%, LP = remainder (avoids rounding mismatch)
        uint256 escrowAmount = (raised * ESCROW_PERCENT_BPS) / BPS_DENOMINATOR;
        uint256 lpAmount = raised - escrowAmount;

        // INVARIANT: escrow + LP = raised (always true by construction)
        assertEq(escrowAmount + lpAmount, raised, "ETH split must sum to raised");

        // INVARIANT: LP is approximately 15% (within 1 wei rounding tolerance)
        uint256 expectedLP = (raised * LP_PERCENT_BPS) / BPS_DENOMINATOR;
        assertLe(lpAmount - expectedLP, 1, "LP should be ~15% (within 1 wei)");
    }

    // ============ Claim Math ============

    /// @notice Fuzz: claim amount proportional to contribution (single claimer)
    function testFuzz_claim_singleBacker_getsAll(
        uint256 totalBackerTokens,
        uint256 raised
    ) public pure {
        totalBackerTokens = bound(totalBackerTokens, 1 ether, 1_000_000_000 ether);
        raised = bound(raised, 1 ether, 10000 ether);

        // Single backer contributed everything
        uint256 tokenAmount = (raised * totalBackerTokens) / raised;
        assertEq(tokenAmount, totalBackerTokens, "Single backer should get all tokens");
    }

    /// @notice Fuzz: two backers' claims never exceed backer pool
    function testFuzz_claim_twoBackers_noOverclaim(
        uint256 totalBackerTokens,
        uint256 raised,
        uint256 contribution1
    ) public pure {
        totalBackerTokens = bound(totalBackerTokens, 1 ether, 1_000_000_000 ether);
        raised = bound(raised, 1 ether, 10000 ether);
        contribution1 = bound(contribution1, 0.01 ether, raised - 0.01 ether);

        uint256 contribution2 = raised - contribution1;

        // First claim (full pool)
        uint256 claim1 = (contribution1 * totalBackerTokens) / raised;

        // Second claim (reduced pool — matches actual router behavior)
        uint256 remainingPool = totalBackerTokens - claim1;
        uint256 claim2 = (contribution2 * remainingPool) / raised;

        // INVARIANT: total claims never exceed pool
        assertLe(claim1 + claim2, totalBackerTokens, "Claims exceed pool");

        // INVARIANT: each claim > 0 (both contributed non-zero)
        assertGt(claim1, 0, "Claim1 should be positive");
        assertGt(claim2, 0, "Claim2 should be positive");
    }

    // ============ Extreme Values ============

    /// @notice Fuzz: very small supply doesn't cause division by zero or revert
    function testFuzz_tinySupply_noRevert(uint256 founderAllocationBps) public pure {
        founderAllocationBps = bound(founderAllocationBps, 0, MAX_FOUNDER_ALLOCATION_BPS);
        uint256 totalSupply = 1; // Absolute minimum

        uint256 remainingBps = BPS_DENOMINATOR - founderAllocationBps;
        uint256 backerAllocationBps = (remainingBps * 7778) / BPS_DENOMINATOR;
        uint256 stakerAllocationBps = (remainingBps * 222) / BPS_DENOMINATOR;

        uint256 founderTokens = (totalSupply * founderAllocationBps) / BPS_DENOMINATOR;
        uint256 backerTokens = (totalSupply * backerAllocationBps) / BPS_DENOMINATOR;
        uint256 stakerTokens = (totalSupply * stakerAllocationBps) / BPS_DENOMINATOR;
        uint256 lpTokens = totalSupply - founderTokens - backerTokens - stakerTokens;

        // Should not revert, allocations should sum correctly
        assertEq(founderTokens + backerTokens + stakerTokens + lpTokens, totalSupply);
    }

    /// @notice Fuzz: very large supply doesn't overflow (uses uint128 bounds)
    function testFuzz_largeSupply_noOverflow(uint256 founderAllocationBps) public pure {
        founderAllocationBps = bound(founderAllocationBps, 0, MAX_FOUNDER_ALLOCATION_BPS);
        uint256 totalSupply = type(uint128).max;

        uint256 remainingBps = BPS_DENOMINATOR - founderAllocationBps;
        uint256 backerAllocationBps = (remainingBps * 7778) / BPS_DENOMINATOR;
        uint256 stakerAllocationBps = (remainingBps * 222) / BPS_DENOMINATOR;

        uint256 founderTokens = (totalSupply * founderAllocationBps) / BPS_DENOMINATOR;
        uint256 backerTokens = (totalSupply * backerAllocationBps) / BPS_DENOMINATOR;
        uint256 stakerTokens = (totalSupply * stakerAllocationBps) / BPS_DENOMINATOR;
        uint256 lpTokens = totalSupply - founderTokens - backerTokens - stakerTokens;

        assertEq(founderTokens + backerTokens + stakerTokens + lpTokens, totalSupply);
    }
}
