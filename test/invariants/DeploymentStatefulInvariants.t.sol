// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
// Deployment-aware stateful invariants
//
// This handler fuzzes deployment itself: contracts can be deployed in many orders,
// wiring can be skipped or repeated, and attacker actions are interleaved with
// launch/finalization attempts. The important property is not "every random order
// works"; it is that incomplete deployment is either non-functional or rejected by
// the readiness gate, and that no attacker can seize critical wiring while the
// system is partially initialized.
// =============================================================================

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { VibesLaunchRouterV2 } from "../../src/VibesLaunchRouterV2.sol";
import { VibesRouterExtension } from "../../src/VibesRouterExtension.sol";
import { VibesRouterStorage } from "../../src/VibesRouterStorage.sol";
import { VibesTokenFactory } from "../../src/VibesTokenFactory.sol";
import { VibesRegistry } from "../../src/VibesRegistry.sol";
import { VibesTranchEscrowFactory } from "../../src/VibesTranchEscrowFactory.sol";
import { VibesTranchEscrow } from "../../src/VibesTranchEscrow.sol";
import { VibesLPLocker } from "../../src/VibesLPLocker.sol";
import { VibesLPFeeClaimer } from "../../src/VibesLPFeeClaimer.sol";
import { VibesCommunityRewardsFactory } from "../../src/VibesCommunityRewardsFactory.sol";
import { VibesStaking } from "../../src/VibesStaking.sol";
import { VibesStakerRewards } from "../../src/VibesStakerRewards.sol";
import { VibesToken } from "../../src/VibesToken.sol";
import { MockAerodromeRouter } from "../mocks/MockAerodromeRouter.sol";

