// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesTokenDistributorV2} from "../src/VibesTokenDistributorV2.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract VibesTokenDistributorV2Test is Test {
    VibesTokenDistributorV2 public distributor;
    VibesToken public token;

    address public founder = makeAddr("founder");
    address public campaign = makeAddr("campaign");
    address public opsWallet = makeAddr("opsWallet");
    address public admin = makeAddr("admin");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");
    address public backer3 = makeAddr("backer3");

    uint256 public constant TOTAL_SUPPLY = 10_000_000 ether;
    uint256 public constant DIST_TOKENS = 700_000 ether;

    // Pre-computed merkle tree for 2 backers:
    // backer1: 400_000 tokens, 0 ETH refund
    // backer2: 300_000 tokens, 1 ETH refund
    bytes32 public leaf1;
    bytes32 public leaf2;
    bytes32 public merkleRoot;

    function setUp() public {
        token = new VibesToken("Test", "TST", 18, TOTAL_SUPPLY, address(this));

        distributor = new VibesTokenDistributorV2(
            address(token),
            founder,
            campaign,
            opsWallet,
            admin
        );

        // Transfer tokens to distributor
        token.transfer(address(distributor), DIST_TOKENS);

        // Build 2-leaf merkle tree
        leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(400_000 ether), uint256(0)))));
        leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer2, uint256(300_000 ether), uint256(1 ether)))));

        // Sort for consistent root
        if (uint256(leaf1) < uint256(leaf2)) {
            merkleRoot = keccak256(abi.encodePacked(leaf1, leaf2));
        } else {
            merkleRoot = keccak256(abi.encodePacked(leaf2, leaf1));
        }
    }

    function _setupDistribution() internal {
        vm.prank(founder);
        distributor.setDistributionRoot(merkleRoot, DIST_TOKENS, 1 ether);
        vm.deal(address(distributor), 1 ether);
    }

    function _getProof(bytes32 leaf, bytes32 sibling) internal pure returns (bytes32[] memory) {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        return proof;
    }

    // ============ Constructor Tests ============

    function test_constructor_setsState() public view {
        assertEq(address(distributor.token()), address(token));
        assertEq(distributor.founder(), founder);
        assertEq(distributor.campaign(), campaign);
        assertEq(distributor.opsWallet(), opsWallet);
        assertEq(distributor.admin(), admin);
        assertFalse(distributor.distributionSet());
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert(VibesTokenDistributorV2.ZeroAddress.selector);
        new VibesTokenDistributorV2(address(0), founder, campaign, opsWallet, admin);
    }

    function test_constructor_revertsZeroFounder() public {
        vm.expectRevert(VibesTokenDistributorV2.ZeroAddress.selector);
        new VibesTokenDistributorV2(address(token), address(0), campaign, opsWallet, admin);
    }

    function test_constructor_revertsZeroCampaign() public {
        vm.expectRevert(VibesTokenDistributorV2.ZeroAddress.selector);
        new VibesTokenDistributorV2(address(token), founder, address(0), opsWallet, admin);
    }

    function test_constructor_revertsZeroOps() public {
        vm.expectRevert(VibesTokenDistributorV2.ZeroAddress.selector);
        new VibesTokenDistributorV2(address(token), founder, campaign, address(0), admin);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert(VibesTokenDistributorV2.ZeroAddress.selector);
        new VibesTokenDistributorV2(address(token), founder, campaign, opsWallet, address(0));
    }

    // ============ setDistributionRoot Tests ============

    function test_setDistributionRoot() public {
        vm.prank(founder);
        distributor.setDistributionRoot(merkleRoot, DIST_TOKENS, 1 ether);

        assertTrue(distributor.distributionSet());
        assertEq(distributor.merkleRoot(), merkleRoot);
        assertEq(distributor.totalTokens(), DIST_TOKENS);
        assertEq(distributor.totalEthRefunds(), 1 ether);
        assertEq(distributor.distributionSetTime(), block.timestamp);
    }

    function test_setDistributionRoot_revertsNotFounder() public {
        vm.prank(backer1);
        vm.expectRevert(VibesTokenDistributorV2.OnlyFounder.selector);
        distributor.setDistributionRoot(merkleRoot, DIST_TOKENS, 0);
    }

    function test_setDistributionRoot_revertsAlreadySet() public {
        vm.prank(founder);
        distributor.setDistributionRoot(merkleRoot, DIST_TOKENS, 0);

        vm.prank(founder);
        vm.expectRevert(VibesTokenDistributorV2.AlreadySet.selector);
        distributor.setDistributionRoot(merkleRoot, DIST_TOKENS, 0);
    }

    function test_setDistributionRoot_revertsZeroRoot() public {
        vm.prank(founder);
        vm.expectRevert(VibesTokenDistributorV2.ZeroAddress.selector);
        distributor.setDistributionRoot(bytes32(0), DIST_TOKENS, 0);
    }

    // ============ Claim Tests ============

    function test_claim_tokensOnly() public {
        _setupDistribution();

        bytes32[] memory proof = _getProof(leaf1, leaf2);

        vm.prank(backer1);
        distributor.claim(400_000 ether, 0, proof);

        assertTrue(distributor.hasClaimed(backer1));
        assertEq(token.balanceOf(backer1), 400_000 ether);
        assertEq(distributor.totalTokensClaimed(), 400_000 ether);
    }

    function test_claim_tokensAndEth() public {
        _setupDistribution();

        bytes32[] memory proof = _getProof(leaf2, leaf1);

        uint256 balBefore = backer2.balance;
        vm.prank(backer2);
        distributor.claim(300_000 ether, 1 ether, proof);

        assertTrue(distributor.hasClaimed(backer2));
        assertEq(token.balanceOf(backer2), 300_000 ether);
        assertEq(backer2.balance - balBefore, 1 ether);
    }

    function test_claim_revertsNotSet() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(backer1);
        vm.expectRevert(VibesTokenDistributorV2.DistributionNotSet.selector);
        distributor.claim(100 ether, 0, proof);
    }

    function test_claim_revertsAlreadyClaimed() public {
        _setupDistribution();
        bytes32[] memory proof = _getProof(leaf1, leaf2);

        vm.prank(backer1);
        distributor.claim(400_000 ether, 0, proof);

        vm.prank(backer1);
        vm.expectRevert(VibesTokenDistributorV2.AlreadyClaimed.selector);
        distributor.claim(400_000 ether, 0, proof);
    }

    function test_claim_revertsInvalidProof() public {
        _setupDistribution();
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(backer1);
        vm.expectRevert(VibesTokenDistributorV2.InvalidProof.selector);
        distributor.claim(400_000 ether, 0, proof);
    }

    function test_claim_revertsZeroAmounts() public {
        _setupDistribution();
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(backer1);
        vm.expectRevert(VibesTokenDistributorV2.InvalidAmount.selector);
        distributor.claim(0, 0, proof);
    }

    function test_claim_revertsInsufficientEth() public {
        vm.prank(founder);
        distributor.setDistributionRoot(merkleRoot, DIST_TOKENS, 1 ether);
        // Don't fund ETH

        bytes32[] memory proof = _getProof(leaf2, leaf1);
        vm.prank(backer2);
        vm.expectRevert(VibesTokenDistributorV2.InsufficientEth.selector);
        distributor.claim(300_000 ether, 1 ether, proof);
    }

    // ============ Batch Distribute Tests ============

    function test_batchDistribute() public {
        _setupDistribution();

        address[] memory recipients = new address[](2);
        recipients[0] = backer1;
        recipients[1] = backer2;

        uint256[] memory tokenAmounts = new uint256[](2);
        tokenAmounts[0] = 400_000 ether;
        tokenAmounts[1] = 300_000 ether;

        uint256[] memory ethRefunds = new uint256[](2);
        ethRefunds[0] = 0;
        ethRefunds[1] = 1 ether;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = _getProof(leaf1, leaf2);
        proofs[1] = _getProof(leaf2, leaf1);

        vm.prank(founder);
        distributor.batchDistribute(recipients, tokenAmounts, ethRefunds, proofs);

        assertTrue(distributor.hasClaimed(backer1));
        assertTrue(distributor.hasClaimed(backer2));
        assertEq(token.balanceOf(backer1), 400_000 ether);
        assertEq(token.balanceOf(backer2), 300_000 ether);
    }

    function test_batchDistribute_skipsAlreadyClaimed() public {
        _setupDistribution();

        // Backer1 claims first
        bytes32[] memory proof1 = _getProof(leaf1, leaf2);
        vm.prank(backer1);
        distributor.claim(400_000 ether, 0, proof1);

        // Now batch includes backer1 (already claimed) and backer2
        address[] memory recipients = new address[](2);
        recipients[0] = backer1;
        recipients[1] = backer2;

        uint256[] memory tokenAmounts = new uint256[](2);
        tokenAmounts[0] = 400_000 ether;
        tokenAmounts[1] = 300_000 ether;

        uint256[] memory ethRefunds = new uint256[](2);
        ethRefunds[0] = 0;
        ethRefunds[1] = 1 ether;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = _getProof(leaf1, leaf2);
        proofs[1] = _getProof(leaf2, leaf1);

        vm.prank(founder);
        distributor.batchDistribute(recipients, tokenAmounts, ethRefunds, proofs);

        // Backer1 still only has original claim
        assertEq(token.balanceOf(backer1), 400_000 ether);
        // Backer2 got claimed via batch
        assertEq(token.balanceOf(backer2), 300_000 ether);
    }

    function test_batchDistribute_revertsNotFounder() public {
        _setupDistribution();

        address[] memory r = new address[](0);
        uint256[] memory t = new uint256[](0);
        uint256[] memory e = new uint256[](0);
        bytes32[][] memory p = new bytes32[][](0);

        vm.prank(backer1);
        vm.expectRevert(VibesTokenDistributorV2.OnlyFounder.selector);
        distributor.batchDistribute(r, t, e, p);
    }

    function test_batchDistribute_revertsArrayMismatch() public {
        _setupDistribution();

        address[] memory r = new address[](1);
        r[0] = backer1;
        uint256[] memory t = new uint256[](2);
        uint256[] memory e = new uint256[](1);
        bytes32[][] memory p = new bytes32[][](1);

        vm.prank(founder);
        vm.expectRevert(VibesTokenDistributorV2.InvalidAmount.selector);
        distributor.batchDistribute(r, t, e, p);
    }

    // ============ Pending ETH Tests ============

    function test_claimPendingEth() public {
        _setupDistribution();

        // Use a contract that rejects ETH as backer to trigger pending ETH
        RejectETH rejector = new RejectETH();
        address rejectorAddr = address(rejector);

        // Build leaf for rejector
        bytes32 rejLeaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(rejectorAddr, uint256(0), uint256(0.5 ether)))));
        // Build a one-leaf tree (root = leaf)
        bytes32 simpleRoot = rejLeaf;

        // Re-deploy distributor with simpleRoot
        VibesTokenDistributorV2 dist2 = new VibesTokenDistributorV2(
            address(token), founder, campaign, opsWallet, admin
        );
        token.transfer(address(dist2), DIST_TOKENS);
        vm.deal(address(dist2), 1 ether);

        vm.prank(founder);
        dist2.setDistributionRoot(simpleRoot, 0, 0.5 ether);

        // Batch distribute to rejector — ETH fails, tracked as pending
        address[] memory recipients = new address[](1);
        recipients[0] = rejectorAddr;
        uint256[] memory tokenAmounts = new uint256[](1);
        tokenAmounts[0] = 0;
        uint256[] memory ethRefunds = new uint256[](1);
        ethRefunds[0] = 0.5 ether;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        vm.prank(founder);
        dist2.batchDistribute(recipients, tokenAmounts, ethRefunds, proofs);

        // ETH should be pending
        assertEq(dist2.pendingEthRefunds(rejectorAddr), 0.5 ether);

        // Now rejector enables ETH acceptance and claims
        rejector.setAcceptETH(true);
        vm.prank(rejectorAddr);
        dist2.claimPendingEth();

        assertEq(dist2.pendingEthRefunds(rejectorAddr), 0);
        assertEq(rejectorAddr.balance, 0.5 ether);
    }

    function test_claimPendingEth_revertsNoPending() public {
        _setupDistribution();
        vm.prank(backer1);
        vm.expectRevert(VibesTokenDistributorV2.NoPendingEth.selector);
        distributor.claimPendingEth();
    }

    // ============ Sweep Tests ============

    function test_sweepUnclaimed() public {
        _setupDistribution();

        // Advance past sweep delay (180 days)
        vm.warp(block.timestamp + 181 days);

        vm.prank(admin);
        distributor.sweepUnclaimed();

        assertEq(token.balanceOf(opsWallet), DIST_TOKENS);
        assertEq(opsWallet.balance, 1 ether);
    }

    function test_sweepUnclaimed_revertsTooEarly() public {
        _setupDistribution();

        vm.warp(block.timestamp + 179 days);

        vm.prank(admin);
        vm.expectRevert(VibesTokenDistributorV2.SweepTooEarly.selector);
        distributor.sweepUnclaimed();
    }

    function test_sweepUnclaimed_revertsNotAdmin() public {
        _setupDistribution();
        vm.warp(block.timestamp + 181 days);

        vm.prank(backer1);
        vm.expectRevert(VibesTokenDistributorV2.OnlyAdmin.selector);
        distributor.sweepUnclaimed();
    }

    function test_sweepUnclaimed_revertsNotSet() public {
        vm.prank(admin);
        vm.expectRevert(VibesTokenDistributorV2.DistributionNotSet.selector);
        distributor.sweepUnclaimed();
    }

    // ============ View Functions ============

    function test_canClaim() public {
        _setupDistribution();
        bytes32[] memory proof = _getProof(leaf1, leaf2);

        assertTrue(distributor.canClaim(backer1, 400_000 ether, 0, proof));
        assertFalse(distributor.canClaim(backer1, 999 ether, 0, proof)); // Wrong amount
    }

    function test_getSweepStatus() public {
        _setupDistribution();

        (bool canSweep, uint256 availableAt) = distributor.getSweepStatus();
        assertFalse(canSweep);
        assertEq(availableAt, block.timestamp + 180 days);

        vm.warp(block.timestamp + 180 days);
        (canSweep, ) = distributor.getSweepStatus();
        assertTrue(canSweep);
    }

    function test_claimProgress() public {
        _setupDistribution();

        bytes32[] memory proof = _getProof(leaf1, leaf2);
        vm.prank(backer1);
        distributor.claim(400_000 ether, 0, proof);

        (uint256 claimed, uint256 total, uint256 ethClaimed, uint256 ethTotal) = distributor.claimProgress();
        assertEq(claimed, 400_000 ether);
        assertEq(total, DIST_TOKENS);
        assertEq(ethClaimed, 0);
        assertEq(ethTotal, 1 ether);
    }

    function test_receiveEth() public {
        vm.deal(backer1, 1 ether);
        vm.prank(backer1);
        (bool sent, ) = address(distributor).call{value: 1 ether}("");
        assertTrue(sent);
        assertEq(address(distributor).balance, 1 ether);
    }

    function test_depositEthForRefunds() public {
        vm.deal(backer1, 1 ether);
        vm.prank(backer1);
        distributor.depositEthForRefunds{value: 1 ether}();
        assertEq(address(distributor).balance, 1 ether);
    }
}

/// @notice Helper contract that rejects ETH transfers (for testing pending refund flow)
contract RejectETH {
    bool public acceptETH;

    function setAcceptETH(bool _accept) external {
        acceptETH = _accept;
    }

    receive() external payable {
        require(acceptETH, "Rejecting ETH");
    }
}
