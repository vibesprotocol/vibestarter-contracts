// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {VibesToken} from "../src/VibesToken.sol";

contract VibesTranchEscrowTest is Test {
    VibesTranchEscrow public implementation;
    VibesTranchEscrowFactory public factory;
    MockTimeOracle public timeOracle;
    VibesToken public token;

    address public admin = makeAddr("admin");
    address public platformWallet = makeAddr("platform");
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");
    address public backer3 = makeAddr("backer3");

    uint256 public constant GOAL = 10 ether;
    uint256 public constant SOFT_CAP = 5 ether;
    uint256 public constant TOKEN_SUPPLY = 1_000_000 ether;

    function setUp() public {
        // Deploy time oracle
        vm.prank(admin);
        timeOracle = new MockTimeOracle();

        // Deploy implementation
        implementation = new VibesTranchEscrow();

        // Deploy factory
        factory = new VibesTranchEscrowFactory(
            address(implementation),
            admin,
            platformWallet,
            address(timeOracle)
        );

        // Deploy token
        vm.prank(founder);
        token = new VibesToken("Test Token", "TEST", 18, TOKEN_SUPPLY, founder);

        // Fund backers
        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);
        vm.deal(backer3, 100 ether);
    }

    // ============ Helper Functions ============

    function _createEscrow(
        VibesTranchEscrow.RaiseType raiseType,
        uint256 goal,
        uint256 softCap,
        uint256 deadline
    ) internal returns (VibesTranchEscrow) {
        address escrowAddr = factory.createEscrow(
            founder,
            address(token),
            raiseType,
            goal,
            softCap,
            deadline
        );
        return VibesTranchEscrow(payable(escrowAddr));
    }

    function _createFixedGoalEscrow() internal returns (VibesTranchEscrow) {
        return _createEscrow(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 7 days
        );
    }

    function _createOpenEndedEscrow(uint256 softCap) internal returns (VibesTranchEscrow) {
        return _createEscrow(
            VibesTranchEscrow.RaiseType.OpenEnded,
            0,
            softCap,
            block.timestamp + 7 days
        );
    }

    function _createProRataEscrow() internal returns (VibesTranchEscrow) {
        return _createEscrow(
            VibesTranchEscrow.RaiseType.ProRata,
            GOAL, // Hard cap
            0,
            block.timestamp + 7 days
        );
    }

    function _fundAndFinalize(VibesTranchEscrow escrow, uint256 amount) internal {
        vm.prank(backer1);
        escrow.contribute{value: amount}();

        // Move time past deadline
        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();
    }

    // ============ Initialization Tests ============

    function test_FactoryCreatesEscrow() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(campaign.founder, founder);
        assertEq(campaign.token, address(token));
        assertEq(uint8(campaign.raiseType), uint8(VibesTranchEscrow.RaiseType.FixedGoal));
        assertEq(campaign.goal, GOAL);
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Active));
    }

    function test_ImplementationCannotBeReinitialized() public {
        vm.expectRevert(VibesTranchEscrow.AlreadyInitialized.selector);
        implementation.initialize(
            founder,
            address(token),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 7 days,
            admin,
            platformWallet,
            address(timeOracle)
        );
    }

    function test_CloneCannotBeReinitalized() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.expectRevert(VibesTranchEscrow.AlreadyInitialized.selector);
        escrow.initialize(
            founder,
            address(token),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 7 days,
            admin,
            platformWallet,
            address(timeOracle)
        );
    }

    // ============ Contribution Tests ============

    function test_ContributeMinimum() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: 0.01 ether}();

        VibesTranchEscrow.Contribution memory contrib = escrow.getContribution(backer1);
        assertEq(contrib.amount, 0.01 ether);
    }

    function test_ContributeBelowMinimum_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.BelowMinContribution.selector);
        escrow.contribute{value: 0.009 ether}();
    }

    function test_ContributeMultipleTimes() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.startPrank(backer1);
        escrow.contribute{value: 1 ether}();
        escrow.contribute{value: 2 ether}();
        vm.stopPrank();

        VibesTranchEscrow.Contribution memory contrib = escrow.getContribution(backer1);
        assertEq(contrib.amount, 3 ether);
    }

    function test_ContributeMultipleBackers() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: 3 ether}();

        vm.prank(backer2);
        escrow.contribute{value: 4 ether}();

        vm.prank(backer3);
        escrow.contribute{value: 3 ether}();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(campaign.totalRaised, 10 ether);
    }

    function test_ContributeAfterDeadline_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        // Move time past deadline
        vm.prank(admin);
        timeOracle.advanceDays(8);

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.CampaignEnded.selector);
        escrow.contribute{value: 1 ether}();
    }

    function test_ContributeExceedsHardCap_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.ExceedsHardCap.selector);
        escrow.contribute{value: 11 ether}();
    }

    function test_ContributeWhenPaused_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(admin);
        escrow.pauseCampaign();

        vm.prank(backer1);
        vm.expectRevert();
        escrow.contribute{value: 1 ether}();
    }

    // ============ Finalization Tests ============

    function test_FinalizeFixedGoal_Success() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: GOAL}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Funded));
    }

    function test_FinalizeFixedGoal_Failure() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: GOAL - 1 ether}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Failed));
    }

    function test_FinalizeOpenEnded_NoSoftCap_AlwaysSucceeds() public {
        VibesTranchEscrow escrow = _createOpenEndedEscrow(0);

        vm.prank(backer1);
        escrow.contribute{value: 0.01 ether}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Funded));
    }

    function test_FinalizeOpenEnded_SoftCapMet() public {
        VibesTranchEscrow escrow = _createOpenEndedEscrow(SOFT_CAP);

        vm.prank(backer1);
        escrow.contribute{value: SOFT_CAP}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Funded));
    }

    function test_FinalizeOpenEnded_SoftCapNotMet_Fails() public {
        VibesTranchEscrow escrow = _createOpenEndedEscrow(SOFT_CAP);

        vm.prank(backer1);
        escrow.contribute{value: SOFT_CAP - 1 ether}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Failed));
    }

    function test_FinalizeProRata_AnyAmountSucceeds() public {
        VibesTranchEscrow escrow = _createProRataEscrow();

        vm.prank(backer1);
        escrow.contribute{value: 0.01 ether}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Funded));
    }

    function test_FinalizeBeforeDeadline_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: GOAL}();

        vm.expectRevert(VibesTranchEscrow.CampaignNotEnded.selector);
        escrow.finalize();
    }

    // ============ Tranche Tests ============

    function test_ClaimKickstartTranche() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        uint256 founderBalBefore = founder.balance;
        uint256 platformBalBefore = platformWallet.balance;

        vm.prank(founder);
        escrow.claimTranche(0);

        // 80% of raised goes to escrow, 10% of that is kickstart
        // 10 ETH * 0.8 * 0.1 = 0.8 ETH
        // Platform fee: 0.8 * 0.025 = 0.02 ETH
        // Founder gets: 0.8 - 0.02 = 0.78 ETH
        uint256 expectedTrancheAmount = (GOAL * 8000 / 10000) * 1000 / 10000;
        uint256 expectedFee = expectedTrancheAmount * 250 / 10000;
        uint256 expectedFounderAmount = expectedTrancheAmount - expectedFee;

        assertEq(founder.balance - founderBalBefore, expectedFounderAmount);
        assertEq(platformWallet.balance - platformBalBefore, expectedFee);
    }

    function test_ClaimAllTranches() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Claim kickstart (tranche 0)
        vm.prank(founder);
        escrow.claimTranche(0);

        // Claim tranches 1-6 (monthly)
        for (uint8 i = 1; i <= 6; i++) {
            vm.prank(admin);
            timeOracle.advanceDays(30);

            vm.prank(founder);
            escrow.claimTranche(i);
        }

        assertTrue(escrow.allTranchesClaimed());
    }

    function test_ClaimTrancheBeforeUnlock_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Claim kickstart first
        vm.prank(founder);
        escrow.claimTranche(0);

        // Try to claim tranche 1 before 30 days
        vm.prank(admin);
        timeOracle.advanceDays(15);

        vm.prank(founder);
        vm.expectRevert();
        escrow.claimTranche(1);
    }

    function test_ClaimTrancheOutOfOrder_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Try to skip kickstart and claim tranche 1
        vm.prank(admin);
        timeOracle.advanceDays(30);

        vm.prank(founder);
        vm.expectRevert();
        escrow.claimTranche(1);
    }

    function test_ClaimTrancheTwice_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(founder);
        escrow.claimTranche(0);

        // After claiming tranche 0, nextTranche becomes 1
        // So trying to claim 0 again fails the "must claim in order" check
        // which reverts with TrancheNotReady (since it's checking if tranche != nextTranche)
        vm.prank(founder);
        vm.expectRevert(); // Will revert due to order check or already claimed
        escrow.claimTranche(0);
    }

    function test_NonFounderCannotClaimTranche() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.OnlyFounder.selector);
        escrow.claimTranche(0);
    }

    // ============ Challenge Tests ============

    function test_RaiseChallenge() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Give backer1 enough tokens to challenge (0.5% of supply)
        uint256 requiredTokens = (TOKEN_SUPPLY * 50) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens);

        // Approve escrow to take tokens
        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);

        // Raise challenge
        vm.prank(backer1);
        escrow.raiseChallenge();

        VibesTranchEscrow.Challenge memory challenge = escrow.getActiveChallenge();
        assertEq(challenge.challenger, backer1);
        assertEq(challenge.amount, requiredTokens);
        assertEq(uint8(challenge.state), uint8(VibesTranchEscrow.ChallengeState.Pending));
    }

    function test_ChallengeInsufficientTokens_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Give backer1 less than required
        uint256 requiredTokens = (TOKEN_SUPPLY * 50) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens - 1);

        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.InsufficientTokensToChallenge.selector);
        escrow.raiseChallenge();
    }

    function test_ChallengeBlocksTrancheClaim() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Setup and raise challenge
        uint256 requiredTokens = (TOKEN_SUPPLY * 50) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens);
        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);
        vm.prank(backer1);
        escrow.raiseChallenge();

        // Founder tries to claim
        vm.prank(founder);
        vm.expectRevert(VibesTranchEscrow.ChallengePending.selector);
        escrow.claimTranche(0);
    }

    function test_UpholdChallenge_FreezesCampaign() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Setup challenge
        uint256 requiredTokens = (TOKEN_SUPPLY * 50) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens);
        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);
        vm.prank(backer1);
        escrow.raiseChallenge();

        uint256 backerBalBefore = token.balanceOf(backer1);

        // Admin upholds
        vm.prank(admin);
        escrow.upholdChallenge();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Frozen));

        // Challenger gets stake back
        assertEq(token.balanceOf(backer1), backerBalBefore + requiredTokens);
    }

    function test_RejectChallenge_SlashesChallenger() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Setup challenge
        uint256 requiredTokens = (TOKEN_SUPPLY * 50) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens);
        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);
        vm.prank(backer1);
        escrow.raiseChallenge();

        // Admin rejects
        vm.prank(admin);
        escrow.rejectChallenge();

        // Challenger gets 80% back (20% slashed)
        uint256 slashAmount = (requiredTokens * 2000) / 10000;
        uint256 returnAmount = requiredTokens - slashAmount;
        assertEq(token.balanceOf(backer1), returnAmount);

        // Slashed tokens went to dead address
        assertEq(token.balanceOf(address(0xdead)), slashAmount);
    }

    function test_ChallengeExpires_NoSlash() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Setup challenge
        uint256 requiredTokens = (TOKEN_SUPPLY * 50) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens);
        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);
        vm.prank(backer1);
        escrow.raiseChallenge();

        // Wait 73 hours (past 72hr window)
        vm.prank(admin);
        timeOracle.advanceTime(73 hours);

        // Anyone can expire
        escrow.expireChallengeIfNeeded();

        // Challenger gets full stake back
        assertEq(token.balanceOf(backer1), requiredTokens);

        // Campaign still funded (not frozen)
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Funded));
    }

    // ============ Refund Tests ============

    function test_ContributorRefund_FailedRaise() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: 5 ether}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        uint256 balBefore = backer1.balance;

        vm.prank(backer1);
        escrow.claimContributorRefund();

        assertEq(backer1.balance - balBefore, 5 ether);
    }

    function test_ContributorRefund_NotContributor_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: 5 ether}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        vm.prank(backer2);
        vm.expectRevert(VibesTranchEscrow.NotAContributor.selector);
        escrow.claimContributorRefund();
    }

    function test_ContributorRefund_AlreadyClaimed_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: 5 ether}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        vm.prank(backer1);
        escrow.claimContributorRefund();

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.AlreadyClaimed.selector);
        escrow.claimContributorRefund();
    }

    // ============ ProRata Tests ============

    function test_ProRata_ExcessRefund() public {
        VibesTranchEscrow escrow = _createProRataEscrow();

        // Oversubscribe: 20 ETH contributed for 10 ETH hard cap
        vm.prank(backer1);
        escrow.contribute{value: 12 ether}();

        vm.prank(backer2);
        escrow.contribute{value: 8 ether}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        // Check allocations
        (uint256 alloc1, uint256 excess1) = escrow.getProRataAllocation(backer1);
        (uint256 alloc2, uint256 excess2) = escrow.getProRataAllocation(backer2);

        // backer1: 12/20 * 10 = 6 ETH allocation, 6 ETH excess
        // backer2: 8/20 * 10 = 4 ETH allocation, 4 ETH excess
        assertEq(alloc1, 6 ether);
        assertEq(excess1, 6 ether);
        assertEq(alloc2, 4 ether);
        assertEq(excess2, 4 ether);

        // Claim excess
        uint256 balBefore = backer1.balance;
        vm.prank(backer1);
        escrow.claimExcessRefund();
        assertEq(backer1.balance - balBefore, 6 ether);
    }

    function test_ProRata_NoExcessWhenUnderSubscribed() public {
        VibesTranchEscrow escrow = _createProRataEscrow();

        vm.prank(backer1);
        escrow.contribute{value: 5 ether}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.NoExcessToRefund.selector);
        escrow.claimExcessRefund();
    }

    // ============ Admin Tests ============

    function test_PauseAndResume() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(admin);
        escrow.pauseCampaign();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Paused));

        vm.prank(admin);
        escrow.resumeCampaign();

        campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Active));
    }

    function test_ForceRefundDuringRaise() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: 5 ether}();

        vm.prank(admin);
        escrow.forceRefundDuringRaise();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Failed));

        // Backer can claim refund
        uint256 balBefore = backer1.balance;
        vm.prank(backer1);
        escrow.claimContributorRefund();
        assertEq(backer1.balance - balBefore, 5 ether);
    }

    function test_FreezeCampaign() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(admin);
        escrow.freezeCampaign("Project abandoned");

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Frozen));
    }

    function test_TransferAdmin() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        escrow.transferAdmin(newAdmin);

        assertEq(escrow.admin(), newAdmin);

        // Old admin can't act
        vm.prank(admin);
        vm.expectRevert(VibesTranchEscrow.OnlyAdmin.selector);
        escrow.pauseCampaign();

        // New admin can
        vm.prank(newAdmin);
        escrow.pauseCampaign();
    }

    function test_NonAdminCannotPause() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.OnlyAdmin.selector);
        escrow.pauseCampaign();
    }

    // ============ Time Oracle Tests ============

    function test_TimeOracleControlsTime() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        // Initial time should match oracle
        assertEq(escrow.getCurrentTime(), timeOracle.getTime());

        // Advance oracle time
        vm.prank(admin);
        timeOracle.advanceDays(5);

        // Escrow should reflect new time
        assertEq(escrow.getCurrentTime(), timeOracle.getTime());
    }

    // ============ Edge Case Tests ============

    function test_ZeroContributions_FailedRaise() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Failed));
    }

    function test_ExactGoalAmount_Succeeds() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: GOAL}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Funded));
    }

    function test_SingleContributor_FullFlow() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        // Single backer funds entire goal
        vm.prank(backer1);
        escrow.contribute{value: GOAL}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        // Founder claims all tranches
        vm.prank(founder);
        escrow.claimTranche(0);

        for (uint8 i = 1; i <= 6; i++) {
            vm.prank(admin);
            timeOracle.advanceDays(30);

            vm.prank(founder);
            escrow.claimTranche(i);
        }

        assertTrue(escrow.allTranchesClaimed());
    }
}