contract DeploymentFuzzHandler is Test {
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrow public escrowImpl;
    VibesTranchEscrowFactory public escrowFactory;
    VibesLPLocker public lpLocker;
    VibesLPFeeClaimer public feeClaimerImpl;
    VibesRouterExtension public extension;
    VibesLaunchRouterV2 public router;
    VibesCommunityRewardsFactory public communityFactory;
    MockAerodromeRouter public aeroRouter;
    VibesToken public vibesToken;
    VibesStaking public staking;
    VibesStakerRewards public stakerRewards;

    address public founder = makeAddr("df_founder");
    address public backer = makeAddr("df_backer");
    address public staker = makeAddr("df_staker");
    address public attacker = makeAddr("df_attacker");
    address public opsWallet = makeAddr("df_opsWallet");
    address public feeRecipient = makeAddr("df_feeRecipient");
    address public weth = makeAddr("df_weth");
    address public aeroFactory = makeAddr("df_aeroFactory");

    bool public ghost_attackerCriticalWrite;
    bool public ghost_silentBrokenFinalization;
    bool public ghost_completeSmokeFailed;
    uint256 public ghost_incompleteReadinessRejections;
    uint256 public smokeAttempts;

    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 constant DEPOSIT = 0.01 ether;
    uint256 constant GOAL = 1 ether;
    bytes32 constant CAPSULE_HASH = keccak256("deployment-fuzz-capsule");
    bytes32 constant PROOF_HASH = keccak256("deployment-fuzz-proof");

    receive() external payable { }

    function deployStep(uint256 seed) external {
        uint256 step = seed % 13;

        if (step == 0 && address(aeroRouter) == address(0)) {
            aeroRouter = new MockAerodromeRouter(weth, aeroFactory);
        } else if (step == 1 && address(tokenFactory) == address(0)) {
            tokenFactory = new VibesTokenFactory();
        } else if (step == 2 && address(registry) == address(0)) {
            registry = new VibesRegistry();
        } else if (step == 3 && address(escrowImpl) == address(0)) {
            escrowImpl = new VibesTranchEscrow();
        } else if (step == 4 && address(extension) == address(0)) {
            extension = new VibesRouterExtension();
        } else if (
            step == 5 && address(lpLocker) == address(0) && address(aeroRouter) != address(0)
        ) {
            lpLocker = new VibesLPLocker(address(aeroRouter), aeroFactory);
        } else if (step == 6 && address(feeClaimerImpl) == address(0)) {
            feeClaimerImpl = new VibesLPFeeClaimer();
        } else if (
            step == 7 && address(router) == address(0) && address(extension) != address(0)
                && address(tokenFactory) != address(0) && address(registry) != address(0)
        ) {
            router = new VibesLaunchRouterV2(
                address(extension),
                address(tokenFactory),
                address(registry),
                address(0),
                payable(address(lpLocker))
            );
        } else if (
            step == 8 && address(escrowFactory) == address(0) && address(escrowImpl) != address(0)
                && address(router) != address(0) && address(lpLocker) != address(0)
        ) {
            escrowFactory = new VibesTranchEscrowFactory(
                address(escrowImpl),
                address(this),
                feeRecipient,
                address(0),
                address(router),
                address(lpLocker),
                address(0)
            );
        } else if (step == 9 && address(communityFactory) == address(0)) {
            communityFactory = new VibesCommunityRewardsFactory();
        } else if (step == 10 && address(vibesToken) == address(0)) {
            vibesToken = new VibesToken("Vibes", "VIBES", 18, 1_000_000_000 ether, address(this));
        } else if (
            step == 11 && address(staking) == address(0) && address(vibesToken) != address(0)
        ) {
            staking = new VibesStaking(address(vibesToken), address(0));
        } else if (
            step == 12 && address(stakerRewards) == address(0) && address(staking) != address(0)
                && address(router) != address(0)
        ) {
            stakerRewards = new VibesStakerRewards(address(this), address(staking), address(router));
        }
    }

    function wireStep(uint256 seed) external {
        uint256 step = seed % 12;

        if (step == 0 && address(router) != address(0) && address(escrowFactory) != address(0)) {
            try VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory)) { }
                catch { }
        } else if (step == 1 && address(router) != address(0) && address(lpLocker) != address(0)) {
            try VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker))) { }
                catch { }
        } else if (step == 2 && address(router) != address(0)) {
            try VibesRouterExtension(address(router)).setOpsWallet(opsWallet) { } catch { }
        } else if (step == 3 && address(router) != address(0)) {
            try VibesRouterExtension(address(router)).setOperationsAdmin(address(this)) { }
                catch { }
        } else if (step == 4 && address(router) != address(0)) {
            try VibesRouterExtension(address(router)).setTrustedLaunchSigner(address(0)) { }
                catch { }
        } else if (
            step == 5 && address(router) != address(0) && address(communityFactory) != address(0)
        ) {
            try VibesRouterExtension(address(router))
                .setCommunityRewardsFactory(address(communityFactory)) { }
                catch { }
        } else if (step == 6 && address(registry) != address(0) && address(router) != address(0)) {
            try registry.authorizeRouter(address(router)) { } catch { }
        } else if (step == 7 && address(lpLocker) != address(0) && address(router) != address(0)) {
            try lpLocker.setAuthorizedRouter(address(router)) { } catch { }
        } else if (
            step == 8 && address(lpLocker) != address(0) && address(feeClaimerImpl) != address(0)
        ) {
            try lpLocker.setFeeClaimerImplementation(address(feeClaimerImpl)) { } catch { }
        } else if (step == 9 && address(escrowFactory) != address(0)) {
            try escrowFactory.lockTimeOracle() { } catch { }
        } else if (
            step == 10 && address(router) != address(0) && address(stakerRewards) != address(0)
        ) {
            try VibesRouterExtension(address(router))
                .setStakerRewardsContract(address(stakerRewards)) { }
                catch { }
        } else if (
            step == 11 && address(staking) != address(0) && address(stakerRewards) != address(0)
        ) {
            try staking.setSnapshotAuthorized(address(stakerRewards), true) { } catch { }
        }
    }

    function toggleStakerAllocationDisabled(bool disabled) external {
        if (address(router) == address(0)) return;
        try VibesRouterExtension(address(router)).setStakerAllocationDisabled(disabled) { }
            catch { }
    }

    function attackerStep(uint256 seed) external {
        uint256 step = seed % 5;

        if (step == 0 && address(registry) != address(0)) {
            vm.prank(attacker);
            try registry.authorizeRouter(attacker) { } catch { }
            if (registry.authorizedRouters(attacker)) ghost_attackerCriticalWrite = true;
        } else if (step == 1 && address(lpLocker) != address(0)) {
            vm.prank(attacker);
            try lpLocker.setAuthorizedRouter(attacker) { } catch { }
            if (lpLocker.authorizedRouter() == attacker) ghost_attackerCriticalWrite = true;
        } else if (step == 2 && address(router) != address(0)) {
            vm.prank(attacker);
            try VibesRouterExtension(address(router)).setOpsWallet(attacker) { } catch { }
            if (router.opsWallet() == attacker) ghost_attackerCriticalWrite = true;
        } else if (step == 3 && address(escrowFactory) != address(0)) {
            vm.prank(attacker);
            try escrowFactory.setAuthorizedRouter(attacker) { } catch { }
            if (escrowFactory.authorizedRouter() == attacker) ghost_attackerCriticalWrite = true;
        } else if (step == 4 && address(tokenFactory) != address(0)) {
            vm.prank(attacker);
            try tokenFactory.deployToken("Permissionless", "PERM", 18, 1 ether, attacker) returns (
                address
            ) {
            // Permissionless token deployment is intentional and not a critical deployment write.
            }
                catch { }
        }
    }

    function tryLaunchAndFinalize(uint256 seed) external {
        _attemptSmoke(seed, false);
    }

    function markCompleteAndSmoke(uint256 seed) external {
        if (!_isDeploymentComplete()) {
            ghost_incompleteReadinessRejections++;
            return;
        }
        if (!_attemptSmoke(seed, true)) {
            ghost_completeSmokeFailed = true;
        }
    }

    function isDeploymentComplete() external view returns (bool) {
        return _isDeploymentComplete();
    }

    function _isDeploymentComplete() internal view returns (bool) {
        if (
            address(tokenFactory) == address(0) || address(registry) == address(0)
                || address(escrowImpl) == address(0) || address(escrowFactory) == address(0)
                || address(lpLocker) == address(0) || address(feeClaimerImpl) == address(0)
                || address(extension) == address(0) || address(router) == address(0)
                || address(communityFactory) == address(0)
        ) return false;

        if (address(router.tokenFactory()) != address(tokenFactory)) return false;
        if (address(router.registry()) != address(registry)) return false;
        if (address(router.escrowFactory()) != address(escrowFactory)) return false;
        if (address(router.lpLocker()) != address(lpLocker)) return false;
        if (router.opsWallet() == address(0)) return false;
        if (!registry.authorizedRouters(address(router))) return false;
        if (lpLocker.authorizedRouter() != address(router)) return false;
        if (lpLocker.feeClaimerImplementation() != address(feeClaimerImpl)) return false;
        if (escrowFactory.authorizedRouter() != address(router)) return false;
        if (escrowFactory.lpLocker() != address(lpLocker)) return false;
        if (escrowFactory.timeOracle() != address(0) || !escrowFactory.timeOracleLocked()) {
            return false;
        }
        if (router.pendingOwner() != address(0)) return false;

        if (!router.stakerAllocationDisabled()) {
            if (address(vibesToken) == address(0) || address(staking) == address(0)) return false;
            if (address(stakerRewards) == address(0)) return false;
            if (router.stakerRewardsContract() != address(stakerRewards)) return false;
            if (stakerRewards.authorizedRouter() != address(router)) return false;
            if (stakerRewards.stakingContract() != address(staking)) return false;
            if (!staking.snapshotAuthorized(address(stakerRewards))) return false;
        }

        return true;
    }

    function _attemptSmoke(uint256 seed, bool requireRewardsActive) internal returns (bool) {
        if (smokeAttempts >= 4) return true;
        smokeAttempts++;

        if (address(router) == address(0)) return false;
        vm.deal(founder, 100 ether);
        vm.deal(backer, 100 ether);

        if (address(staking) != address(0) && address(vibesToken) != address(0)) {
            _ensureStakeBeforeReward();
        }

        uint256 deadline = block.timestamp + 2 days + (seed % 5 days);

        vm.prank(founder);
        try router.launchWithCampaign{ value: DEPOSIT }(
            "Deploy Fuzz",
            "DFUZZ",
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
            deadline,
            0,
            0,
            0,
            0,
            0,
            ""
        ) returns (
            address token, address escrow, address vesting
        ) {
            vesting;
            vm.prank(backer);
            try VibesTranchEscrow(payable(escrow)).contribute{ value: GOAL }(0, 0, "") { }
            catch {
                return false;
            }

            try VibesTranchEscrow(payable(escrow)).finalize() { }
            catch {
                return false;
            }

            bool fullyComplete = uint8(router.finalizationPhase(token))
                == uint8(VibesRouterStorage.FinalizationPhase.FullyComplete);
            if (!fullyComplete) return false;

            if (address(stakerRewards) != address(0) && !router.stakerAllocationDisabled()) {
                (,,,,, bool active) = stakerRewards.getRewardsInfo(escrow);

                uint256 rewardsBalance = IERC20(token).balanceOf(address(stakerRewards));
                bool snapshotAuthorized = address(staking) != address(0)
                    && staking.snapshotAuthorized(address(stakerRewards));

                if (rewardsBalance > 0 && !active && !snapshotAuthorized) {
                    ghost_silentBrokenFinalization = true;
                }
                if (requireRewardsActive && !active) return false;
            }

            return true;
        } catch {
            return false;
        }
    }

    function _ensureStakeBeforeReward() internal {
        if (staking.stakedBalance(staker) > 0) return;

        assertTrue(vibesToken.transfer(staker, 10_000 ether));
        vm.startPrank(staker);
        vibesToken.approve(address(staking), type(uint256).max);
        try staking.stake(10_000 ether, 0, 0, "") { } catch { }
        vm.stopPrank();
        skip(1);
    }
}

