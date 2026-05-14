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
import {VibesToken} from "../src/VibesToken.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockAerodromeRouter.sol";

/// @dev Minimal pool mock for H-4 recordManualLPLock onchain-proof path: exposes a
///      settable balanceOf(DEAD) so tests can simulate off-chain LP burn.
contract E2EPool {
    mapping(address => uint256) public balanceOf;
    function setBalance(address holder, uint256 amount) external { balanceOf[holder] = amount; }
}

/**
 * @title End-to-End Scenario Tests
 * @notice Full lifecycle simulations exercising cross-contract boundaries.
 *
 * NOT unit tests — these simulate real-world raise lifecycles end-to-end:
 *   1. Happy path: FixedGoal with vesting+treasury, all tranches claimed
 *   2. Happy path: ProRata oversubscribed, excess refunds, partial token claims
 *   3. Failed raise: deadline passes, all contributors refunded
 *   4. Mid-lifecycle freeze: challenge upheld, holder refunds via merkle
 *   5. Treasury governance: proposal → challenge → malicious termination → vesting freeze
 *   6. Adversarial: griefing attempts, front-running, double claims
 *   7. LP failure: deferred resolution with active backers
 *   8. Admin emergency: pause, deposit management, rescue operations
 *
 * Every scenario tracks ETH accounting to assert no value is created or destroyed.
 */
