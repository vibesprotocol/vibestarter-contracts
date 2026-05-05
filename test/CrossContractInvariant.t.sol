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
import {VibesVesting} from "../src/VibesVesting.sol";
import {VibesTreasuryEscrow} from "../src/VibesTreasuryEscrow.sol";
import {VibesStaking} from "../src/VibesStaking.sol";
import {VibesStakerRewards} from "../src/VibesStakerRewards.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockAerodromeRouter.sol";

/**
 * @title Cross-Contract Invariant & Chain Tests
 * @notice Tests that verify:
 *   1. ETH conservation across the entire system (no ETH created or destroyed)
 *   2. Token balance invariants (router holds >= sum of backer claims)
 *   3. Treasury freeze → vesting freeze → staker impact (full E2E chain)
 *   4. Multiple campaign isolation (one failure doesn't affect another)
 *   5. ProRata excess + freeze accounting stays balanced
 */
contract CrossContractInvariantTest is Test {
    VibesLaunchRouterV2 public router;
    VibesRouterExtension public ext;
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrowFactory public escrowFactory;
    VibesLPLocker public lpLocker;
    VibesStaking public staking;
    VibesStakerRewards public stakerRewards;
    MockAerodromeRouter public aeroRouter;
    MockTimeOracle public timeOracle;
    VibesTranchEscrow public escrowImpl;
    VibesToken public vibesToken;

    address public admin;
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");
    address public backer3 = makeAddr("backer3");
    address public staker1 = makeAddr("staker1");
    address public platformWallet = makeAddr("platform");
    address public opsWallet = makeAddr("opsWallet");

    address public weth = makeAddr("weth");
    address public aeroFactory = makeAddr("aeroFactory");

    uint256 public constant SUPPLY = 1_000_000 ether;
    uint256 public constant DEPOSIT = 0.01 ether;
    uint256 public constant GOAL = 10 ether;
    uint256 public constant VIBES_SUPPLY = 1_000_000_000 ether;

    bytes32 public capsule = keccak256("capsule");
    bytes32 public proof = keccak256("proof");

    function setUp() public {
        admin = address(this);

        tokenFactory = new VibesTokenFactory();
        registry = new VibesRegistry();
        aeroRouter = new MockAerodromeRouter(weth, aeroFactory);
        lpLocker = new VibesLPLocker(address(aeroRouter), aeroFactory);
        {
            VibesLPFeeClaimer _fc = new VibesLPFeeClaimer();
            lpLocker.setFeeClaimerImplementation(address(_fc));
        }
        timeOracle = new MockTimeOracle();
        timeOracle.setRealTimeMode(true);
        escrowImpl = new VibesTranchEscrow();

        // Deploy $VIBES + staking
        vibesToken = new VibesToken("Vibes", "VIBES", 18, VIBES_SUPPLY, address(this));
        staking = new VibesStaking(address(vibesToken), address(0));

        ext = new VibesRouterExtension();
        router = new VibesLaunchRouterV2(
            address(ext), address(tokenFactory), address(registry),
            address(0), payable(address(0))
        );

        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl), admin, platformWallet,
            address(timeOracle), address(router), address(lpLocker),
            address(0) // no trusted signer
        );

        // Deploy staker rewards
        stakerRewards = new VibesStakerRewards(admin, address(staking), address(router));
        staking.setSnapshotAuthorized(address(stakerRewards), true);

        // Wire everything
        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker)));
        VibesRouterExtension(address(router)).setOpsWallet(opsWallet);
        VibesRouterExtension(address(router)).setStakerRewardsContract(address(stakerRewards));

        registry.authorizeRouter(address(router));
        lpLocker.setAuthorizedRouter(address(router));

        vm.deal(founder, 200 ether);
        vm.deal(backer1, 200 ether);
        vm.deal(backer2, 200 ether);
        vm.deal(backer3, 200 ether);
        vm.deal(staker1, 200 ether);

        // Give staker1 some VIBES for staking
        vibesToken.transfer(staker1, 100_000 ether);
    }

    receive() external payable {}

    // ============ Time Helpers ============

    function _advanceDays(uint256 _days) internal {
        vm.warp(block.timestamp + _days * 1 days);
        skip((_days) * 1 days);
    }

    function _advanceTime(uint256 _seconds) internal {
        vm.warp(block.timestamp + _seconds);
        skip(_seconds);
    }

    // ============ Launch Helpers ============

    function _launchFixed(uint256 founderBps, uint256 treasuryBps)
        internal returns (address token, VibesTranchEscrow escrow, address vesting, address treasury)
    {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        address escrowAddr;
        address vestingAddr;
        (token, escrowAddr, vestingAddr) = router.launchWithCampaign{value: DEPOSIT}(
            "Token", "TKN", 18, SUPPLY,
            capsule, 1, 1, 1, proof,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline, founderBps, treasuryBps, 0, 0, 0, ""
        );
        escrow = VibesTranchEscrow(payable(escrowAddr));
        vesting = vestingAddr;
        treasury = VibesRouterExtension(address(router)).tokenToTreasury(token);
    }

    // ============================================================
    // 1. ETH CONSERVATION INVARIANT
    // ============================================================

    /// @notice Full lifecycle: all ETH that enters the system is accounted for
    function test_invariant_ethConservation_fullLifecycle() public {
        // Record starting balances
        uint256 startFounder = founder.balance;
        uint256 startBacker1 = backer1.balance;
        uint256 startBacker2 = backer2.balance;
        uint256 startPlatform = platformWallet.balance;

        // Launch campaign with 7.5% founder + 10% treasury
        (address token, VibesTranchEscrow escrow,, ) = _launchFixed(750, 1000);

        // Two backers contribute
        vm.prank(backer1);
        escrow.contribute{value: 6 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 4 ether}(0, 0, "");

        // Finalize
        _advanceDays(15);
        escrow.finalize();

        // Claim all tranches
        _advanceTime(73 hours);
        vm.prank(founder);
        escrow.claimTranche(0);

        for (uint8 i = 1; i <= 6; i++) {
            _advanceDays(30);
            vm.prank(founder);
            escrow.requestTranche(i);
            _advanceTime(73 hours);
            vm.prank(founder);
            escrow.claimTranche(i);
        }

        // Claim platform fees
        escrow.claimPlatformFees();

        // Calculate total ETH that entered the system
        uint256 totalIn = DEPOSIT + 6 ether + 4 ether; // deposit + contributions

        // Calculate total ETH that left the system.
        // Successful raise: backers paid in ETH and received tokens (not ETH back).
        // Underflow-safe arithmetic: each actor's `net received` = balance_now - balance_start,
        // adjusted by what they paid in. For founder: they paid DEPOSIT and received tranches.
        // For backers: they paid contribution and received tokens (no ETH back).
        uint256 founderPaid = DEPOSIT;
        uint256 founderReceived = founder.balance + founderPaid > startFounder
            ? (founder.balance + founderPaid) - startFounder
            : 0;
        // backer1 and backer2: paid contribution, received nothing back in ETH → 0 ETH received.
        // (Kept these assertions for documentation; unused in the conservation equation.)
        uint256 platformReceived = platformWallet.balance > startPlatform
            ? platformWallet.balance - startPlatform
            : 0;

        // ETH left in contracts
        uint256 escrowRemaining = address(escrow).balance;
        uint256 routerRemaining = address(router).balance;
        uint256 lpLockerRemaining = address(lpLocker).balance;
        uint256 aeroRemaining = address(aeroRouter).balance; // mock holds LP ETH

        uint256 totalOut = founderReceived + platformReceived;
        uint256 totalHeld = escrowRemaining + routerRemaining + lpLockerRemaining + aeroRemaining;

        // Conservation: totalIn = totalOut + totalHeld (allowing for rounding dust)
        uint256 totalAccounted = totalOut + totalHeld;
        assertApproxEqAbs(totalIn, totalAccounted, 10, "ETH not conserved across system");
    }

    // ============================================================
    // 2. TOKEN BALANCE INVARIANT
    // ============================================================

    /// @notice Router token balance >= sum of unclaimed backer tokens
    function test_invariant_routerTokenBalance_coversClaimPool() public {
        (address token, VibesTranchEscrow escrow,, ) = _launchFixed(750, 1000);

        // Fund and finalize
        vm.prank(backer1);
        escrow.contribute{value: 6 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 4 ether}(0, 0, "");
        _advanceDays(15);
        escrow.finalize();

        // Check invariant: router balance >= backerTokensForClaims
        uint256 routerBalance = IERC20(token).balanceOf(address(router));
        uint256 claimPool = VibesRouterExtension(address(router)).backerTokensForClaims(token);

        assertGe(routerBalance, claimPool, "Router balance must cover claim pool");

        // backer1 claims
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        // Invariant still holds
        routerBalance = IERC20(token).balanceOf(address(router));
        claimPool = VibesRouterExtension(address(router)).backerTokensForClaims(token);
        assertGe(routerBalance, claimPool, "Invariant holds after partial claim");

        // backer2 claims
        vm.prank(backer2);
        VibesRouterExtension(address(router)).claimTokens(token);

        routerBalance = IERC20(token).balanceOf(address(router));
        claimPool = VibesRouterExtension(address(router)).backerTokensForClaims(token);
        assertEq(claimPool, 0, "Claim pool should be empty");
    }

    // ============================================================
    // 3. TREASURY FREEZE → VESTING FREEZE → STAKER IMPACT (FULL E2E)
    // ============================================================

    /// @notice Full chain: launch → fund → treasury proposal → malicious upheld → vesting frozen → staker rewards unaffected
    function test_chain_treasuryFreeze_vestingFreeze_stakerRewardsIntact() public {
        // Staker1 stakes before raise
        vm.startPrank(staker1);
        vibesToken.approve(address(staking), 100_000 ether);
        staking.stake(100_000 ether, 0, 0, "");
        vm.stopPrank();
        _advanceTime(1); // firstStakeTime < notifiedAt

        // Launch campaign with 7.5% founder + 10% treasury
        (address token, VibesTranchEscrow escrow, address vestingAddr, address treasuryAddr) = _launchFixed(750, 1000);

        // Fund and finalize
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");
        _advanceDays(15);
        escrow.finalize();

        // Verify staker rewards were notified
        (,, , uint256 totalStakedSnap,,bool active) = stakerRewards.getRewardsInfo(address(escrow));
        assertTrue(active, "Staker rewards should be active");
        assertEq(totalStakedSnap, 100_000 ether, "Snapshot should capture staker balance");

        // Verify vesting is active
        VibesVesting vesting = VibesVesting(vestingAddr);
        assertFalse(vesting.frozen(), "Vesting should not be frozen yet");

        // Treasury: activate, create proposal, challenge, upholdMalicious
        VibesTreasuryEscrow treasury = VibesTreasuryEscrow(treasuryAddr);

        // Advance past treasury cliff. Router is NOT in testnet mode here, so mainnet
        // RELEASE_CLIFF (180 days) applies — not 6 days.
        _advanceDays(181);

        // Give backer1 enough tokens to challenge treasury (0.5% of supply)
        uint256 challengeTokens = (SUPPLY * 50) / 10000;
        // backer1 should have tokens from claiming
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        uint256 backer1Tokens = IERC20(token).balanceOf(backer1);
        assertTrue(backer1Tokens >= challengeTokens, "Backer needs enough tokens to challenge");

        // Founder creates treasury proposal
        uint256 proposalAmount = IERC20(token).balanceOf(treasuryAddr) / 10; // max 10%
        vm.prank(founder);
        treasury.createProposal(proposalAmount, keccak256("use funds"));

        // Backer challenges
        vm.startPrank(backer1);
        IERC20(token).approve(treasuryAddr, challengeTokens);
        treasury.raiseChallenge("Malicious intent");
        vm.stopPrank();

        // Admin upholds as malicious → treasury burned, vesting frozen
        treasury.upholdChallengeMalicious();

        // Verify cascade
        assertTrue(treasury.terminated(), "Treasury should be terminated");
        assertTrue(vesting.frozen(), "Vesting should be frozen");
        assertEq(IERC20(token).balanceOf(treasuryAddr), 0, "Treasury tokens should be burned");
        assertEq(IERC20(token).balanceOf(vestingAddr), 0, "Vesting tokens should be burned");

        // Staker rewards should STILL be claimable (unaffected by treasury/vesting freeze)
        (bool canClaim, uint256 claimAmount) = stakerRewards.canClaim(address(escrow), staker1);
        assertTrue(canClaim, "Staker should still be able to claim rewards");
        assertTrue(claimAmount > 0, "Staker reward amount should be > 0");

        vm.prank(staker1);
        stakerRewards.claim(address(escrow));
        assertTrue(IERC20(token).balanceOf(staker1) > 0, "Staker should have received rewards");
    }

    // ============================================================
    // 4. MULTIPLE CAMPAIGN ISOLATION
    // ============================================================

    /// @notice One campaign failing doesn't affect another campaign's funds
    function test_isolation_failedCampaign_doesNotAffectSuccessful() public {
        // Launch campaign 1 (will succeed)
        (address token1, VibesTranchEscrow escrow1,, ) = _launchFixed(0, 0);

        // Fund campaign 1
        vm.prank(backer1);
        escrow1.contribute{value: GOAL}(0, 0, "");

        // Launch campaign 2 (will fail)
        uint256 deadline2 = block.timestamp + 14 days;
        vm.prank(founder);
        (address token2, address escrow2Addr, ) = router.launchWithCampaign{value: DEPOSIT}(
            "Token2", "TK2", 18, SUPPLY,
            keccak256("cap2"), 1, 1, 1, keccak256("proof2"),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline2, 0, 0, 0, 0, 0, ""
        );
        VibesTranchEscrow escrow2 = VibesTranchEscrow(payable(escrow2Addr));

        // Only partial funding for campaign 2
        vm.prank(backer2);
        escrow2.contribute{value: 3 ether}(0, 0, "");

        // Finalize both
        _advanceDays(15);
        escrow1.finalize();
        escrow2.finalize();

        // Campaign 1 should be Funded
        assertEq(uint8(escrow1.getCampaign().state), uint8(VibesTranchEscrow.CampaignState.Funded));
        // Campaign 2 should be Failed
        assertEq(uint8(escrow2.getCampaign().state), uint8(VibesTranchEscrow.CampaignState.Failed));

        // Campaign 1: backer1 can claim tokens
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token1);
        assertTrue(IERC20(token1).balanceOf(backer1) > 0, "Backer1 should have campaign1 tokens");

        // Campaign 2: backer2 can claim refund
        uint256 backer2BalBefore = backer2.balance;
        vm.prank(backer2);
        escrow2.claimContributorRefund();
        assertEq(backer2.balance - backer2BalBefore, 3 ether, "Backer2 should get full refund");

        // Campaign 1 funds are isolated — backer2's refund didn't affect it
        _advanceTime(73 hours);
        uint256 founderBalBefore = founder.balance;
        vm.prank(founder);
        escrow1.claimTranche(0);
        assertTrue(founder.balance > founderBalBefore, "Founder should receive kickstart from campaign1");
    }

    // ============================================================
    // 5. PRO-RATA EXCESS + FREEZE ACCOUNTING
    // ============================================================

    /// @notice ProRata: excess refunds + freeze accounting stays balanced
    function test_invariant_proRata_excessPlusFreeze_balanced() public {
        // Launch ProRata campaign
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (address token, address escrowAddr,) = router.launchWithCampaign{value: DEPOSIT}(
            "Token", "TKN", 18, SUPPLY,
            capsule, 1, 1, 1, proof,
            VibesTranchEscrow.RaiseType.ProRata,
            GOAL, 0, deadline, 0, 0, 0, 0, 0, ""
        );
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Oversubscribe: 3 backers contribute 20 ETH total into 10 ETH goal
        vm.prank(backer1);
        escrow.contribute{value: 8 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 7 ether}(0, 0, "");
        vm.prank(backer3);
        escrow.contribute{value: 5 ether}(0, 0, "");

        _advanceDays(15);
        escrow.finalize();

        // totalCommitted=20, goal=10, excess=10
        assertEq(escrow.effectiveRaised(), GOAL);
        assertEq(escrow.totalExcessRefundLiability(), 10 ether);

        // Backer1 claims excess: contributed 8, allocation = (8*10)/20 = 4, excess = 4
        uint256 b1BalBefore = backer1.balance;
        vm.prank(backer1);
        escrow.claimExcessRefund();
        assertEq(backer1.balance - b1BalBefore, 4 ether);

        // Freeze campaign after partial excess claims
        escrow.freezeCampaign("testing freeze accounting");

        // frozenEthBalance should NOT include unclaimed excess (6 ETH) or platform fees
        uint256 frozenEth = escrow.frozenEthBalance();
        uint256 escrowBal = address(escrow).balance;
        uint256 unclaimedExcess = escrow.totalExcessRefundLiability();
        uint256 pendingFees = escrow.pendingPlatformFees();

        // Invariant: frozenEthBalance = balance - unclaimedExcess - pendingFees
        uint256 expectedFrozen = escrowBal - unclaimedExcess - pendingFees;
        assertEq(frozenEth, expectedFrozen, "Frozen ETH should exclude excess liability and fees");

        // Remaining backers can still claim excess even after freeze
        uint256 b2BalBefore = backer2.balance;
        vm.prank(backer2);
        escrow.claimExcessRefund();
        uint256 b2Excess = backer2.balance - b2BalBefore;
        assertEq(b2Excess, 7 ether - (7 ether * GOAL) / 20 ether, "Backer2 excess correct");
    }
}
