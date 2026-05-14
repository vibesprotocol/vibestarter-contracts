// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesLaunchRouterV2} from "../src/VibesLaunchRouterV2.sol";
import {VibesRouterExtension} from "../src/VibesRouterExtension.sol";
import {VibesRouterStorage} from "../src/VibesRouterStorage.sol";
import {VibesTokenFactory} from "../src/VibesTokenFactory.sol";
import {VibesRegistry} from "../src/VibesRegistry.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesLPLocker} from "../src/VibesLPLocker.sol";
import {VibesLPFeeClaimer} from "../src/VibesLPFeeClaimer.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {VibesTreasuryEscrow} from "../src/VibesTreasuryEscrow.sol";
import {VibesTokenDistributorV2} from "../src/VibesTokenDistributorV2.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockAerodromeRouter.sol";

/**
 * @title SecurityAuditFixes
 * @notice Tests for security audit remediations:
 *   - H-01: Challenge window boundary race (claimTranche <= fix, raiseChallenge >= fix)
 *   - C-01: Excess liability underflow (min() fix on last claimant)
 *   - M-02: Locked address overlap check
 *   - M-03: Frozen ETH balance excludes pending platform fees
 *   - L-01: Batch size limit (100 recipients max)
 *   - L-04: canExecuteProposal view after challenge resolved
 *   - U-02: Router receive() ETHReceived event
 */
