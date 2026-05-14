// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { VibesLaunchRouterV2 } from "../src/VibesLaunchRouterV2.sol";
import { VibesRouterExtension } from "../src/VibesRouterExtension.sol";
import { VibesRouterStorage } from "../src/VibesRouterStorage.sol";
import { VibesTokenFactory } from "../src/VibesTokenFactory.sol";
import { VibesRegistry } from "../src/VibesRegistry.sol";
import { VibesTranchEscrowFactory } from "../src/VibesTranchEscrowFactory.sol";
import { VibesTranchEscrow } from "../src/VibesTranchEscrow.sol";
import { VibesLPLocker } from "../src/VibesLPLocker.sol";
import { VibesLPFeeClaimer } from "../src/VibesLPFeeClaimer.sol";
import { VibesCommunityRewardsFactory } from "../src/VibesCommunityRewardsFactory.sol";
import { VibesStaking } from "../src/VibesStaking.sol";
import { VibesStakerRewards } from "../src/VibesStakerRewards.sol";
import { VibesToken } from "../src/VibesToken.sol";
import { MockAerodromeRouter, MockLPToken } from "./mocks/MockAerodromeRouter.sol";

contract DeploymentPipelineTest is Test {
    VibesTokenFactory tokenFactory;
    VibesRegistry registry;
    VibesTranchEscrow escrowImpl;
    VibesTranchEscrowFactory escrowFactory;
    VibesLPLocker lpLocker;
    VibesLPFeeClaimer feeClaimerImpl;
    VibesRouterExtension extension;
    VibesLaunchRouterV2 router;
    VibesCommunityRewardsFactory communityFactory;
    MockAerodromeRouter aeroRouter;

    VibesToken vibesToken;
    VibesStaking staking;
    VibesStakerRewards stakerRewards;

    address founder = makeAddr("founder");
    address backer = makeAddr("backer");
    address staker = makeAddr("staker");
    address attacker = makeAddr("attacker");
    address opsAdmin = makeAddr("opsAdmin");
    address opsWallet = makeAddr("opsWallet");
    address feeRecipient = makeAddr("feeRecipient");
    address gnosisSafe = makeAddr("gnosisSafe");
    address weth = makeAddr("weth");
    address aeroFactory = makeAddr("aeroFactory");

    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 constant DEPOSIT = 0.01 ether;
    uint256 constant GOAL = 10 ether;
    bytes32 constant CAPSULE_HASH = keccak256("deployment-capsule");
    bytes32 constant PROOF_HASH = keccak256("deployment-proof");

    receive() external payable { }

    function _deployCore() internal {
        tokenFactory = new VibesTokenFactory();
        registry = new VibesRegistry();
        escrowImpl = new VibesTranchEscrow();

        aeroRouter = new MockAerodromeRouter(weth, aeroFactory);
        lpLocker = new VibesLPLocker(address(aeroRouter), aeroFactory);
        feeClaimerImpl = new VibesLPFeeClaimer();
        lpLocker.setFeeClaimerImplementation(address(feeClaimerImpl));

        extension = new VibesRouterExtension();
        router = new VibesLaunchRouterV2(
            address(extension),
            address(tokenFactory),
            address(registry),
            address(0),
            payable(address(lpLocker))
        );

        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl),
            opsAdmin,
            feeRecipient,
            address(0),
            address(router),
            address(lpLocker),
            address(0)
        );
        communityFactory = new VibesCommunityRewardsFactory();

        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        VibesRouterExtension(address(router)).setOpsWallet(opsWallet);
        VibesRouterExtension(address(router)).setOperationsAdmin(opsAdmin);
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(address(0));
        VibesRouterExtension(address(router)).setCommunityRewardsFactory(address(communityFactory));

        registry.authorizeRouter(address(router));
        lpLocker.setAuthorizedRouter(address(router));

        vm.deal(founder, 100 ether);
        vm.deal(backer, 100 ether);
    }

    function _deployStaking(bool authorizeSnapshots) internal {
        vibesToken = new VibesToken("Vibes", "VIBES", 18, 1_000_000_000 ether, address(this));
        staking = new VibesStaking(address(vibesToken), address(0));
        stakerRewards = new VibesStakerRewards(address(this), address(staking), address(router));

        if (authorizeSnapshots) {
            staking.setSnapshotAuthorized(address(stakerRewards), true);
        }

        VibesRouterExtension(address(router)).setStakerRewardsContract(address(stakerRewards));
    }

    function _assertDeploymentReady(bool requireTimeOracleLocked, bool requireStakerRewards)
        internal
        view
    {
        require(
            address(router.tokenFactory()) == address(tokenFactory), "router tokenFactory mismatch"
        );
        require(address(router.registry()) == address(registry), "router registry mismatch");
        require(
            address(router.escrowFactory()) == address(escrowFactory),
            "router escrowFactory mismatch"
        );
        require(address(router.lpLocker()) == address(lpLocker), "router lpLocker mismatch");
        require(router.opsWallet() == opsWallet, "ops wallet not configured");
        require(registry.authorizedRouters(address(router)), "router not registry-authorized");
        require(lpLocker.authorizedRouter() == address(router), "lp locker router not authorized");
        require(lpLocker.feeClaimerImplementation().code.length > 0, "fee claimer impl missing");
        require(
            escrowFactory.authorizedRouter() == address(router), "escrow factory router mismatch"
        );
        require(escrowFactory.lpLocker() == address(lpLocker), "escrow factory lp locker mismatch");

        if (requireTimeOracleLocked) {
            require(escrowFactory.timeOracle() == address(0), "production time oracle must be zero");
            require(escrowFactory.timeOracleLocked(), "time oracle not locked");
        }

        if (requireStakerRewards) {
            require(
                router.stakerRewardsContract() == address(stakerRewards), "router rewards mismatch"
            );
            require(stakerRewards.authorizedRouter() == address(router), "rewards router mismatch");
            require(stakerRewards.stakingContract() == address(staking), "rewards staking mismatch");
            require(
                staking.snapshotAuthorized(address(stakerRewards)),
                "staker rewards not authorized for snapshots"
            );
        }
    }

    function assertDeploymentReady(bool requireTimeOracleLocked, bool requireStakerRewards)
        external
        view
    {
        _assertDeploymentReady(requireTimeOracleLocked, requireStakerRewards);
    }

    function _stakeBeforeFinalization() internal {
        assertTrue(vibesToken.transfer(staker, 100_000 ether));
        vm.startPrank(staker);
        vibesToken.approve(address(staking), type(uint256).max);
        staking.stake(100_000 ether, 0, 0, "");
        vm.stopPrank();
        skip(1);
    }

    function _launchFundAndFinalize() internal returns (address token, address escrow) {
        vm.prank(founder);
        (token, escrow,) = router.launchWithCampaign{ value: DEPOSIT }(
            "Deploy Test",
            "DPLY",
            18,
            TOTAL_SUPPLY,
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 14 days,
            0,
            0,
            0,
            0,
            0,
            ""
        );

        vm.prank(backer);
        VibesTranchEscrow(payable(escrow)).contribute{ value: GOAL }(0, 0, "");

        VibesTranchEscrow(payable(escrow)).finalize();
    }

    function test_deploymentReadinessFailsIfTimeOracleRemainsUnlocked() public {
        _deployCore();
        _deployStaking(true);

        vm.expectRevert("time oracle not locked");
        this.assertDeploymentReady(true, true);
    }

    function test_deploymentReadinessFailsIfStakerRewardsCannotSnapshot() public {
        _deployCore();
        _deployStaking(false);
        vm.prank(opsAdmin);
        escrowFactory.lockTimeOracle();

        vm.expectRevert("staker rewards not authorized for snapshots");
        this.assertDeploymentReady(true, true);
    }

    function test_completeDeploymentReadinessPassesOnlyAfterAllCriticalSteps() public {
        _deployCore();
        _deployStaking(true);
        vm.prank(opsAdmin);
        escrowFactory.lockTimeOracle();

        VibesRouterExtension(address(router)).transferOwnership(gnosisSafe);
        assertEq(router.pendingOwner(), gnosisSafe, "safe must still accept router ownership");
        vm.prank(gnosisSafe);
        VibesRouterExtension(address(router)).acceptOwnership();

        _assertDeploymentReady(true, true);
        assertEq(router.owner(), gnosisSafe, "router ownership transfer incomplete");
    }

    /// @notice ZXVC VIB-03 (2026-05) regression — fail-closed deployment.
    /// @dev Originally PoC test_missedSnapshotAuthorizationLeavesFinalizationCompleteButRewardsInactive,
    ///      which asserted the BUG: Phase 2 reached FullyComplete with reward.active == false
    ///      and tokens permanently stranded in stakerRewards because notifyReward was wrapped
    ///      in try/catch. The VIB-03 fix moves notifyReward BEFORE the safeTransfer in
    ///      VibesRouterExtension._executePhase2 and removes the try/catch, so a missed
    ///      snapshot authorisation now reverts Phase 2 entirely — tokens are NOT transferred
    ///      and reward.active stays false. Phase 2 is deferrable via finalize()'s outer
    ///      try/catch (FinalizationDeferred event), so finalize() itself does not revert;
    ///      the campaign just stops at LPComplete and adminRetryFinalization can pick up
    ///      after the missing setSnapshotAuthorized is fixed.
    function test_VIB03_missedSnapshotAuthorizationBlocksFinalizationAndProtectsTokens() public {
        _deployCore();
        _deployStaking(false); // snapshot NOT authorised — deployment bug
        _stakeBeforeFinalization();

        (address token, address escrow) = _launchFundAndFinalize();

        // Phase 1 (LP) succeeded — that path doesn't touch staker rewards. Phase 2 deferred.
        assertEq(
            uint8(router.finalizationPhase(token)),
            uint8(VibesRouterStorage.FinalizationPhase.LPComplete),
            "Phase 2 must NOT mark finalization complete without snapshot authorization"
        );

        (
            address rewardToken,
            uint256 totalTokens,
            uint256 claimedTokens,
            uint256 totalStakedSnapshot,
            uint256 notifiedAt,
            bool active
        ) = stakerRewards.getRewardsInfo(escrow);

        // Reward is unset (Phase 2 reverted before notify state landed).
        assertFalse(active, "reward.active must remain false");
        assertEq(rewardToken, address(0), "inactive reward token should be unset");
        assertEq(totalTokens, 0, "inactive reward total should be zero");
        assertEq(claimedTokens, 0, "inactive reward claimed should be zero");
        assertEq(totalStakedSnapshot, 0, "inactive reward snapshot should be zero");
        assertEq(notifiedAt, 0, "inactive reward timestamp should be zero");

        // VIB-03 invariant: tokens never sit in stakerRewards while reward.active == false.
        assertEq(
            VibesToken(token).balanceOf(address(stakerRewards)),
            0,
            "staker tokens must NOT be stranded in inactive rewards contract"
        );

        // Sanity: after the deploy is fixed, adminRetryFinalization picks up Phase 2.
        staking.setSnapshotAuthorized(address(stakerRewards), true);
        VibesRouterExtension(address(router)).adminRetryFinalization(token);

        assertEq(
            uint8(router.finalizationPhase(token)),
            uint8(VibesRouterStorage.FinalizationPhase.FullyComplete),
            "Phase 2 should complete after snapshot authorisation is fixed"
        );
        (,,,,, active) = stakerRewards.getRewardsInfo(escrow);
        assertTrue(active, "reward.active should flip true once Phase 2 completes");

        uint256 expectedStakerTokens =
            (TOTAL_SUPPLY * router.ECOSYSTEM_ALLOCATION_BPS()) / router.BPS_DENOMINATOR();
        assertEq(
            VibesToken(token).balanceOf(address(stakerRewards)),
            expectedStakerTokens,
            "staker tokens transferred only after notifyReward succeeds"
        );
    }

    function test_completeDeploymentFinalizesAndActivatesStakerRewards() public {
        _deployCore();
        _deployStaking(true);
        _stakeBeforeFinalization();

        (address token, address escrow) = _launchFundAndFinalize();

        (address rewardToken, uint256 totalTokens,, uint256 totalStakedSnapshot,, bool active) =
            stakerRewards.getRewardsInfo(escrow);

        uint256 expectedStakerTokens =
            (TOTAL_SUPPLY * router.ECOSYSTEM_ALLOCATION_BPS()) / router.BPS_DENOMINATOR();

        assertEq(
            uint8(router.finalizationPhase(token)),
            uint8(VibesRouterStorage.FinalizationPhase.FullyComplete)
        );
        assertTrue(active, "reward should be active after complete deployment");
        assertEq(rewardToken, token, "reward token mismatch");
        assertEq(totalTokens, expectedStakerTokens, "staker reward token amount mismatch");
        assertEq(totalStakedSnapshot, 100_000 ether, "snapshot should capture existing stake");
        assertEq(stakerRewards.getRewardedRaisesCount(), 1, "raise should be enumerable");
    }

    function test_partialDeploymentRejectsLaunchesUntilCriticalWiringExists() public {
        VibesTokenFactory bareTokenFactory = new VibesTokenFactory();
        VibesRegistry bareRegistry = new VibesRegistry();
        VibesRouterExtension bareExtension = new VibesRouterExtension();
        VibesLaunchRouterV2 bareRouter = new VibesLaunchRouterV2(
            address(bareExtension),
            address(bareTokenFactory),
            address(bareRegistry),
            address(0),
            payable(address(0))
        );

        vm.deal(founder, 1 ether);
        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.EscrowFactoryNotSet.selector);
        bareRouter.launchWithCampaign{ value: DEPOSIT }(
            "Bare",
            "BARE",
            18,
            TOTAL_SUPPLY,
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 14 days,
            0,
            0,
            0,
            0,
            0,
            ""
        );

        vm.prank(founder);
        vm.expectRevert("Not authorized router");
        bareRouter.launch(
            "Bare", "BARE", 18, TOTAL_SUPPLY, founder, CAPSULE_HASH, 1, 1, 1, PROOF_HASH
        );
    }

    function test_nonOwnersCannotWirePartiallyDeployedContracts() public {
        _deployCore();

        vm.prank(attacker);
        vm.expectRevert("Not owner");
        registry.authorizeRouter(attacker);

        vm.prank(attacker);
        vm.expectRevert(VibesLPLocker.OnlyOwner.selector);
        lpLocker.setAuthorizedRouter(attacker);

        vm.prank(attacker);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).setEscrowFactory(attacker);

        vm.prank(attacker);
        vm.expectRevert(VibesTranchEscrowFactory.OnlyAdmin.selector);
        escrowFactory.setAuthorizedRouter(attacker);
    }

    function test_escrowImplementationAndPredictedCloneCannotBeHijacked() public {
        _deployCore();

        address projectToken =
            tokenFactory.deployToken("Pre", "PRE", 18, TOTAL_SUPPLY, address(this));
        uint256 deadline = block.timestamp + 14 days;
        address predicted = escrowFactory.predictEscrowAddress(founder, projectToken, deadline, 0);

        vm.prank(attacker);
        (bool noCodeCallSucceeded,) = predicted.call(
            abi.encodeWithSelector(
                VibesTranchEscrow.initialize.selector,
                attacker,
                projectToken,
                VibesTranchEscrow.RaiseType.FixedGoal,
                GOAL,
                0,
                deadline,
                0,
                attacker,
                attacker,
                address(0),
                attacker,
                attacker,
                address(0)
            )
        );

        assertTrue(noCodeCallSucceeded, "calls to a predicted no-code address should be inert");
        assertEq(predicted.code.length, 0, "attacker should not be able to deploy the clone");

        vm.prank(address(router));
        address actual = escrowFactory.createEscrow(
            founder, projectToken, VibesTranchEscrow.RaiseType.FixedGoal, GOAL, 0, deadline, 0
        );

        assertEq(actual, predicted, "factory should still own deterministic clone creation");
        assertGt(actual.code.length, 0, "clone should be deployed by factory");
        assertEq(
            VibesTranchEscrow(payable(actual)).getCampaign().founder, founder, "founder hijacked"
        );

        vm.prank(attacker);
        vm.expectRevert(VibesTranchEscrow.AlreadyInitialized.selector);
        VibesTranchEscrow(payable(actual))
            .initialize(
                attacker,
                projectToken,
                VibesTranchEscrow.RaiseType.FixedGoal,
                GOAL,
                0,
                deadline,
                0,
                attacker,
                attacker,
                address(0),
                attacker,
                attacker,
                address(0)
            );

        vm.expectRevert(VibesTranchEscrow.AlreadyInitialized.selector);
        escrowImpl.initialize(
            attacker,
            projectToken,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            deadline,
            0,
            attacker,
            attacker,
            address(0),
            attacker,
            attacker,
            address(0)
        );
    }

    function test_attackerInitializedFeeClaimerImplementationDoesNotBlockFutureLockerClones()
        public
    {
        MockAerodromeRouter localAero = new MockAerodromeRouter(weth, aeroFactory);
        VibesLPLocker localLocker = new VibesLPLocker(address(localAero), aeroFactory);
        VibesLPFeeClaimer localImpl = new VibesLPFeeClaimer();
        localLocker.setFeeClaimerImplementation(address(localImpl));
        localLocker.setAuthorizedRouter(address(this));

        VibesToken projectToken = new VibesToken("LP Test", "LPT", 18, TOTAL_SUPPLY, address(this));
        MockLPToken fakePool = new MockLPToken(address(projectToken), weth);

        vm.prank(attacker);
        localImpl.initialize(
            address(fakePool),
            makeAddr("implCampaign"),
            address(projectToken),
            feeRecipient,
            address(0)
        );
        assertTrue(localImpl.initialized(), "implementation should be attacker-initializable today");

        uint256 lpTokens = 150_000 ether;
        projectToken.approve(address(localLocker), lpTokens);
        (address pool, uint256 lpAmount) = localLocker.createAndLockLP{ value: 7.5 ether }(
            address(projectToken), lpTokens, makeAddr("realCampaign"), feeRecipient, address(0)
        );

        address claimer = localLocker.campaignToFeeClaimer(makeAddr("realCampaign"));
        assertGt(lpAmount, 0, "LP should still be created");
        assertTrue(pool != address(0), "pool should be created");
        assertTrue(claimer != address(0), "real claimer clone should be deployed");
        assertTrue(claimer != address(localImpl), "locker must not use implementation as holder");
        assertTrue(
            VibesLPFeeClaimer(claimer).initialized(), "clone should initialize independently"
        );
    }
}
