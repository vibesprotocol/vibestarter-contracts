// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {VibesLaunchRouterV2} from "../src/VibesLaunchRouterV2.sol";
import {VibesRouterExtension} from "../src/VibesRouterExtension.sol";
import {VibesRouterStorage} from "../src/VibesRouterStorage.sol";
import {VibesCommunityRewards} from "../src/VibesCommunityRewards.sol";
import {VibesCommunityRewardsFactory} from "../src/VibesCommunityRewardsFactory.sol";
import {VibesTokenFactory} from "../src/VibesTokenFactory.sol";
import {VibesRegistry} from "../src/VibesRegistry.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesLPLocker} from "../src/VibesLPLocker.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockAerodromeRouter.sol";

/// @dev PC-03 tests: atomic admin-pre-authorized per-launcher Community Rewards deployment.
///      Verifies that when admin pre-authorizes a launcher, the router atomically deploys
///      a fresh VibesCommunityRewards contract bound to the newly-deployed token and
///      transfers the slice to it, all within a single launchWithCampaign call.
contract VibesCommunityAllocationForLaunchTest is Test {
    VibesLaunchRouterV2 public router;
    VibesRouterExtension public extension;
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrowFactory public escrowFactory;
    VibesLPLocker public lpLocker;
    MockAerodromeRouter public aeroRouter;
    MockTimeOracle public timeOracle;
    VibesTranchEscrow public escrowImpl;
    VibesCommunityRewardsFactory public communityFactory;

    address public owner;
    address public vibesLauncher = makeAddr("vibesLauncher");
    address public regularFounder = makeAddr("regularFounder");
    address public communityAdmin = makeAddr("communityAdmin"); // admin of the new VibesCommunityRewards
    address public opsWallet = makeAddr("opsWallet");
    address public stakerRewardsAddr = makeAddr("stakerRewards");
    address public stranger = makeAddr("stranger");

    address public weth = makeAddr("weth");
    address public aeroFactory = makeAddr("aeroFactory");

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant DEPOSIT = 0.01 ether;
    uint256 public constant CLIFF = 180 days;

    bytes32 public capsuleHash = keccak256("capsule");
    bytes32 public proofHash = keccak256("proof");

    function setUp() public {
        owner = address(this);

        tokenFactory = new VibesTokenFactory();
        registry = new VibesRegistry();
        aeroRouter = new MockAerodromeRouter(weth, aeroFactory);
        lpLocker = new VibesLPLocker(address(aeroRouter), aeroFactory);
        timeOracle = new MockTimeOracle();
        escrowImpl = new VibesTranchEscrow();

        extension = new VibesRouterExtension();
        router = new VibesLaunchRouterV2(
            address(extension),
            address(tokenFactory),
            address(registry),
            address(0),
            payable(address(0))
        );

        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl),
            owner,
            makeAddr("platform"),
            address(timeOracle),
            address(router),
            address(lpLocker),
            address(0)
        );

        communityFactory = new VibesCommunityRewardsFactory();

        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker)));
        VibesRouterExtension(address(router)).setOpsWallet(opsWallet);
        VibesRouterExtension(address(router)).setStakerRewardsContract(stakerRewardsAddr);
        VibesRouterExtension(address(router)).setCommunityRewardsFactory(address(communityFactory));

        registry.authorizeRouter(address(router));

        vm.deal(vibesLauncher, 100 ether);
        vm.deal(regularFounder, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    // ============================================
    // SETTER
    // ============================================

    function test_Setter_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );
    }

    function test_Setter_RevertsZeroLauncher() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            address(0), 1500, CLIFF, communityAdmin
        );
    }

    function test_Setter_RevertsExceedsCap() public {
        vm.expectRevert(VibesRouterStorage.InvalidAllocation.selector);
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 2001, CLIFF, communityAdmin
        );
    }

    function test_Setter_RevertsNonZeroBpsWithZeroAdmin() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, address(0)
        );
    }

    function test_Setter_RevertsNonZeroBpsWithZeroCliff() public {
        vm.expectRevert(VibesRouterStorage.InvalidAllocation.selector);
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, 0, communityAdmin
        );
    }

    function test_Setter_RevokeWithZeroBpsAllowed() public {
        // Authorize first
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );
        // Revoke — zero bps, other params ignored
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 0, 0, address(0)
        );
        (uint256 bps, uint256 cliff, address admin_) = router.communityConfigForLaunch(vibesLauncher);
        assertEq(bps, 0);
        assertEq(cliff, 0);
        assertEq(admin_, address(0));
    }

    function test_Setter_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit VibesRouterStorage.CommunityAllocationSet(vibesLauncher, 1500, CLIFF, communityAdmin);
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );
    }

    function test_Setter_AllowsExactlyCapValue() public {
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 2000, CLIFF, communityAdmin
        );
        (uint256 bps, uint256 cliff, address admin_) = router.communityConfigForLaunch(vibesLauncher);
        assertEq(bps, 2000);
        assertEq(cliff, CLIFF);
        assertEq(admin_, communityAdmin);
    }

    // ============================================
    // DEFAULT STATE — UNAUTHORIZED LAUNCHER
    // ============================================

    function test_Default_UnauthorizedFounderDeploysNoCommunityContract() public {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(regularFounder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1000, 0, 0, 0, ""
        );

        (uint256 tokenAmount, uint256 backerAllocation, uint256 stakerAllocation) =
            router.pendingLP(token);

        // Standard behaviour: founder 5% + treasury 10% + LP 15% + staker 2.5% + backer 67.5%
        assertEq(stakerAllocation, TOTAL_SUPPLY * 250 / 10000, "staker 2.5%");
        assertEq(tokenAmount, TOTAL_SUPPLY * 1500 / 10000, "LP 15%");
        assertEq(backerAllocation, TOTAL_SUPPLY * 6750 / 10000, "backer 67.5%");

        // No community contract deployed
        assertEq(router.tokenToCommunityRewards(token), address(0));
    }

    // ============================================
    // AUTHORIZED LAUNCHER — ATOMIC DEPLOYMENT
    // ============================================

    function test_Authorized_VibesRaiseAtomicDeployment() public {
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);

        uint256 launchTimestamp = block.timestamp;
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(vibesLauncher);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Vibes", "VIBES", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline,
            500,   // founder 5%
            1500,  // treasury 15%
            0, 0, 0, ""
        );

        // Community contract deployed
        address crAddr = router.tokenToCommunityRewards(token);
        assertTrue(crAddr != address(0), "community contract deployed");

        VibesCommunityRewards cr = VibesCommunityRewards(crAddr);

        // Verify construction params
        assertEq(address(cr.token()), token, "token bound correctly");
        assertEq(cr.unlockTime(), launchTimestamp + CLIFF, "cliff = launch + 180d");
        assertEq(cr.admin(), communityAdmin, "admin set");

        // Verify 15% transferred atomically
        assertEq(IERC20(token).balanceOf(crAddr), TOTAL_SUPPLY * 1500 / 10000, "community 15%");

        // Verify backer slice = 50% exactly
        (uint256 tokenAmount, uint256 backerAllocation, uint256 stakerAllocation) =
            router.pendingLP(token);
        assertEq(stakerAllocation, 0, "staker 0%");
        assertEq(tokenAmount, TOTAL_SUPPLY * 1500 / 10000, "LP 15%");
        assertEq(backerAllocation, TOTAL_SUPPLY * 5000 / 10000, "backer 50% floor");
    }

    function test_Authorized_ConfigConsumedAndClearedAfterLaunch() public {
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);

        uint256 deadline = block.timestamp + 14 days;
        vm.prank(vibesLauncher);
        router.launchWithCampaign{value: DEPOSIT}(
            "Vibes", "VIBES", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1500, 0, 0, 0, ""
        );

        (uint256 bps, uint256 cliff, address admin_) = router.communityConfigForLaunch(vibesLauncher);
        assertEq(bps, 0, "bps cleared");
        assertEq(cliff, 0, "cliff cleared");
        assertEq(admin_, address(0), "admin cleared");
    }

    function test_Authorized_SecondLaunchBySameLauncherGetsNoCommunitySlice() public {
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);

        uint256 deadline = block.timestamp + 14 days;
        // First launch consumes the authorization
        vm.prank(vibesLauncher);
        (address token1, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "A", "A", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1500, 0, 0, 0, ""
        );
        assertTrue(router.tokenToCommunityRewards(token1) != address(0), "first token has CR");

        // Second launch by the same wallet — no community slice, no CR deployed
        vm.prank(vibesLauncher);
        (address token2, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "B", "B", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1500, 0, 0, 0, ""
        );
        assertEq(router.tokenToCommunityRewards(token2), address(0), "second token no CR");

        // Second launch: founder 5% + treasury 15% + LP 15% + staker 0% + backer 65%
        (, uint256 backerAlloc2, ) = router.pendingLP(token2);
        assertEq(backerAlloc2, TOTAL_SUPPLY * 6500 / 10000, "backer 65% on second");
    }

    function test_Authorized_EmitsConsumedEventWithDeployedAddress() public {
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);

        uint256 deadline = block.timestamp + 14 days;
        vm.recordLogs();
        vm.prank(vibesLauncher);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Vibes", "VIBES", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1500, 0, 0, 0, ""
        );

        address expectedCr = router.tokenToCommunityRewards(token);

        bool found = false;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("CommunityAllocationConsumed(address,address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), token);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), vibesLauncher);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), expectedCr);
                uint256 amount = abi.decode(logs[i].data, (uint256));
                assertEq(amount, TOTAL_SUPPLY * 1500 / 10000);
                found = true;
                break;
            }
        }
        assertTrue(found, "CommunityAllocationConsumed not emitted");
    }

    // ============================================
    // ISOLATION — AUTHORIZATION IS PER-WALLET
    // ============================================

    function test_Isolation_UnauthorizedLauncherCannotUseOthersConfig() public {
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );

        uint256 deadline = block.timestamp + 14 days;
        vm.prank(regularFounder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Other", "OTH", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1000, 0, 0, 0, ""
        );
        assertEq(router.tokenToCommunityRewards(token), address(0), "no CR for unauthorized");

        // vibesLauncher's config is still intact
        (uint256 bps, , ) = router.communityConfigForLaunch(vibesLauncher);
        assertEq(bps, 1500, "vibesLauncher config still set");
    }

    // ============================================
    // BACKER FLOOR (50%) ENFORCEMENT
    // ============================================

    function test_BackerFloor_RevertsBelow50Percent() public {
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 2000, CLIFF, communityAdmin
        );
        // founder 5% + treasury 15% (combined cap = 20%, exact) + LP 15% + eco 2.5% +
        // community 20% = 57.5%. Backers = 42.5% → below 50% floor → revert.
        // (The old values 750/1750 now trip MAX_FOUNDER_PLUS_TREASURY_BPS first,
        //  so we dial founder+treasury down to the 20% cap and max the community
        //  slice to reach the backer-floor violation we're testing.)

        uint256 deadline = block.timestamp + 14 days;
        vm.prank(vibesLauncher);
        vm.expectRevert(VibesRouterStorage.BackerAllocationTooLow.selector);
        router.launchWithCampaign{value: DEPOSIT}(
            "Too", "TOO", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1500, 0, 0, 0, ""
        );
    }

    function test_BackerFloor_ExactlyAt50PercentPasses() public {
        // $VIBES shape: founder 5% + treasury 15% + LP 15% + eco 0% + community 15% = 50%
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);

        uint256 deadline = block.timestamp + 14 days;
        vm.prank(vibesLauncher);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Vibes", "VIBES", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1500, 0, 0, 0, ""
        );
        ( , uint256 backerAlloc, ) = router.pendingLP(token);
        assertEq(backerAlloc, TOTAL_SUPPLY * 5000 / 10000, "exactly 50%");
    }

    // ============================================
    // CONSERVATION INVARIANT
    // ============================================

    function test_Conservation_WithCommunitySlice() public {
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);

        uint256 deadline = block.timestamp + 14 days;
        vm.prank(vibesLauncher);
        (address token, , address vesting) = router.launchWithCampaign{value: DEPOSIT}(
            "Vibes", "VIBES", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1500, 0, 0, 0, ""
        );

        address crAddr = router.tokenToCommunityRewards(token);

        uint256 founderBal = IERC20(token).balanceOf(vesting);
        uint256 treasuryBal = IERC20(token).balanceOf(router.tokenToTreasury(token));
        uint256 communityBal = IERC20(token).balanceOf(crAddr);
        uint256 routerBal = IERC20(token).balanceOf(address(router));

        assertEq(founderBal, TOTAL_SUPPLY * 500 / 10000, "founder 5%");
        assertEq(treasuryBal, TOTAL_SUPPLY * 1500 / 10000, "treasury 15%");
        assertEq(communityBal, TOTAL_SUPPLY * 1500 / 10000, "community 15%");
        assertEq(routerBal, TOTAL_SUPPLY * 6500 / 10000, "router holds LP + backer");

        assertEq(founderBal + treasuryBal + communityBal + routerBal, TOTAL_SUPPLY, "conservation");
    }

    // ============================================
    // COMMUNITY REWARDS CONTRACT BEHAVIOUR POST-DEPLOY
    // ============================================

    function test_DeployedContract_CliffEnforced() public {
        VibesRouterExtension(address(router)).setCommunityAllocationForLaunch(
            vibesLauncher, 1500, CLIFF, communityAdmin
        );
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);

        uint256 deadline = block.timestamp + 14 days;
        vm.prank(vibesLauncher);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Vibes", "VIBES", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1500, 0, 0, 0, ""
        );

        VibesCommunityRewards cr = VibesCommunityRewards(router.tokenToCommunityRewards(token));

        // Pre-cliff — createBatch must revert
        vm.prank(communityAdmin);
        vm.expectRevert(VibesCommunityRewards.BeforeCliff.selector);
        cr.createBatch(bytes32(uint256(1)), 1000, 0, bytes32(uint256(0xbeef)));

        // Warp past cliff — now admin can create batches
        vm.warp(block.timestamp + CLIFF + 1);
        vm.prank(communityAdmin);
        cr.createBatch(bytes32(uint256(1)), 1000, 0, bytes32(uint256(0xbeef)));
        assertEq(cr.batchCount(), 1);
    }
}