contract DeploymentStatefulInvariants is Test {
    DeploymentFuzzHandler handler;

    function setUp() public {
        handler = new DeploymentFuzzHandler();
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.deployStep.selector;
        selectors[1] = handler.wireStep.selector;
        selectors[2] = handler.toggleStakerAllocationDisabled.selector;
        selectors[3] = handler.attackerStep.selector;
        selectors[4] = handler.tryLaunchAndFinalize.selector;
        selectors[5] = handler.markCompleteAndSmoke.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_attackersCannotOwnCriticalDeploymentWiring() public view {
        assertFalse(
            handler.ghost_attackerCriticalWrite(), "attacker seized critical deployment wiring"
        );
    }

    function invariant_noSilentBrokenRewardFinalization() public view {
        assertFalse(
            handler.ghost_silentBrokenFinalization(),
            "finalization completed while reward notification was silently broken"
        );
    }

    function invariant_completeDeploymentSmokeDoesNotFail() public view {
        assertFalse(
            handler.ghost_completeSmokeFailed(), "readiness-complete deployment failed smoke test"
        );
    }

    function test_handlerDetectsMissingSnapshotAuthorizationAsSilentBrokenFinalization() public {
        for (uint256 step = 0; step <= 12; step++) {
            handler.deployStep(step);
        }

        for (uint256 step = 0; step <= 10; step++) {
            handler.wireStep(step);
        }

        assertFalse(
            handler.isDeploymentComplete(), "deployment should be incomplete without snapshot auth"
        );
        handler.tryLaunchAndFinalize(0);
        assertTrue(
            handler.ghost_silentBrokenFinalization(),
            "handler should flag completed finalization with inactive staker rewards"
        );
    }
}
