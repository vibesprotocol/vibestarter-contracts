// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";

contract VibesTranchEscrowFactoryTest is Test {
    VibesTranchEscrowFactory public factory;
    VibesTranchEscrow public implementation;

    address public admin = makeAddr("admin");
    address public platformWallet = makeAddr("platform");
    address public router = makeAddr("router");
    address public lpLocker = makeAddr("lpLocker");
    address public founder = makeAddr("founder");
    address public token = makeAddr("token");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        implementation = new VibesTranchEscrow();

        factory = new VibesTranchEscrowFactory(
            address(implementation),
            admin,
            platformWallet,
            address(0), // timeOracle (production mode)
            router,
            lpLocker,
            address(0)  // trustedSigner (disabled for tests)
        );
    }

    // ============ Constructor ============

    function test_constructor() public view {
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.admin(), admin);
        assertEq(factory.platformWallet(), platformWallet);
        assertEq(factory.timeOracle(), address(0));
        assertEq(factory.authorizedRouter(), router);
        assertEq(factory.lpLocker(), lpLocker);
    }

    function test_constructor_revertsZeroImpl() public {
        vm.expectRevert(VibesTranchEscrowFactory.ZeroAddress.selector);
        new VibesTranchEscrowFactory(address(0), admin, platformWallet, address(0), router, lpLocker, address(0));
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert(VibesTranchEscrowFactory.ZeroAddress.selector);
        new VibesTranchEscrowFactory(
            address(implementation), address(0), platformWallet, address(0), router, lpLocker, address(0)
        );
    }

    function test_constructor_revertsZeroPlatform() public {
        vm.expectRevert(VibesTranchEscrowFactory.ZeroAddress.selector);
        new VibesTranchEscrowFactory(
            address(implementation), admin, address(0), address(0), router, lpLocker, address(0)
        );
    }

    function test_constructor_revertsZeroRouter() public {
        vm.expectRevert(VibesTranchEscrowFactory.ZeroAddress.selector);
        new VibesTranchEscrowFactory(
            address(implementation), admin, platformWallet, address(0), address(0), lpLocker, address(0)
        );
    }

    function test_constructor_revertsZeroLPLocker() public {
        vm.expectRevert(VibesTranchEscrowFactory.ZeroAddress.selector);
        new VibesTranchEscrowFactory(
            address(implementation), admin, platformWallet, address(0), router, address(0), address(0)
        );
    }

    // ============ Create Escrow ============

    function test_createEscrow() public {
        uint256 deadline = block.timestamp + 14 days;

        vm.prank(router);
        address escrow = factory.createEscrow(
            founder,
            token,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether,
            0,
            deadline,
            0 // immediate
        );

        assertTrue(escrow != address(0));
        assertTrue(factory.isEscrow(escrow));
        assertEq(factory.totalEscrows(), 1);
    }

    function test_createEscrow_revertsNotRouter() public {
        vm.prank(stranger);
        vm.expectRevert(VibesTranchEscrowFactory.OnlyRouter.selector);
        factory.createEscrow(founder, token, VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0, block.timestamp + 14 days, 0);
    }

    function test_createEscrow_revertsDeadlineInPast() public {
        vm.prank(router);
        vm.expectRevert(VibesTranchEscrowFactory.DeadlineInPast.selector);
        factory.createEscrow(founder, token, VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0, block.timestamp - 1, 0);
    }

    function test_createEscrow_revertsDeadlineTooFar() public {
        vm.prank(router);
        vm.expectRevert(VibesTranchEscrowFactory.DeadlineTooFar.selector);
        factory.createEscrow(
            founder, token, VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0,
            block.timestamp + 31 days, 0
        );
    }

    function test_createEscrow_scheduledRaise() public {
        uint256 raiseStart = block.timestamp + 5 days;
        uint256 deadline = raiseStart + 14 days;

        vm.prank(router);
        address escrow = factory.createEscrow(
            founder, token, VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0, deadline, raiseStart
        );

        assertTrue(escrow != address(0));
    }

    function test_createEscrow_revertsRaiseStartInPast() public {
        // Warp forward so block.timestamp - 1 is nonzero (default block.timestamp is 1,
        // and raiseStart == 0 is treated as "immediate" which skips validation)
        vm.warp(1000);
        vm.prank(router);
        vm.expectRevert(VibesTranchEscrowFactory.RaiseStartInPast.selector);
        factory.createEscrow(
            founder, token, VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0,
            block.timestamp + 14 days, block.timestamp - 1
        );
    }

    function test_createEscrow_revertsRaiseStartTooFar() public {
        uint256 raiseStart = block.timestamp + 31 days;
        vm.prank(router);
        vm.expectRevert(VibesTranchEscrowFactory.RaiseStartTooFar.selector);
        factory.createEscrow(
            founder, token, VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0,
            raiseStart + 14 days, raiseStart
        );
    }

    function test_createEscrow_multipleEscrows() public {
        vm.startPrank(router);
        factory.createEscrow(founder, token, VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0, block.timestamp + 14 days, 0);
        factory.createEscrow(founder, makeAddr("token2"), VibesTranchEscrow.RaiseType.OpenEnded, 0, 5 ether, block.timestamp + 14 days, 0);
        vm.stopPrank();

        assertEq(factory.totalEscrows(), 2);
    }

    // ============ Predict Address ============

    function test_predictEscrowAddress() public {
        uint256 deadline = block.timestamp + 14 days;
        address predicted = factory.predictEscrowAddress(founder, token, deadline, 0);

        vm.prank(router);
        address actual = factory.createEscrow(founder, token, VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0, deadline, 0);

        assertEq(predicted, actual);
    }

    // ============ Admin Functions ============

    function test_setAdmin_setsPendingAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        factory.setAdmin(newAdmin);
        assertEq(factory.pendingAdmin(), newAdmin);
        assertEq(factory.admin(), admin); // not transferred yet
    }

    function test_setAdmin_acceptCompletes() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        factory.setAdmin(newAdmin);
        vm.prank(newAdmin);
        factory.acceptAdmin();
        assertEq(factory.admin(), newAdmin);
        assertEq(factory.pendingAdmin(), address(0));
    }

    function test_setAdmin_revertsNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(VibesTranchEscrowFactory.OnlyAdmin.selector);
        factory.setAdmin(stranger);
    }

    function test_setAdmin_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert(VibesTranchEscrowFactory.ZeroAddress.selector);
        factory.setAdmin(address(0));
    }

    function test_setPlatformWallet() public {
        address newWallet = makeAddr("newWallet");
        vm.prank(admin);
        factory.setPlatformWallet(newWallet);
        assertEq(factory.platformWallet(), newWallet);
    }

    function test_setTimeOracle() public {
        address newOracle = makeAddr("oracle");
        vm.prank(admin);
        factory.setTimeOracle(newOracle);
        assertEq(factory.timeOracle(), newOracle);
    }

    // ============ lockTimeOracle ============

    function test_lockTimeOracle_initiallyUnlocked() public view {
        assertFalse(factory.timeOracleLocked(), "timeOracleLocked should default to false");
    }

    function test_lockTimeOracle_setsLatch() public {
        vm.prank(admin);
        factory.lockTimeOracle();
        assertTrue(factory.timeOracleLocked(), "lockTimeOracle should latch the flag");
    }

    function test_lockTimeOracle_emitsEvent() public {
        // Lock with the production-default value (address(0)) -- this is the expected
        // post-deploy mainnet sequence.
        vm.expectEmit(true, true, true, true);
        emit VibesTranchEscrowFactory.TimeOracleLockedPermanently(address(0), admin);
        vm.prank(admin);
        factory.lockTimeOracle();
    }

    function test_lockTimeOracle_revertsOnDoubleCall() public {
        vm.prank(admin);
        factory.lockTimeOracle();
        vm.prank(admin);
        vm.expectRevert(VibesTranchEscrowFactory.TimeOracleAlreadyLocked.selector);
        factory.lockTimeOracle();
    }

    function test_lockTimeOracle_revertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(VibesTranchEscrowFactory.OnlyAdmin.selector);
        factory.lockTimeOracle();
    }

    function test_setTimeOracle_revertsAfterLock() public {
        // Set a non-zero oracle first, then lock.
        address oracle = makeAddr("oracle");
        vm.prank(admin);
        factory.setTimeOracle(oracle);
        vm.prank(admin);
        factory.lockTimeOracle();

        // setTimeOracle is now permanently disabled.
        vm.prank(admin);
        vm.expectRevert(VibesTranchEscrowFactory.TimeOracleIsLocked.selector);
        factory.setTimeOracle(makeAddr("differentOracle"));

        // Locked value is preserved.
        assertEq(factory.timeOracle(), oracle);
    }

    function test_setTimeOracle_revertsForNonAdminBeforeLock() public {
        vm.prank(stranger);
        vm.expectRevert(VibesTranchEscrowFactory.OnlyAdmin.selector);
        factory.setTimeOracle(makeAddr("oracle"));
    }

    function test_lockTimeOracle_lockOnZeroIsThePostDeployMainnetFlow() public {
        // Mirror the intended mainnet runbook: factory deployed with timeOracle=0
        // then locked from the protocol-admin Safe so future raises can never inherit
        // a malicious oracle. This test asserts that flow is reachable in one tx and
        // produces the locked-at-zero state.
        assertEq(factory.timeOracle(), address(0));
        assertFalse(factory.timeOracleLocked());

        vm.prank(admin);
        factory.lockTimeOracle();

        assertEq(factory.timeOracle(), address(0));
        assertTrue(factory.timeOracleLocked());

        // Confirm setTimeOracle is permanently disabled even with an admin caller.
        vm.prank(admin);
        vm.expectRevert(VibesTranchEscrowFactory.TimeOracleIsLocked.selector);
        factory.setTimeOracle(makeAddr("evilOracle"));
    }

    function test_setAuthorizedRouter() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(admin);
        factory.setAuthorizedRouter(newRouter);
        assertEq(factory.authorizedRouter(), newRouter);
    }

    function test_setLPLocker() public {
        address newLocker = makeAddr("newLocker");
        vm.prank(admin);
        factory.setLPLocker(newLocker);
        assertEq(factory.lpLocker(), newLocker);
    }

    // ============ View Functions ============

    function test_getFounderEscrows() public {
        uint256 deadline = block.timestamp + 14 days;
        vm.startPrank(router);
        factory.createEscrow(founder, token, VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0, deadline, 0);
        factory.createEscrow(founder, makeAddr("t2"), VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0, deadline, 0);
        vm.stopPrank();

        address[] memory escrows = factory.getFounderEscrows(founder);
        assertEq(escrows.length, 2);
    }

    function test_getAllEscrows() public {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(router);
        factory.createEscrow(founder, token, VibesTranchEscrow.RaiseType.FixedGoal, 10 ether, 0, deadline, 0);

        address[] memory all = factory.getAllEscrows();
        assertEq(all.length, 1);
    }
}
