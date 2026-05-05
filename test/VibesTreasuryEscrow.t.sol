// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesTreasuryEscrow} from "../src/VibesTreasuryEscrow.sol";
import {VibesVesting} from "../src/VibesVesting.sol";
import {VibesToken} from "../src/VibesToken.sol";

contract VibesTreasuryEscrowTest is Test {
    VibesTreasuryEscrow public treasury;
    VibesVesting public vesting;
    VibesToken public token;

    address public router = makeAddr("router");
    address public founder = makeAddr("founder");
    address public admin = makeAddr("admin");
    address public backer = makeAddr("backer");
    address public stranger = makeAddr("stranger");

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant TREASURY_AMOUNT = 100_000 ether; // 10% of supply
    uint256 public constant VESTING_AMOUNT = 75_000 ether;   // 7.5% of supply

    function setUp() public {
        token = new VibesToken("Test", "TST", 18, TOTAL_SUPPLY, address(this));

        // Deploy treasury and vesting as the router (authorizedStarter = msg.sender)
        vm.startPrank(router);
        treasury = new VibesTreasuryEscrow(address(token), founder, admin, 180 days, 14 days, 72 hours);
        vesting = new VibesVesting(address(token), founder, 180 days, 365 days);
        // Link treasury <-> vesting
        treasury.setVestingContract(address(vesting));
        vesting.setAuthorizedFreezer(address(treasury));
        vm.stopPrank();

        // Transfer treasury tokens
        token.transfer(address(treasury), TREASURY_AMOUNT);
        // Transfer vesting tokens and initialize
        token.transfer(address(vesting), VESTING_AMOUNT);
        vm.prank(router);
        vesting.initializeAmount();

        // Give backer enough tokens for challenging (0.5% of supply = 5000 tokens)
        token.transfer(backer, 10_000 ether);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsState() public view {
        assertEq(address(treasury.token()), address(token));
        assertEq(treasury.founder(), founder);
        assertEq(treasury.admin(), admin);
        assertEq(treasury.authorizedStarter(), router);
        assertFalse(treasury.active());
        assertFalse(treasury.terminated());
        assertEq(treasury.vestingContract(), address(vesting));
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert(VibesTreasuryEscrow.ZeroAddress.selector);
        new VibesTreasuryEscrow(address(0), founder, admin, 180 days, 14 days, 72 hours);
    }

    function test_constructor_revertsZeroFounder() public {
        vm.expectRevert(VibesTreasuryEscrow.ZeroAddress.selector);
        new VibesTreasuryEscrow(address(token), address(0), admin, 180 days, 14 days, 72 hours);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert(VibesTreasuryEscrow.ZeroAddress.selector);
        new VibesTreasuryEscrow(address(token), founder, address(0), 180 days, 14 days, 72 hours);
    }

    // ============ Constants Tests ============

    function test_releaseCliff() public view {
        assertEq(treasury.RELEASE_CLIFF(), 180 days); // 6 months
    }

    function test_maxClaimBps() public view {
        assertEq(treasury.MAX_CLAIM_BPS(), 1000); // 10%
    }

    function test_cooldown() public view {
        assertEq(treasury.COOLDOWN(), 14 days);
    }

    function test_challengeWindow() public view {
        assertEq(treasury.CHALLENGE_WINDOW(), 72 hours);
    }

    function test_challengeThreshold() public view {
        assertEq(treasury.CHALLENGE_THRESHOLD_BPS(), 50); // 0.5%
    }

    function test_challengeSlash() public view {
        assertEq(treasury.CHALLENGE_SLASH_BPS(), 2000); // 20%
    }

    // ============ Activation Tests ============

    function test_activate() public {
        vm.prank(router);
        treasury.activate();
        assertTrue(treasury.active());
    }

    function test_activate_revertsNotStarter() public {
        vm.prank(stranger);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAuthorizedStarter.selector);
        treasury.activate();
    }

    function test_activate_revertsDouble() public {
        vm.prank(router);
        treasury.activate();
        vm.prank(router);
        vm.expectRevert(VibesTreasuryEscrow.AlreadyActive.selector);
        treasury.activate();
    }

    function test_activate_revertsNoTokens() public {
        vm.prank(router);
        VibesTreasuryEscrow emptyTreasury = new VibesTreasuryEscrow(address(token), founder, admin, 180 days, 14 days, 72 hours);
        vm.prank(router);
        vm.expectRevert(VibesTreasuryEscrow.NoTokensDeposited.selector);
        emptyTreasury.activate();
    }

    // ============ Release Cliff Tests ============

    function test_cliff_revertsBeforeCliff() public {
        vm.prank(router);
        treasury.activate();

        // Immediately after activation — cliff not elapsed
        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.ReleaseCliffNotElapsed.selector);
        treasury.createProposal(5_000 ether, bytes32(0));
    }

    function test_cliff_revertsAt3Months() public {
        vm.prank(router);
        treasury.activate();

        // 3 months in — still before cliff
        vm.warp(block.timestamp + 90 days);
        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.ReleaseCliffNotElapsed.selector);
        treasury.createProposal(5_000 ether, bytes32(0));
    }

    function test_cliff_succeedsAfter6Months() public {
        vm.prank(router);
        treasury.activate();

        // Exactly 180 days + 1 second after activation
        vm.warp(block.timestamp + 180 days + 1);
        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));

        assertEq(treasury.proposalCount(), 1);
    }

    function test_cliffRemaining_beforeActivation() public view {
        assertEq(treasury.cliffRemaining(), 180 days);
    }

    function test_cliffRemaining_duringCliff() public {
        vm.prank(router);
        treasury.activate();

        vm.warp(block.timestamp + 30 days);
        assertEq(treasury.cliffRemaining(), 150 days);
    }

    function test_cliffRemaining_afterCliff() public {
        vm.prank(router);
        treasury.activate();

        vm.warp(block.timestamp + 180 days + 1);
        assertEq(treasury.cliffRemaining(), 0);
    }

    function test_activatedAt_setOnActivation() public {
        uint256 activationTime = block.timestamp;
        vm.prank(router);
        treasury.activate();
        assertEq(treasury.activatedAt(), activationTime);
    }

    function test_canCreateProposal_cliffNotElapsed() public {
        vm.prank(router);
        treasury.activate();

        (bool can, string memory reason) = treasury.canCreateProposal();
        assertFalse(can);
        assertEq(reason, "Release cliff not elapsed (6 months)");
    }

    // ============ Proposal Tests ============

    function _activateTreasury() internal {
        vm.prank(router);
        treasury.activate();
        // Warp past 6-month cliff so proposals can be created
        vm.warp(block.timestamp + 180 days + 1);
    }

    function test_createProposal() public {
        _activateTreasury();
        bytes32 reason = keccak256("Marketing campaign Q1");

        vm.prank(founder);
        treasury.createProposal(5_000 ether, reason);

        (uint256 amount, bytes32 reasonHash, uint256 timestamp, VibesTreasuryEscrow.ProposalState state) = treasury.getProposal();
        assertEq(amount, 5_000 ether);
        assertEq(reasonHash, reason);
        assertEq(timestamp, block.timestamp);
        assertEq(uint256(state), uint256(VibesTreasuryEscrow.ProposalState.Pending));
        assertEq(treasury.proposalCount(), 1);
    }

    function test_createProposal_revertsNotFounder() public {
        _activateTreasury();
        vm.prank(stranger);
        vm.expectRevert(VibesTreasuryEscrow.OnlyFounder.selector);
        treasury.createProposal(1000 ether, bytes32(0));
    }

    function test_createProposal_revertsNotActive() public {
        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.NotActive.selector);
        treasury.createProposal(1000 ether, bytes32(0));
    }

    function test_createProposal_revertsZeroAmount() public {
        _activateTreasury();
        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.AmountZero.selector);
        treasury.createProposal(0, bytes32(0));
    }

    function test_createProposal_revertsExceedsMax() public {
        _activateTreasury();
        // 10% of 100k = 10k. Requesting 10001 should fail.
        uint256 tooMuch = 10_001 ether;
        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.ExceedsMaxClaim.selector);
        treasury.createProposal(tooMuch, bytes32(0));
    }

    function test_createProposal_maxExactly10Percent() public {
        _activateTreasury();
        // Exactly 10% should work
        uint256 maxAmount = (TREASURY_AMOUNT * 1000) / 10000;
        vm.prank(founder);
        treasury.createProposal(maxAmount, bytes32(0));

        (uint256 amount,,,) = treasury.getProposal();
        assertEq(amount, maxAmount);
    }

    function test_createProposal_revertsDuplicateActive() public {
        _activateTreasury();
        vm.prank(founder);
        treasury.createProposal(1000 ether, bytes32(0));

        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.ProposalAlreadyActive.selector);
        treasury.createProposal(1000 ether, bytes32(0));
    }

    function test_createProposal_revertsCooldown() public {
        _activateTreasury();

        // First proposal + execute
        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));
        vm.warp(block.timestamp + 72 hours + 1);
        treasury.executeProposal();

        // Try second proposal immediately (should fail - 2 week cooldown)
        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.CooldownNotElapsed.selector);
        treasury.createProposal(5_000 ether, bytes32(0));
    }

    function test_createProposal_afterCooldown() public {
        _activateTreasury();

        // First proposal + execute
        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));
        vm.warp(block.timestamp + 72 hours + 1);
        treasury.executeProposal();

        // Wait cooldown
        vm.warp(block.timestamp + 14 days + 1);

        // Second proposal should work
        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));
        assertEq(treasury.proposalCount(), 2);
    }

    function test_createProposal_revertsTerminated() public {
        _createAndChallenge();
        vm.prank(admin);
        treasury.upholdChallengeMalicious();

        // Treasury is terminated, no more proposals
        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.TreasuryIsTerminated.selector);
        treasury.createProposal(1000 ether, bytes32(0));
    }

    // ============ Execute Tests ============

    function test_executeProposal() public {
        _activateTreasury();

        uint256 amount = 5_000 ether;
        vm.prank(founder);
        treasury.createProposal(amount, bytes32(0));

        // Warp past challenge window
        vm.warp(block.timestamp + 72 hours + 1);

        uint256 founderBefore = token.balanceOf(founder);
        treasury.executeProposal();
        uint256 founderAfter = token.balanceOf(founder);

        assertEq(founderAfter - founderBefore, amount);
        assertEq(treasury.totalWithdrawn(), amount);

        (,,, VibesTreasuryEscrow.ProposalState state) = treasury.getProposal();
        assertEq(uint256(state), uint256(VibesTreasuryEscrow.ProposalState.Executed));
    }

    function test_executeProposal_revertsWindowOpen() public {
        _activateTreasury();

        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));

        // Still within window
        vm.warp(block.timestamp + 71 hours);
        vm.expectRevert(VibesTreasuryEscrow.ChallengeWindowOpen.selector);
        treasury.executeProposal();
    }

    function test_executeProposal_revertsNoPending() public {
        _activateTreasury();
        vm.expectRevert(VibesTreasuryEscrow.ProposalNotPending.selector);
        treasury.executeProposal();
    }

    // ============ Challenge Tests ============

    function test_raiseChallenge() public {
        _activateTreasury();

        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));

        // Backer needs to approve first
        vm.prank(backer);
        token.approve(address(treasury), type(uint256).max);

        vm.prank(backer);
        treasury.raiseChallenge("Founder is misusing funds");

        (address challenger, string memory reason, uint256 amount, uint256 timestamp, VibesTreasuryEscrow.ChallengeState state) = treasury.getChallenge();
        assertEq(challenger, backer);
        assertEq(reason, "Founder is misusing funds");
        // 0.5% of 1M supply = 5000 tokens
        assertEq(amount, 5_000 ether);
        assertEq(timestamp, block.timestamp);
        assertEq(uint256(state), uint256(VibesTreasuryEscrow.ChallengeState.Pending));

        // Proposal should be Challenged
        (,,, VibesTreasuryEscrow.ProposalState pState) = treasury.getProposal();
        assertEq(uint256(pState), uint256(VibesTreasuryEscrow.ProposalState.Challenged));
    }

    function test_raiseChallenge_revertsWindowClosed() public {
        _activateTreasury();

        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));

        // Warp past window
        vm.warp(block.timestamp + 73 hours);

        vm.prank(backer);
        token.approve(address(treasury), type(uint256).max);
        vm.prank(backer);
        vm.expectRevert(VibesTreasuryEscrow.ChallengeWindowClosed.selector);
        treasury.raiseChallenge("Too late");
    }

    function test_raiseChallenge_revertsInsufficientTokens() public {
        _activateTreasury();

        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));

        // Stranger has no tokens
        vm.prank(stranger);
        token.approve(address(treasury), type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(VibesTreasuryEscrow.InsufficientTokensToChallenge.selector);
        treasury.raiseChallenge("No tokens");
    }

    // ============ Upheld Rework Tests ============

    function _createAndChallenge() internal {
        _activateTreasury();

        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));

        vm.prank(backer);
        token.approve(address(treasury), type(uint256).max);
        vm.prank(backer);
        treasury.raiseChallenge("Bad proposal");
    }

    function test_upholdChallengeRework() public {
        _createAndChallenge();

        uint256 backerBefore = token.balanceOf(backer);

        vm.prank(admin);
        treasury.upholdChallengeRework();

        // Stake returned to challenger
        uint256 backerAfter = token.balanceOf(backer);
        assertEq(backerAfter - backerBefore, 5_000 ether);

        // Proposal blocked
        (,,, VibesTreasuryEscrow.ProposalState pState) = treasury.getProposal();
        assertEq(uint256(pState), uint256(VibesTreasuryEscrow.ProposalState.Blocked));

        // Challenge upheld rework
        (,,,, VibesTreasuryEscrow.ChallengeState cState) = treasury.getChallenge();
        assertEq(uint256(cState), uint256(VibesTreasuryEscrow.ChallengeState.UpheldRework));

        // Treasury NOT terminated
        assertFalse(treasury.terminated());
    }

    function test_upholdChallengeRework_enforcesCooldown() public {
        _createAndChallenge();

        vm.prank(admin);
        treasury.upholdChallengeRework();

        // Founder must wait 14-day cooldown before resubmitting
        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.CooldownNotElapsed.selector);
        treasury.createProposal(3_000 ether, bytes32(0));

        // After cooldown, can submit again
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(founder);
        treasury.createProposal(3_000 ether, bytes32(0));
        assertEq(treasury.proposalCount(), 2);
    }

    function test_upholdChallengeRework_revertsNotAdmin() public {
        _createAndChallenge();

        vm.prank(stranger);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAdmin.selector);
        treasury.upholdChallengeRework();
    }

    // ============ Upheld Malicious Tests ============

    function test_upholdChallengeMalicious() public {
        _createAndChallenge();

        uint256 backerBefore = token.balanceOf(backer);
        uint256 treasuryBefore = token.balanceOf(address(treasury));

        vm.prank(admin);
        treasury.upholdChallengeMalicious();

        // Stake returned to challenger
        uint256 backerAfter = token.balanceOf(backer);
        assertEq(backerAfter - backerBefore, 5_000 ether);

        // Treasury tokens burned (sent to 0xdead)
        uint256 treasuryAfter = token.balanceOf(address(treasury));
        assertEq(treasuryAfter, 0);
        // The burned amount = treasuryBefore minus the challenger stake that was returned
        uint256 expectedBurn = treasuryBefore - 5_000 ether;
        assertGt(token.balanceOf(address(0xdead)), expectedBurn - 1); // allow rounding

        // Proposal terminated
        (,,, VibesTreasuryEscrow.ProposalState pState) = treasury.getProposal();
        assertEq(uint256(pState), uint256(VibesTreasuryEscrow.ProposalState.Terminated));

        // Challenge upheld malicious
        (,,,, VibesTreasuryEscrow.ChallengeState cState) = treasury.getChallenge();
        assertEq(uint256(cState), uint256(VibesTreasuryEscrow.ChallengeState.UpheldMalicious));

        // Treasury terminated
        assertTrue(treasury.terminated());
    }

    function test_upholdChallengeMalicious_freezesVesting() public {
        // Start vesting first
        vm.prank(router);
        vesting.startVesting();

        _createAndChallenge();

        vm.prank(admin);
        treasury.upholdChallengeMalicious();

        // Vesting should be frozen
        assertTrue(vesting.frozen());

        // Vesting tokens burned
        assertEq(token.balanceOf(address(vesting)), 0);

        // Founder can't release from vesting
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert("Vesting frozen");
        vesting.release();
    }

    function test_upholdChallengeMalicious_revertsNotAdmin() public {
        _createAndChallenge();

        vm.prank(stranger);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAdmin.selector);
        treasury.upholdChallengeMalicious();
    }

    // ============ Rejected Challenge Tests ============

    function test_rejectChallenge() public {
        _createAndChallenge();

        uint256 backerBefore = token.balanceOf(backer);
        uint256 deadBefore = token.balanceOf(address(0xdead));

        vm.prank(admin);
        treasury.rejectChallenge();

        // 20% slashed, 80% returned
        uint256 stakeAmount = 5_000 ether;
        uint256 slashAmount = (stakeAmount * 2000) / 10000; // 1000 tokens
        uint256 returnAmount = stakeAmount - slashAmount;

        uint256 backerAfter = token.balanceOf(backer);
        uint256 deadAfter = token.balanceOf(address(0xdead));

        assertEq(backerAfter - backerBefore, returnAmount);
        assertEq(deadAfter - deadBefore, slashAmount);

        // Proposal goes back to Pending
        (,,, VibesTreasuryEscrow.ProposalState pState) = treasury.getProposal();
        assertEq(uint256(pState), uint256(VibesTreasuryEscrow.ProposalState.Pending));

        // Challenge rejected
        (,,,, VibesTreasuryEscrow.ChallengeState cState) = treasury.getChallenge();
        assertEq(uint256(cState), uint256(VibesTreasuryEscrow.ChallengeState.Rejected));
    }

    function test_rejectChallenge_allowsImmediateExecution() public {
        _createAndChallenge();

        // Fast forward 24h after challenge
        vm.warp(block.timestamp + 24 hours);

        vm.prank(admin);
        treasury.rejectChallenge();

        // Audit fix F6: After rejection, proposalChallengeResolved = true
        // Proposal should be immediately executable (no new window)
        assertTrue(treasury.proposalChallengeResolved());

        // Execute immediately — no need to wait for a new window
        treasury.executeProposal();

        // Verify founder received tokens
        assertTrue(token.balanceOf(founder) > 0, "Founder should receive tokens after immediate execute");
    }

    // ============ Challenge Expiry Tests ============

    function test_expireChallengeIfNeeded() public {
        _createAndChallenge();

        uint256 backerBefore = token.balanceOf(backer);

        // Wait 72h (challenge timeout)
        vm.warp(block.timestamp + 72 hours + 1);

        treasury.expireChallengeIfNeeded();

        // Full stake returned (no slash on timeout)
        uint256 backerAfter = token.balanceOf(backer);
        assertEq(backerAfter - backerBefore, 5_000 ether);

        // Proposal goes back to Pending
        (,,, VibesTreasuryEscrow.ProposalState pState) = treasury.getProposal();
        assertEq(uint256(pState), uint256(VibesTreasuryEscrow.ProposalState.Pending));
    }

    function test_expireChallengeIfNeeded_noopBeforeTimeout() public {
        _createAndChallenge();

        // Only 24h passed
        vm.warp(block.timestamp + 24 hours);

        treasury.expireChallengeIfNeeded();

        // Challenge still pending
        (,,,, VibesTreasuryEscrow.ChallengeState cState) = treasury.getChallenge();
        assertEq(uint256(cState), uint256(VibesTreasuryEscrow.ChallengeState.Pending));
    }

    // ============ Support Challenge Tests ============

    function test_supportChallenge() public {
        _createAndChallenge();

        // Token holders can support — give stranger a small balance
        token.transfer(stranger, 1 ether);
        vm.prank(stranger);
        treasury.supportChallenge("I agree, this is bad");

        // Just emits event, no state change
        (,,,, VibesTreasuryEscrow.ChallengeState cState) = treasury.getChallenge();
        assertEq(uint256(cState), uint256(VibesTreasuryEscrow.ChallengeState.Pending));
    }

    // ============ View Function Tests ============

    function test_treasuryBalance() public {
        assertEq(treasury.treasuryBalance(), TREASURY_AMOUNT);
    }

    function test_maxClaimable() public view {
        assertEq(treasury.maxClaimable(), TREASURY_AMOUNT / 10);
    }

    function test_canCreateProposal_active() public {
        _activateTreasury();
        (bool can, string memory reason) = treasury.canCreateProposal();
        assertTrue(can);
        assertEq(reason, "");
    }

    function test_canCreateProposal_notActive() public view {
        (bool can,) = treasury.canCreateProposal();
        assertFalse(can);
    }

    function test_canCreateProposal_cooldown() public {
        _activateTreasury();

        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));
        vm.warp(block.timestamp + 72 hours + 1);
        treasury.executeProposal();

        (bool can, string memory reason) = treasury.canCreateProposal();
        assertFalse(can);
        assertEq(reason, "Cooldown period active");
    }

    function test_canCreateProposal_terminated() public {
        _createAndChallenge();
        vm.prank(admin);
        treasury.upholdChallengeMalicious();

        (bool can, string memory reason) = treasury.canCreateProposal();
        assertFalse(can);
        assertEq(reason, "Treasury terminated");
    }

    function test_canExecuteProposal() public {
        _activateTreasury();

        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));

        // During window
        (bool can1,) = treasury.canExecuteProposal();
        assertFalse(can1);

        // After window
        vm.warp(block.timestamp + 72 hours + 1);
        (bool can2,) = treasury.canExecuteProposal();
        assertTrue(can2);
    }

    function test_cooldownRemaining() public {
        _activateTreasury();

        // No cooldown initially
        assertEq(treasury.cooldownRemaining(), 0);

        // Execute a proposal
        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));
        vm.warp(block.timestamp + 72 hours + 1);
        treasury.executeProposal();

        // Should be ~14 days
        assertGt(treasury.cooldownRemaining(), 13 days);
        assertLe(treasury.cooldownRemaining(), 14 days);
    }

    function test_challengeWindowRemaining() public {
        _activateTreasury();

        // No active proposal
        assertEq(treasury.challengeWindowRemaining(), 0);

        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));

        // Should be ~72h
        assertGt(treasury.challengeWindowRemaining(), 71 hours);
        assertLe(treasury.challengeWindowRemaining(), 72 hours);
    }

    function test_getTreasuryStatus() public {
        _activateTreasury();

        (
            uint256 balance,
            uint256 withdrawn,
            uint256 proposals,
            uint256 lastClaim,
            bool isActive,
            bool isTerminated,
            VibesTreasuryEscrow.ProposalState pState,
            VibesTreasuryEscrow.ChallengeState cState
        ) = treasury.getTreasuryStatus();

        assertEq(balance, TREASURY_AMOUNT);
        assertEq(withdrawn, 0);
        assertEq(proposals, 0);
        assertEq(lastClaim, 0);
        assertTrue(isActive);
        assertFalse(isTerminated);
        assertEq(uint256(pState), uint256(VibesTreasuryEscrow.ProposalState.None));
        assertEq(uint256(cState), uint256(VibesTreasuryEscrow.ChallengeState.None));
    }

    // ============ Admin Transfer Tests ============

    function test_transferAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        treasury.transferAdmin(newAdmin);
        assertEq(treasury.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        treasury.acceptAdmin();
        assertEq(treasury.admin(), newAdmin);
    }

    function test_transferAdmin_revertsNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAdmin.selector);
        treasury.transferAdmin(stranger);
    }

    function test_acceptAdmin_revertsNotPending() public {
        vm.prank(stranger);
        vm.expectRevert(VibesTreasuryEscrow.OnlyPendingAdmin.selector);
        treasury.acceptAdmin();
    }

    // ============ Full Lifecycle Tests ============

    function test_fullLifecycle_multipleProposals() public {
        _activateTreasury();

        // Proposal 1: 10% = 10000 tokens
        vm.prank(founder);
        treasury.createProposal(10_000 ether, keccak256("Hire developer"));

        vm.warp(block.timestamp + 72 hours + 1);
        treasury.executeProposal();

        assertEq(treasury.totalWithdrawn(), 10_000 ether);
        assertEq(token.balanceOf(founder), 10_000 ether);

        // Wait cooldown
        vm.warp(block.timestamp + 14 days + 1);

        // Proposal 2: 10% of remaining 90k = 9000 tokens
        vm.prank(founder);
        treasury.createProposal(9_000 ether, keccak256("Marketing"));

        vm.warp(block.timestamp + 72 hours + 1);
        treasury.executeProposal();

        assertEq(treasury.totalWithdrawn(), 19_000 ether);
        assertEq(token.balanceOf(founder), 19_000 ether);
    }

    function test_fullLifecycle_reworkThenNewProposal() public {
        _activateTreasury();

        // Proposal 1: challenged and upheld as rework (blocked, cooldown applied)
        vm.prank(founder);
        treasury.createProposal(5_000 ether, bytes32(0));

        vm.prank(backer);
        token.approve(address(treasury), type(uint256).max);
        vm.prank(backer);
        treasury.raiseChallenge("Needs work");

        vm.prank(admin);
        treasury.upholdChallengeRework();

        // Must wait 14-day cooldown
        vm.warp(block.timestamp + 14 days + 1);

        // Founder submits reworked proposal
        vm.prank(founder);
        treasury.createProposal(3_000 ether, keccak256("Better plan"));

        vm.warp(block.timestamp + 72 hours + 1);
        treasury.executeProposal();

        assertEq(treasury.totalWithdrawn(), 3_000 ether);
    }

    function test_fullLifecycle_maliciousTerminatesEverything() public {
        // Start vesting
        vm.prank(router);
        vesting.startVesting();

        _activateTreasury();

        // Founder makes suspicious proposal
        vm.prank(founder);
        treasury.createProposal(10_000 ether, bytes32(0));

        vm.prank(backer);
        token.approve(address(treasury), type(uint256).max);
        vm.prank(backer);
        treasury.raiseChallenge("Founder abandoned project");

        vm.prank(admin);
        treasury.upholdChallengeMalicious();

        // Treasury terminated and empty
        assertTrue(treasury.terminated());
        assertEq(token.balanceOf(address(treasury)), 0);

        // Vesting frozen and empty
        assertTrue(vesting.frozen());
        assertEq(token.balanceOf(address(vesting)), 0);

        // Founder can't do anything
        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.TreasuryIsTerminated.selector);
        treasury.createProposal(1000 ether, bytes32(0));
    }

    function test_maxClaimable_decreasesAfterWithdrawal() public {
        _activateTreasury();

        uint256 maxBefore = treasury.maxClaimable();
        assertEq(maxBefore, 10_000 ether); // 10% of 100k

        // Withdraw 10k
        vm.prank(founder);
        treasury.createProposal(10_000 ether, bytes32(0));
        vm.warp(block.timestamp + 72 hours + 1);
        treasury.executeProposal();

        uint256 maxAfter = treasury.maxClaimable();
        assertEq(maxAfter, 9_000 ether); // 10% of 90k
    }

    // ============ Vesting Freeze Edge Cases ============

    function test_vestingFreeze_onlyAuthorizedFreezer() public {
        vm.prank(stranger);
        vm.expectRevert("Only authorized freezer");
        vesting.freeze();
    }

    function test_vestingFreeze_cannotDoubleFreeze() public {
        _createAndChallenge();
        vm.prank(admin);
        treasury.upholdChallengeMalicious();

        // Second freeze attempt from a different source should fail
        vm.prank(address(treasury));
        vm.expectRevert("Already frozen");
        vesting.freeze();
    }

    function test_setVestingContract_revertsNotStarter() public {
        vm.prank(stranger);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAuthorizedStarter.selector);
        treasury.setVestingContract(address(vesting));
    }
}
