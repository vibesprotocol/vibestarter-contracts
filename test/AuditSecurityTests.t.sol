// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Malicious Contracts for Reentrancy Tests ============

/// @notice Contract that attempts reentrancy on claimContributorRefund
contract ReentrantRefundClaimer {
    VibesTranchEscrow public escrow;
    uint256 public attackCount;

    constructor(address _escrow) {
        escrow = VibesTranchEscrow(payable(_escrow));
    }

    function attack() external {
        escrow.claimContributorRefund();
    }

    receive() external payable {
        if (attackCount < 2) {
            attackCount++;
            try escrow.claimContributorRefund() {} catch {}
        }
    }
}

/// @notice Contract that attempts reentrancy on claimTranche
contract ReentrantTrancheClaimer {
    VibesTranchEscrow public escrow;
    uint8 public targetTranche;
    uint256 public attackCount;

    constructor(address _escrow) {
        escrow = VibesTranchEscrow(payable(_escrow));
    }

    function setTarget(uint8 _tranche) external {
        targetTranche = _tranche;
    }

    function attack(uint8 _tranche) external {
        escrow.claimTranche(_tranche);
    }

    receive() external payable {
        if (attackCount < 2) {
            attackCount++;
            try escrow.claimTranche(targetTranche) {} catch {}
        }
    }
}

/// @notice Contract that attempts reentrancy on claimExcessRefund
contract ReentrantExcessClaimer {
    VibesTranchEscrow public escrow;
    uint256 public attackCount;

    constructor(address _escrow) {
        escrow = VibesTranchEscrow(payable(_escrow));
    }

    function attack() external {
        escrow.claimExcessRefund();
    }

    receive() external payable {
        if (attackCount < 2) {
            attackCount++;
            try escrow.claimExcessRefund() {} catch {}
        }
    }
}

// Mock router for tests
contract SimpleRouter {
    function completeFinalization(address) external {
        VibesTranchEscrow(payable(msg.sender)).setLPCreated();
    }
    function completeDistribution(address) external {}
    receive() external payable {}
}

/**
 * @title Audit Security Tests
 * @notice Tests covering:
 *   1. Reentrancy exploit attempts on all ETH-sending functions
 *   2. State machine adversarial transitions
 *   3. F10 commit-reveal merkle root timelock
 */
