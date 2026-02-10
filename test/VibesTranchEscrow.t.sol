// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {VibesToken} from "../src/VibesToken.sol";

// Mock router that implements completeFinalization
contract MockRouter {
    function completeFinalization(address) external {
        // No-op for tests - in production this creates LP and distributor
    }

    // Accept ETH sent during finalize() (LP ETH forwarded from escrow)
    receive() external payable {}
}

contract VibesTranchEscrowTest is Test {
    VibesTranchEscrow public implementation;
    VibesTranchEscrowFactory public factory;
    MockTimeOracle public timeOracle;
    VibesToken public token;
    MockRouter public mockRouter;

    address public admin = makeAddr("admin");
    address public platformWallet = makeAddr("platform");
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");
    address public backer3 = makeAddr("backer3");
    address public router;

    uint256 public constant GOAL = 10 ether;
    uint256 public constant SOFT_CAP = 5 ether;
    uint256 public constant TOKEN_SUPPLY = 1_000_000 ether;

    function setUp() public {
        // Deploy time oracle
        vm.prank(admin);
        timeOracle = new MockTimeOracle();

        // Deploy mock router that implements completeFinalization
        mockRouter = new MockRouter();
        router = address(mockRouter);

        // Deploy implementation
        implementation = new VibesTranchEscrow();

        // Deploy factory
        factory = new VibesTranchEscrowFactory(
            address(implementation),
            admin,
            platformWallet,
            address(timeOracle),
            router, // authorizedRouter
            makeAddr("lpLocker") // lpLocker
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
        return _createEscrowWithStart(raiseType, goal, softCap, deadline, 0);
    }

    function _createEscrowWithStart(
        VibesTranchEscrow.RaiseType raiseType,
        uint256 goal,
        uint256 softCap,
        uint256 deadline,
        uint256 raiseStart
    ) internal returns (VibesTranchEscrow) {
        vm.prank(router);
        address escrowAddr = factory.createEscrow(
            founder,
            address(token),
            raiseType,
            goal,
            softCap,
            deadline,
            raiseStart
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

        // finalize() now sends LP ETH directly to the router during finalization
        escrow.finalize();
    }

    function _advancePastChallengeWindow() internal {
        // Advance past the 72-hour challenge window
        vm.prank(admin);
        timeOracle.advanceTime(73 hours);
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
            0, // raiseStart
            admin,
            platformWallet,
            address(timeOracle),
            router,
            makeAddr("lpLocker")
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
            0, // raiseStart
            admin,
            platformWallet,
            address(timeOracle),
            router,
            makeAddr("lpLocker")
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

        // Contribute less than goal - can't finalize early unless goal is reached
        vm.prank(backer1);
        escrow.contribute{value: GOAL - 1 ether}();

        vm.expectRevert(VibesTranchEscrow.CampaignNotEnded.selector);
        escrow.finalize();
    }

    function test_FinalizeEarly_WhenGoalReached() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        // Contribute full goal - early finalization allowed
        vm.prank(backer1);
        escrow.contribute{value: GOAL}();

        // Should succeed without waiting for deadline
        escrow.finalize();

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Funded));
    }

    // ============ Tranche Tests ============

    function test_ClaimKickstartTranche() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Must wait for challenge window to pass
        _advancePastChallengeWindow();

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

        // Wait for challenge window then claim kickstart (tranche 0)
        _advancePastChallengeWindow();
        vm.prank(founder);
        escrow.claimTranche(0);

        // Claim tranches 1-6 (monthly, each needs 30 days + 72hr challenge window)
        for (uint8 i = 1; i <= 6; i++) {
            vm.prank(admin);
            timeOracle.advanceDays(30);
            _advancePastChallengeWindow();

            vm.prank(founder);
            escrow.claimTranche(i);
        }

        assertTrue(escrow.allTranchesClaimed());
    }

    function test_ClaimTrancheBeforeUnlock_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Claim kickstart first (after challenge window)
        _advancePastChallengeWindow();
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
        _advancePastChallengeWindow();

        vm.prank(founder);
        vm.expectRevert();
        escrow.claimTranche(1);
    }

    function test_ClaimTrancheTwice_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        _advancePastChallengeWindow();
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

        _advancePastChallengeWindow();
        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.OnlyFounder.selector);
        escrow.claimTranche(0);
    }

    // ============ Challenge Tests ============

    function test_RaiseChallenge() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Give backer1 enough tokens to challenge (0.25% for tranche 0 - graduated threshold)
        uint256 thresholdBps = escrow.getChallengeThreshold(0); // 25 bps = 0.25%
        uint256 requiredTokens = (TOKEN_SUPPLY * thresholdBps) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens);

        // Approve escrow to take tokens
        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);

        // Raise challenge
        vm.prank(backer1);
        escrow.raiseChallenge("Test challenge reason");

        VibesTranchEscrow.Challenge memory challenge = escrow.getActiveChallenge();
        assertEq(challenge.challenger, backer1);
        assertEq(challenge.amount, requiredTokens);
        assertEq(uint8(challenge.state), uint8(VibesTranchEscrow.ChallengeState.Pending));
    }

    function test_ChallengeInsufficientTokens_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Give backer1 less than required (0.25% for tranche 0)
        uint256 thresholdBps = escrow.getChallengeThreshold(0);
        uint256 requiredTokens = (TOKEN_SUPPLY * thresholdBps) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens - 1);

        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.InsufficientTokensToChallenge.selector);
        escrow.raiseChallenge("Test challenge reason");
    }

    function test_ChallengeBlocksTrancheClaim() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Setup and raise challenge (0.25% for tranche 0)
        uint256 thresholdBps = escrow.getChallengeThreshold(0);
        uint256 requiredTokens = (TOKEN_SUPPLY * thresholdBps) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens);
        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);
        vm.prank(backer1);
        escrow.raiseChallenge("Test challenge reason");

        // Founder tries to claim
        vm.prank(founder);
        vm.expectRevert(VibesTranchEscrow.ChallengePending.selector);
        escrow.claimTranche(0);
    }

    function test_UpholdChallenge_FreezesCampaign() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Setup challenge (0.25% for tranche 0)
        uint256 thresholdBps = escrow.getChallengeThreshold(0);
        uint256 requiredTokens = (TOKEN_SUPPLY * thresholdBps) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens);
        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);
        vm.prank(backer1);
        escrow.raiseChallenge("Test challenge reason");

        uint256 backerBalBefore = token.balanceOf(backer1);

        // Admin upholds (pass empty exclude addresses for test)
        address[] memory excludeAddresses = new address[](0);
        vm.prank(admin);
        escrow.upholdChallenge(excludeAddresses);

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Frozen));

        // Challenger gets stake back
        assertEq(token.balanceOf(backer1), backerBalBefore + requiredTokens);
    }

    function test_RejectChallenge_SlashesChallenger() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Setup challenge (0.25% for tranche 0)
        uint256 thresholdBps = escrow.getChallengeThreshold(0);
        uint256 requiredTokens = (TOKEN_SUPPLY * thresholdBps) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens);
        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);
        vm.prank(backer1);
        escrow.raiseChallenge("Test challenge reason");

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

        // Setup challenge (0.25% for tranche 0)
        uint256 thresholdBps = escrow.getChallengeThreshold(0);
        uint256 requiredTokens = (TOKEN_SUPPLY * thresholdBps) / 10000;
        vm.prank(founder);
        token.transfer(backer1, requiredTokens);
        vm.prank(backer1);
        token.approve(address(escrow), requiredTokens);
        vm.prank(backer1);
        escrow.raiseChallenge("Test challenge reason");

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

        address[] memory excludeAddresses = new address[](0);
        vm.prank(admin);
        escrow.freezeCampaign("Project abandoned", excludeAddresses);

        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Frozen));
    }

    function test_TransferAdmin_TwoStep() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        address newAdmin = makeAddr("newAdmin");

        // Step 1: Current admin initiates transfer
        vm.prank(admin);
        escrow.transferAdmin(newAdmin);

        // Admin is still the old admin until accepted
        assertEq(escrow.admin(), admin);
        assertEq(escrow.pendingAdmin(), newAdmin);

        // Old admin can still act
        vm.prank(admin);
        escrow.pauseCampaign();
        vm.prank(admin);
        escrow.resumeCampaign();

        // Random address can't accept
        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.OnlyPendingAdmin.selector);
        escrow.acceptAdmin();

        // Step 2: New admin accepts
        vm.prank(newAdmin);
        escrow.acceptAdmin();

        assertEq(escrow.admin(), newAdmin);
        assertEq(escrow.pendingAdmin(), address(0));

        // Old admin can't act anymore
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

        // finalize() now sends LP ETH directly to the router
        escrow.finalize();

        // Founder claims all tranches (must wait for challenge window each time)
        _advancePastChallengeWindow();
        vm.prank(founder);
        escrow.claimTranche(0);

        for (uint8 i = 1; i <= 6; i++) {
            vm.prank(admin);
            timeOracle.advanceDays(30);
            _advancePastChallengeWindow();

            vm.prank(founder);
            escrow.claimTranche(i);
        }

        assertTrue(escrow.allTranchesClaimed());
    }

    // ============ Challenge Window Tests ============

    function test_ClaimTrancheBeforeChallengeWindowEnds_Reverts() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Don't advance past challenge window
        vm.prank(founder);
        vm.expectRevert(VibesTranchEscrow.ChallengeWindowOpen.selector);
        escrow.claimTranche(0);
    }

    // ============ LP ETH Tests ============

    function test_LPEthSentDuringFinalize() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(backer1);
        escrow.contribute{value: GOAL}();

        uint256 routerBalBefore = router.balance;

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        // LP ETH should have been sent to the router during finalize
        uint256 lpEthSent = escrow.getLPEthSent();
        assertGt(lpEthSent, 0);
        assertEq(router.balance - routerBalBefore, lpEthSent);
        assertTrue(escrow.lpWithdrawn());
    }

    function test_LPEthSent_FailedRaise_NoLP() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        // Contribute less than goal
        vm.prank(backer1);
        escrow.contribute{value: GOAL - 1 ether}();

        vm.prank(admin);
        timeOracle.advanceDays(8);

        escrow.finalize();

        // Failed raise should not send LP ETH
        assertEq(escrow.getLPEthSent(), 0);
        assertFalse(escrow.lpWithdrawn());
    }

    // ============ Scheduled Raise Tests ============

    function test_ScheduledRaise_ContributeBeforeStart_Reverts() public {
        // Create escrow with raiseStart 3 days from now
        uint256 raiseStart = block.timestamp + 3 days;
        VibesTranchEscrow escrow = _createEscrowWithStart(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            raiseStart + 7 days, // deadline relative to raiseStart
            raiseStart
        );

        // Try to contribute before raiseStart
        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.RaiseNotStarted.selector);
        escrow.contribute{value: 1 ether}();
    }

    function test_ScheduledRaise_ContributeAfterStart_Succeeds() public {
        uint256 raiseStart = block.timestamp + 3 days;
        VibesTranchEscrow escrow = _createEscrowWithStart(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            raiseStart + 7 days,
            raiseStart
        );

        // Advance past raiseStart
        vm.prank(admin);
        timeOracle.advanceDays(4);

        // Should succeed now
        vm.prank(backer1);
        escrow.contribute{value: 1 ether}();

        VibesTranchEscrow.Contribution memory contrib = escrow.getContribution(backer1);
        assertEq(contrib.amount, 1 ether);
    }

    function test_ScheduledRaise_IsRaiseStarted_View() public {
        uint256 raiseStart = block.timestamp + 3 days;
        VibesTranchEscrow escrow = _createEscrowWithStart(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            raiseStart + 7 days,
            raiseStart
        );

        // Before start
        assertFalse(escrow.isRaiseStarted());

        // After start
        vm.prank(admin);
        timeOracle.advanceDays(4);
        assertTrue(escrow.isRaiseStarted());
    }

    function test_ImmediateRaise_IsRaiseStarted_AlwaysTrue() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        assertTrue(escrow.isRaiseStarted());
    }

    // ============ Graduated Challenge Threshold Tests ============

    function test_GraduatedThresholds_Values() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        // Early tranches: 0.25%
        assertEq(escrow.getChallengeThreshold(0), 25);
        assertEq(escrow.getChallengeThreshold(1), 25);
        assertEq(escrow.getChallengeThreshold(2), 25);
        // Mid tranches: 0.50%
        assertEq(escrow.getChallengeThreshold(3), 50);
        assertEq(escrow.getChallengeThreshold(4), 50);
        // Late tranches: 1.00%
        assertEq(escrow.getChallengeThreshold(5), 100);
        assertEq(escrow.getChallengeThreshold(6), 100);
    }

    // ============ Founder Update Tests ============

    function test_FounderCanPostUpdate() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(founder);
        escrow.postUpdate("QmTestCid123");
        // If no revert, it succeeded. Event emission tested implicitly.
    }

    function test_NonFounderCannotPostUpdate() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.OnlyFounder.selector);
        escrow.postUpdate("QmTestCid123");
    }

    function test_CannotPostUpdateDuringActiveRaise() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        vm.prank(founder);
        vm.expectRevert();
        escrow.postUpdate("QmTestCid123");
    }

    function test_CanPostUpdateWhenCompleted() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Claim all tranches to complete
        _advancePastChallengeWindow();
        vm.prank(founder);
        escrow.claimTranche(0);

        for (uint8 i = 1; i <= 6; i++) {
            vm.prank(admin);
            timeOracle.advanceDays(30);
            _advancePastChallengeWindow();
            vm.prank(founder);
            escrow.claimTranche(i);
        }

        // Now completed — update should still work
        vm.prank(founder);
        escrow.postUpdate("QmCompletedUpdate");
    }
}