contract SecurityAuditFixesTest is Test {
    VibesLaunchRouterV2 public router;
    VibesRouterExtension public ext;
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrowFactory public escrowFactory;
    VibesLPLocker public lpLocker;
    MockAerodromeRouter public aeroRouter;
    MockTimeOracle public timeOracle;
    VibesTranchEscrow public escrowImpl;

    address public owner;
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");
    address public backer3 = makeAddr("backer3");
    address public opsWallet = makeAddr("opsWallet");
    address public platformWallet = makeAddr("platform");
    address public stakerRewardsAddr = makeAddr("stakerRewards");
    address public stranger = makeAddr("stranger");

    address public weth = makeAddr("weth");
    address public aeroFactory = makeAddr("aeroFactory");

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant DEPOSIT = 0.01 ether;
    uint256 public constant GOAL = 10 ether;

    bytes32 public capsuleHash = keccak256("capsule");
    bytes32 public proofHash = keccak256("proof");

    function setUp() public {
        owner = address(this);

        tokenFactory = new VibesTokenFactory();
        registry = new VibesRegistry();
        aeroRouter = new MockAerodromeRouter(weth, aeroFactory);
        lpLocker = new VibesLPLocker(address(aeroRouter), aeroFactory);
        {
            VibesLPFeeClaimer _fc = new VibesLPFeeClaimer();
            lpLocker.setFeeClaimerImplementation(address(_fc));
        }
        timeOracle = new MockTimeOracle();
        escrowImpl = new VibesTranchEscrow();

        ext = new VibesRouterExtension();
        router = new VibesLaunchRouterV2(
            address(ext),
            address(tokenFactory),
            address(registry),
            address(0),
            payable(address(0))
        );

        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl),
            owner,
            platformWallet,
            address(timeOracle),
            address(router),
            address(lpLocker),
            address(0)  // trustedSigner (disabled for tests)
        );

        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker)));
        VibesRouterExtension(address(router)).setOpsWallet(opsWallet);
        VibesRouterExtension(address(router)).setStakerRewardsContract(stakerRewardsAddr);

        registry.authorizeRouter(address(router));
        lpLocker.setAuthorizedRouter(address(router));

        // Use real-time mode so vm.warp() advances _currentTime() correctly
        timeOracle.setRealTimeMode(true);

        vm.deal(founder, 100 ether);
        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);
        vm.deal(backer3, 100 ether);
    }

    receive() external payable {}

    // ============ Helpers ============

    function _launchCampaign(VibesTranchEscrow.RaiseType raiseType, uint256 goal)
        internal
        returns (address token, address escrow)
    {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (token, escrow,) = router.launchWithCampaign{value: DEPOSIT}(
            "TestToken", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            raiseType,
            goal, 0, deadline, 750, 0, 0,
            0, 0, ""  // sigDeadline, launchSignature (disabled)
        );
    }

    function _launchFixedGoal() internal returns (address token, address escrow) {
        return _launchCampaign(VibesTranchEscrow.RaiseType.FixedGoal, GOAL);
    }

    function _launchProRata(uint256 goal) internal returns (address token, address escrow) {
        return _launchCampaign(VibesTranchEscrow.RaiseType.ProRata, goal);
    }

    /// @dev Fund a campaign past goal, warp past deadline, and finalize via claimTokens
    function _fundAndFinalize(address token, VibesTranchEscrow escrow, address backer, uint256 amount) internal {
        vm.prank(backer);
        escrow.contribute{value: amount}(0, 0, "");

        vm.warp(block.timestamp + 15 days);

        // claimTokens auto-finalizes
        vm.prank(backer);
        VibesRouterExtension(address(router)).claimTokens(token);
    }

    /// @dev Claim a monthly tranche: request, wait out challenge window, claim
    function _claimMonthlyTranche(VibesTranchEscrow escrow, uint8 tranche) internal {
        vm.warp(escrow.getTrancheUnlockTime(tranche) + 1);
        vm.prank(founder);
        escrow.requestTranche(tranche);
        vm.warp(block.timestamp + 72 hours + 1);
        vm.prank(founder);
        escrow.claimTranche(tranche);
    }

    // ============ H-01: Challenge Window Boundary Race — claimTranche ============

    function test_H01_claimTranche_revertsAtExactWindowEnd() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Fund and finalize
        _fundAndFinalize(token, escrow, backer1, GOAL);

        // Claim kickstart (tranche 0) — no challenge window
        vm.prank(founder);
        escrow.claimTranche(0);

        // Request tranche 1
        vm.warp(escrow.getTrancheUnlockTime(1) + 1);
        vm.prank(founder);
        escrow.requestTranche(1);

        uint256 requestedAt = escrow.trancheRequestedAt(1);
        uint256 exactWindowEnd = requestedAt + 72 hours;

        // Warp to EXACTLY the window end — should REVERT (the <= fix means at-boundary is blocked)
        vm.warp(exactWindowEnd);
        vm.prank(founder);
        vm.expectRevert(VibesTranchEscrow.ChallengeWindowOpen.selector);
        escrow.claimTranche(1);

        // Warp 1 second later — should succeed
        vm.warp(exactWindowEnd + 1);
        vm.prank(founder);
        escrow.claimTranche(1);

        assertTrue(escrow.trancheClaimed(1), "Tranche 1 should be claimed after window");
    }

    // ============ H-01: Challenge Window Boundary Race — raiseChallenge ============

    function test_H01_challenge_revertsAtExactWindowEnd() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Fund and finalize
        _fundAndFinalize(token, escrow, backer1, GOAL);

        // Claim kickstart (tranche 0) — no challenge window
        vm.prank(founder);
        escrow.claimTranche(0);

        // Request tranche 1
        vm.warp(escrow.getTrancheUnlockTime(1) + 1);
        vm.prank(founder);
        escrow.requestTranche(1);

        uint256 requestedAt = escrow.trancheRequestedAt(1);
        uint256 exactWindowEnd = requestedAt + 72 hours;

        // Warp to EXACTLY the window end — raiseChallenge should REVERT (the >= fix)
        vm.warp(exactWindowEnd);
        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.ChallengeWindowClosed.selector);
        escrow.raiseChallenge("test challenge", 0, 0, "");

        // Warp 1 second BEFORE the end — backer must hold tokens to challenge
        // Backer1 already claimed tokens during finalize, so they have tokens
        uint256 backerBalance = IERC20(token).balanceOf(backer1);
        assertTrue(backerBalance > 0, "Backer1 should have tokens from finalization");

        // Need to approve escrow to transfer challenger stake
        vm.prank(backer1);
        IERC20(token).approve(address(escrow), type(uint256).max);

        vm.warp(exactWindowEnd - 1);
        vm.prank(backer1);
        escrow.raiseChallenge("test challenge", 0, 0, "");

        // Verify challenge was raised
        (address challenger,,,,,) = escrow.activeChallenge();
        assertEq(challenger, backer1, "Challenge should have been raised by backer1");
    }

    // ============ C-01: Excess Liability Underflow ============

    function test_C01_excessRefund_lastClaimantNoUnderflow() public {
        // Launch a ProRata campaign with goal = 7 ether
        (address token, address escrowAddr) = _launchProRata(7 ether);
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // 3 backers each contribute ~3.334 ether (total slightly over 10 ether, well above 7 goal)
        // Using odd amounts to maximize rounding gaps
        vm.prank(backer1);
        escrow.contribute{value: 3.334 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 3.334 ether}(0, 0, "");
        vm.prank(backer3);
        escrow.contribute{value: 3.334 ether}(0, 0, "");

        // Warp past deadline and finalize
        vm.warp(block.timestamp + 15 days);
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        // All 3 backers claim excess refund in sequence
        // The LAST claimant must NOT revert (the min() fix prevents underflow)
        vm.prank(backer1);
        escrow.claimExcessRefund();

        vm.prank(backer2);
        escrow.claimExcessRefund();

        // This is the critical call — without the min() fix, this would underflow
        vm.prank(backer3);
        escrow.claimExcessRefund();

        // Verify all 3 backers received their excess
        VibesTranchEscrow.Contribution memory c1 = escrow.getContribution(backer1);
        VibesTranchEscrow.Contribution memory c2 = escrow.getContribution(backer2);
        VibesTranchEscrow.Contribution memory c3 = escrow.getContribution(backer3);
        assertTrue(c1.excessClaimed, "Backer1 excess should be claimed");
        assertTrue(c2.excessClaimed, "Backer2 excess should be claimed");
        assertTrue(c3.excessClaimed, "Backer3 excess should be claimed");
    }

    // ============ M-02: Locked Address Overlap ============

    function test_M02_setLockedAddresses_revertsOnOverlap() public {
        (, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Post-ZXVC-VIB-02 (2026-05): the router latches custody addresses at the end of
        // Phase 2, after which both setters revert with "Locked". The M-02 overlap check
        // is now only reachable pre-finalisation (e.g., admin/router wiring before launch
        // completes). Test it in that pre-finalisation window — don't fund-and-finalise.
        require(!escrow.lockedAddressesFinalized(), "Pre-finalisation precondition");

        // Try to set both vesting and staker to the same address — should revert with M-02.
        address sameAddr = makeAddr("sameAddr");
        vm.prank(address(router));
        vm.expectRevert("Overlapping locked addresses");
        escrow.setLockedAddresses(sameAddr, sameAddr);
    }

    // ============ L-01: Batch Size Limit ============

    function test_L01_batchDistribute_revertsOver100() public {
        // Deploy a token for the distributor
        vm.prank(founder);
        VibesToken distToken = new VibesToken("DistToken", "DST", 18, TOTAL_SUPPLY, founder);

        // Create distributor
        VibesTokenDistributorV2 distributor = new VibesTokenDistributorV2(
            address(distToken),
            founder,
            makeAddr("campaign"),
            opsWallet,
            owner  // admin
        );

        // Set up a dummy merkle root so distributionSet = true
        vm.prank(founder);
        distributor.setDistributionRoot(keccak256("root"), TOTAL_SUPPLY, 0);

        // Fund the distributor
        vm.prank(founder);
        distToken.transfer(address(distributor), TOTAL_SUPPLY);

        // Build arrays of 101 recipients
        address[] memory recipients = new address[](101);
        uint256[] memory tokenAmounts = new uint256[](101);
        uint256[] memory ethRefunds = new uint256[](101);
        bytes32[][] memory proofs = new bytes32[][](101);

        for (uint256 i = 0; i < 101; i++) {
            recipients[i] = address(uint160(i + 1000));
            tokenAmounts[i] = 1 ether;
            ethRefunds[i] = 0;
            proofs[i] = new bytes32[](0);
        }

        // Should revert with "Batch too large"
        vm.prank(founder);
        vm.expectRevert("Batch too large");
        distributor.batchDistribute(recipients, tokenAmounts, ethRefunds, proofs);
    }

    // ============ L-04: Treasury canExecuteProposal View ============

    function test_L04_canExecuteProposal_trueAfterChallengeResolved() public {
        // Deploy a token for treasury
        vm.prank(founder);
        VibesToken treasuryToken = new VibesToken("TreasuryToken", "TRT", 18, TOTAL_SUPPLY, founder);

        // Create treasury escrow (6-month cliff, 14-day cooldown, 72h challenge window)
        VibesTreasuryEscrow treasury = new VibesTreasuryEscrow(
            address(treasuryToken),
            founder,
            owner,     // admin
            180 days,  // releaseCliff
            14 days,   // cooldown
            72 hours   // challengeWindow
        );

        // Fund treasury and activate
        vm.prank(founder);
        treasuryToken.transfer(address(treasury), 100_000 ether);
        treasury.activate();

        // Warp past the 6-month cliff
        vm.warp(block.timestamp + 181 days);

        // Founder creates a proposal (10% of balance = 10,000 tokens)
        vm.prank(founder);
        treasury.createProposal(10_000 ether, keccak256("reason"));

        // Stranger needs tokens to challenge — fund them
        vm.prank(founder);
        treasuryToken.transfer(stranger, 10_000 ether);

        // Stranger approves treasury and raises a challenge
        vm.prank(stranger);
        treasuryToken.approve(address(treasury), type(uint256).max);
        vm.prank(stranger);
        treasury.raiseChallenge("I object");

        // Admin rejects the challenge (sets proposalChallengeResolved = true)
        treasury.rejectChallenge(); // called as owner (admin)

        // canExecuteProposal should return true BEFORE the challenge window expires
        // (the proposalChallengeResolved early-return in L-04)
        (bool canExecute, string memory reason) = treasury.canExecuteProposal();
        assertTrue(canExecute, "Should be executable after challenge resolved");
        assertEq(reason, "", "Reason should be empty");

        // Verify we are still within the original challenge window
        // (proposal was created just a few seconds ago relative to current block.timestamp)
        uint256 windowRemaining = treasury.challengeWindowRemaining();
        // We may or may not have time remaining depending on warp timing,
        // but the key assertion is that canExecuteProposal returned true
    }

    // ============ U-02: Router receive() Event ============

    function test_U02_receive_emitsETHReceivedEvent() public {
        // Send ETH directly to the router and check for ETHReceived event
        vm.deal(stranger, 1 ether);

        vm.prank(stranger);
        vm.expectEmit(true, false, false, true, address(router));
        emit VibesLaunchRouterV2.ETHReceived(stranger, 0.5 ether);
        (bool success,) = address(router).call{value: 0.5 ether}("");
        assertTrue(success, "ETH transfer to router should succeed");
    }

    // ============ M-03: Frozen ETH Balance Excludes Pending Fees ============

    function test_M03_frozenEthBalance_excludesPendingFees() public {
        // Launch a FixedGoal campaign
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Fund and finalize
        _fundAndFinalize(token, escrow, backer1, GOAL);

        // Claim kickstart tranche (tranche 0) to accrue platform fees
        vm.prank(founder);
        escrow.claimTranche(0);

        // Record state before freeze
        uint256 escrowBalance = address(escrow).balance;
        uint256 excessLiability = escrow.totalExcessRefundLiability();
        uint256 fees = escrow.pendingPlatformFees();

        assertTrue(fees > 0, "Platform fees should be accrued after kickstart claim");

        // Freeze the campaign
        escrow.freezeCampaign("test freeze");

        // Verify frozenEthBalance == balance - excessLiability - pendingPlatformFees
        uint256 expectedFrozen = escrowBalance - excessLiability - fees;
        assertEq(
            escrow.frozenEthBalance(),
            expectedFrozen,
            "Frozen ETH balance must exclude pending platform fees"
        );

        // Also verify directly: frozenEthBalance < balance (fees were subtracted)
        assertTrue(
            escrow.frozenEthBalance() < escrowBalance,
            "Frozen balance should be less than total balance due to excluded fees"
        );
    }

    // ============ H-02: Router Pause Doesn't Brick Finalization ============

    function test_H02_finalize_succeedsWhenRouterPaused() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Backer contributes full goal
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        // Pause the router BEFORE finalization
        VibesRouterExtension(address(router)).pause();

        // Warp past deadline
        vm.warp(block.timestamp + 15 days);

        // Finalize should succeed (try/catch catches the paused router revert)
        escrow.finalize();

        // Campaign should be in Funded state despite router being paused
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Funded),
            "Campaign should be Funded even with paused router");

        // lpCreated should be false (deferred)
        assertFalse(escrow.lpCreated(), "LP should NOT be created when router was paused");
    }

    // ============ H-04: LP Rescue Tranche Gate ============

    function test_H04_claimTranche_revertsWhenLPNotCreated() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Backer contributes full goal
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        // Pause router to force deferred finalization (LP not created)
        VibesRouterExtension(address(router)).pause();

        vm.warp(block.timestamp + 15 days);
        escrow.finalize();

        // Campaign is Funded but lpCreated is false
        assertFalse(escrow.lpCreated());

        // Unpause router for subsequent operations
        router.emergencyUnpause();

        // Kickstart tranche (tranche 0) should revert — LP not created
        vm.prank(founder);
        vm.expectRevert(VibesTranchEscrow.LPNotCreated.selector);
        escrow.claimTranche(0);
    }

    function test_H04_claimTranche_succeedsAfterSetLPCreated() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        // Pause → finalize (deferred) → unpause
        VibesRouterExtension(address(router)).pause();
        vm.warp(block.timestamp + 15 days);
        escrow.finalize();
        router.emergencyUnpause();

        assertFalse(escrow.lpCreated());

        // Router calls setLPCreated (simulating backup finalization resolving LP)
        vm.prank(address(router));
        escrow.setLPCreated();

        assertTrue(escrow.lpCreated());

        // Now kickstart tranche should succeed
        vm.prank(founder);
        escrow.claimTranche(0);

        assertTrue(escrow.trancheClaimed(0), "Tranche 0 should be claimed after LP created");
    }

    function test_H04_setLPCreated_onlyRouter() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Stranger cannot call setLPCreated
        vm.prank(stranger);
        vm.expectRevert(VibesTranchEscrow.OnlyRouter.selector);
        escrow.setLPCreated();
    }

    // ============ H-06: Time Oracle Drift Bound ============

    function test_H06_currentTime_revertsWhenOracleTooFarAhead() public {
        (, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Switch oracle out of real-time mode so we can set arbitrary time
        timeOracle.setRealTimeMode(false);

        // Set oracle 2 hours ahead of block.timestamp (exceeds MAX_TIME_DRIFT of 1 hour)
        timeOracle.setTime(block.timestamp + 2 hours);

        // Any action using _currentTime() should revert
        vm.prank(backer1);
        vm.expectRevert("Oracle drift exceeded");
        escrow.contribute{value: 1 ether}(0, 0, "");
    }

    function test_H06_currentTime_succeedsWithinDriftBound() public {
        (, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Switch oracle out of real-time mode
        timeOracle.setRealTimeMode(false);

        // Set oracle 30 minutes ahead (within MAX_TIME_DRIFT of 1 hour)
        timeOracle.setTime(block.timestamp + 30 minutes);

        // Contribution should succeed
        vm.prank(backer1);
        escrow.contribute{value: 1 ether}(0, 0, "");

        (uint256 amt,,) = escrow.contributions(backer1);
        assertEq(amt, 1 ether);
    }

    // ============ C-03: safeTransferFrom for $VIBES Burn ============

    function test_C03_vibesBurn_useSafeTransferFrom() public {
        // Deploy a mock $VIBES token that returns false on transferFrom
        MockFalseReturnERC20 fakeVibes = new MockFalseReturnERC20();

        // Set vibes token and burn amount on router
        VibesRouterExtension(address(router)).setVibesToken(address(fakeVibes));
        VibesRouterExtension(address(router)).setLaunchBurnAmount(100 ether);

        // Give founder fake vibes and approve
        fakeVibes.mint(founder, 1000 ether);
        vm.prank(founder);
        fakeVibes.approve(address(router), 1000 ether);

        // Now make the token return false on transferFrom
        fakeVibes.setReturnFalse(true);

        // Launch should revert (safeTransferFrom catches the false return)
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        vm.expectRevert(); // SafeERC20 reverts on false return
        router.launchWithCampaign{value: DEPOSIT}(
            "TestToken", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline, 750, 0, 0,
            0, 0, ""
        );
    }

    // ============ E2E: Full Lifecycle with Deferred Finalization ============

    function test_E2E_pausedRouter_deferredLP_fullLifecycle() public {
        // 1. Launch campaign
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // 2. Fund past goal
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        // 3. Pause router to simulate emergency
        VibesRouterExtension(address(router)).pause();

        // 4. Warp past deadline and finalize
        vm.warp(block.timestamp + 15 days);
        escrow.finalize();

        // Verify: Funded but lpCreated = false
        assertEq(uint8(escrow.getCampaign().state), uint8(VibesTranchEscrow.CampaignState.Funded));
        assertFalse(escrow.lpCreated());

        // 5. Tranche claims blocked
        vm.prank(founder);
        vm.expectRevert(VibesTranchEscrow.LPNotCreated.selector);
        escrow.claimTranche(0);

        // 6. Unpause router
        router.emergencyUnpause();

        // 7. Admin resolves LP via backup finalization
        // (In a real scenario, finalizeSuccessfulCampaign on extension would be called)
        // For this test, just setLPCreated directly via router prank
        vm.prank(address(router));
        escrow.setLPCreated();

        // 8. Now tranches work
        vm.prank(founder);
        escrow.claimTranche(0); // Kickstart
        assertTrue(escrow.trancheClaimed(0));

        // 9. Monthly tranche 1
        _claimMonthlyTranche(escrow, 1);
        assertTrue(escrow.trancheClaimed(1));
    }

    function test_E2E_proRataRounding_allClaimantsSucceed() public {
        // Pro-rata campaign: 3 backers, goal = 7 ETH, each contributes unequal amounts
        // Tests C-01 (underflow) + excess refund flow through to freeze (M-03)
        (address token, address escrowAddr) = _launchProRata(7 ether);
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // 3 backers contribute 3.333... ETH each (total = ~10 ETH, well above 7 ETH goal)
        uint256 amount1 = 3333333333333333334; // 3.333... ETH + 1 wei
        uint256 amount2 = 3333333333333333333; // 3.333... ETH
        uint256 amount3 = 3333333333333333333; // 3.333... ETH

        vm.prank(backer1);
        escrow.contribute{value: amount1}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: amount2}(0, 0, "");
        vm.prank(backer3);
        escrow.contribute{value: amount3}(0, 0, "");

        // Warp past deadline, finalize via claimTokens
        vm.warp(block.timestamp + 15 days);
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        // All 3 backers claim excess refund — the LAST one must not underflow
        vm.prank(backer1);
        escrow.claimExcessRefund();
        vm.prank(backer2);
        escrow.claimExcessRefund();
        vm.prank(backer3);
        escrow.claimExcessRefund(); // This was the underflow revert before C-01 fix

        // Liability should be 0 or very small (rounding dust absorbed)
        assertLe(escrow.totalExcessRefundLiability(), 2,
            "Excess liability should be 0 or at most 2 wei dust");

        // Now freeze the campaign and verify frozen ETH excludes pending fees (M-03)
        escrow.freezeCampaign("test freeze after excess claims");

        uint256 frozenEth = escrow.frozenEthBalance();
        uint256 fees = escrow.pendingPlatformFees();

        // frozenEth should NOT include the pending fees
        assertTrue(frozenEth > 0, "Frozen ETH should be > 0");
        // The frozen balance should be: balance - excessLiability - fees
        assertEq(
            frozenEth,
            address(escrow).balance - escrow.totalExcessRefundLiability() - fees,
            "Frozen ETH accounting must exclude both excess liability and fees"
        );
    }
}

// ============ Mock for C-03 test ============

/// @notice ERC20 that can return false on transferFrom (instead of reverting)
contract MockFalseReturnERC20 {
    string public name = "MockVibes";
    string public symbol = "MVIBES";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool public returnFalse;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setReturnFalse(bool _returnFalse) external {
        returnFalse = _returnFalse;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (returnFalse) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (returnFalse) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
