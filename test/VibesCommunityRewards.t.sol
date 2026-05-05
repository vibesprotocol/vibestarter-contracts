// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VibesCommunityRewards} from "../src/VibesCommunityRewards.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Tests for VibesCommunityRewards: cliff enforcement, batch lifecycle,
///      claims, rescue, pause, admin transfer, and solvency invariants.
///
///      Merkle trees are built manually to match the double-hash encoding the contract
///      expects (keccak256(abi.encodePacked(keccak256(abi.encodePacked(recipient, amount))))),
///      consistent with the existing packages/shared/src/merkle.ts off-chain builder.
contract VibesCommunityRewardsTest is Test {
    VibesCommunityRewards public cr;
    VibesToken public vibes;

    address public admin = makeAddr("admin");
    address public newAdmin = makeAddr("newAdmin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public stranger = makeAddr("stranger");

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant COMMUNITY_SLICE = 200_000_000 ether; // 20%
    uint256 public unlockTime;

    function setUp() public {
        vibes = new VibesToken("Vibes", "VIBES", 18, TOTAL_SUPPLY, address(this));
        unlockTime = block.timestamp + 180 days;
        cr = new VibesCommunityRewards(IERC20(address(vibes)), unlockTime, admin);
        // Simulate the router merkle claim that deposits the 20% community slice.
        vibes.transfer(address(cr), COMMUNITY_SLICE);
    }

    // ============================================
    // SETUP SANITY
    // ============================================

    function test_InitialState() public view {
        assertEq(address(cr.token()), address(vibes));
        assertEq(cr.unlockTime(), unlockTime);
        assertEq(cr.admin(), admin);
        assertEq(cr.pendingAdmin(), address(0));
        assertEq(cr.paused(), false);
        assertEq(cr.batchCount(), 0);
        assertEq(cr.isUnlocked(), false);
        assertEq(vibes.balanceOf(address(cr)), COMMUNITY_SLICE);
    }

    // ============================================
    // CLIFF ENFORCEMENT
    // ============================================

    function test_CannotCreateBatchBeforeCliff() public {
        vm.prank(admin);
        vm.expectRevert(VibesCommunityRewards.BeforeCliff.selector);
        cr.createBatch(bytes32(uint256(1)), 100 ether, 0, _meta("batch"));
    }

    function test_CannotClaimBeforeCliff() public {
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.expectRevert(VibesCommunityRewards.BeforeCliff.selector);
        cr.claim(0, alice, 1 ether, emptyProof);
    }

    function test_IsUnlockedFlipsAtCliff() public {
        assertEq(cr.isUnlocked(), false);
        vm.warp(unlockTime);
        assertEq(cr.isUnlocked(), true);
    }

    // ============================================
    // BATCH CREATION
    // ============================================

    function test_CreateBatch_Happy() public {
        vm.warp(unlockTime);

        (bytes32 root, , , ) = _build3LeafTree(alice, 100 ether, bob, 200 ether, charlie, 50 ether);

        vm.prank(admin);
        uint256 batchId = cr.createBatch(root, 350 ether, 30 days, bytes32(uint256(0xbeef)));

        assertEq(batchId, 0);
        assertEq(cr.batchCount(), 1);

        (bytes32 storedRoot, uint256 totalAmount, uint256 claimedAmount, , uint256 rescueAfter, bool rescued, bytes32 meta) =
            cr.batches(0);
        assertEq(storedRoot, root);
        assertEq(totalAmount, 350 ether);
        assertEq(claimedAmount, 0);
        assertEq(rescueAfter, block.timestamp + 30 days);
        assertEq(rescued, false);
        assertEq(meta, bytes32(uint256(0xbeef)));
    }

    function test_CreateBatch_RevertsIfNotAdmin() public {
        vm.warp(unlockTime);
        vm.prank(stranger);
        vm.expectRevert(VibesCommunityRewards.OnlyAdmin.selector);
        cr.createBatch(bytes32(uint256(1)), 100 ether, 0, _meta("batch"));
    }

    function test_CreateBatch_RevertsIfInsufficientBalance() public {
        vm.warp(unlockTime);
        vm.prank(admin);
        vm.expectRevert(VibesCommunityRewards.InsufficientBatchBalance.selector);
        cr.createBatch(bytes32(uint256(1)), COMMUNITY_SLICE + 1, 0, _meta("batch"));
    }

    function test_CreateBatch_RevertsWhenPaused() public {
        vm.warp(unlockTime);
        vm.prank(admin);
        cr.setPaused(true);

        vm.prank(admin);
        vm.expectRevert(VibesCommunityRewards.IsPaused.selector);
        cr.createBatch(bytes32(uint256(1)), 100 ether, 0, _meta("batch"));
    }

    function test_CreateBatch_RevertsWhenMetadataHashMissing() public {
        vm.warp(unlockTime);
        vm.prank(admin);
        vm.expectRevert(VibesCommunityRewards.MetadataHashRequired.selector);
        cr.createBatch(bytes32(uint256(1)), 100 ether, 0, bytes32(0));
    }

    function test_CreateBatch_NoRescueWindow() public {
        vm.warp(unlockTime);
        vm.prank(admin);
        uint256 batchId = cr.createBatch(bytes32(uint256(1)), 100 ether, 0, _meta("batch"));
        ( , , , , uint256 rescueAfter, , ) = cr.batches(batchId);
        assertEq(rescueAfter, 0);
    }

    // ============================================
    // CLAIMS
    // ============================================

    function test_Claim_Happy() public {
        vm.warp(unlockTime);

        (bytes32 root, bytes32[] memory proofA, , ) =
            _build3LeafTree(alice, 100 ether, bob, 200 ether, charlie, 50 ether);

        vm.prank(admin);
        cr.createBatch(root, 350 ether, 30 days, _meta("batch"));

        cr.claim(0, alice, 100 ether, proofA);
        assertEq(vibes.balanceOf(alice), 100 ether);
        assertEq(cr.claimed(0, alice), true);

        (, , uint256 claimedAmount, , , , ) = cr.batches(0);
        assertEq(claimedAmount, 100 ether);
    }

    function test_Claim_RevertsDoubleClaim() public {
        vm.warp(unlockTime);
        (bytes32 root, bytes32[] memory proofA, , ) =
            _build3LeafTree(alice, 100 ether, bob, 200 ether, charlie, 50 ether);

        vm.prank(admin);
        cr.createBatch(root, 350 ether, 30 days, _meta("batch"));

        cr.claim(0, alice, 100 ether, proofA);
        vm.expectRevert(VibesCommunityRewards.AlreadyClaimed.selector);
        cr.claim(0, alice, 100 ether, proofA);
    }

    function test_Claim_RevertsInvalidProof() public {
        vm.warp(unlockTime);
        (bytes32 root, bytes32[] memory proofA, , ) =
            _build3LeafTree(alice, 100 ether, bob, 200 ether, charlie, 50 ether);

        vm.prank(admin);
        cr.createBatch(root, 350 ether, 30 days, _meta("batch"));

        // Wrong amount for alice
        vm.expectRevert(VibesCommunityRewards.InvalidProof.selector);
        cr.claim(0, alice, 999 ether, proofA);
    }

    function test_Claim_RevertsWhenPaused() public {
        vm.warp(unlockTime);
        (bytes32 root, bytes32[] memory proofA, , ) =
            _build3LeafTree(alice, 100 ether, bob, 200 ether, charlie, 50 ether);

        vm.prank(admin);
        cr.createBatch(root, 350 ether, 30 days, _meta("batch"));

        vm.prank(admin);
        cr.setPaused(true);

        vm.expectRevert(VibesCommunityRewards.IsPaused.selector);
        cr.claim(0, alice, 100 ether, proofA);
    }

    function test_Claim_AnyoneCanRelay() public {
        vm.warp(unlockTime);
        (bytes32 root, bytes32[] memory proofA, , ) =
            _build3LeafTree(alice, 100 ether, bob, 200 ether, charlie, 50 ether);

        vm.prank(admin);
        cr.createBatch(root, 350 ether, 30 days, _meta("batch"));

        vm.prank(stranger);
        cr.claim(0, alice, 100 ether, proofA);
        assertEq(vibes.balanceOf(alice), 100 ether);
        assertEq(vibes.balanceOf(stranger), 0);
    }

    function test_Claim_AllThreeLeaves() public {
        vm.warp(unlockTime);
        (bytes32 root, bytes32[] memory pA, bytes32[] memory pB, bytes32[] memory pC) =
            _build3LeafTree(alice, 100 ether, bob, 200 ether, charlie, 50 ether);

        vm.prank(admin);
        cr.createBatch(root, 350 ether, 30 days, _meta("batch"));

        cr.claim(0, alice, 100 ether, pA);
        cr.claim(0, bob, 200 ether, pB);
        cr.claim(0, charlie, 50 ether, pC);

        assertEq(vibes.balanceOf(alice), 100 ether);
        assertEq(vibes.balanceOf(bob), 200 ether);
        assertEq(vibes.balanceOf(charlie), 50 ether);

        (, , uint256 claimedAmount, , , , ) = cr.batches(0);
        assertEq(claimedAmount, 350 ether);
    }

    // ============================================
    // RESCUE
    // ============================================

    function test_Rescue_ReturnsUnclaimedToContractAccounting() public {
        vm.warp(unlockTime);
        (bytes32 root, bytes32[] memory pA, , ) =
            _build3LeafTree(alice, 100 ether, bob, 200 ether, charlie, 50 ether);

        vm.prank(admin);
        cr.createBatch(root, 350 ether, 30 days, _meta("batch"));

        cr.claim(0, alice, 100 ether, pA);

        vm.warp(block.timestamp + 31 days);

        vm.prank(admin);
        cr.rescueBatch(0);

        ( , , , , , bool rescued, ) = cr.batches(0);
        assertTrue(rescued);

        // Contract balance unchanged by rescue (tokens stay; batch marked)
        assertEq(vibes.balanceOf(address(cr)), COMMUNITY_SLICE - 100 ether);

        vm.prank(admin);
        uint256 batchId2 = cr.createBatch(bytes32(uint256(42)), 250 ether, 0, _meta("batch2"));
        assertEq(batchId2, 1);
    }

    function test_Rescue_RevertsBeforeWindow() public {
        vm.warp(unlockTime);
        (bytes32 root, , , ) = _build3LeafTree(alice, 100 ether, bob, 200 ether, charlie, 50 ether);

        vm.prank(admin);
        cr.createBatch(root, 350 ether, 30 days, _meta("batch"));

        vm.prank(admin);
        vm.expectRevert(VibesCommunityRewards.RescueWindowNotOpen.selector);
        cr.rescueBatch(0);
    }

    function test_Rescue_RevertsWhenWindowDisabled() public {
        vm.warp(unlockTime);
        vm.prank(admin);
        cr.createBatch(bytes32(uint256(1)), 100 ether, 0, _meta("batch"));

        vm.warp(block.timestamp + 365 days);

        vm.prank(admin);
        vm.expectRevert(VibesCommunityRewards.RescueDisabled.selector);
        cr.rescueBatch(0);
    }

    function test_Rescue_RevertsIfAlreadyRescued() public {
        vm.warp(unlockTime);
        vm.prank(admin);
        cr.createBatch(bytes32(uint256(1)), 100 ether, 30 days, _meta("batch"));

        vm.warp(block.timestamp + 31 days);

        vm.prank(admin);
        cr.rescueBatch(0);

        vm.prank(admin);
        vm.expectRevert(VibesCommunityRewards.BatchRescuedErr.selector);
        cr.rescueBatch(0);
    }

    // ============================================
    // ADMIN TRANSFER
    // ============================================

    function test_AdminTransfer_Flow() public {
        vm.prank(admin);
        cr.transferAdmin(newAdmin);
        assertEq(cr.pendingAdmin(), newAdmin);
        assertEq(cr.admin(), admin);

        vm.prank(newAdmin);
        cr.acceptAdmin();
        assertEq(cr.admin(), newAdmin);
        assertEq(cr.pendingAdmin(), address(0));
    }

    function test_AdminTransfer_RevertsIfNotPending() public {
        vm.prank(admin);
        cr.transferAdmin(newAdmin);

        vm.prank(stranger);
        vm.expectRevert(VibesCommunityRewards.OnlyPendingAdmin.selector);
        cr.acceptAdmin();
    }

    // ============================================
    // SOLVENCY INVARIANT
    // ============================================

    function test_CreateBatch_RevertsWhenPriorUnclaimedBlocksNewBatch() public {
        vm.warp(unlockTime);

        vm.prank(admin);
        cr.createBatch(bytes32(uint256(1)), 180_000_000 ether, 30 days, _meta("batch"));

        vm.prank(admin);
        vm.expectRevert(VibesCommunityRewards.InsufficientBatchBalance.selector);
        cr.createBatch(bytes32(uint256(2)), 30_000_000 ether, 0, _meta("batch2"));
    }

    // ============================================
    // MERKLE TREE HELPER (3 leaves)
    // ============================================

    /// @dev Build a 3-leaf merkle tree and return (root, proofA, proofB, proofC) where
    ///      proofX is the proof for (partyX, amountX). Tree construction matches the
    ///      TS builder in packages/shared/src/merkle.ts: leaves are double-hashed; pairs
    ///      are combined via sorted-pair hash; odd elements are promoted.
    function _build3LeafTree(
        address a, uint256 amtA,
        address b, uint256 amtB,
        address c, uint256 amtC
    ) internal pure returns (
        bytes32 root,
        bytes32[] memory proofA,
        bytes32[] memory proofB,
        bytes32[] memory proofC
    ) {
        bytes32 leafA = _leaf(a, amtA);
        bytes32 leafB = _leaf(b, amtB);
        bytes32 leafC = _leaf(c, amtC);

        // Layer 1: [hash(A, B), C] (C promoted as odd element)
        bytes32 parentAB = _hashPair(leafA, leafB);
        // Layer 2 (root): hash(parentAB, C)
        root = _hashPair(parentAB, leafC);

        // Proof for A: [B, C]
        proofA = new bytes32[](2);
        proofA[0] = leafB;
        proofA[1] = leafC;

        // Proof for B: [A, C]
        proofB = new bytes32[](2);
        proofB[0] = leafA;
        proofB[1] = leafC;

        // Proof for C: [parentAB]
        proofC = new bytes32[](1);
        proofC[0] = parentAB;
    }

    function _leaf(address recipient, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(abi.encodePacked(recipient, amount))));
    }

    function _hashPair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    /// @dev Helper: produces a non-zero metadata hash for test batches.
    ///      In production, admin would `keccak256(content)` of the published distribution-policy doc.
    function _meta(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }
}