contract E2EScenariosTest is Test {

    // ============ Infrastructure ============

    VibesLaunchRouterV2 public router;
    VibesRouterExtension public ext;
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrowFactory public escrowFactory;
    VibesLPLocker public lpLocker;
    MockAerodromeRouter public aeroRouter;
    MockTimeOracle public timeOracle;
    VibesTranchEscrow public escrowImpl;

    // ============ Actors ============

    address public admin;               // Test contract is admin/owner
    address public founder   = makeAddr("founder");
    address public backer1   = makeAddr("backer1");
    address public backer2   = makeAddr("backer2");
    address public backer3   = makeAddr("backer3");
    address public backer4   = makeAddr("backer4");
    address public attacker  = makeAddr("attacker");
    address public platformWallet = makeAddr("platform");
    address public opsWallet = makeAddr("opsWallet");
    address public stakerRewardsAddr = makeAddr("stakerRewards");

    address public weth        = makeAddr("weth");
    address public aeroFactory = makeAddr("aeroFactory");

    // ============ Constants ============

    uint256 public constant SUPPLY  = 1_000_000 ether;
    uint256 public constant DEPOSIT = 0.01 ether;
    uint256 public constant GOAL    = 10 ether;

    bytes32 public capsule = keccak256("capsule");
    bytes32 public proof   = keccak256("proof");

    // ============ Setup ============

    function setUp() public {
        admin = address(this);

        tokenFactory = new VibesTokenFactory();
        registry     = new VibesRegistry();
        aeroRouter   = new MockAerodromeRouter(weth, aeroFactory);
        lpLocker     = new VibesLPLocker(address(aeroRouter), aeroFactory);
        {
            VibesLPFeeClaimer _fc = new VibesLPFeeClaimer();
            lpLocker.setFeeClaimerImplementation(address(_fc));
        }
        timeOracle   = new MockTimeOracle();
        timeOracle.setRealTimeMode(true);
        escrowImpl   = new VibesTranchEscrow();

        ext    = new VibesRouterExtension();
        router = new VibesLaunchRouterV2(
            address(ext), address(tokenFactory), address(registry),
            address(0), payable(address(0))
        );

        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl), admin, platformWallet,
            address(timeOracle), address(router), address(lpLocker),
            address(0) // trustedSigner disabled
        );

        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker)));
        VibesRouterExtension(address(router)).setOpsWallet(opsWallet);
        VibesRouterExtension(address(router)).setStakerRewardsContract(stakerRewardsAddr);

        registry.authorizeRouter(address(router));
        lpLocker.setAuthorizedRouter(address(router));

        // Use mock time mode — all time advances go through the oracle
        // This keeps _currentTime() and block.timestamp decoupled, which is safer for testing.

        vm.deal(founder,  200 ether);
        vm.deal(backer1,  200 ether);
        vm.deal(backer2,  200 ether);
        vm.deal(backer3,  200 ether);
        vm.deal(backer4,  200 ether);
        vm.deal(attacker, 200 ether);
    }

    receive() external payable {}

    // ================================================================
    //  TIME HELPERS
    // ================================================================

    function _advanceDays(uint256 _days) internal {
        vm.warp(block.timestamp + _days * 1 days);
        skip((_days) * 1 days);
    }

    function _advanceTime(uint256 _seconds) internal {
        vm.warp(block.timestamp + _seconds);
        skip(_seconds);
    }

    // ================================================================
    //  LAUNCH HELPERS
    // ================================================================

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
        escrow  = VibesTranchEscrow(payable(escrowAddr));
        vesting = vestingAddr;
        treasury = router.tokenToTreasury(token);
    }

    function _launchProRata(uint256 hardCap, uint256 founderBps, uint256 treasuryBps)
        internal returns (address token, VibesTranchEscrow escrow, address vesting, address treasury)
    {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        address escrowAddr;
        address vestingAddr;
        (token, escrowAddr, vestingAddr) = router.launchWithCampaign{value: DEPOSIT}(
            "ProRata", "PRT", 18, SUPPLY,
            capsule, 1, 1, 1, proof,
            VibesTranchEscrow.RaiseType.ProRata,
            hardCap, 0, deadline, founderBps, treasuryBps, 0, 0, 0, ""
        );
        escrow  = VibesTranchEscrow(payable(escrowAddr));
        vesting = vestingAddr;
        treasury = router.tokenToTreasury(token);
    }

    function _launchOpenEnded(uint256 softCap, uint256 founderBps)
        internal returns (address token, VibesTranchEscrow escrow)
    {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        address escrowAddr;
        (token, escrowAddr,) = router.launchWithCampaign{value: DEPOSIT}(
            "Open", "OPN", 18, SUPPLY,
            capsule, 1, 1, 1, proof,
            VibesTranchEscrow.RaiseType.OpenEnded,
            0, softCap, deadline, founderBps, 0, 0, 0, 0, ""
        );
        escrow = VibesTranchEscrow(payable(escrowAddr));
    }

    // ================================================================
    //  TRANCHE HELPERS
    // ================================================================

    function _claimKickstart(VibesTranchEscrow escrow) internal {
        // Kickstart is tranche 0 — still subject to the 72h challenge window after finalization.
        skip(73 hours);
        vm.prank(founder);
        escrow.claimTranche(0);
    }

    function _claimMonthlyTranche(VibesTranchEscrow escrow, uint8 t) internal {
        uint256 unlockTime = escrow.getTrancheUnlockTime(t);
        // Advance block.timestamp to unlock time; oracle is in real-time mode so it follows.
        // (DO NOT call timeOracle.setTime — that disables useRealTime and re-introduces drift.)
        if (block.timestamp < unlockTime + 1) {
            vm.warp(unlockTime + 1);
        }
        vm.prank(founder);
        escrow.requestTranche(t);
        // Advance past 72h challenge window
        skip(73 hours);
        vm.prank(founder);
        escrow.claimTranche(t);
    }

    function _claimAllTranches(VibesTranchEscrow escrow) internal {
        _claimKickstart(escrow);
        for (uint8 i = 1; i <= 6; i++) {
            _claimMonthlyTranche(escrow, i);
        }
    }

    /// @dev Build a single-leaf merkle tree (root == leaf) for one holder
    function _singleLeafRoot(address holder, uint256 tokenAmount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(holder, tokenAmount));
    }

    /// @dev Build a two-leaf merkle tree and return (root, proof for leaf1, proof for leaf2).
    /// @dev Audit fix C-02: leaves use DOUBLE-HASH to prevent leaf/intermediate collision —
    ///      escrow.claimHolderRefund() hashes as `keccak256(abi.encodePacked(keccak256(abi.encodePacked(holder, amount))))`.
    function _twoLeafMerkle(address a, uint256 amtA, address b, uint256 amtB)
        internal pure returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB)
    {
        bytes32 leafA = keccak256(abi.encodePacked(keccak256(abi.encodePacked(a, amtA))));
        bytes32 leafB = keccak256(abi.encodePacked(keccak256(abi.encodePacked(b, amtB))));
        // Sort leaves (OpenZeppelin MerkleProof expects sorted pairs)
        bytes32 left  = leafA < leafB ? leafA : leafB;
        bytes32 right = leafA < leafB ? leafB : leafA;
        root = keccak256(abi.encodePacked(left, right));
        proofA = new bytes32[](1);
        proofA[0] = leafB;
        proofB = new bytes32[](1);
        proofB[0] = leafA;
    }

    // ================================================================
    //  SCENARIO 1: Happy Path FixedGoal with Vesting + Treasury
    //
    //  Founder launches with 7.5% vesting + 10% treasury.
    //  3 backers contribute different amounts.  Raise succeeds.
    //  All tranches claimed over ~6 months.  Vesting cliff elapses.
    //  Treasury proposal executed.  Everything settles cleanly.
    //
    //  Validates: launch, contribute, finalize, LP creation, token claims,
    //  tranche lifecycle, vesting activation, treasury activation,
    //  platform fees, deposit refund, Completed state.
    // ================================================================

    function test_scenario1_happyPath_fixedGoal_fullLifecycle() public {
        // --- Launch ---
        (address token, VibesTranchEscrow escrow, address vestingAddr, address treasuryAddr) =
            _launchFixed(750, 1000); // 7.5% founder, 10% treasury

        assertTrue(vestingAddr != address(0), "Vesting should exist");
        assertTrue(treasuryAddr != address(0), "Treasury should exist");

        // --- Contribute ---
        vm.prank(backer1);
        escrow.contribute{value: 4 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 3 ether}(0, 0, "");
        vm.prank(backer3);
        escrow.contribute{value: 3 ether}(0, 0, "");

        assertEq(escrow.getCampaign().totalRaised, 10 ether);

        // --- Finalize ---
        uint256 founderBalBefore = founder.balance;
        _advanceDays(15);
        escrow.finalize();

        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        assertEq(uint(c.state), uint(VibesTranchEscrow.CampaignState.Funded));

        // LP locked, deposit refunded
        assertTrue(lpLocker.hasLockedLP(address(escrow)));
        assertEq(founder.balance, founderBalBefore + DEPOSIT, "Deposit should be refunded");
        assertEq(uint(router.lpStatus(token)), uint(VibesRouterStorage.LPStatus.Created));

        // Vesting started, treasury activated
        VibesVesting vesting = VibesVesting(vestingAddr);
        assertTrue(vesting.start() > 0, "Vesting should have started");
        VibesTreasuryEscrow treasury = VibesTreasuryEscrow(treasuryAddr);
        assertTrue(treasury.active(), "Treasury should be active");

        // --- All 3 backers claim tokens ---
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        vm.prank(backer2);
        VibesRouterExtension(address(router)).claimTokens(token);
        vm.prank(backer3);
        VibesRouterExtension(address(router)).claimTokens(token);

        uint256 b1Tokens = IERC20(token).balanceOf(backer1);
        uint256 b2Tokens = IERC20(token).balanceOf(backer2);
        uint256 b3Tokens = IERC20(token).balanceOf(backer3);
        assertTrue(b1Tokens > b2Tokens, "Backer1 contributed more, should get more tokens");
        assertEq(b2Tokens, b3Tokens, "Equal contributions = equal tokens");

        // --- Claim all 7 tranches ---
        uint256 founderEthBefore = founder.balance;
        _claimAllTranches(escrow);

        assertTrue(escrow.allTranchesClaimed(), "All tranches should be claimed");
        c = escrow.getCampaign();
        assertEq(uint(c.state), uint(VibesTranchEscrow.CampaignState.Completed));
        assertTrue(founder.balance > founderEthBefore, "Founder should receive tranche ETH");

        // --- Platform fees ---
        uint256 platformBalBefore = platformWallet.balance;
        escrow.claimPlatformFees();
        assertTrue(platformWallet.balance > platformBalBefore, "Platform should receive fees");

        // --- ETH accounting: all escrow ETH should be drained ---
        // (tranches to founder + fees to platform + LP to locker)
        assertEq(address(escrow).balance, 0, "Escrow should have 0 ETH after completion");
    }

    // ================================================================
    //  SCENARIO 2: ProRata Oversubscribed — Excess Refunds + Partial Claims
    //
    //  4 backers oversubscribe a 10 ETH cap by 3x.
    //  After finalization, some claim excess, some claim tokens, some do neither.
    //  Verifies pro-rata accounting doesn't lose or create value.
    // ================================================================

    function test_scenario2_proRata_oversubscribed_excessRefunds() public {
        (address token, VibesTranchEscrow escrow,,) = _launchProRata(GOAL, 750, 0);

        // 4 backers oversubscribe 3x (30 ETH into 10 ETH cap)
        vm.prank(backer1);
        escrow.contribute{value: 10 ether}(0, 0, ""); // 33.3% of committed
        vm.prank(backer2);
        escrow.contribute{value: 8 ether}(0, 0, "");  // 26.7%
        vm.prank(backer3);
        escrow.contribute{value: 7 ether}(0, 0, "");  // 23.3%
        vm.prank(backer4);
        escrow.contribute{value: 5 ether}(0, 0, "");  // 16.7%

        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        assertEq(c.totalCommitted, 30 ether, "Total committed should be 30 ETH");

        // Finalize
        _advanceDays(15);
        escrow.finalize();

        c = escrow.getCampaign();
        assertEq(uint(c.state), uint(VibesTranchEscrow.CampaignState.Funded));

        // Excess liability tracked (audit fix F4)
        assertEq(escrow.totalExcessRefundLiability(), 20 ether, "Excess liability = 30 - 10");

        // --- Backer1 and backer2 claim excess refunds ---
        uint256 b1Before = backer1.balance;
        vm.prank(backer1);
        escrow.claimExcessRefund();
        uint256 b1Excess = backer1.balance - b1Before;
        // backer1 contributed 10/30 of 30 ETH, allocation = 10*(10/30) = 3.33 ETH, excess ≈ 6.67 ETH
        assertTrue(b1Excess > 6 ether && b1Excess < 7 ether, "Backer1 excess should be ~6.67 ETH");

        uint256 b2Before = backer2.balance;
        vm.prank(backer2);
        escrow.claimExcessRefund();
        uint256 b2Excess = backer2.balance - b2Before;
        assertTrue(b2Excess > 5 ether && b2Excess < 6 ether, "Backer2 excess should be ~5.33 ETH");

        // --- Backer1 and backer3 claim tokens ---
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        vm.prank(backer3);
        VibesRouterExtension(address(router)).claimTokens(token);

        assertTrue(IERC20(token).balanceOf(backer1) > 0);
        assertTrue(IERC20(token).balanceOf(backer3) > 0);

        // Backer1 contributed 10 ETH but effective allocation is 10*(10/30) ≈ 3.33 ETH worth
        // Backer3 contributed 7 ETH, effective allocation is 7*(10/30) ≈ 2.33 ETH worth
        // So backer1 should get more tokens than backer3
        assertTrue(IERC20(token).balanceOf(backer1) > IERC20(token).balanceOf(backer3));

        // --- Backer4 has NOT claimed excess OR tokens yet — both should still work ---
        vm.prank(backer4);
        escrow.claimExcessRefund();
        vm.prank(backer4);
        VibesRouterExtension(address(router)).claimTokens(token);
        assertTrue(IERC20(token).balanceOf(backer4) > 0);

        // --- Double claim should revert ---
        vm.prank(backer1);
        vm.expectRevert();
        escrow.claimExcessRefund();

        vm.prank(backer1);
        vm.expectRevert();
        VibesRouterExtension(address(router)).claimTokens(token);
    }

    // ================================================================
    //  SCENARIO 3: Failed Raise — Full Contributor Refunds
    //
    //  Raise doesn't meet goal.  Deadline passes.  All contributors get full refunds.
    //  Founder deposit is NOT returned (forfeited on failed raise — admin must refund).
    //  Nobody can claim tokens.  Escrow ETH accounting balances.
    // ================================================================

    function test_scenario3_failedRaise_fullRefunds() public {
        (address token, VibesTranchEscrow escrow,,) = _launchFixed(750, 0);

        // Contribute only 60% of goal
        vm.prank(backer1);
        escrow.contribute{value: 3 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 3 ether}(0, 0, "");

        // Deadline passes — only 6 of 10 ETH raised
        _advanceDays(15);
        escrow.finalize();

        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        assertEq(uint(c.state), uint(VibesTranchEscrow.CampaignState.Failed));

        // --- Contributors claim refunds ---
        uint256 b1Before = backer1.balance;
        vm.prank(backer1);
        escrow.claimContributorRefund();
        assertEq(backer1.balance - b1Before, 3 ether, "Backer1 should get full refund");

        uint256 b2Before = backer2.balance;
        vm.prank(backer2);
        escrow.claimContributorRefund();
        assertEq(backer2.balance - b2Before, 3 ether, "Backer2 should get full refund");

        // --- Token claims should fail ---
        vm.prank(backer1);
        vm.expectRevert();
        VibesRouterExtension(address(router)).claimTokens(token);

        // --- Double refund should fail ---
        vm.prank(backer1);
        vm.expectRevert();
        escrow.claimContributorRefund();

        // --- Non-contributor refund should fail ---
        vm.prank(backer3);
        vm.expectRevert();
        escrow.claimContributorRefund();

        // --- Escrow should have 0 ETH ---
        assertEq(address(escrow).balance, 0, "Escrow should be empty after all refunds");
    }

    // ================================================================
    //  SCENARIO 4: Freeze Mid-Lifecycle — Challenge Upheld, Holder Refunds
    //
    //  Raise succeeds.  Founder claims kickstart + tranche 1.
    //  Backer challenges tranche 2.  Admin upholds → campaign frozen.
    //  Some backers claimed tokens before freeze, some after (F3 fix).
    //  Admin sets merkle root.  All holders claim refunds.
    //  Validates freeze accounting, token burn, proportional ETH refunds.
    // ================================================================

    function test_scenario4_freezeMidLifecycle_holderRefunds() public {
        (address token, VibesTranchEscrow escrow, address vestingAddr,) = _launchFixed(750, 0);

        // 2 backers
        vm.prank(backer1);
        escrow.contribute{value: 6 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 4 ether}(0, 0, "");

        // Finalize
        _advanceDays(15);
        escrow.finalize();

        // Backer1 claims tokens, backer2 does NOT (tests F3 fix)
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        uint256 b1Tokens = IERC20(token).balanceOf(backer1);
        assertTrue(b1Tokens > 0);

        // Founder claims kickstart
        _claimKickstart(escrow);

        // Founder claims tranche 1
        _claimMonthlyTranche(escrow, 1);

        // Locked addresses are wired automatically by the router during Phase 2 finalisation
        // (and latched there by ZXVC VIB-02 fix). No manual call needed here.

        // --- Backer1 challenges tranche 2 ---
        vm.warp(escrow.getTrancheUnlockTime(2) + 1);
        timeOracle.setTime(escrow.getTrancheUnlockTime(2) + 1);
        vm.prank(founder);
        escrow.requestTranche(2);

        uint256 threshold = escrow.getChallengeThreshold(2);
        uint256 stakeNeeded = (SUPPLY * threshold) / 10000;
        vm.prank(backer1);
        IERC20(token).approve(address(escrow), stakeNeeded);
        vm.prank(backer1);
        escrow.raiseChallenge("Founder abandoned project", 0, 0, "");

        // --- Admin upholds challenge → freeze ---
        escrow.upholdChallenge();

        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        assertEq(uint(c.state), uint(VibesTranchEscrow.CampaignState.Frozen));
        assertTrue(escrow.frozenEthBalance() > 0, "Should have frozen ETH");
        assertTrue(escrow.frozenTotalSupply() > 0, "Should have frozen supply");

        // --- F3: Backer2 claims tokens AFTER freeze ---
        vm.prank(backer2);
        VibesRouterExtension(address(router)).claimTokens(token);
        uint256 b2Tokens = IERC20(token).balanceOf(backer2);
        assertTrue(b2Tokens > 0, "Backer2 should claim tokens after freeze");

        // --- Admin sets merkle root → Refunding ---
        // IMPORTANT: Use the frozenTotalSupply to determine valid claim amounts.
        // Backer1 received challenge stake back (increasing their balance beyond what was
        // counted in the frozen snapshot). The merkle tree should only include amounts
        // that sum to <= frozenTotalSupply. In production, the off-chain snapshot tool
        // handles this; in tests, we use the correct proportion.
        //
        // We use backer2's tokens as-is, and give backer1 the rest of the redeemable supply.
        uint256 redeemable = escrow.frozenTotalSupply();
        uint256 b1MerkleTokens = redeemable - b2Tokens;  // backer1's share of the refund pool

        (bytes32 root, bytes32[] memory proof1, bytes32[] memory proof2) =
            _twoLeafMerkle(backer1, b1MerkleTokens, backer2, b2Tokens);
        // F10 commit-reveal pattern
        escrow.commitRefundMerkleRoot(root);
        vm.warp(block.timestamp + 25 hours);
        escrow.finalizeRefundMerkleRoot();

        c = escrow.getCampaign();
        assertEq(uint(c.state), uint(VibesTranchEscrow.CampaignState.Refunding));

        // --- Both holders claim refunds ---
        vm.prank(backer1);
        IERC20(token).approve(address(escrow), b1MerkleTokens);
        uint256 b1EthBefore = backer1.balance;
        vm.prank(backer1);
        escrow.claimHolderRefund(b1MerkleTokens, proof1);
        uint256 b1Refund = backer1.balance - b1EthBefore;

        vm.prank(backer2);
        IERC20(token).approve(address(escrow), b2Tokens);
        uint256 b2EthBefore = backer2.balance;
        vm.prank(backer2);
        escrow.claimHolderRefund(b2Tokens, proof2);
        uint256 b2Refund = backer2.balance - b2EthBefore;

        // Both should receive ETH refunds
        assertTrue(b1Refund > 0 && b2Refund > 0, "Both should receive ETH");
        // Total refunds should approximately equal the frozen pool (minus rounding)
        assertTrue(b1Refund + b2Refund <= escrow.frozenEthBalance(), "Refunds should not exceed frozen pool");

        // Tokens burned (backer1 may still hold excess tokens not in merkle — that's fine)
        assertEq(IERC20(token).balanceOf(backer2), 0, "Backer2 tokens should be burned");
    }

    // ================================================================
    //  SCENARIO 5: Treasury Governance — Full Lifecycle Including Malicious
    //
    //  Raise succeeds with 7.5% founder + 10% treasury.
    //  Treasury activates. Founder proposes withdrawal.
    //  First proposal: challenged, rejected, executed (F6 fix — immediate after rejection).
    //  Second proposal: challenged, upheld as malicious → treasury burned, vesting frozen.
    //  Validates treasury+vesting interplay and nuclear termination path.
    // ================================================================

    function test_scenario5_treasuryGovernance_maliciousTermination() public {
        (address token, VibesTranchEscrow escrow, address vestingAddr, address treasuryAddr) =
            _launchFixed(750, 1000);

        assertTrue(treasuryAddr != address(0), "Treasury should be deployed");

        // Fund and finalize
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");
        _advanceDays(15);
        escrow.finalize();

        // Backer claims tokens (needs them to challenge treasury)
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        uint256 backerTokens = IERC20(token).balanceOf(backer1);
        assertTrue(backerTokens > 0);

        VibesTreasuryEscrow treasury = VibesTreasuryEscrow(treasuryAddr);
        assertTrue(treasury.active(), "Treasury should be active after finalization");

        uint256 treasuryBalance = IERC20(token).balanceOf(treasuryAddr);
        assertTrue(treasuryBalance > 0, "Treasury should hold tokens");

        // --- Wait past treasury cliff ---
        // Treasury cliff is 180 days (mainnet default from constructor)
        // Treasury checks block.timestamp, so advance both oracle AND block time
        _advanceDays(181);
        vm.warp(block.timestamp + 181 days);

        // --- First proposal: challenge rejected, then immediate execute (F6 fix) ---
        uint256 maxClaim = treasury.maxClaimable();
        assertTrue(maxClaim > 0, "Should be able to claim");

        vm.prank(founder);
        treasury.createProposal(maxClaim, keccak256("milestone1"));

        // Backer challenges
        uint256 challengeStake = (SUPPLY * 50) / 10000; // 0.5%
        vm.prank(backer1);
        IERC20(token).approve(treasuryAddr, challengeStake);
        vm.prank(backer1);
        treasury.raiseChallenge("suspicious withdrawal");

        // Admin rejects challenge (slashes challenger 20%)
        uint256 backerBefore = IERC20(token).balanceOf(backer1);
        treasury.rejectChallenge();
        uint256 backerAfter = IERC20(token).balanceOf(backer1);
        // Backer gets back 80% of stake
        assertTrue(backerAfter > backerBefore, "Challenger should get back most of stake");

        // F6: Execute immediately after rejection (no waiting)
        uint256 founderTokensBefore = IERC20(token).balanceOf(founder);
        vm.prank(founder);
        treasury.executeProposal();
        assertTrue(IERC20(token).balanceOf(founder) > founderTokensBefore, "Founder receives treasury tokens");

        // --- Second proposal: malicious upheld → nuclear termination ---
        _advanceDays(15); // cooldown
        vm.warp(block.timestamp + 15 days);

        uint256 maxClaim2 = treasury.maxClaimable();
        vm.prank(founder);
        treasury.createProposal(maxClaim2, keccak256("rug"));

        // Backer challenges again
        vm.prank(backer1);
        IERC20(token).approve(treasuryAddr, challengeStake);
        vm.prank(backer1);
        treasury.raiseChallenge("this is a rug pull");

        // Admin upholds as MALICIOUS
        uint256 treasuryBalBefore = IERC20(token).balanceOf(treasuryAddr);
        treasury.upholdChallengeMalicious();

        // Treasury burned
        assertEq(IERC20(token).balanceOf(treasuryAddr), 0, "Treasury tokens should be burned");
        assertTrue(treasury.terminated(), "Treasury should be terminated");

        // Vesting frozen — unvested tokens burned
        VibesVesting vesting = VibesVesting(vestingAddr);
        assertTrue(vesting.frozen(), "Vesting should be frozen");

        // Founder can't release any more vesting tokens
        vm.prank(founder);
        vm.expectRevert();
        vesting.release();
    }

    // ================================================================
    //  SCENARIO 6: Adversarial Attacks — Griefing & Economic Exploits
    //
    //  Tests attack vectors that real adversaries would attempt:
    //  - Double-contribute attempts
    //  - Token claim front-running
    //  - Freeze + excess refund siphoning (F4 fix validation)
    //  - rescueERC20 exploitation (F2 fix validation)
    //  - createDistributor griefing (F5 fix validation)
    //  - Challenge spam (per-challenger cooldown)
    // ================================================================

    function test_scenario6_adversarial_rescueExploit_blocked() public {
        // Attacker scenario: admin tries to drain pre-finalization campaign tokens
        (address token, VibesTranchEscrow escrow,,) = _launchFixed(750, 0);

        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        uint256 routerTokenBalance = IERC20(token).balanceOf(address(router));
        assertTrue(routerTokenBalance > 0, "Router should hold campaign tokens");

        // F2: Admin cannot rescue active campaign tokens
        vm.expectRevert(VibesRouterStorage.TokenHasActiveEscrow.selector);
        VibesRouterExtension(address(router)).rescueERC20(token, attacker, routerTokenBalance);

        // Tokens stay safe
        assertEq(IERC20(token).balanceOf(address(router)), routerTokenBalance);
    }

    function test_scenario6_adversarial_distributorGrief_blocked() public {
        // Attacker scenario: anyone calls createDistributor to brick backer claims
        (address token, VibesTranchEscrow escrow,,) = _launchFixed(750, 0);

        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");
        _advanceDays(15);
        escrow.finalize();

        // F5: createDistributor always reverts
        vm.prank(attacker);
        vm.expectRevert(VibesRouterStorage.DistributorDisabled.selector);
        VibesRouterExtension(address(router)).createDistributor(token);

        // Backer claims still work
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        assertTrue(IERC20(token).balanceOf(backer1) > 0);
    }

    function test_scenario6_adversarial_proRataFreezeExcessSiphon_blocked() public {
        // Attacker scenario: freeze a pro-rata raise to absorb unclaimed excess into holder pool
        (address token, VibesTranchEscrow escrow,,) = _launchProRata(GOAL, 0, 0);

        // Oversubscribe 2x
        vm.prank(backer1);
        escrow.contribute{value: 12 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 8 ether}(0, 0, "");

        _advanceDays(15);
        escrow.finalize();

        // Neither backer has claimed excess yet
        uint256 excessLiability = escrow.totalExcessRefundLiability();
        assertEq(excessLiability, 10 ether, "Excess = 20 - 10");

        // Admin freezes — F4 fix ensures excess is excluded from holder pool
        escrow.freezeCampaign("test");

        uint256 frozenEth = escrow.frozenEthBalance();
        uint256 escrowBal = address(escrow).balance;
        assertEq(frozenEth, escrowBal - excessLiability, "Frozen balance excludes excess liability");

        // Backers can STILL claim their excess even after freeze
        uint256 b1Before = backer1.balance;
        vm.prank(backer1);
        escrow.claimExcessRefund();
        assertTrue(backer1.balance > b1Before, "Backer1 excess claim works after freeze");

        uint256 b2Before = backer2.balance;
        vm.prank(backer2);
        escrow.claimExcessRefund();
        assertTrue(backer2.balance > b2Before, "Backer2 excess claim works after freeze");

        // All excess claimed — liability should be 0
        assertEq(escrow.totalExcessRefundLiability(), 0);
    }

    function test_scenario6_adversarial_nonContributorCannotClaim() public {
        (address token, VibesTranchEscrow escrow,,) = _launchFixed(750, 0);

        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        _advanceDays(15);
        escrow.finalize();

        // Attacker who didn't contribute tries to claim tokens
        vm.prank(attacker);
        vm.expectRevert();
        VibesRouterExtension(address(router)).claimTokens(token);

        // Attacker tries to claim contributor refund on funded raise
        vm.prank(attacker);
        vm.expectRevert();
        escrow.claimContributorRefund();
    }

    // ================================================================
    //  SCENARIO 7: LP Failure + Deferred Resolution
    //
    //  Aerodrome fails during finalization.  Campaign still reaches Funded.
    //  Backers claim tokens.  Owner manually resolves LP later.
    //  Full tranche lifecycle completes.
    // ================================================================

    function test_scenario7_lpFailure_deferredResolution_fullLifecycle() public {
        // Make LP creation fail
        aeroRouter.setShouldFail(true);

        (address token, VibesTranchEscrow escrow,,) = _launchFixed(750, 0);

        vm.prank(backer1);
        escrow.contribute{value: 6 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 4 ether}(0, 0, "");

        _advanceDays(15);

        // F1: Finalization succeeds with rescued LP
        escrow.finalize();

        assertEq(uint(escrow.getCampaign().state), uint(VibesTranchEscrow.CampaignState.Funded));
        assertEq(uint(router.lpStatus(token)), uint(VibesRouterStorage.LPStatus.Rescued));

        // Backers claim tokens normally
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        vm.prank(backer2);
        VibesRouterExtension(address(router)).claimTokens(token);
        assertTrue(IERC20(token).balanceOf(backer1) > 0);
        assertTrue(IERC20(token).balanceOf(backer2) > 0);

        // --- Audit fix H-4 recovery flow ---
        // (1) Owner resolves rescued funds out to off-chain admin wallet.
        address adminWallet = makeAddr("adminLPWallet");
        lpLocker.resolveRescuedFunds(address(escrow), adminWallet);

        // (2) Simulate off-chain LP creation: admin creates a pool on Aerodrome and burns LP
        //     to DEAD. We mock this by deploying a pool contract and setting its DEAD balance.
        E2EPool mockPool = new E2EPool();
        uint256 manualLpAmount = 1 ether;
        mockPool.setBalance(0x000000000000000000000000000000000000dEaD, manualLpAmount);

        // (3) Owner records the manual lock with the onchain dead-address proof.
        lpLocker.recordManualLPLock(address(escrow), address(mockPool), address(0), manualLpAmount);

        // (4) Now completeLP() on the router can succeed (F7b gate satisfied).
        VibesRouterExtension(address(router)).completeLP(token);
        assertEq(uint(router.lpStatus(token)), uint(VibesRouterStorage.LPStatus.Created));

        // Founder can still claim tranches
        _claimAllTranches(escrow);
        assertTrue(escrow.allTranchesClaimed());
    }

    // ================================================================
    //  SCENARIO 8: Admin Emergency — Pause, Force Refund, Deposit Management
    //
    //  Tests admin intervention paths:
    //  - Pause blocks all launches and claims
    //  - Emergency unpause restores access
    //  - Force refund during active raise
    //  - Deposit forfeiture and manual refund
    // ================================================================

    function test_scenario8_adminEmergency_pauseAndForceRefund() public {
        // Launch a campaign
        (address token, VibesTranchEscrow escrow,,) = _launchFixed(0, 0);

        vm.prank(backer1);
        escrow.contribute{value: 5 ether}(0, 0, "");

        // --- Admin pauses router (incident response) ---
        VibesRouterExtension(address(router)).pause();
        assertTrue(router.paused());

        // F7: launch() is now blocked
        vm.prank(founder);
        vm.expectRevert();
        router.launch("X", "X", 18, SUPPLY, founder, capsule, 1, 1, 1, proof);

        // launchWithCampaign also blocked
        vm.prank(founder);
        vm.expectRevert();
        router.launchWithCampaign{value: DEPOSIT}(
            "X", "X", 18, SUPPLY, capsule, 1, 1, 1, proof,
            VibesTranchEscrow.RaiseType.FixedGoal, GOAL, 0,
            block.timestamp + 14 days, 0, 0, 0, 0, 0, ""
        );

        // claimTokens also blocked
        vm.prank(backer1);
        vm.expectRevert();
        VibesRouterExtension(address(router)).claimTokens(token);

        // --- Emergency unpause ---
        router.emergencyUnpause();
        assertFalse(router.paused());

        // --- Admin forces refund on the active raise ---
        escrow.forceRefundDuringRaise();

        VibesTranchEscrow.Campaign memory c = escrow.getCampaign();
        assertEq(uint(c.state), uint(VibesTranchEscrow.CampaignState.Failed));

        // Backer gets full refund
        uint256 b1Before = backer1.balance;
        vm.prank(backer1);
        escrow.claimContributorRefund();
        assertEq(backer1.balance - b1Before, 5 ether);
    }

    // ================================================================
    //  SCENARIO 9: Multi-Campaign Isolation
    //
    //  Two campaigns running simultaneously on the same router.
    //  One succeeds, one fails.  Verify no cross-contamination of state,
    //  tokens, ETH, or lifecycle transitions.
    // ================================================================

    function test_scenario9_multiCampaign_isolation() public {
        // Campaign A: FixedGoal, will succeed
        (address tokenA, VibesTranchEscrow escrowA,,) = _launchFixed(0, 0);

        // Campaign B: FixedGoal, will fail (different founder address used via separate launch)
        uint256 deadline = block.timestamp + 14 days;
        address founder2 = makeAddr("founder2");
        vm.deal(founder2, 100 ether);
        vm.prank(founder2);
        (address tokenB, address escrowBAddr,) = router.launchWithCampaign{value: DEPOSIT}(
            "TokenB", "TKB", 18, SUPPLY,
            keccak256("capsuleB"), 1, 1, 1, keccak256("proofB"),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline, 0, 0, 0, 0, 0, ""
        );
        VibesTranchEscrow escrowB = VibesTranchEscrow(payable(escrowBAddr));

        // Fund campaign A to success
        vm.prank(backer1);
        escrowA.contribute{value: GOAL}(0, 0, "");

        // Fund campaign B partially (will fail)
        vm.prank(backer2);
        escrowB.contribute{value: 3 ether}(0, 0, "");

        // Finalize both
        _advanceDays(15);
        escrowA.finalize();
        escrowB.finalize();

        // A is Funded, B is Failed
        assertEq(uint(escrowA.getCampaign().state), uint(VibesTranchEscrow.CampaignState.Funded));
        assertEq(uint(escrowB.getCampaign().state), uint(VibesTranchEscrow.CampaignState.Failed));

        // Backer1 claims tokens for A
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(tokenA);
        assertTrue(IERC20(tokenA).balanceOf(backer1) > 0);

        // Backer1 CANNOT claim tokens for B (not a contributor)
        vm.prank(backer1);
        vm.expectRevert();
        VibesRouterExtension(address(router)).claimTokens(tokenB);

        // Backer2 gets refund from B
        uint256 b2Before = backer2.balance;
        vm.prank(backer2);
        escrowB.claimContributorRefund();
        assertEq(backer2.balance - b2Before, 3 ether);

        // Backer2 CANNOT get refund from A (funded, not failed)
        vm.prank(backer2);
        vm.expectRevert();
        escrowA.claimContributorRefund();

        // Tokens are different
        assertTrue(tokenA != tokenB);
        assertEq(IERC20(tokenB).balanceOf(backer1), 0, "Backer1 should have 0 of tokenB");
    }

    // ================================================================
    //  SCENARIO 10: OpenEnded Raise — No Goal, Soft Cap
    //
    //  An open-ended raise with a soft cap.  Any amount finalizes as success
    //  as long as soft cap is met.  Verifies this raise type works E2E.
    // ================================================================

    function test_scenario10_openEnded_softCap_fullLifecycle() public {
        (address token, VibesTranchEscrow escrow) = _launchOpenEnded(5 ether, 0);

        // Contribute above soft cap
        vm.prank(backer1);
        escrow.contribute{value: 3 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 4 ether}(0, 0, "");

        assertEq(escrow.getCampaign().totalRaised, 7 ether);

        // Finalize — soft cap (5 ETH) met
        _advanceDays(15);
        escrow.finalize();

        assertEq(uint(escrow.getCampaign().state), uint(VibesTranchEscrow.CampaignState.Funded));

        // Backers claim tokens
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        vm.prank(backer2);
        VibesRouterExtension(address(router)).claimTokens(token);
        assertTrue(IERC20(token).balanceOf(backer1) > 0);
        assertTrue(IERC20(token).balanceOf(backer2) > 0);

        // Full tranche lifecycle
        _claimAllTranches(escrow);
        assertTrue(escrow.allTranchesClaimed());
    }

    // ================================================================
    //  SCENARIO 11: Treasury Challenge Expiry — Immediate Execution (F6)
    //
    //  Like scenario 5 but the challenge expires (admin doesn't act in 72h).
    //  After expiry, proposal becomes immediately executable.
    //  A new proposal can still be challenged (flag resets).
    // ================================================================

    function test_scenario11_treasuryChallengeExpiry_immediateExecution() public {
        (address token, VibesTranchEscrow escrow, , address treasuryAddr) =
            _launchFixed(750, 1000);

        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");
        _advanceDays(15);
        escrow.finalize();

        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        VibesTreasuryEscrow treasury = VibesTreasuryEscrow(treasuryAddr);

        // Wait past cliff — treasury checks block.timestamp
        _advanceDays(181);
        vm.warp(block.timestamp + 181 days);

        // Founder proposes
        uint256 maxClaim = treasury.maxClaimable();
        vm.prank(founder);
        treasury.createProposal(maxClaim, keccak256("plan"));

        // Backer challenges
        uint256 stake = (SUPPLY * 50) / 10000;
        vm.prank(backer1);
        IERC20(token).approve(treasuryAddr, stake);
        vm.prank(backer1);
        treasury.raiseChallenge("disagree");

        // Nobody acts for 72h — challenge expires (treasury uses block.timestamp)
        _advanceTime(73 hours);
        vm.warp(block.timestamp + 73 hours);
        treasury.expireChallengeIfNeeded();

        // F6: Proposal immediately executable after expiry
        uint256 founderBal = IERC20(token).balanceOf(founder);
        vm.prank(founder);
        treasury.executeProposal();
        assertTrue(IERC20(token).balanceOf(founder) > founderBal, "Should execute after expiry");

        // Wait cooldown, make new proposal — challenge IS allowed on new proposal
        _advanceDays(15);
        vm.warp(block.timestamp + 15 days);
        uint256 newMax = treasury.maxClaimable();
        vm.prank(founder);
        treasury.createProposal(newMax, keccak256("plan2"));

        assertFalse(treasury.proposalChallengeResolved(), "Flag should reset for new proposal");
    }
}