contract AuditSecurityTest is Test {
    VibesTranchEscrow public implementation;
    VibesTranchEscrowFactory public factory;
    MockTimeOracle public timeOracle;
    VibesToken public token;
    SimpleRouter public mockRouter;

    address public admin = makeAddr("admin");
    address public platformWallet = makeAddr("platform");
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");

    uint256 public constant GOAL = 10 ether;
    uint256 public constant TOKEN_SUPPLY = 1_000_000 ether;

    function setUp() public {
        vm.prank(admin);
        timeOracle = new MockTimeOracle();
        vm.prank(admin);
        timeOracle.setRealTimeMode(true);

        mockRouter = new SimpleRouter();

        implementation = new VibesTranchEscrow();
        factory = new VibesTranchEscrowFactory(
            address(implementation),
            admin,
            platformWallet,
            address(timeOracle),
            address(mockRouter),
            makeAddr("lpLocker"),
            address(0)
        );

        vm.prank(founder);
        token = new VibesToken("Test Token", "TEST", 18, TOKEN_SUPPLY, founder);

        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);
        vm.deal(admin, 100 ether);
    }

    // ============ Helpers ============

    function _createFixedGoalEscrow() internal returns (VibesTranchEscrow) {
        vm.prank(address(mockRouter));
        address escrowAddr = factory.createEscrow(
            founder,
            address(token),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 7 days,
            0
        );
        return VibesTranchEscrow(payable(escrowAddr));
    }

    function _createProRataEscrow() internal returns (VibesTranchEscrow) {
        vm.prank(address(mockRouter));
        address escrowAddr = factory.createEscrow(
            founder,
            address(token),
            VibesTranchEscrow.RaiseType.ProRata,
            GOAL,
            0,
            block.timestamp + 7 days,
            0
        );
        return VibesTranchEscrow(payable(escrowAddr));
    }

    function _fundAndFinalize(VibesTranchEscrow escrow, uint256 amount) internal {
        vm.prank(backer1);
        escrow.contribute{value: amount}(0, 0, "");
        skip((8) * 1 days);
        escrow.finalize();
    }

    // ============================================================
    // REENTRANCY TESTS
    // ============================================================

    /// @notice Reentrancy on claimContributorRefund is blocked by nonReentrant
    function test_reentrancy_claimContributorRefund_blocked() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();

        // Create attacker contract and fund it
        ReentrantRefundClaimer attacker = new ReentrantRefundClaimer(address(escrow));
        vm.deal(address(attacker), 10 ether);

        // Contribute as attacker
        vm.prank(address(attacker));
        escrow.contribute{value: 5 ether}(0, 0, "");

        // Also contribute normally
        vm.prank(backer1);
        escrow.contribute{value: 3 ether}(0, 0, "");

        // Fail the campaign
        skip((8) * 1 days);
        escrow.finalize();

        // Attacker tries reentrancy — should get exactly 5 ETH, not more
        uint256 attackerBalBefore = address(attacker).balance;
        vm.prank(address(attacker));
        attacker.attack();

        uint256 received = address(attacker).balance - attackerBalBefore;
        assertEq(received, 5 ether, "Should only receive contribution amount, not more");

        // Verify reentrancy didn't drain additional funds
        // backer1 should still be able to claim their full refund
        uint256 backer1BalBefore = backer1.balance;
        vm.prank(backer1);
        escrow.claimContributorRefund();
        assertEq(backer1.balance - backer1BalBefore, 3 ether, "backer1 refund intact");
    }

    /// @notice Reentrancy on claimExcessRefund is blocked by nonReentrant
    function test_reentrancy_claimExcessRefund_blocked() public {
        VibesTranchEscrow escrow = _createProRataEscrow();

        // Create attacker and contribute
        ReentrantExcessClaimer attacker = new ReentrantExcessClaimer(address(escrow));
        vm.deal(address(attacker), 20 ether);

        vm.prank(address(attacker));
        escrow.contribute{value: 10 ether}(0, 0, "");
        vm.prank(backer1);
        escrow.contribute{value: 10 ether}(0, 0, "");

        // Finalize (oversubscribed)
        skip((8) * 1 days);
        escrow.finalize();

        // Attacker tries reentrancy on excess claim
        uint256 attackerBalBefore = address(attacker).balance;
        vm.prank(address(attacker));
        attacker.attack();

        uint256 received = address(attacker).balance - attackerBalBefore;
        uint256 expectedExcess = 10 ether - (10 ether * GOAL) / 20 ether;
        assertEq(received, expectedExcess, "Should only receive excess, not double");
    }

    // ============================================================
    // STATE MACHINE ADVERSARIAL TESTS
    // ============================================================

    /// @notice Cannot claim tranche in Active state
    function test_stateMachine_claimTranche_revertsInActive() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        vm.prank(founder);
        vm.expectRevert();
        escrow.claimTranche(0);
    }

    /// @notice Cannot contribute after campaign is funded
    function test_stateMachine_contribute_revertsAfterFunded() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(backer2);
        vm.expectRevert();
        escrow.contribute{value: 1 ether}(0, 0, "");
    }

    /// @notice Cannot finalize twice
    function test_stateMachine_finalize_revertsIfAlreadyFunded() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Second finalize should revert
        vm.expectRevert();
        escrow.finalize();
    }

    /// @notice Cannot contribute to a failed campaign
    function test_stateMachine_contribute_revertsAfterFailed() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        vm.prank(backer1);
        escrow.contribute{value: 3 ether}(0, 0, ""); // Below goal

        skip((8) * 1 days);
        escrow.finalize(); // Fails

        vm.prank(backer2);
        vm.expectRevert();
        escrow.contribute{value: 1 ether}(0, 0, "");
    }

    /// @notice Cannot claim contributor refund from funded campaign
    function test_stateMachine_claimRefund_revertsIfFunded() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(backer1);
        vm.expectRevert();
        escrow.claimContributorRefund();
    }

    /// @notice Cannot freeze a completed campaign (all tranches claimed)
    function test_stateMachine_freeze_revertsIfCompleted() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Claim all tranches
        skip(73 hours);
        vm.prank(founder);
        escrow.claimTranche(0); // kickstart

        for (uint8 i = 1; i <= 6; i++) {
            skip((30) * 1 days);
            vm.prank(founder);
            escrow.requestTranche(i);
            skip(73 hours);
            vm.prank(founder);
            escrow.claimTranche(i);
        }

        // Should be completed now
        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(uint8(camp.state), uint8(VibesTranchEscrow.CampaignState.Completed));

        // Cannot freeze a completed campaign
        vm.prank(admin);
        vm.expectRevert();
        escrow.freezeCampaign("too late");
    }

    /// @notice Cannot claim tranche from frozen campaign
    function test_stateMachine_claimTranche_revertsIfFrozen() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        // Claim kickstart then freeze
        skip(73 hours);
        vm.prank(founder);
        escrow.claimTranche(0);

        vm.prank(admin);
        escrow.freezeCampaign("frozen");

        // Cannot claim tranche 1
        skip((30) * 1 days);
        vm.prank(founder);
        vm.expectRevert();
        escrow.requestTranche(1);
    }

    // ============================================================
    // F10: MERKLE ROOT COMMIT-REVEAL TESTS
    // ============================================================

    /// @notice F10: Cannot finalize merkle root before delay
    function test_F10_finalizeReverts_beforeDelay() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(admin);
        escrow.freezeCampaign("test");

        bytes32 root = keccak256("merkle root");
        vm.prank(admin);
        escrow.commitRefundMerkleRoot(root);

        // Try to finalize immediately — should revert
        vm.expectRevert(VibesTranchEscrow.MerkleRootDelayNotElapsed.selector);
        escrow.finalizeRefundMerkleRoot();
    }

    /// @notice F10: Can finalize merkle root after delay
    function test_F10_finalizeSucceeds_afterDelay() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(admin);
        escrow.freezeCampaign("test");

        bytes32 root = keccak256("merkle root");
        vm.prank(admin);
        escrow.commitRefundMerkleRoot(root);

        // Advance past 24hr delay
        vm.warp(block.timestamp + 25 hours);

        // Anyone can finalize after delay
        escrow.finalizeRefundMerkleRoot();

        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(uint8(camp.state), uint8(VibesTranchEscrow.CampaignState.Refunding));
        assertEq(camp.refundMerkleRoot, root);
    }

    /// @notice F10: Admin can cancel pending merkle root
    function test_F10_cancelPendingMerkleRoot() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(admin);
        escrow.freezeCampaign("test");

        bytes32 root = keccak256("bad root");
        vm.prank(admin);
        escrow.commitRefundMerkleRoot(root);

        // Cancel before finalization
        vm.prank(admin);
        escrow.cancelPendingMerkleRoot();

        // Verify cancelled
        assertEq(escrow.pendingMerkleRoot(), bytes32(0));

        // Cannot finalize cancelled root
        vm.warp(block.timestamp + 25 hours);
        vm.expectRevert(VibesTranchEscrow.NoPendingMerkleRoot.selector);
        escrow.finalizeRefundMerkleRoot();
    }

    /// @notice F10: Cannot commit empty merkle root
    function test_F10_commitReverts_emptyRoot() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(admin);
        escrow.freezeCampaign("test");

        vm.prank(admin);
        vm.expectRevert("Empty merkle root");
        escrow.commitRefundMerkleRoot(bytes32(0));
    }

    /// @notice F10: Can recommit a different root (replaces pending)
    function test_F10_recommit_replacesPending() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(admin);
        escrow.freezeCampaign("test");

        bytes32 root1 = keccak256("root1");
        bytes32 root2 = keccak256("root2");

        vm.prank(admin);
        escrow.commitRefundMerkleRoot(root1);

        // Recommit with different root
        vm.prank(admin);
        escrow.commitRefundMerkleRoot(root2);

        // Advance past delay and finalize — should use root2
        vm.warp(block.timestamp + 25 hours);
        escrow.finalizeRefundMerkleRoot();

        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(camp.refundMerkleRoot, root2);
    }

    /// @notice F10: Only admin can commit
    function test_F10_commitReverts_nonAdmin() public {
        VibesTranchEscrow escrow = _createFixedGoalEscrow();
        _fundAndFinalize(escrow, GOAL);

        vm.prank(admin);
        escrow.freezeCampaign("test");

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.OnlyAdmin.selector);
        escrow.commitRefundMerkleRoot(keccak256("root"));
    }
}
