// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VibesLaunchRouterV2} from "../src/VibesLaunchRouterV2.sol";
import {VibesRouterExtension} from "../src/VibesRouterExtension.sol";
import {VibesRegistry} from "../src/VibesRegistry.sol";
import {VibesStakerRewards} from "../src/VibesStakerRewards.sol";
import {VibesStaking} from "../src/VibesStaking.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {VibesTokenFactory} from "../src/VibesTokenFactory.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesLPLocker} from "../src/VibesLPLocker.sol";

contract Specialist3MockRouter {
    function completeFinalization(address) external {
        VibesTranchEscrow(payable(msg.sender)).setLPCreated();
    }

    function completeDistribution(address) external {}

    function finalizationPhase(address) external pure returns (uint8) {
        return 0;
    }

    receive() external payable {}
}

contract RejectingFeeRecipient {
    receive() external payable {
        revert("reject fee");
    }
}

contract Specialist3ManualAuditTest is Test {
    address internal founder = makeAddr("founder");
    address internal backer = makeAddr("backer");
    address internal platformWallet = makeAddr("platformWallet");
    address internal lpLocker = makeAddr("lpLocker");
    address internal maliciousAdmin = makeAddr("maliciousAdmin");

    uint256 internal constant GOAL = 10 ether;
    uint256 internal constant TOKEN_SUPPLY = 1_000 ether;

    /// @notice ZXVC VIB-04 (2026-05) regression — historical stakers can still claim after unstake.
    /// @dev Originally PoC test_POC_fullUnstakeMakesHistoricalStakerRewardUnclaimable, which
    ///      exercised the BUG: VibesStaking resets firstStakeTime to 0 on full unstake; the
    ///      eligibility gate `stakerFirstStake >= notifiedAt` then incorrectly blocked the
    ///      historical reward even though balanceAtSnapshot still recorded the staker's
    ///      pre-unstake balance. After the fix, _getStakerBalance and canClaim trust
    ///      balanceAtSnapshot directly — a non-zero snapshot balance means eligible,
    ///      regardless of current firstStakeTime.
    function test_VIB04_fullUnstakeAfterNotifyStillAllowsHistoricalClaim() public {
        address mockRouter = makeAddr("router");
        address escrow = makeAddr("escrow");
        address staker = makeAddr("staker");
        uint256 stakeAmount = 100_000 ether;
        uint256 rewardAmount = 25_000 ether;

        VibesToken vibesToken = new VibesToken("Vibes", "VIBES", 18, 1_000_000 ether, address(this));
        VibesToken rewardToken = new VibesToken("Reward", "RWD", 18, 1_000_000 ether, address(this));
        VibesStaking staking = new VibesStaking(address(vibesToken), address(0));
        VibesStakerRewards rewards = new VibesStakerRewards(address(this), address(staking), mockRouter);
        staking.setSnapshotAuthorized(address(rewards), true);

        vibesToken.transfer(staker, stakeAmount);
        vm.startPrank(staker);
        vibesToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount, 0, 0, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        rewardToken.transfer(address(rewards), rewardAmount);
        vm.prank(mockRouter);
        rewards.notifyReward(address(rewardToken), rewardAmount, escrow);

        uint256 snapshotId = rewards.raiseSnapshotId(escrow);
        assertEq(staking.balanceAtSnapshot(snapshotId, staker), stakeAmount);

        // Staker fully unstakes — VibesStaking resets firstStakeTime to 0 here.
        vm.prank(staker);
        staking.requestUnstake();
        vm.warp(block.timestamp + staking.UNSTAKE_COOLDOWN() + 1);
        vm.prank(staker);
        staking.unstake(stakeAmount);

        // Snapshot still records the pre-unstake balance — that is the authoritative state.
        assertEq(staking.balanceAtSnapshot(snapshotId, staker), stakeAmount, "snapshot still records pre-unstake stake");
        assertEq(staking.firstStakeTime(staker), 0, "VibesStaking reset firstStakeTime on full unstake");

        // ZXVC VIB-04 fix: canClaim now trusts balanceAtSnapshot, not firstStakeTime.
        (bool canClaim, uint256 quotedAmount) = rewards.canClaim(escrow, staker);
        assertTrue(canClaim, "post-fix: historical staker remains eligible despite later full unstake");
        assertEq(quotedAmount, rewardAmount, "staker should be quoted the full reward (sole staker)");

        // Claim succeeds and delivers the full snapshotted share.
        uint256 stakerBalanceBefore = rewardToken.balanceOf(staker);
        vm.prank(staker);
        rewards.claim(escrow);
        assertEq(
            rewardToken.balanceOf(staker) - stakerBalanceBefore,
            rewardAmount,
            "staker receives full reward share"
        );
        assertEq(rewardToken.balanceOf(address(rewards)), 0, "reward fully distributed, none stranded");
    }

    /// @notice ZXVC VIB-05 (2026-05) regression — deep snapshot backlog reverts cleanly, catchUp unblocks.
    /// @dev Pre-fix this PoC asserted the BUG: a staker who hadn't acted while many
    ///      snapshots accumulated would OOG inside the unbounded eager-backfill loop and
    ///      be unable to unstake. After fix, the eager backfill is capped at
    ///      MAX_BACKFILL_PER_CALL (50). If the backlog exceeds that, stake/unstake
    ///      reverts cleanly with SnapshotBacklogTooDeep (no more OOG). The permissionless
    ///      catchUpSnapshots helper lets anyone clear the backlog in chunks; once the
    ///      remaining backlog is at or below the cap, the unstake succeeds.
    function test_VIB05_deepSnapshotBacklogRevertsCleanlyThenCatchUpAllowsUnstake() public {
        address snapshotter = makeAddr("snapshotter");
        address staker = makeAddr("staker");
        uint256 stakeAmount = 100_000 ether;

        VibesToken vibesToken = new VibesToken("Vibes", "VIBES", 18, 1_000_000 ether, address(this));
        VibesStaking staking = new VibesStaking(address(vibesToken), address(0));
        staking.setSnapshotAuthorized(snapshotter, true);

        vibesToken.transfer(staker, stakeAmount);
        vm.startPrank(staker);
        vibesToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount, 0, 0, "");
        vm.stopPrank();

        // Inflate the snapshot count well beyond MAX_BACKFILL_PER_CALL (50).
        for (uint256 i = 0; i < 500; i++) {
            vm.prank(snapshotter);
            staking.takeSnapshot();
        }

        vm.prank(staker);
        staking.requestUnstake();
        vm.warp(block.timestamp + staking.UNSTAKE_COOLDOWN() + 1);

        // ZXVC VIB-05 fix: unstake now reverts CLEANLY with SnapshotBacklogTooDeep
        // (carrying the actual backlog count) rather than OOG'ing the user.
        uint256 cap = staking.MAX_BACKFILL_PER_CALL();
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(VibesStaking.SnapshotBacklogTooDeep.selector, uint256(500)));
        staking.unstake(stakeAmount);
        assertEq(staking.stakedBalance(staker), stakeAmount, "principal still staked after revert");

        // Anyone can call catchUpSnapshots to chip away at the backlog. Loop until the
        // remaining backlog fits in one stake/unstake call.
        while (staking.currentSnapshotId() - staking.lastSnapshotWritten(staker) > cap) {
            staking.catchUpSnapshots(staker, cap);
        }

        // With backlog reduced, unstake now lands.
        vm.prank(staker);
        staking.unstake(stakeAmount);
        assertEq(staking.stakedBalance(staker), 0, "principal fully unstaked after catch-up");
        assertEq(
            vibesToken.balanceOf(staker),
            stakeAmount,
            "staker received their principal back"
        );
    }

    /// @notice ZXVC VIB-07 (2026-05) regression — registry rejects pre-deploy squatting.
    /// @dev Pre-fix this PoC asserted the BUG: an attacker could pre-register a CREATE-predicted
    ///      address for a future factory deployment, locking in attacker-chosen provenance
    ///      (founder, capsule, attestation). After fix, register() requires the token address
    ///      to already have code — so the predicted address (with no code yet) is rejected.
    function test_VIB07_registryRejectsPreDeploySquatting() public {
        VibesTokenFactory tokenFactory = new VibesTokenFactory();
        VibesRegistry registry = new VibesRegistry();

        address predicted = vm.computeCreateAddress(address(tokenFactory), vm.getNonce(address(tokenFactory)));
        assertEq(predicted.code.length, 0, "predicted address has no code yet");

        VibesRegistry.Attestation memory fakeAttestation = VibesRegistry.Attestation({
            version: 1,
            agentTool: 1,
            modelProvider: 1,
            proofType: 1,
            proofArtifactHash: keccak256("fake-proof")
        });

        // ZXVC VIB-07 fix: register() now reverts because the predicted address has no code.
        vm.prank(makeAddr("attacker"));
        vm.expectRevert("Token has no code");
        registry.register(predicted, keccak256("fake-capsule"), fakeAttestation);

        // Sanity: the predicted address is still un-registered, so the legitimate factory
        // flow can claim provenance once the token is actually deployed.
        assertEq(registry.founderOf(predicted), address(0), "no squatted provenance");
        assertFalse(registry.isRegistered(predicted), "no squatted registration");
    }

    /// @notice ZXVC VIB-02 (2026-05) — regression for the post-Phase-2 admin custody-setter attack.
    /// @dev Originally PoC test_POC_adminCanManipulateRefundDenominatorWithLockedAddressSetter,
    ///      which exercised the buggy behaviour: a malicious admin called setLockedAddresses
    ///      with a victim holder's address as the "vesting" arg to exclude their balance from
    ///      frozenTotalSupply, then extracted 100% of frozenEthBalance via a self-favouring
    ///      merkle root. After the fix, the router latches custody addresses during Phase 2
    ///      and both setters revert "Locked". This test asserts the lockout from every angle
    ///      (admin, router, and the one-shot finalize itself).
    function test_VIB02_custodySettersLockedAfterRouterFinalization() public {
        (VibesTranchEscrow escrow, VibesToken token, Specialist3MockRouter router) = _fundedEscrow(TOKEN_SUPPLY);

        address victimHolder = makeAddr("victimHolder");
        uint256 attackerTokens = 1 ether;
        uint256 victimTokens = TOKEN_SUPPLY - attackerTokens;

        vm.startPrank(founder);
        token.transfer(victimHolder, victimTokens);
        token.transfer(maliciousAdmin, attackerTokens);
        vm.stopPrank();

        // Legitimate Phase 2 finalisation: in production VibesRouterExtension._executePhase2
        // calls finalizeLockedAddresses() after wiring vesting/staker/treasury. We simulate
        // that step here using the mock router so the test exercises the post-Phase-2 state.
        vm.prank(address(router));
        escrow.finalizeLockedAddresses();
        assertTrue(escrow.lockedAddressesFinalized(), "router latch must engage");

        // 1. The original attack vector: admin can no longer rewire setLockedAddresses to
        //    exclude a victim holder from the refund denominator.
        vm.prank(maliciousAdmin);
        vm.expectRevert("Locked");
        escrow.setLockedAddresses(victimHolder, address(0));

        // 2. setTreasuryContract is locked by the same latch.
        vm.prank(maliciousAdmin);
        vm.expectRevert("Locked");
        escrow.setTreasuryContract(victimHolder);

        // 3. Even the router itself cannot rewire after finalisation — closes any
        //    same-router-second-call path (defence in depth against router bugs).
        vm.prank(address(router));
        vm.expectRevert("Locked");
        escrow.setLockedAddresses(victimHolder, address(0));

        // 4. finalizeLockedAddresses() is one-shot — second call reverts so any future
        //    refactor that double-calls it fails loudly instead of silently re-latching.
        vm.prank(address(router));
        vm.expectRevert("Already finalized");
        escrow.finalizeLockedAddresses();

        // 5. Non-router cannot call finalize at all — admin has no override.
        vm.prank(maliciousAdmin);
        vm.expectRevert(VibesTranchEscrow.OnlyRouter.selector);
        escrow.finalizeLockedAddresses();
    }

    /// @notice ZXVC VIB-01 (2026-05) regression — per-campaign fee claimer excluded.
    /// @dev Originally PoC test_POC_feeClaimerTokenBalanceDilutesFreezeRefundDenominator,
    ///      which exercised the buggy behaviour: project tokens held by the per-campaign
    ///      VibesLPFeeClaimer were silently counted as "redeemable" in frozenTotalSupply,
    ///      diluting per-holder ETH refunds. The option (a) fix excludes the fee claimer
    ///      registered with the LP locker (read lazily via campaignToFeeClaimer). We
    ///      vm.mockCall the locker view here to simulate the post-LP-lock state without
    ///      walking through the full rescue + manual-lock setup.
    function test_VIB01_canonicalFeeClaimerBalanceExcludedFromDenominator() public {
        (VibesTranchEscrow escrow, VibesToken token,) = _fundedEscrow(TOKEN_SUPPLY);

        address legitimateHolder = makeAddr("legitimateHolder");
        address simulatedFeeClaimer = makeAddr("simulatedFeeClaimer");
        address vesting = makeAddr("vesting");

        vm.startPrank(founder);
        token.transfer(legitimateHolder, 500 ether);
        token.transfer(simulatedFeeClaimer, 100 ether);
        token.transfer(vesting, 400 ether);
        vm.stopPrank();

        // ZXVC VIB-01 fix: simulate the locker recognising simulatedFeeClaimer as the
        // canonical fee claimer for this campaign. In production the locker records this
        // during createAndLockLP / recordManualLPLock.
        // vm.etch + vm.mockCall: stub code so the escrow's code.length guard passes, then
        // intercept the actual view dispatch with canned return data.
        address locker = escrow.lpLocker();
        vm.etch(locker, hex"60016000fe"); // any non-empty bytecode
        vm.mockCall(
            locker,
            abi.encodeWithSignature("campaignToFeeClaimer(address)", address(escrow)),
            abi.encode(simulatedFeeClaimer)
        );
        // getLockedPosition: no real pool registered — return zero-pool struct so the
        // try block sees a zero pool and skips that exclusion (it only adds when non-zero).
        VibesLPLocker.LockedLP memory pos;
        vm.mockCall(
            locker,
            abi.encodeWithSignature("getLockedPosition(address)", address(escrow)),
            abi.encode(pos)
        );

        vm.prank(maliciousAdmin);
        escrow.setLockedAddresses(vesting, address(0));
        vm.prank(maliciousAdmin);
        escrow.freezeCampaign("fee claimer must be excluded");

        // Post-fix: the locker-registered fee claimer's balance is excluded.
        assertEq(token.balanceOf(simulatedFeeClaimer), 100 ether);
        assertEq(
            escrow.frozenTotalSupply(),
            500 ether,
            "Fee-claimer balance must be excluded from the holder-refund denominator"
        );
    }

    /// @notice ZXVC VIB-11 (2026-05) regression — platform fees still claimable after freeze.
    /// @dev Pre-fix this PoC asserted the BUG: claimPlatformFees reverted with "Fees locked
    ///      during refund" once a campaign was frozen, leaving pending platform fees
    ///      permanently stranded. The previous guard was over-restrictive — freeze
    ///      accounting already subtracts pendingPlatformFees from frozenEthBalance, so
    ///      paying out the pending fees does not touch holder refund funds. After fix,
    ///      claimPlatformFees succeeds in Frozen/Refunding and only reverts in the Failed
    ///      contributor-refund state (where the entire balance is owed back to backers).
    function test_VIB11_platformFeesStillClaimableAfterFreeze() public {
        (VibesTranchEscrow escrow,,) = _fundedEscrow(TOKEN_SUPPLY);

        vm.prank(founder);
        escrow.claimTranche(0);

        uint256 pendingFees = escrow.pendingPlatformFees();
        assertGt(pendingFees, 0);

        vm.prank(maliciousAdmin);
        escrow.freezeCampaign("freeze with pending fees");

        // ZXVC VIB-11 fix: claimPlatformFees succeeds in Frozen state.
        uint256 walletBalBefore = platformWallet.balance;
        escrow.claimPlatformFees();
        assertEq(escrow.pendingPlatformFees(), 0, "pending fees cleared after claim");
        assertEq(platformWallet.balance - walletBalBefore, pendingFees, "platform wallet received the fees");
    }

    function test_POC_revertingFeeRecipientBricksFeePaidLaunches() public {
        VibesTokenFactory tokenFactory = new VibesTokenFactory();
        VibesRegistry registry = new VibesRegistry();
        VibesRouterExtension extension = new VibesRouterExtension();
        VibesLaunchRouterV2 router = new VibesLaunchRouterV2(
            address(extension),
            address(tokenFactory),
            address(registry),
            address(0),
            payable(address(0))
        );
        registry.authorizeRouter(address(router));

        RejectingFeeRecipient rejecting = new RejectingFeeRecipient();
        VibesRouterExtension(address(router)).setFeeConfig(true, 0.01 ether, address(rejecting));

        vm.deal(founder, 1 ether);
        vm.prank(founder);
        vm.expectRevert("Fee transfer failed");
        router.launch{value: 0.01 ether}(
            "Blocked",
            "BLK",
            18,
            TOKEN_SUPPLY,
            founder,
            keccak256("capsule"),
            1,
            1,
            1,
            keccak256("proof")
        );
    }

    function _fundedEscrow(uint256 supply)
        internal
        returns (VibesTranchEscrow escrow, VibesToken token, Specialist3MockRouter router)
    {
        router = new Specialist3MockRouter();
        VibesTranchEscrow implementation = new VibesTranchEscrow();
        VibesTranchEscrowFactory factory = new VibesTranchEscrowFactory(
            address(implementation),
            maliciousAdmin,
            platformWallet,
            address(0),
            address(router),
            lpLocker,
            address(0)
        );
        token = new VibesToken("Project", "PRJ", 18, supply, founder);

        vm.prank(address(router));
        address escrowAddr = factory.createEscrow(
            founder,
            address(token),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 7 days,
            0
        );
        escrow = VibesTranchEscrow(payable(escrowAddr));

        vm.deal(backer, 100 ether);
        vm.prank(backer);
        escrow.contribute{value: GOAL}(0, 0, "");
        vm.warp(block.timestamp + 8 days);
        escrow.finalize();
    }
}
