// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";

contract MathRoundingAnalysisTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant MAX_FOUNDER_BPS = 750;
    uint256 constant MIN_TREASURY_BPS = 1_000;
    uint256 constant MAX_TREASURY_BPS = 1_750;
    uint256 constant MAX_FOUNDER_PLUS_TREASURY_BPS = 2_000;
    uint256 constant LP_BPS = 1_500;
    uint256 constant ECOSYSTEM_BPS = 250;
    uint256 constant MAX_COMMUNITY_BPS = 2_000;
    uint256 constant MIN_BACKER_BPS = 5_000;

    uint256 constant ESCROW_BPS = 8_500;
    uint256 constant KICKSTART_BPS = 1_000;
    uint256 constant MONTHLY_BPS = 1_500;
    uint256 constant MONTHLY_TRANCHES = 6;
    uint256 constant PLATFORM_FEE_BPS = 250;

    function testFuzz_launchAllocationCurrentModelSumsToSupply(
        uint256 totalSupply,
        uint256 founderSeed,
        uint256 treasurySeed,
        uint256 communitySeed,
        bool stakerAllocationDisabled
    ) public pure {
        totalSupply = bound(totalSupply, 1, type(uint128).max);

        uint256 founderBps = bound(founderSeed, 0, MAX_FOUNDER_BPS);
        uint256 treasuryBps =
            treasurySeed % 4 == 0 ? 0 : bound(treasurySeed, MIN_TREASURY_BPS, MAX_TREASURY_BPS);

        if (founderBps + treasuryBps > MAX_FOUNDER_PLUS_TREASURY_BPS) {
            founderBps = MAX_FOUNDER_PLUS_TREASURY_BPS - treasuryBps;
        }

        uint256 ecosystemBps = stakerAllocationDisabled ? 0 : ECOSYSTEM_BPS;
        uint256 usedBeforeCommunity = founderBps + treasuryBps + LP_BPS + ecosystemBps;
        uint256 maxCommunityForBackerFloor = BPS - MIN_BACKER_BPS - usedBeforeCommunity;
        uint256 communityBps =
            bound(communitySeed, 0, _min(MAX_COMMUNITY_BPS, maxCommunityForBackerFloor));
        uint256 backerBps = BPS - founderBps - treasuryBps - LP_BPS - ecosystemBps - communityBps;

        uint256 founderTokens = (totalSupply * founderBps) / BPS;
        uint256 treasuryTokens = (totalSupply * treasuryBps) / BPS;
        uint256 stakerTokens = (totalSupply * ecosystemBps) / BPS;
        uint256 lpTokens = (totalSupply * LP_BPS) / BPS;
        uint256 communityTokens = (totalSupply * communityBps) / BPS;
        uint256 backerTokens = totalSupply - founderTokens - treasuryTokens - stakerTokens
            - lpTokens - communityTokens;

        assertGe(backerBps, MIN_BACKER_BPS, "valid launch should preserve backer floor");
        assertEq(
            founderTokens + treasuryTokens + stakerTokens + lpTokens + communityTokens
                + backerTokens,
            totalSupply,
            "allocations must sum exactly to total supply"
        );
        assertGe(
            backerTokens, (totalSupply * backerBps) / BPS, "backer remainder should receive dust"
        );
    }

    function testFuzz_proRataRefundMathConservesContributionsAndBoundsDust(
        uint256 c0,
        uint256 c1,
        uint256 c2,
        uint256 c3,
        uint256 c4,
        uint256 goalSeed
    ) public pure {
        (uint256[5] memory contributions, uint256 totalCommitted) =
            _boundedContributions(c0, c1, c2, c3, c4);
        uint256 goal = bound(goalSeed, 1, totalCommitted);

        uint256 sumEffective;
        uint256 sumExcess;
        for (uint256 i = 0; i < contributions.length; i++) {
            uint256 effective = totalCommitted > goal
                ? (contributions[i] * goal) / totalCommitted
                : contributions[i];
            uint256 excess = contributions[i] - effective;
            sumEffective += effective;
            sumExcess += excess;

            assertLe(
                effective, contributions[i], "effective contribution cannot exceed contribution"
            );
            assertEq(
                effective + excess, contributions[i], "per-user effective plus excess mismatch"
            );
        }

        assertLe(sumEffective, goal, "effective pro-rata allocation cannot exceed goal");
        assertEq(
            sumEffective + sumExcess, totalCommitted, "global contribution accounting mismatch"
        );
        if (totalCommitted > goal) {
            assertLt(goal - sumEffective, contributions.length, "pro-rata floor dust too large");
        }
    }

    function testFuzz_excessThenFailedRefundCannotOverpayContributor(
        uint256 contributionSeed,
        uint256 totalCommittedSeed,
        uint256 goalSeed
    ) public pure {
        uint256 contribution = bound(contributionSeed, 1, 100 ether);
        uint256 totalCommitted = bound(totalCommittedSeed, contribution, 1_000 ether);
        uint256 goal = bound(goalSeed, 1, totalCommitted);

        uint256 allocation =
            totalCommitted > goal ? (contribution * goal) / totalCommitted : contribution;
        uint256 excess = contribution - allocation;
        uint256 failedRefundAfterExcess = contribution - excess;

        assertEq(
            excess + failedRefundAfterExcess, contribution, "excess plus failed refund overpays"
        );
        assertLe(excess, contribution, "excess cannot exceed contribution");
        assertLe(failedRefundAfterExcess, contribution, "failed refund cannot exceed contribution");
    }

    function testFuzz_backerTokenClaimsStayWithinInitialPool(
        uint256 c0,
        uint256 c1,
        uint256 c2,
        uint256 c3,
        uint256 c4,
        uint256 tokenPoolSeed
    ) public pure {
        (uint256[5] memory effectiveContributions, uint256 effectiveRaised) =
            _boundedContributions(c0, c1, c2, c3, c4);
        uint256 tokenPool = bound(tokenPoolSeed, 1, type(uint128).max);

        uint256 sumClaims;
        for (uint256 i = 0; i < effectiveContributions.length; i++) {
            uint256 claim = (effectiveContributions[i] * tokenPool) / effectiveRaised;
            sumClaims += claim;
            assertLe(claim, tokenPool, "single backer claim exceeds pool");
        }

        assertLe(sumClaims, tokenPool, "backer claims exceed initial pool");
        assertLt(
            tokenPool - sumClaims, effectiveContributions.length, "backer claim dust too large"
        );
    }

    function testFuzz_trancheAndPlatformFeeMathNeverOverdraws(uint256 raised) public pure {
        raised = bound(raised, 1, type(uint128).max);

        uint256 escrowAmount = (raised * ESCROW_BPS) / BPS;
        uint256 lpAmount = raised - escrowAmount;
        uint256 expectedLpFloor = (raised * LP_BPS) / BPS;

        uint256 kickstart = (escrowAmount * KICKSTART_BPS) / BPS;
        uint256 monthly = (escrowAmount * MONTHLY_BPS) / BPS;
        uint256 totalTranches = kickstart + (monthly * MONTHLY_TRANCHES);

        assertEq(escrowAmount + lpAmount, raised, "escrow plus LP must equal raised");
        assertLe(lpAmount - expectedLpFloor, 1, "LP ceil/floor drift should be at most one wei");
        assertLe(totalTranches, escrowAmount, "tranches cannot overdraw escrow allocation");
        assertLt(escrowAmount - totalTranches, 1 + MONTHLY_TRANCHES, "tranche floor dust too large");

        uint256[7] memory trancheAmounts =
            [kickstart, monthly, monthly, monthly, monthly, monthly, monthly];
        uint256 totalFees;
        uint256 totalFounder;
        for (uint256 i = 0; i < trancheAmounts.length; i++) {
            uint256 fee = (trancheAmounts[i] * PLATFORM_FEE_BPS) / BPS;
            uint256 founderAmount = trancheAmounts[i] - fee;
            totalFees += fee;
            totalFounder += founderAmount;
            assertEq(fee + founderAmount, trancheAmounts[i], "fee plus founder amount mismatch");
        }
        assertEq(
            totalFees + totalFounder, totalTranches, "fee accounting must conserve tranche amount"
        );
    }

    function testFuzz_holderRefundsCannotOverdrawFrozenEth(
        uint256 ethSeed,
        uint256 a0,
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 a4
    ) public pure {
        uint256 frozenEth = bound(ethSeed, 1, type(uint128).max);
        (uint256[5] memory tokenAmounts, uint256 frozenSupply) =
            _boundedContributions(a0, a1, a2, a3, a4);

        uint256 sumRefunds;
        for (uint256 i = 0; i < tokenAmounts.length; i++) {
            uint256 refund = (frozenEth * tokenAmounts[i]) / frozenSupply;
            sumRefunds += refund;
        }

        assertLe(sumRefunds, frozenEth, "holder refunds exceed frozen ETH");
        assertLt(frozenEth - sumRefunds, tokenAmounts.length, "holder refund dust too large");
    }

    function testFuzz_stakerRewardsCannotOverdrawRewardPool(
        uint256 rewardSeed,
        uint256 s0,
        uint256 s1,
        uint256 s2,
        uint256 s3,
        uint256 s4
    ) public pure {
        uint256 reward = bound(rewardSeed, 1, type(uint128).max);
        (uint256[5] memory stakes, uint256 totalStaked) = _boundedContributions(s0, s1, s2, s3, s4);

        uint256 sumClaims;
        for (uint256 i = 0; i < stakes.length; i++) {
            uint256 claim = (stakes[i] * reward) / totalStaked;
            sumClaims += claim;
        }

        assertLe(sumClaims, reward, "staker claims exceed reward pool");
        assertLt(reward - sumClaims, stakes.length, "staker reward dust too large");
    }

    function test_tinyValuesDoNotOverdraw() public pure {
        uint256 raised = 1;
        uint256 escrowAmount = (raised * ESCROW_BPS) / BPS;
        uint256 lpAmount = raised - escrowAmount;
        uint256 totalTranches = ((escrowAmount * KICKSTART_BPS) / BPS)
            + (((escrowAmount * MONTHLY_BPS) / BPS) * MONTHLY_TRANCHES);

        assertEq(escrowAmount, 0, "one wei raise rounds escrow portion down");
        assertEq(lpAmount, 1, "one wei raise leaves one wei for LP by remainder");
        assertEq(totalTranches, 0, "zero escrow portion cannot create tranche claims");

        uint256 reward = 1;
        uint256 totalStaked = 3;
        uint256 claims =
            (1 * reward) / totalStaked + (1 * reward) / totalStaked + (1 * reward) / totalStaked;
        assertEq(claims, 0, "tiny reward rounds to dust rather than overdrawing");
    }

    function _boundedContributions(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4)
        internal
        pure
        returns (uint256[5] memory values, uint256 sum)
    {
        values[0] = bound(a0, 1, 100 ether);
        values[1] = bound(a1, 1, 100 ether);
        values[2] = bound(a2, 1, 100 ether);
        values[3] = bound(a3, 1, 100 ether);
        values[4] = bound(a4, 1, 100 ether);

        for (uint256 i = 0; i < values.length; i++) {
            sum += values[i];
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
