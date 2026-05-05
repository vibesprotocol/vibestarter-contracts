// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {VibesLaunchRouterV2} from "../src/VibesLaunchRouterV2.sol";
import {VibesRouterExtension} from "../src/VibesRouterExtension.sol";
import {VibesRouterStorage} from "../src/VibesRouterStorage.sol";
import {VibesTokenFactory} from "../src/VibesTokenFactory.sol";
import {VibesRegistry} from "../src/VibesRegistry.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesLPLocker} from "../src/VibesLPLocker.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockAerodromeRouter.sol";

/// @dev PC-01 tests: admin-toggleable staker-allocation disable.
///      Verifies that when `stakerAllocationDisabled` is true, the 2.5% ecosystem slice
///      is absorbed into the backer slice and no staker-rewards notification occurs.
contract VibesStakerAllocationDisabledTest is Test {
    VibesLaunchRouterV2 public router;
    VibesRouterExtension public extension;
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrowFactory public escrowFactory;
    VibesLPLocker public lpLocker;
    MockAerodromeRouter public aeroRouter;
    MockTimeOracle public timeOracle;
    VibesTranchEscrow public escrowImpl;

    address public owner;
    address public founder = makeAddr("founder");
    address public opsWallet = makeAddr("opsWallet");
    address public stakerRewardsAddr = makeAddr("stakerRewards");
    address public stranger = makeAddr("stranger");

    address public weth = makeAddr("weth");
    address public aeroFactory = makeAddr("aeroFactory");

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant DEPOSIT = 0.01 ether;

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

        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker)));
        VibesRouterExtension(address(router)).setOpsWallet(opsWallet);
        VibesRouterExtension(address(router)).setStakerRewardsContract(stakerRewardsAddr);

        registry.authorizeRouter(address(router));

        vm.deal(founder, 100 ether);
        vm.deal(owner, 100 ether);
    }

    // ============================================
    // DEFAULT STATE (flag false — existing behaviour)
    // ============================================

    function test_DefaultFlagIsFalse() public view {
        assertEq(VibesRouterStorage(address(router)).stakerAllocationDisabled(), false);
    }

    function test_Default_LaunchAllocatesTwoAndAHalfToStakers() public {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1000, 0, 0, 0, ""
        );

        (uint256 tokenAmount, uint256 backerAllocation, uint256 stakerAllocation) =
            router.pendingLP(token);

        // Expected: founder 5% + treasury 10% + LP 15% + staker 2.5% + backer 67.5% = 100%
        assertEq(stakerAllocation, TOTAL_SUPPLY * 250 / 10000, "staker 2.5%");
        assertEq(tokenAmount, TOTAL_SUPPLY * 1500 / 10000, "LP 15%");
        assertEq(backerAllocation, TOTAL_SUPPLY * 6750 / 10000, "backer 67.5%");

        _assertConservation(token, backerAllocation, tokenAmount, stakerAllocation, 500, 1000);
    }

    // ============================================
    // ADMIN TOGGLE
    // ============================================

    function test_SetFlag_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);
    }

    function test_SetFlag_FlipsValue() public {
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);
        assertEq(VibesRouterStorage(address(router)).stakerAllocationDisabled(), true);

        VibesRouterExtension(address(router)).setStakerAllocationDisabled(false);
        assertEq(VibesRouterStorage(address(router)).stakerAllocationDisabled(), false);
    }

    function test_SetFlag_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit VibesRouterStorage.StakerAllocationDisabledSet(true);
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);
    }

    // ============================================
    // DISABLED BEHAVIOUR (flag true)
    // ============================================

    function test_Disabled_LaunchAllocatesZeroToStakers() public {
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);

        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1000, 0, 0, 0, ""
        );

        (uint256 tokenAmount, uint256 backerAllocation, uint256 stakerAllocation) =
            router.pendingLP(token);

        // Expected: founder 5% + treasury 10% + LP 15% + staker 0% + backer 70% = 100%
        assertEq(stakerAllocation, 0, "staker 0%");
        assertEq(tokenAmount, TOTAL_SUPPLY * 1500 / 10000, "LP 15%");
        assertEq(backerAllocation, TOTAL_SUPPLY * 7000 / 10000, "backer 70%");

        _assertConservation(token, backerAllocation, tokenAmount, stakerAllocation, 500, 1000);
    }

    function test_Disabled_EmitsPerLaunchEvent() public {
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);

        uint256 deadline = block.timestamp + 14 days;
        vm.recordLogs();
        vm.prank(founder);
        (address token, address escrow, ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1000, 0, 0, 0, ""
        );

        bool found = false;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("StakerAllocationDisabledForLaunch(address,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), token);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), escrow);
                found = true;
                break;
            }
        }
        assertTrue(found, "StakerAllocationDisabledForLaunch not emitted");
    }

    function test_Disabled_NoEventWhenFlagFalse() public {
        uint256 deadline = block.timestamp + 14 days;
        vm.recordLogs();
        vm.prank(founder);
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1000, 0, 0, 0, ""
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("StakerAllocationDisabledForLaunch(address,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                revert("Event should NOT be emitted when flag is false");
            }
        }
    }

    function test_FlagFlipBackToEnabled_NextLaunchGetsStakerSlice() public {
        // Flip ON
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(true);

        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (address token1, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "A", "A", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1000, 0, 0, 0, ""
        );
        ( , , uint256 stakerAlloc1) = router.pendingLP(token1);
        assertEq(stakerAlloc1, 0);

        // Flip OFF
        VibesRouterExtension(address(router)).setStakerAllocationDisabled(false);

        vm.prank(founder);
        (address token2, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "B", "B", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 500, 1000, 0, 0, 0, ""
        );
        ( , , uint256 stakerAlloc2) = router.pendingLP(token2);
        assertEq(stakerAlloc2, TOTAL_SUPPLY * 250 / 10000);
    }

    // ============================================
    // CONSERVATION HELPER
    // ============================================

    /// @dev Verify that founder + treasury + LP + staker + backer = totalSupply.
    function _assertConservation(
        address token,
        uint256 backerTokens,
        uint256 lpTokens,
        uint256 stakerTokens,
        uint256 founderBps,
        uint256 treasuryBps
    ) internal view {
        uint256 founderTokens = TOTAL_SUPPLY * founderBps / 10000;
        uint256 treasuryTokens = TOTAL_SUPPLY * treasuryBps / 10000;
        uint256 sum = founderTokens + treasuryTokens + lpTokens + stakerTokens + backerTokens;
        assertEq(sum, TOTAL_SUPPLY, "conservation");

        // Router holds backer + LP + staker tokens until finalisation
        uint256 routerBal = IERC20(token).balanceOf(address(router));
        assertEq(routerBal, backerTokens + lpTokens + stakerTokens, "router balance");
    }
}
