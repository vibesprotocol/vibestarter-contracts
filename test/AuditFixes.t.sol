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
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockAerodromeRouter.sol";

/**
 * @title AuditFixes
 * @notice Tests for audit finding remediations:
 *   - Finding A: Claim order independence
 *   - Finding B: Launch validation (goal > 0)
 *   - Finding C: frozenTotalSupply != 0 guard
 *   - Finding D: Deposit orphaning fix
 *   - Finding E-pause: Fallback pause guard + emergencyUnpause
 *   - Finding E-rescue: rescueETH deposit reservation
 */

/// @dev Minimal pool mock for H-4 recordManualLPLock onchain-proof path
contract AuditFixesPool {
    mapping(address => uint256) public balanceOf;
    function setBalance(address holder, uint256 amount) external { balanceOf[holder] = amount; }
}

contract AuditFixesTest is Test {
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
    }

    receive() external payable {}

    // ============ Helpers ============

    function _launchFixedGoal() internal returns (address token, address escrow) {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (token, escrow,) = router.launchWithCampaign{value: DEPOSIT}(
            "TestToken", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline, 750, 0, 0,
            0, 0, ""  // sigDeadline, launchSignature (disabled)
        );
    }

    // ============ Finding A: Claim Order Independence ============

    function test_claimTokens_orderIndependence() public {
        (address token, address escrow) = _launchFixedGoal();
        VibesTranchEscrow e = VibesTranchEscrow(payable(escrow));

        // Both backers contribute equal amounts
        vm.prank(backer1);
        e.contribute{value: 5 ether}(0, 0, "");
        vm.prank(backer2);
        e.contribute{value: 5 ether}(0, 0, "");

        // Finalize
        vm.warp(block.timestamp + 15 days);
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        uint256 backer1Tokens = IERC20(token).balanceOf(backer1);

        vm.prank(backer2);
        VibesRouterExtension(address(router)).claimTokens(token);

        uint256 backer2Tokens = IERC20(token).balanceOf(backer2);

        // With the audit fix, both backers should get the same amount
        // (equal contributions = equal token allocation regardless of claim order)
        assertEq(backer1Tokens, backer2Tokens, "Claim amounts should be order-independent");
        assertTrue(backer1Tokens > 0, "Backer should receive tokens");
    }

    // ============ Finding B: Launch Validation ============

    function test_launchWithCampaign_revertsZeroGoalFixedGoal() public {
        uint256 deadline = block.timestamp + 14 days;

        vm.prank(founder);
        vm.expectRevert("FixedGoal requires goal > 0");
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            0, 0, deadline, 750, 0, 0,  // goal = 0
            0, 0, ""  // sigDeadline, launchSignature (disabled)
        );
    }

    function test_launchWithCampaign_revertsZeroGoalProRata() public {
        uint256 deadline = block.timestamp + 14 days;

        vm.prank(founder);
        vm.expectRevert("ProRata requires goal > 0");
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.ProRata,
            0, 0, deadline, 750, 0, 0,  // goal = 0
            0, 0, ""  // sigDeadline, launchSignature (disabled)
        );
    }

    function test_launchWithCampaign_allowsZeroGoalOpenEnded() public {
        uint256 deadline = block.timestamp + 14 days;

        vm.prank(founder);
        (address token,,) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.OpenEnded,
            0, 0, deadline, 750, 0, 0,  // goal = 0 is ok for OpenEnded
            0, 0, ""  // sigDeadline, launchSignature (disabled)
        );
        assertTrue(token != address(0));
    }

    // ============ Finding D: Deposit Tracking ============

    function test_depositTracking_incrementsReserved() public {
        assertEq(router.totalReservedDeposits(), 0);

        _launchFixedGoal();

        assertEq(router.totalReservedDeposits(), DEPOSIT);
    }

    // ============ Finding E-pause: Fallback Pause Guard ============

    function test_fallback_blockedWhenPaused() public {
        // Pause the router (via extension before we pause)
        VibesRouterExtension(address(router)).pause();

        // Try to call an extension function through fallback — should revert
        vm.expectRevert();
        VibesRouterExtension(address(router)).setOpsWallet(stranger);
    }

    function test_emergencyUnpause_worksWhenPaused() public {
        // Pause the router
        VibesRouterExtension(address(router)).pause();

        // Verify paused
        assertTrue(router.paused());

        // Emergency unpause (direct router function, not through fallback)
        router.emergencyUnpause();

        // Verify unpaused
        assertFalse(router.paused());
    }

    function test_emergencyUnpause_onlyOwner() public {
        VibesRouterExtension(address(router)).pause();

        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        router.emergencyUnpause();
    }

    // ============ Finding E-rescue: rescueETH Deposit Protection ============

    function test_rescueETH_cannotDrainDeposits() public {
        _launchFixedGoal();

        // Send extra ETH to the router (simulating accidentally sent ETH)
        vm.deal(address(router), DEPOSIT + 1 ether);

        // Should be able to rescue the extra 1 ether
        VibesRouterExtension(address(router)).rescueETH(opsWallet, 1 ether);
        assertEq(opsWallet.balance, 1 ether);

        // Should NOT be able to rescue the deposit
        vm.expectRevert("Would drain reserved deposits");
        VibesRouterExtension(address(router)).rescueETH(opsWallet, DEPOSIT);
    }

    function test_rescueETH_fullAmountWhenNoDeposits() public {
        // Send ETH to router (no campaigns launched, so no deposits)
        vm.deal(address(router), 5 ether);

        VibesRouterExtension(address(router)).rescueETH(opsWallet, 5 ether);
        assertEq(opsWallet.balance, 5 ether);
    }

    // ============ Production Review Track B Fixes ============

    /// Helper: finalize a FixedGoal campaign (contribute goal → warp past deadline → claim tokens triggers finalize)
    function _fundAndFinalize() internal returns (address token, VibesTranchEscrow escrow) {
        address _token;
        address _escrow;
        (_token, _escrow) = _launchFixedGoal();
        escrow = VibesTranchEscrow(payable(_escrow));
        token = _token;

        // Backer contributes the full goal
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        // Warp past deadline to allow finalization
        vm.warp(block.timestamp + 15 days);

        // Trigger finalization via claimTokens (auto-finalizes)
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
    }

    /// Helper: drive a funded campaign all the way to Completed by claiming all 7 tranches
    function _claimAllTranches(VibesTranchEscrow escrow) internal {
        // Tranche 0 (kickstart): no request needed, claimable immediately after finalize
        vm.prank(founder);
        escrow.claimTranche(0);

        // Tranches 1-6: each needs request → wait 72h challenge window → claim
        _claimMonthlyTranche(escrow, 1);
        _claimMonthlyTranche(escrow, 2);
        _claimMonthlyTranche(escrow, 3);
        _claimMonthlyTranche(escrow, 4);
        _claimMonthlyTranche(escrow, 5);
        _claimMonthlyTranche(escrow, 6);
    }

    function _claimMonthlyTranche(VibesTranchEscrow escrow, uint8 tranche) internal {
        vm.warp(escrow.getTrancheUnlockTime(tranche) + 1);
        vm.prank(founder);
        escrow.requestTranche(tranche);
        vm.warp(block.timestamp + 72 hours + 1);
        vm.prank(founder);
        escrow.claimTranche(tranche);
    }

    // ============ B1: Token Claims in Completed State (F1) ============

    function test_claimTokens_afterCompleted() public {
        // Launch with two backers
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Both backers contribute
        vm.prank(backer1);
        escrow.contribute{value: 5 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 5 ether}(0, 0, "");

        // Finalize — backer1 claims tokens during finalization
        vm.warp(block.timestamp + 15 days);
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        // Drive to Completed
        _claimAllTranches(escrow);

        // Verify campaign is in Completed state
        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(uint(camp.state), uint(VibesTranchEscrow.CampaignState.Completed));

        // Backer2 should still be able to claim tokens in Completed state
        vm.prank(backer2);
        VibesRouterExtension(address(router)).claimTokens(token);

        uint256 backer2Balance = IERC20(token).balanceOf(backer2);
        assertTrue(backer2Balance > 0, "Backer2 should receive tokens after Completed");
    }

    // ============ B2: Excess Refunds in Completed State (F2) ============

    function test_excessRefund_afterCompleted() public {
        // Launch ProRata campaign
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (address token, address escrowAddr,) = router.launchWithCampaign{value: DEPOSIT}(
            "TestToken", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.ProRata,
            GOAL, 0, deadline, 750, 0, 0,
            0, 0, ""
        );
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Oversubscribe: backer1 contributes 2x the goal
        vm.prank(backer1);
        escrow.contribute{value: 20 ether}(0, 0, "");

        // Finalize
        vm.warp(block.timestamp + 15 days);
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        // Drive to Completed
        _claimAllTranches(escrow);

        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(uint(camp.state), uint(VibesTranchEscrow.CampaignState.Completed));

        // Backer should be able to claim excess refund in Completed state
        vm.prank(backer1);
        escrow.claimExcessRefund();

        // Verify backer received excess ETH (contributed 20, goal was 10, so ~10 ETH excess)
        // Backer started with 100 ETH, spent 20, got back ~10 excess
        assertTrue(backer1.balance > 80 ether, "Backer should receive excess refund");
    }

    // ============ B3: Platform Fees Blocked During Freeze/Refund (F3) ============

    function test_platformFees_blockedDuringFreeze() public {
        (address token, VibesTranchEscrow escrow) = _fundAndFinalize();

        // Claim first two tranches to accumulate platform fees
        vm.prank(founder);
        escrow.claimTranche(0);

        vm.warp(escrow.getTrancheUnlockTime(1) + 1);
        vm.prank(founder);
        escrow.requestTranche(1);
        vm.warp(block.timestamp + 72 hours + 1);
        vm.prank(founder);
        escrow.claimTranche(1);

        // Freeze the campaign
        escrow.freezeCampaign("test freeze");

        // Platform fee withdrawal should be blocked
        vm.expectRevert("Fees locked during refund");
        escrow.claimPlatformFees();
    }

    function test_platformFees_blockedDuringRefunding() public {
        (address token, VibesTranchEscrow escrow) = _fundAndFinalize();

        // Claim a tranche to accumulate fees
        vm.prank(founder);
        escrow.claimTranche(0);

        // Freeze → commit merkle root → wait → finalize → Refunding (F10 commit-reveal)
        escrow.freezeCampaign("test freeze");
        escrow.commitRefundMerkleRoot(keccak256("merkle"));
        vm.warp(block.timestamp + 25 hours);
        escrow.finalizeRefundMerkleRoot();

        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(uint(camp.state), uint(VibesTranchEscrow.CampaignState.Refunding));

        // Platform fee withdrawal should be blocked
        vm.expectRevert("Fees locked during refund");
        escrow.claimPlatformFees();
    }

    // ============ B4: LP Creation Failure — Now Rescued (Audit Fix F1) ============

    function test_finalization_succeedsWithRescuedLP() public {
        // Deploy with a deliberately broken LP locker that returns (address(0), 0)
        MockFailingLPLocker failingLocker = new MockFailingLPLocker();

        // Set up the router with the failing locker
        VibesRouterExtension(address(router)).setLPLocker(payable(address(failingLocker)));
        failingLocker.setAuthorizedRouter(address(router));

        // Create a new escrow factory pointing to the failing locker
        VibesTranchEscrow newEscrowImpl = new VibesTranchEscrow();
        VibesTranchEscrowFactory newFactory = new VibesTranchEscrowFactory(
            address(newEscrowImpl),
            owner,
            platformWallet,
            address(timeOracle),
            address(router),
            address(failingLocker),
            address(0)
        );
        VibesRouterExtension(address(router)).setEscrowFactory(address(newFactory));

        // Launch
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (address token, address escrowAddr,) = router.launchWithCampaign{value: DEPOSIT}(
            "TestToken", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline, 750, 0, 0,
            0, 0, ""
        );
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Contribute and warp past deadline
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");
        vm.warp(block.timestamp + 15 days);

        // Audit fix F1: Finalization should SUCCEED with rescued LP status
        escrow.finalize();

        // Campaign should be Funded (finalization succeeded despite LP failure)
        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(uint(camp.state), uint(VibesTranchEscrow.CampaignState.Funded));

        // LP status should be Rescued
        assertEq(uint(router.lpStatus(token)), uint(VibesRouterStorage.LPStatus.Rescued));

        // Backers should still be able to claim tokens
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        assertTrue(IERC20(token).balanceOf(backer1) > 0, "Backer should receive tokens despite LP rescue");
    }

    // ============ B5: Auto-Wire Locked Addresses on Finalization (F7) ============

    function test_lockedAddresses_autoSetOnFinalization() public {
        (address token, VibesTranchEscrow escrow) = _fundAndFinalize();

        // After finalization, vesting and staker rewards should be auto-wired
        address vestingAddr = router.tokenToVesting(token);
        address stakerAddr = escrow.stakerRewards();

        // stakerRewards should be set to the router's stakerRewardsContract
        assertEq(stakerAddr, stakerRewardsAddr, "Staker rewards should be auto-wired");

        // vestingContract should match the router's vesting for this token
        assertEq(escrow.vestingContract(), vestingAddr, "Vesting contract should be auto-wired");
    }

    function test_setLockedAddresses_allowsRouter() public {
        (address token, VibesTranchEscrow escrow) = _fundAndFinalize();

        // Router should be able to call setLockedAddresses (not just admin)
        address newVesting = makeAddr("newVesting");
        address newStaker = makeAddr("newStaker");

        vm.prank(address(router));
        escrow.setLockedAddresses(newVesting, newStaker);

        assertEq(escrow.vestingContract(), newVesting);
        assertEq(escrow.stakerRewards(), newStaker);
    }

    function test_setLockedAddresses_rejectsStranger() public {
        (address token, VibesTranchEscrow escrow) = _fundAndFinalize();

        vm.prank(stranger);
        vm.expectRevert();
        escrow.setLockedAddresses(makeAddr("v"), makeAddr("s"));
    }

    // ============ C3: Post-Completed State Transition Matrix ============
    // Systematically tests every user-facing function in the Completed state
    // to ensure only token claims and excess refunds are allowed.

    /// Helper: get a campaign to Completed state
    function _getToCompleted() internal returns (address token, VibesTranchEscrow escrow) {
        (token, escrow) = _fundAndFinalize();
        _claimAllTranches(escrow);

        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(uint(camp.state), uint(VibesTranchEscrow.CampaignState.Completed));
    }

    function test_completed_claimPlatformFees_succeeds() public {
        (, VibesTranchEscrow escrow) = _getToCompleted();

        // Platform fees were accrued during tranche claims — should be claimable after Completed
        uint256 platformBalBefore = platformWallet.balance;
        escrow.claimPlatformFees();
        assertTrue(platformWallet.balance > platformBalBefore, "Platform should receive fees");
    }

    function test_completed_contribute_reverts() public {
        (, VibesTranchEscrow escrow) = _getToCompleted();

        vm.prank(backer2);
        vm.expectRevert();
        escrow.contribute{value: 1 ether}(0, 0, "");
    }

    function test_completed_requestTranche_reverts() public {
        (, VibesTranchEscrow escrow) = _getToCompleted();

        vm.prank(founder);
        vm.expectRevert();
        escrow.requestTranche(1);
    }

    function test_completed_raiseChallenge_reverts() public {
        (, VibesTranchEscrow escrow) = _getToCompleted();

        vm.prank(backer1);
        vm.expectRevert();
        escrow.raiseChallenge("test", 0, 0, "");
    }

    function test_completed_freezeCampaign_reverts() public {
        (, VibesTranchEscrow escrow) = _getToCompleted();

        vm.expectRevert();
        escrow.freezeCampaign("test");
    }

    function test_completed_claimContributorRefund_reverts() public {
        (, VibesTranchEscrow escrow) = _getToCompleted();

        vm.prank(backer1);
        vm.expectRevert();
        escrow.claimContributorRefund();
    }

    function test_completed_finalize_reverts() public {
        (, VibesTranchEscrow escrow) = _getToCompleted();

        vm.expectRevert();
        escrow.finalize();
    }

    // ============ C4: LP Failure via Aerodrome — Now Rescued (Audit Fix F1) ============

    function test_finalization_succeedsWhenAerodromeRouterFails() public {
        // Tell the mock router to fail on addLiquidity
        aeroRouter.setShouldFail(true);

        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");
        vm.warp(block.timestamp + 15 days);

        // Audit fix F1: Finalization should succeed with rescued LP
        escrow.finalize();

        // Campaign should be Funded
        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(uint(camp.state), uint(VibesTranchEscrow.CampaignState.Funded));

        // LP status should be Rescued
        assertEq(uint(router.lpStatus(token)), uint(VibesRouterStorage.LPStatus.Rescued));
    }

    // ============ $VIBES Burn-to-Launch Tests ============

    function test_vibesBurn_disabledByDefault() public {
        // vibesToken is address(0) by default — launch should work without any $VIBES
        (address token,) = _launchFixedGoal();
        assertTrue(token != address(0), "Launch should succeed without $VIBES burn");
    }

    function test_vibesBurn_burnsWhenConfigured() public {
        // Deploy a mock $VIBES token
        MockVibesTokenSimple vibes = new MockVibesTokenSimple();
        uint256 burnAmount = 1000 ether;

        // Configure burn via extension (delegatecall)
        VibesRouterExtension(address(router)).setVibesToken(address(vibes));
        VibesRouterExtension(address(router)).setLaunchBurnAmount(burnAmount);

        // Mint $VIBES to founder and approve router
        vibes.mint(founder, burnAmount);
        vm.prank(founder);
        vibes.approve(address(router), burnAmount);

        // Launch — should burn $VIBES
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (address token,,) = router.launchWithCampaign{value: DEPOSIT}(
            "TestToken", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline, 750, 0, 0,
            0, 0, ""
        );

        assertTrue(token != address(0), "Launch should succeed");
        assertEq(vibes.balanceOf(founder), 0, "Founder should have 0 $VIBES after burn");
        assertEq(vibes.balanceOf(address(0xdead)), burnAmount, "Dead address should hold burned $VIBES");
    }

    function test_vibesBurn_revertsWithoutApproval() public {
        MockVibesTokenSimple vibes = new MockVibesTokenSimple();
        uint256 burnAmount = 1000 ether;

        VibesRouterExtension(address(router)).setVibesToken(address(vibes));
        VibesRouterExtension(address(router)).setLaunchBurnAmount(burnAmount);

        // Mint $VIBES but DON'T approve
        vibes.mint(founder, burnAmount);

        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        vm.expectRevert();
        router.launchWithCampaign{value: DEPOSIT}(
            "TestToken", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline, 750, 0, 0,
            0, 0, ""
        );
    }

    function test_vibesBurn_revertsWithInsufficientBalance() public {
        MockVibesTokenSimple vibes = new MockVibesTokenSimple();
        uint256 burnAmount = 1000 ether;

        VibesRouterExtension(address(router)).setVibesToken(address(vibes));
        VibesRouterExtension(address(router)).setLaunchBurnAmount(burnAmount);

        // Mint only half the required amount
        vibes.mint(founder, burnAmount / 2);
        vm.prank(founder);
        vibes.approve(address(router), burnAmount);

        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        vm.expectRevert();
        router.launchWithCampaign{value: DEPOSIT}(
            "TestToken", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline, 750, 0, 0,
            0, 0, ""
        );
    }

    function test_vibesBurn_skippedWhenAmountZero() public {
        MockVibesTokenSimple vibes = new MockVibesTokenSimple();

        // Set token but leave amount at 0
        VibesRouterExtension(address(router)).setVibesToken(address(vibes));
        // launchBurnAmount defaults to 0

        // Launch should succeed without any $VIBES
        (address token,) = _launchFixedGoal();
        assertTrue(token != address(0), "Launch should succeed with burn amount = 0");
    }

    function test_vibesBurn_skippedWhenTokenAddressZero() public {
        // Set amount but leave token at address(0)
        VibesRouterExtension(address(router)).setLaunchBurnAmount(1000 ether);

        // Launch should succeed without $VIBES token configured
        (address token,) = _launchFixedGoal();
        assertTrue(token != address(0), "Launch should succeed with vibesToken = address(0)");
    }
    // ================================================================
    // CONSOLIDATED AUDIT REVIEW FIXES (F1–F8)
    // ================================================================

    // ============ F1: LP Rescue + Manual Resolution ============

    function test_F1_completeLP_manualResolution() public {
        aeroRouter.setShouldFail(true);
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");
        vm.warp(block.timestamp + 15 days);

        escrow.finalize();
        assertEq(uint(router.lpStatus(token)), uint(VibesRouterStorage.LPStatus.Rescued));

        // Audit fix H-4: completeLP now requires a real locker-side lock with onchain DEAD
        // balance proof. Perform the full recovery: resolve → simulate off-chain LP → record → completeLP.
        address adminWallet = makeAddr("adminLPWallet");
        lpLocker.resolveRescuedFunds(address(escrow), adminWallet);

        AuditFixesPool mockPool = new AuditFixesPool();
        uint256 manualLpAmount = 1 ether;
        mockPool.setBalance(0x000000000000000000000000000000000000dEaD, manualLpAmount);

        lpLocker.recordManualLPLock(address(escrow), address(mockPool), address(0), manualLpAmount);

        VibesRouterExtension(address(router)).completeLP(token);
        assertEq(uint(router.lpStatus(token)), uint(VibesRouterStorage.LPStatus.Created));
    }

    function test_F1_completeLP_revertsIfNotRescued() public {
        (address token, VibesTranchEscrow escrow) = _fundAndFinalize();

        // LP was created normally — completeLP should revert
        vm.expectRevert(VibesRouterStorage.NotInRescuedState.selector);
        VibesRouterExtension(address(router)).completeLP(token);
    }

    function test_F1_lpStatus_createdOnNormalFinalize() public {
        (address token, VibesTranchEscrow escrow) = _fundAndFinalize();
        assertEq(uint(router.lpStatus(token)), uint(VibesRouterStorage.LPStatus.Created));
    }

    // ============ F2: rescueERC20 Guards ============

    function test_F2_rescueERC20_revertsActiveEscrow() public {
        (address token,) = _launchFixedGoal();

        // Token has an active escrow — rescue should revert
        vm.expectRevert(VibesRouterStorage.TokenHasActiveEscrow.selector);
        VibesRouterExtension(address(router)).rescueERC20(token, opsWallet, 1);
    }

    function test_F2_rescueERC20_revertsAfterFinalization() public {
        // Launch with two backers so claims remain after first claim
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        vm.prank(backer1);
        escrow.contribute{value: 5 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 5 ether}(0, 0, "");

        vm.warp(block.timestamp + 15 days);
        // Only backer1 claims — backer2's allocation still in router
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        // Both guards apply: backerTokensForClaims > 0 fires first (backer2 hasn't claimed)
        assertTrue(router.tokenToEscrow(token) != address(0));
        vm.expectRevert(VibesRouterStorage.TokenHasActiveClaims.selector);
        VibesRouterExtension(address(router)).rescueERC20(token, opsWallet, 1);
    }

    function test_F2_rescueERC20_succeedsUnrelatedToken() public {
        _launchFixedGoal();

        // Deploy a random ERC20 and send to router
        VibesToken randomToken = new VibesToken("Random", "RND", 18, 1000 ether, address(router));

        // Rescue unrelated token should succeed
        VibesRouterExtension(address(router)).rescueERC20(address(randomToken), opsWallet, 1000 ether);
        assertEq(randomToken.balanceOf(opsWallet), 1000 ether);
    }

    // ============ F3: Token Claims in Frozen State ============

    function test_F3_claimTokens_afterFreeze() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Two backers contribute
        vm.prank(backer1);
        escrow.contribute{value: 5 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 5 ether}(0, 0, "");

        // Finalize — only backer1 claims
        vm.warp(block.timestamp + 15 days);
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        uint256 backer1Tokens = IERC20(token).balanceOf(backer1);
        assertTrue(backer1Tokens > 0);

        // Freeze campaign before backer2 claims
        escrow.freezeCampaign("abandoned");

        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(uint(camp.state), uint(VibesTranchEscrow.CampaignState.Frozen));

        // Audit fix F3: backer2 should still be able to claim tokens in Frozen state
        vm.prank(backer2);
        VibesRouterExtension(address(router)).claimTokens(token);

        uint256 backer2Tokens = IERC20(token).balanceOf(backer2);
        assertTrue(backer2Tokens > 0, "Backer2 should claim tokens after freeze");
        assertEq(backer1Tokens, backer2Tokens, "Equal contributions = equal tokens");
    }

    function test_F3_claimTokens_afterRefunding() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        vm.warp(block.timestamp + 15 days);
        // Don't claim tokens yet — go straight to freeze

        // Need to finalize first so campaign reaches Funded
        escrow.finalize();

        // Freeze → commit → wait → finalize → Refunding (F10 commit-reveal)
        escrow.freezeCampaign("abandoned");
        escrow.commitRefundMerkleRoot(keccak256("root"));
        vm.warp(block.timestamp + 25 hours);
        escrow.finalizeRefundMerkleRoot();

        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(uint(camp.state), uint(VibesTranchEscrow.CampaignState.Refunding));

        // Backer should still be able to claim tokens in Refunding state
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        assertTrue(IERC20(token).balanceOf(backer1) > 0, "Should claim tokens in Refunding state");
    }

    // ============ F4: Pro-Rata Excess Refund Liability ============

    /// Helper: launch oversubscribed pro-rata raise
    function _launchOversubscribedProRata() internal returns (address token, VibesTranchEscrow escrow) {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        address escrowAddr;
        (token, escrowAddr,) = router.launchWithCampaign{value: DEPOSIT}(
            "TestToken", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.ProRata,
            GOAL, 0, deadline, 750, 0, 0,
            0, 0, ""
        );
        escrow = VibesTranchEscrow(payable(escrowAddr));

        // Oversubscribe: 2x the goal
        vm.prank(backer1);
        escrow.contribute{value: 12 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 8 ether}(0, 0, "");

        // Finalize
        vm.warp(block.timestamp + 15 days);
        escrow.finalize();
    }

    function test_F4_excessLiability_trackedAtFinalization() public {
        (, VibesTranchEscrow escrow) = _launchOversubscribedProRata();

        // totalCommitted = 20 ether, goal = 10 ether, excess = 10 ether
        assertEq(escrow.totalExcessRefundLiability(), 10 ether);
    }

    function test_F4_freeze_excludesExcessFromFrozenBalance() public {
        (, VibesTranchEscrow escrow) = _launchOversubscribedProRata();

        uint256 escrowBalance = address(escrow).balance;
        uint256 excessLiability = escrow.totalExcessRefundLiability();
        assertTrue(excessLiability > 0, "Should have excess liability");

        // Freeze
        escrow.freezeCampaign("test");

        // frozenEthBalance should exclude excess liability
        uint256 frozen = escrow.frozenEthBalance();
        assertEq(frozen, escrowBalance - excessLiability, "Frozen balance should exclude excess liability");
    }

    function test_F4_claimExcessRefund_afterFreeze() public {
        (address token, VibesTranchEscrow escrow) = _launchOversubscribedProRata();

        // Freeze before any excess claims
        escrow.freezeCampaign("test");

        uint256 balBefore = backer1.balance;

        // Audit fix F4: backer1 should still be able to claim excess in Frozen state
        vm.prank(backer1);
        escrow.claimExcessRefund();

        assertTrue(backer1.balance > balBefore, "Should receive excess refund after freeze");

        // Liability should have decreased
        assertTrue(escrow.totalExcessRefundLiability() < 10 ether);
    }

    function test_F4_fixedGoal_noExcessLiability() public {
        (address token, VibesTranchEscrow escrow) = _fundAndFinalize();
        assertEq(escrow.totalExcessRefundLiability(), 0, "FixedGoal should have zero excess liability");
    }

    // ============ F5: createDistributor Disabled ============

    function test_F5_createDistributor_reverts() public {
        (address token, VibesTranchEscrow escrow) = _fundAndFinalize();

        vm.expectRevert(VibesRouterStorage.DistributorDisabled.selector);
        VibesRouterExtension(address(router)).createDistributor(token);
    }

    // ============ F6: Treasury Challenge Convergence ============

    function test_F6_rejectChallenge_thenExecuteImmediately() public {
        // Set up treasury directly (not through router lifecycle)
        VibesToken tToken = new VibesToken("TreasuryTest", "TT", 18, 1_000_000 ether, address(this));
        address treasuryAdmin = makeAddr("tAdmin");

        vm.prank(address(this));
        VibesTreasuryEscrow treasury = new VibesTreasuryEscrow(
            address(tToken), founder, treasuryAdmin, 1 days, 1 hours, 2 hours
        );

        tToken.transfer(address(treasury), 100_000 ether);
        tToken.transfer(backer1, 10_000 ether); // For challenging

        // Activate
        vm.prank(address(this));
        treasury.activate();

        // Wait past cliff
        vm.warp(block.timestamp + 1 days + 1);

        // Founder creates proposal
        vm.prank(founder);
        treasury.createProposal(5_000 ether, keccak256("reason"));

        // Backer challenges
        vm.prank(backer1);
        tToken.approve(address(treasury), 10_000 ether);
        vm.prank(backer1);
        treasury.raiseChallenge("dispute");

        // Admin rejects challenge
        vm.prank(treasuryAdmin);
        treasury.rejectChallenge();

        // Audit fix F6: Proposal should be immediately executable (no need to wait for window)
        vm.prank(founder);
        treasury.executeProposal();

        // Founder should have received tokens
        assertTrue(tToken.balanceOf(founder) > 0, "Founder should receive tokens after immediate execute");
    }

    function test_F6_rejectChallenge_blocksRechallenge() public {
        VibesToken tToken = new VibesToken("TreasuryTest", "TT", 18, 1_000_000 ether, address(this));
        address treasuryAdmin = makeAddr("tAdmin");

        vm.prank(address(this));
        VibesTreasuryEscrow treasury = new VibesTreasuryEscrow(
            address(tToken), founder, treasuryAdmin, 1 days, 1 hours, 2 hours
        );

        tToken.transfer(address(treasury), 100_000 ether);
        tToken.transfer(backer1, 10_000 ether);

        vm.prank(address(this));
        treasury.activate();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(founder);
        treasury.createProposal(5_000 ether, keccak256("reason"));

        // Challenge + reject
        vm.prank(backer1);
        tToken.approve(address(treasury), 10_000 ether);
        vm.prank(backer1);
        treasury.raiseChallenge("dispute");
        vm.prank(treasuryAdmin);
        treasury.rejectChallenge();

        // Audit fix F6: Second challenge should revert
        vm.prank(backer1);
        vm.expectRevert(VibesTreasuryEscrow.ChallengeAlreadyResolved.selector);
        treasury.raiseChallenge("dispute again");
    }

    function test_F6_newProposal_resetsFlag() public {
        VibesToken tToken = new VibesToken("TreasuryTest", "TT", 18, 1_000_000 ether, address(this));
        address treasuryAdmin = makeAddr("tAdmin");

        vm.prank(address(this));
        VibesTreasuryEscrow treasury = new VibesTreasuryEscrow(
            address(tToken), founder, treasuryAdmin, 1 days, 1 hours, 2 hours
        );

        tToken.transfer(address(treasury), 100_000 ether);
        tToken.transfer(backer1, 10_000 ether);

        vm.prank(address(this));
        treasury.activate();
        vm.warp(block.timestamp + 1 days + 1);

        // First proposal: challenge + reject + execute
        vm.prank(founder);
        treasury.createProposal(5_000 ether, keccak256("reason1"));
        vm.prank(backer1);
        tToken.approve(address(treasury), 10_000 ether);
        vm.prank(backer1);
        treasury.raiseChallenge("dispute");
        vm.prank(treasuryAdmin);
        treasury.rejectChallenge();
        vm.prank(founder);
        treasury.executeProposal();

        // Wait for cooldown
        vm.warp(block.timestamp + 1 hours + 1);

        // Second proposal: challenge should be allowed (flag reset)
        vm.prank(founder);
        treasury.createProposal(5_000 ether, keccak256("reason2"));

        assertFalse(treasury.proposalChallengeResolved(), "Flag should reset for new proposal");

        // Challenge should succeed on new proposal
        vm.prank(backer1);
        treasury.raiseChallenge("new dispute");
        // If we got here without revert, the flag was properly reset
    }

    // ============ F7: launch() Pause Guard ============

    function test_F7_launch_revertsWhenPaused() public {
        VibesRouterExtension(address(router)).pause();

        vm.prank(founder);
        vm.expectRevert();
        router.launch(
            "Test", "TST", 18, TOTAL_SUPPLY, founder,
            capsuleHash, 1, 1, 1, proofHash
        );
    }

    function test_F7_launch_succeedsAfterUnpause() public {
        VibesRouterExtension(address(router)).pause();
        router.emergencyUnpause();

        vm.prank(founder);
        address token = router.launch(
            "Test", "TST", 18, TOTAL_SUPPLY, founder,
            capsuleHash, 1, 1, 1, proofHash
        );
        assertTrue(token != address(0));
    }

    // ============ F8: Time Oracle Consistency ============

    function test_F8_escrow_currentTime_public() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Since we're in real-time mode, currentTime() should equal block.timestamp
        assertEq(escrow.currentTime(), block.timestamp);
    }
}

/// @dev Mock LP locker that always returns (address(0), 0) to simulate LP creation failure
contract MockFailingLPLocker {
    address public authorizedRouter;

    function setAuthorizedRouter(address _router) external {
        authorizedRouter = _router;
    }

    function createAndLockLP(address, uint256, address, address, address) external payable returns (address, uint256) {
        return (address(0), 0);
    }

    // Accept ETH
    receive() external payable {}
}

/// @dev Minimal ERC20 mock for $VIBES burn-to-launch tests
contract MockVibesTokenSimple {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
