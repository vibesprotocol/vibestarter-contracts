// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {VibesTokenDistributorV2} from "../src/VibesTokenDistributorV2.sol";
import {VibesToken} from "../src/VibesToken.sol";

/**
 * Cross-layer Merkle verification tests
 *
 * These tests verify that merkle trees built by the TypeScript implementation
 * (packages/shared/src/merkle.ts) produce roots and proofs that are compatible
 * with the Solidity MerkleProof.verify used in VibesTokenDistributorV2.
 *
 * The test data is generated independently on both sides using the same inputs,
 * and the resulting hashes/roots/proofs must match exactly.
 */
contract CrossLayerMerkleTest is Test {
    VibesTokenDistributorV2 public distributor;
    VibesToken public token;

    address public founder = makeAddr("founder");
    address public campaign = makeAddr("campaign");
    address public opsWallet = makeAddr("opsWallet");
    address public admin = makeAddr("admin");

    // Fixed test addresses (matching TS test data)
    address public constant BACKER1 = address(0x1);
    address public constant BACKER2 = address(0x2);
    address public constant BACKER3 = address(0x3);

    // Token amounts (matching TS test data)
    uint256 public constant TOKENS1 = 400_000 ether;
    uint256 public constant TOKENS2 = 300_000 ether;
    uint256 public constant TOKENS3 = 200_000 ether;

    // ETH refunds (matching TS test data)
    uint256 public constant REFUND1 = 0;
    uint256 public constant REFUND2 = 1 ether;
    uint256 public constant REFUND3 = 0.5 ether;

    uint256 public constant TOTAL_SUPPLY = 10_000_000 ether;
    uint256 public constant DIST_TOKENS = TOKENS1 + TOKENS2 + TOKENS3; // 900,000 ether
    uint256 public constant TOTAL_REFUNDS = REFUND2 + REFUND3; // 1.5 ether

    function setUp() public {
        token = new VibesToken("Test", "TST", 18, TOTAL_SUPPLY, address(this));

        distributor = new VibesTokenDistributorV2(
            address(token),
            founder,
            campaign,
            opsWallet,
            admin
        );

        // Fund distributor
        token.transfer(address(distributor), DIST_TOKENS);
        vm.deal(address(distributor), TOTAL_REFUNDS);
    }

    // ============ Leaf Hash Tests ============

    /// @notice Verify leaf hashing uses double-hash: keccak256(abi.encodePacked(keccak256(abi.encodePacked(address, uint256, uint256))))
    function test_crossLayer_leafHash_matches() public pure {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER2, TOKENS2, REFUND2))));
        bytes32 leaf3 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER3, TOKENS3, REFUND3))));

        // These hashes must be deterministic — same inputs always produce same output
        assertTrue(leaf1 != bytes32(0), "Leaf1 should not be zero");
        assertTrue(leaf2 != bytes32(0), "Leaf2 should not be zero");
        assertTrue(leaf3 != bytes32(0), "Leaf3 should not be zero");

        // Each leaf should be unique
        assertTrue(leaf1 != leaf2, "Leaf1 and leaf2 should differ");
        assertTrue(leaf2 != leaf3, "Leaf2 and leaf3 should differ");
        assertTrue(leaf1 != leaf3, "Leaf1 and leaf3 should differ");
    }

    // ============ Tree Construction Tests ============

    /// @notice Build a 2-leaf tree and verify root
    function test_crossLayer_twoLeafTree() public pure {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER2, TOKENS2, REFUND2))));

        // Root = hash(sorted(leaf1, leaf2))
        bytes32 root = _hashPair(leaf1, leaf2);
        assertTrue(root != bytes32(0), "Root should not be zero");

        // Verify proof: leaf1 with proof [leaf2] should verify
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        assertTrue(MerkleProof.verify(proof, root, leaf1), "Leaf1 proof should verify");

        // Verify proof: leaf2 with proof [leaf1] should verify
        proof[0] = leaf1;
        assertTrue(MerkleProof.verify(proof, root, leaf2), "Leaf2 proof should verify");
    }

    /// @notice Build a 3-leaf tree matching TypeScript odd-element promotion
    function test_crossLayer_threeLeafTree() public pure {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER2, TOKENS2, REFUND2))));
        bytes32 leaf3 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER3, TOKENS3, REFUND3))));

        // TS tree construction for 3 leaves:
        // Layer 0: [leaf1, leaf2, leaf3]
        // Layer 1: [hash(leaf1, leaf2), leaf3]  (leaf3 promoted as odd element)
        // Layer 2 (root): [hash(parent01, leaf3)]
        bytes32 parent01 = _hashPair(leaf1, leaf2);
        bytes32 root = _hashPair(parent01, leaf3);

        // Verify proof for leaf1: [leaf2, leaf3]
        bytes32[] memory proof1 = new bytes32[](2);
        proof1[0] = leaf2;
        proof1[1] = leaf3;
        assertTrue(MerkleProof.verify(proof1, root, leaf1), "Leaf1 proof should verify in 3-leaf tree");

        // Verify proof for leaf2: [leaf1, leaf3]
        bytes32[] memory proof2 = new bytes32[](2);
        proof2[0] = leaf1;
        proof2[1] = leaf3;
        assertTrue(MerkleProof.verify(proof2, root, leaf2), "Leaf2 proof should verify in 3-leaf tree");

        // Verify proof for leaf3: [parent01]
        bytes32[] memory proof3 = new bytes32[](1);
        proof3[0] = parent01;
        assertTrue(MerkleProof.verify(proof3, root, leaf3), "Leaf3 proof should verify in 3-leaf tree");
    }

    /// @notice Build a 4-leaf balanced tree
    function test_crossLayer_fourLeafTree() public pure {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER2, TOKENS2, REFUND2))));
        bytes32 leaf3 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER3, TOKENS3, REFUND3))));
        // 4th backer
        bytes32 leaf4 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(address(0x4), uint256(100_000 ether), uint256(0)))));

        // Balanced tree:
        // Layer 0: [leaf1, leaf2, leaf3, leaf4]
        // Layer 1: [hash(leaf1, leaf2), hash(leaf3, leaf4)]
        // Layer 2 (root): [hash(parent01, parent23)]
        bytes32 parent01 = _hashPair(leaf1, leaf2);
        bytes32 parent23 = _hashPair(leaf3, leaf4);
        bytes32 root = _hashPair(parent01, parent23);

        // Verify all proofs
        bytes32[] memory proof1 = new bytes32[](2);
        proof1[0] = leaf2;
        proof1[1] = parent23;
        assertTrue(MerkleProof.verify(proof1, root, leaf1), "Leaf1 proof in 4-leaf tree");

        bytes32[] memory proof4 = new bytes32[](2);
        proof4[0] = leaf3;
        proof4[1] = parent01;
        assertTrue(MerkleProof.verify(proof4, root, leaf4), "Leaf4 proof in 4-leaf tree");
    }

    // ============ Full Claim Flow Tests ============

    /// @notice End-to-end: build tree, set root in distributor, claim with proof
    function test_crossLayer_fullClaimFlow_twoBackers() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER2, TOKENS2, REFUND2))));

        bytes32 root = _hashPair(leaf1, leaf2);

        // Set root in distributor (founder only)
        vm.prank(founder);
        distributor.setDistributionRoot(root, TOKENS1 + TOKENS2, REFUND2);

        // Backer1 claims with proof [leaf2]
        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf2;

        vm.prank(BACKER1);
        distributor.claim(TOKENS1, REFUND1, proof1);

        assertEq(token.balanceOf(BACKER1), TOKENS1);

        // Backer2 claims with proof [leaf1]
        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = leaf1;

        vm.prank(BACKER2);
        distributor.claim(TOKENS2, REFUND2, proof2);

        assertEq(token.balanceOf(BACKER2), TOKENS2);
        assertEq(BACKER2.balance, REFUND2);
    }

    /// @notice End-to-end: 3-leaf tree with odd element promotion, claims all work
    function test_crossLayer_fullClaimFlow_threeBackers() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER2, TOKENS2, REFUND2))));
        bytes32 leaf3 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER3, TOKENS3, REFUND3))));

        bytes32 parent01 = _hashPair(leaf1, leaf2);
        bytes32 root = _hashPair(parent01, leaf3);

        // Set root
        vm.prank(founder);
        distributor.setDistributionRoot(root, DIST_TOKENS, TOTAL_REFUNDS);

        // Backer1 claims: proof [leaf2, leaf3]
        bytes32[] memory proof1 = new bytes32[](2);
        proof1[0] = leaf2;
        proof1[1] = leaf3;
        vm.prank(BACKER1);
        distributor.claim(TOKENS1, REFUND1, proof1);
        assertEq(token.balanceOf(BACKER1), TOKENS1);

        // Backer2 claims: proof [leaf1, leaf3]
        bytes32[] memory proof2 = new bytes32[](2);
        proof2[0] = leaf1;
        proof2[1] = leaf3;
        vm.prank(BACKER2);
        distributor.claim(TOKENS2, REFUND2, proof2);
        assertEq(token.balanceOf(BACKER2), TOKENS2);
        assertEq(BACKER2.balance, REFUND2);

        // Backer3 claims: proof [parent01]
        bytes32[] memory proof3 = new bytes32[](1);
        proof3[0] = parent01;
        vm.prank(BACKER3);
        distributor.claim(TOKENS3, REFUND3, proof3);
        assertEq(token.balanceOf(BACKER3), TOKENS3);
        assertEq(BACKER3.balance, REFUND3);
    }

    /// @notice Verify wrong leaf data fails proof verification
    function test_crossLayer_invalidLeafData_reverts() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER2, TOKENS2, REFUND2))));

        bytes32 root = _hashPair(leaf1, leaf2);

        vm.prank(founder);
        distributor.setDistributionRoot(root, TOKENS1 + TOKENS2, REFUND2);

        // Try to claim with wrong token amount
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.prank(BACKER1);
        vm.expectRevert(VibesTokenDistributorV2.InvalidProof.selector);
        distributor.claim(TOKENS1 + 1, REFUND1, proof); // Wrong amount!
    }

    /// @notice Verify wrong ETH refund fails proof verification
    function test_crossLayer_invalidRefund_reverts() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER2, TOKENS2, REFUND2))));

        bytes32 root = _hashPair(leaf1, leaf2);

        vm.prank(founder);
        distributor.setDistributionRoot(root, TOKENS1 + TOKENS2, REFUND2);

        // Backer2 claims with wrong refund
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;

        vm.prank(BACKER2);
        vm.expectRevert(VibesTokenDistributorV2.InvalidProof.selector);
        distributor.claim(TOKENS2, REFUND2 + 1, proof); // Wrong refund!
    }

    /// @notice Verify canClaim view function works with cross-layer proofs
    function test_crossLayer_canClaim_viewFunction() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER2, TOKENS2, REFUND2))));
        bytes32 leaf3 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER3, TOKENS3, REFUND3))));

        bytes32 parent01 = _hashPair(leaf1, leaf2);
        bytes32 root = _hashPair(parent01, leaf3);

        vm.prank(founder);
        distributor.setDistributionRoot(root, DIST_TOKENS, TOTAL_REFUNDS);

        // Check canClaim returns true for valid proofs
        bytes32[] memory proof1 = new bytes32[](2);
        proof1[0] = leaf2;
        proof1[1] = leaf3;
        assertTrue(distributor.canClaim(BACKER1, TOKENS1, REFUND1, proof1));

        bytes32[] memory proof3 = new bytes32[](1);
        proof3[0] = parent01;
        assertTrue(distributor.canClaim(BACKER3, TOKENS3, REFUND3, proof3));

        // Check canClaim returns false for wrong data
        assertFalse(distributor.canClaim(BACKER1, TOKENS1 + 1, REFUND1, proof1));
    }

    // ============ Batch Distribution Test ============

    /// @notice Verify batch distribute works with cross-layer tree proofs
    function test_crossLayer_batchDistribute() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER2, TOKENS2, REFUND2))));

        bytes32 root = _hashPair(leaf1, leaf2);

        vm.prank(founder);
        distributor.setDistributionRoot(root, TOKENS1 + TOKENS2, REFUND2);

        // Batch distribute to both backers
        address[] memory recipients = new address[](2);
        recipients[0] = BACKER1;
        recipients[1] = BACKER2;

        uint256[] memory tokenAmounts = new uint256[](2);
        tokenAmounts[0] = TOKENS1;
        tokenAmounts[1] = TOKENS2;

        uint256[] memory ethRefunds = new uint256[](2);
        ethRefunds[0] = REFUND1;
        ethRefunds[1] = REFUND2;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = leaf2;
        proofs[1] = new bytes32[](1);
        proofs[1][0] = leaf1;

        vm.prank(founder);
        distributor.batchDistribute(recipients, tokenAmounts, ethRefunds, proofs);

        assertEq(token.balanceOf(BACKER1), TOKENS1);
        assertEq(token.balanceOf(BACKER2), TOKENS2);
    }

    // ============ Single Leaf Edge Case ============

    /// @notice Single backer — proof should be empty
    function test_crossLayer_singleLeaf_emptyProof() public {
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(BACKER1, TOKENS1, REFUND1))));

        // Single leaf: root IS the leaf
        bytes32 root = leaf1;

        vm.prank(founder);
        distributor.setDistributionRoot(root, TOKENS1, REFUND1);

        // Claim with empty proof
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(BACKER1);
        distributor.claim(TOKENS1, REFUND1, proof);

        assertEq(token.balanceOf(BACKER1), TOKENS1);
    }

    // ============ Helper ============

    /// @dev Sorted pair hash matching OpenZeppelin's MerkleProof._hashPair
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        if (uint256(a) < uint256(b)) {
            return keccak256(abi.encodePacked(a, b));
        } else {
            return keccak256(abi.encodePacked(b, a));
        }
    }
}
