// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockTimeOracle} from "../../src/MockTimeOracle.sol";
import {VibesCommunityRewards} from "../../src/VibesCommunityRewards.sol";
import {VibesStakerRewards} from "../../src/VibesStakerRewards.sol";
import {VibesStaking} from "../../src/VibesStaking.sol";
import {VibesToken} from "../../src/VibesToken.sol";
import {VibesTranchEscrow} from "../../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../../src/VibesTranchEscrowFactory.sol";

contract EconomicMockRouter {
    function completeFinalization(address) external {
        VibesTranchEscrow(payable(msg.sender)).setLPCreated();
    }

    function completeDistribution(address) external {}

    function finalizationPhase(address) external pure returns (uint8) {
        return 0;
    }

    receive() external payable {}
}

contract EconomicMechanicsAuditTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TOKEN_SUPPLY = 1_000_000 ether;

    address internal admin = makeAddr("admin");
    address internal platformWallet = makeAddr("platformWallet");
    address internal founder = makeAddr("founder");
    address internal backer1 = makeAddr("backer1");
    address internal backer2 = makeAddr("backer2");
    address internal backer3 = makeAddr("backer3");
    address internal challenger1 = makeAddr("challenger1");
    address internal challenger2 = makeAddr("challenger2");
    address internal alice = makeAddr("alice");
    address internal staker = makeAddr("staker");
    address internal sameBlockStaker = makeAddr("sameBlockStaker");

    MockTimeOracle internal timeOracle;
    EconomicMockRouter internal router;
    VibesTranchEscrowFactory internal factory;

    function setUp() public {
        vm.prank(admin);
        timeOracle = new MockTimeOracle();
        vm.prank(admin);
        timeOracle.setRealTimeMode(true);

        router = new EconomicMockRouter();
        VibesTranchEscrow implementation = new VibesTranchEscrow();
        factory = new VibesTranchEscrowFactory(
            address(implementation),
            admin,
            platformWallet,
            address(timeOracle),
            address(router),
            makeAddr("lpLocker"),
            address(0)
        );

        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);
        vm.deal(backer3, 100 ether);
    }

    function test_AUDIT_LPPriceCanOpenBelowBackerPurchasePrice() public pure {
        uint256 totalSupply = 1_000_000_000 ether;
        uint256 raised = 100 ether;

        uint256 founderBps = 500;
        uint256 treasuryBps = 1_500;
        uint256 communityBps = 1_500;
        uint256 stakerBps = 0;
        uint256 lpBps = 1_500;
        uint256 backerBps = BPS - founderBps - treasuryBps - communityBps - stakerBps - lpBps;

        assertEq(backerBps, 5_000, "scenario uses the minimum backer floor");

        uint256 backerTokens = (totalSupply * backerBps) / BPS;
        uint256 lpTokens = (totalSupply * lpBps) / BPS;
        uint256 lpEth = (raised * lpBps) / BPS;

        uint256 backerPurchasePrice = (raised * 1e18) / backerTokens;
        uint256 lpOpeningPrice = (lpEth * 1e18) / lpTokens;

        assertEq(lpOpeningPrice * 2, backerPurchasePrice, "LP opens at half the backer price");
    }

    /// @notice ZXVC VIB-10 (2026-05) regression — community batch claim respects totalAmount.
    /// @dev Pre-fix this PoC asserted the BUG: a merkle leaf whose amount exceeded the
    ///      declared batch totalAmount succeeded — over-claiming the batch and breaking
    ///      the accounting invariant. After fix, claim reverts with "Exceeds batch total".
    function test_VIB10_communityRewardsClaimRespectsDeclaredBatchTotal() public {
        VibesToken token = new VibesToken("Community", "COMM", 18, 1_000 ether, address(this));
        VibesCommunityRewards rewards =
            new VibesCommunityRewards(IERC20(address(token)), block.timestamp, admin);
        token.transfer(address(rewards), 200 ether);

        bytes32 root = _communityLeaf(alice, 150 ether);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(admin);
        rewards.createBatch(root, 100 ether, 30 days, keccak256("overcommitted batch"));

        // ZXVC VIB-10 fix: 150 > 100 totalAmount → revert.
        vm.expectRevert(bytes("Exceeds batch total"));
        rewards.claim(0, alice, 150 ether, emptyProof);

        // Sanity: nothing claimed, nothing leaked.
        (, uint256 totalAmount, uint256 claimedAmount,,,,) = rewards.batches(0);
        assertEq(totalAmount, 100 ether);
        assertEq(claimedAmount, 0, "claim must not advance accounting on revert");
        assertEq(token.balanceOf(alice), 0, "no tokens leaked to recipient");
    }

    /// @notice ZXVC VIB-06 (2026-05) regression — same-block stakers cleanly excluded.
    /// @dev Pre-fix this PoC asserted the BUG: a staker who staked in the same block as
    ///      notifyReward was counted in totalStakedSnapshot (diluting pre-existing stakers)
    ///      yet locked out by the firstStakeTime gate (couldn't claim) — 90% of the reward
    ///      stranded. VIB-04 removed the firstStakeTime gate; the staker became claimable
    ///      but still diluted. VIB-06 closes the loop in two parts:
    ///        (a) VibesStaking subtracts same-block new-stake amounts from
    ///            snapshotTotalStaked at takeSnapshot time, so the denominator no longer
    ///            includes them;
    ///        (b) VibesStakerRewards reads everFirstStakeTime (which never resets on full
    ///            unstake) and excludes stakers whose ever-first-stake landed at or after
    ///            the snapshot timestamp.
    ///      Result: pre-existing staker takes 100% of their share against the eligible-only
    ///      denominator, same-block staker reverts NoStakeAtSnapshot, no dilution.
    function test_VIB06_sameBlockStakerExcludedFromBothEligibilityAndDenominator() public {
        VibesToken stakeToken = new VibesToken("Vibes", "VIBES", 18, 10_000 ether, address(this));
        VibesToken rewardToken = new VibesToken("Reward", "RWD", 18, 10_000 ether, address(this));

        VibesStaking staking = new VibesStaking(address(stakeToken), address(0));
        VibesStakerRewards rewards =
            new VibesStakerRewards(address(this), address(staking), address(this));
        staking.setSnapshotAuthorized(address(rewards), true);

        stakeToken.transfer(staker, 100 ether);
        stakeToken.transfer(sameBlockStaker, 900 ether);

        // Pre-existing staker stakes at t=100.
        vm.warp(100);
        vm.startPrank(staker);
        stakeToken.approve(address(staking), 100 ether);
        staking.stake(100 ether, 0, 0, "");
        vm.stopPrank();

        // sameBlockStaker stakes at t=200 — same block as notifyReward below.
        vm.warp(200);
        vm.startPrank(sameBlockStaker);
        stakeToken.approve(address(staking), 900 ether);
        staking.stake(900 ether, 0, 0, "");
        vm.stopPrank();

        address escrow = makeAddr("rewardedEscrow");
        rewardToken.transfer(address(rewards), 1_000 ether);
        rewards.notifyReward(address(rewardToken), 1_000 ether, escrow);

        // VIB-06 part (a): snapshot total excludes sameBlockStaker's 900 ether — only the
        // pre-existing 100 ether is in the eligible denominator.
        uint256 snapId = rewards.raiseSnapshotId(escrow);
        assertEq(staking.snapshotTotalStaked(snapId), 100 ether, "eligible total excludes same-block stake");
        assertEq(staking.snapshotTimestamps(snapId), 200, "snapshot timestamp recorded");

        // Pre-existing staker takes 100% of the reward (no dilution).
        vm.prank(staker);
        rewards.claim(escrow);
        assertEq(rewardToken.balanceOf(staker), 1_000 ether, "pre-existing staker receives full reward");

        // VIB-06 part (b): same-block staker is rejected at the eligibility check.
        vm.prank(sameBlockStaker);
        vm.expectRevert(VibesStakerRewards.NoStakeAtSnapshot.selector);
        rewards.claim(escrow);

        // Nothing stranded.
        assertEq(rewardToken.balanceOf(address(rewards)), 0, "reward fully distributed, no dilution residue");
    }

    /// @notice ZXVC VIB-08 (2026-05) regression — rejected challenge releases the per-tranche slot.
    /// @dev Pre-fix this PoC asserted the BUG: a collusive first challenger could lock a
    ///      tranche's only challenge slot by raising a weak challenge that admin rejected —
    ///      the trancheChallenged flag stayed true, so a legitimate second challenger was
    ///      permanently blocked. After fix, rejectChallenge clears the flag so a fresh
    ///      challenge can be raised on the same tranche (still gated by the per-challenger
    ///      CHALLENGE_COOLDOWN, which prevents the same challenger from re-attacking).
    function test_VIB08_collusiveChallengeDoesNotConsumeSlotAfterReject() public {
        VibesToken token = _newToken("Challenge", "CHAL");
        VibesTranchEscrow escrow = _createEscrow(
            token,
            VibesTranchEscrow.RaiseType.FixedGoal,
            1 ether,
            0,
            block.timestamp + 7 days
        );

        vm.prank(backer1);
        escrow.contribute{value: 1 ether}(0, 0, "");
        escrow.finalize();

        vm.prank(founder);
        escrow.claimTranche(0);

        uint256 required = (token.totalSupply() * 25) / BPS;
        token.transfer(challenger1, required);
        token.transfer(challenger2, required);

        vm.warp(escrow.getTrancheUnlockTime(1));
        vm.prank(founder);
        escrow.requestTranche(1);

        vm.startPrank(challenger1);
        token.approve(address(escrow), required);
        escrow.raiseChallenge("weak challenge", 0, 0, "");
        vm.stopPrank();

        vm.prank(admin);
        escrow.rejectChallenge();

        // ZXVC VIB-08: the per-tranche slot is released on reject.
        assertFalse(escrow.trancheChallenged(1), "tranche slot must be released after reject");

        // The founder's original requestTranche is still in flight; the 72h challenge window
        // is still open, so the second challenger can raise a fresh challenge on the same
        // tranche without the founder needing to re-request.
        vm.startPrank(challenger2);
        token.approve(address(escrow), required);
        escrow.raiseChallenge("substantive later challenge succeeds", 0, 0, "");
        vm.stopPrank();

        assertTrue(escrow.trancheChallenged(1), "second challenge re-marks the slot");
    }

    /// @notice ZXVC Extra-1 (2026-05) regression — pro-rata rounding doesn't brick fee claim.
    /// @dev Pre-fix this PoC asserted the BUG: pro-rata per-account refund floors over-paid
    ///      the aggregate liability by 2 wei, leaving address(this).balance 2 wei below
    ///      pendingPlatformFees; the unconditional `transfer(pendingPlatformFees)` then
    ///      reverted "Fee transfer failed", stranding the fees permanently. After fix,
    ///      claimPlatformFees caps the transfer at address(this).balance and zeros out
    ///      pendingPlatformFees regardless — the platform wallet receives what's actually
    ///      in the contract, and no residue is stuck.
    function test_Extra1_proRataRoundingDoesNotBrickPlatformFees() public {
        VibesToken token = _newToken("Prorata", "PRO");
        VibesTranchEscrow escrow = _createEscrow(
            token,
            VibesTranchEscrow.RaiseType.ProRata,
            2 ether,
            0,
            block.timestamp + 7 days
        );

        _contribute(escrow, backer1, 1 ether);
        _contribute(escrow, backer2, 1 ether);
        _contribute(escrow, backer3, 1 ether);

        vm.warp(block.timestamp + 8 days);
        escrow.finalize();

        _claimExcess(escrow, backer1);
        _claimExcess(escrow, backer2);
        _claimExcess(escrow, backer3);

        _claimAllTranches(escrow);

        // The pro-rata rounding still leaves pendingPlatformFees slightly above balance.
        uint256 pendingBefore = escrow.pendingPlatformFees();
        uint256 balBefore = address(escrow).balance;
        assertEq(pendingBefore, 42_500_000_000_000_000);
        assertEq(
            balBefore,
            42_499_999_999_999_998,
            "per-account pro-rata floors over-refunded aggregate liability by 2 wei"
        );
        assertGt(pendingBefore, balBefore, "precondition: pending > balance");

        // ZXVC Extra-1 fix: claim no longer reverts; the cap pays out address(this).balance.
        address platformWallet = escrow.platformWallet();
        uint256 walletBefore = platformWallet.balance;
        escrow.claimPlatformFees();
        assertEq(escrow.pendingPlatformFees(), 0, "pending zeroed regardless of cap");
        assertEq(address(escrow).balance, 0, "all available balance paid to platform wallet");
        assertEq(platformWallet.balance - walletBefore, balBefore, "platform wallet received the capped amount");
    }

    function _newToken(string memory name, string memory symbol) internal returns (VibesToken) {
        return new VibesToken(name, symbol, 18, TOKEN_SUPPLY, address(this));
    }

    function _createEscrow(
        VibesToken token,
        VibesTranchEscrow.RaiseType raiseType,
        uint256 goal,
        uint256 softCap,
        uint256 deadline
    ) internal returns (VibesTranchEscrow) {
        vm.prank(address(router));
        address escrowAddr = factory.createEscrow(
            founder,
            address(token),
            raiseType,
            goal,
            softCap,
            deadline,
            0
        );
        return VibesTranchEscrow(payable(escrowAddr));
    }

    function _contribute(VibesTranchEscrow escrow, address backer, uint256 amount) internal {
        vm.prank(backer);
        escrow.contribute{value: amount}(0, 0, "");
    }

    function _claimExcess(VibesTranchEscrow escrow, address backer) internal {
        vm.prank(backer);
        escrow.claimExcessRefund();
    }

    function _claimAllTranches(VibesTranchEscrow escrow) internal {
        vm.prank(founder);
        escrow.claimTranche(0);

        for (uint8 tranche = 1; tranche <= 6; tranche++) {
            vm.warp(escrow.getTrancheUnlockTime(tranche));
            vm.prank(founder);
            escrow.requestTranche(tranche);
            vm.warp(block.timestamp + 73 hours);
            vm.prank(founder);
            escrow.claimTranche(tranche);
        }
    }

    function _communityLeaf(address recipient, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(abi.encodePacked(recipient, amount))));
    }
}
