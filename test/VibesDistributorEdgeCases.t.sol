// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesTokenDistributorV2} from "../src/VibesTokenDistributorV2.sol";
import {VibesToken} from "../src/VibesToken.sol";

/// @notice Contract that attempts reentrancy via receive()
contract ReentrantDistributionRecipient {
    VibesTokenDistributorV2 public distributor;
    uint256 public attackCount;

    constructor(address _distributor) {
        distributor = VibesTokenDistributorV2(payable(_distributor));
    }

    receive() external payable {
        if (attackCount < 2) {
            attackCount++;
            try distributor.claimPendingEth() {} catch {}
        }
    }
}

/// @notice Contract that consumes excessive gas in receive()
contract GasGuzzler {
    uint256 public waste;

    receive() external payable {
        // Consume ~30k gas in a loop
        for (uint256 i = 0; i < 100; i++) {
            waste = i;
        }
    }
}

/// @notice Contract that conditionally rejects ETH
contract ConditionalRejector {
    bool public acceptETH;

    function setAcceptETH(bool _accept) external {
        acceptETH = _accept;
    }

    receive() external payable {
        require(acceptETH, "Rejecting ETH");
    }
}

/// @notice Contract that always accepts ETH
contract ETHAcceptor {
    receive() external payable {}
}

/**
 * @title VibesTokenDistributorV2 Edge Case Tests
 * @notice Tests for critical coverage gaps:
 *         - Sweep with pending ETH protection (H8 fix)
 *         - Batch distribution with mixed rejecting recipients
 *         - Combined token + ETH claim edge cases
 *         - Insufficient ETH during batch distribution
 */
contract VibesDistributorEdgeCasesTest is Test {
    VibesTokenDistributorV2 public distributor;
    VibesToken public token;

    address public founder = makeAddr("founder");
    address public campaign = makeAddr("campaign");
    address public opsWallet = makeAddr("opsWallet");
    address public admin = makeAddr("admin");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");

    uint256 public constant TOTAL_SUPPLY = 10_000_000 ether;
    uint256 public constant DIST_TOKENS = 700_000 ether;

    function setUp() public {
        token = new VibesToken("Test", "TST", 18, TOTAL_SUPPLY, address(this));
    }

    // ============ Helpers ============

    function _deployDistributor() internal returns (VibesTokenDistributorV2) {
        VibesTokenDistributorV2 dist = new VibesTokenDistributorV2(
            address(token), founder, campaign, opsWallet, admin
        );
        token.transfer(address(dist), DIST_TOKENS);
        return dist;
    }

    function _singleLeafRoot(bytes32 leaf) internal pure returns (bytes32) {
        return leaf;
    }

    // ============ Sweep + Pending ETH Protection (H8) ============

    function test_sweep_protectsPendingEthRefunds() public {
        distributor = _deployDistributor();

        // Create rejecting contract as a backer
        ConditionalRejector rejector = new ConditionalRejector();
        address rejAddr = address(rejector);

        // Build single-leaf tree for rejector: 0 tokens, 2 ETH refund
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(rejAddr, uint256(0), uint256(2 ether)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.deal(address(distributor), 3 ether); // 2 ETH for refund + 1 ETH excess

        vm.prank(founder);
        distributor.setDistributionRoot(root, 0, 2 ether);

        // Batch distribute — ETH rejected, tracked as pending
        address[] memory r = new address[](1);
        r[0] = rejAddr;
        uint256[] memory t = new uint256[](1);
        t[0] = 0;
        uint256[] memory e = new uint256[](1);
        e[0] = 2 ether;
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = new bytes32[](0);

        vm.prank(founder);
        distributor.batchDistribute(r, t, e, p);

        assertEq(distributor.pendingEthRefunds(rejAddr), 2 ether);
        assertEq(distributor.totalPendingEthRefunds(), 2 ether);

        // Advance past sweep delay
        vm.warp(block.timestamp + 181 days);

        uint256 opsBalBefore = opsWallet.balance;

        // Sweep — should only sweep the 1 ETH excess, NOT the 2 ETH pending
        vm.prank(admin);
        distributor.sweepUnclaimed();

        // Ops wallet gets tokens + only excess ETH (3 - 2 pending = 1)
        assertEq(opsWallet.balance, opsBalBefore + 1 ether, "Ops should get only non-pending ETH");

        // Pending ETH should still be claimable
        rejector.setAcceptETH(true);
        vm.prank(rejAddr);
        distributor.claimPendingEth();
        assertEq(rejAddr.balance, 2 ether, "Pending refund should still be claimable after sweep");
    }

    function test_sweep_withNoPendingEth() public {
        distributor = _deployDistributor();

        // Set up with claimed distribution
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(400_000 ether), uint256(0)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.prank(founder);
        distributor.setDistributionRoot(root, DIST_TOKENS, 0);

        // Advance past sweep delay
        vm.warp(block.timestamp + 181 days);

        // Sweep with no pending — all goes to ops
        vm.prank(admin);
        distributor.sweepUnclaimed();

        assertEq(token.balanceOf(opsWallet), DIST_TOKENS);
    }

    // ============ Batch Distribution with Mixed Recipients ============

    function test_batchDistribute_mixedRejectingRecipients() public {
        distributor = _deployDistributor();

        // One rejects ETH, one accepts
        ConditionalRejector rejector = new ConditionalRejector();
        ETHAcceptor acceptor = new ETHAcceptor();

        address rejAddr = address(rejector);
        address accAddr = address(acceptor);

        // Build 2-leaf tree
        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(rejAddr, uint256(100_000 ether), uint256(1 ether)))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(accAddr, uint256(100_000 ether), uint256(1 ether)))));

        bytes32 root;
        if (uint256(leaf1) < uint256(leaf2)) {
            root = keccak256(abi.encodePacked(leaf1, leaf2));
        } else {
            root = keccak256(abi.encodePacked(leaf2, leaf1));
        }

        vm.deal(address(distributor), 2 ether);
        vm.prank(founder);
        distributor.setDistributionRoot(root, 200_000 ether, 2 ether);

        // Batch distribute both
        address[] memory recipients = new address[](2);
        recipients[0] = rejAddr;
        recipients[1] = accAddr;
        uint256[] memory tokenAmounts = new uint256[](2);
        tokenAmounts[0] = 100_000 ether;
        tokenAmounts[1] = 100_000 ether;
        uint256[] memory ethRefunds = new uint256[](2);
        ethRefunds[0] = 1 ether;
        ethRefunds[1] = 1 ether;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = leaf2;
        proofs[1] = new bytes32[](1);
        proofs[1][0] = leaf1;

        vm.prank(founder);
        distributor.batchDistribute(recipients, tokenAmounts, ethRefunds, proofs);

        // Rejector: tokens distributed, ETH pending
        assertEq(token.balanceOf(rejAddr), 100_000 ether, "Rejector should receive tokens");
        assertEq(distributor.pendingEthRefunds(rejAddr), 1 ether, "Rejector ETH should be pending");

        // Acceptor: both tokens and ETH received
        assertEq(token.balanceOf(accAddr), 100_000 ether, "Acceptor should receive tokens");
        assertEq(accAddr.balance, 1 ether, "Acceptor should receive ETH");
    }

    function test_batchDistribute_skipsAlreadyClaimed() public {
        distributor = _deployDistributor();

        // Set up single-backer tree
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(400_000 ether), uint256(0)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.prank(founder);
        distributor.setDistributionRoot(root, DIST_TOKENS, 0);

        // Direct claim first
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(backer1);
        distributor.claim(400_000 ether, 0, proof);

        // Now batch — should skip backer1 (already claimed)
        address[] memory r = new address[](1);
        r[0] = backer1;
        uint256[] memory t = new uint256[](1);
        t[0] = 400_000 ether;
        uint256[] memory e = new uint256[](1);
        e[0] = 0;
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = new bytes32[](0);

        vm.prank(founder);
        distributor.batchDistribute(r, t, e, p);

        // Balance unchanged (not double-distributed)
        assertEq(token.balanceOf(backer1), 400_000 ether);
    }

    // ============ Claim Edge Cases ============

    function test_claim_tokenOnly_zeroEthRefund() public {
        distributor = _deployDistributor();

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(500_000 ether), uint256(0)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.prank(founder);
        distributor.setDistributionRoot(root, DIST_TOKENS, 0);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(backer1);
        distributor.claim(500_000 ether, 0, proof);

        assertEq(token.balanceOf(backer1), 500_000 ether);
    }

    function test_claim_ethOnly_zeroTokens() public {
        distributor = _deployDistributor();

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(0), uint256(1 ether)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.deal(address(distributor), 1 ether);
        vm.prank(founder);
        distributor.setDistributionRoot(root, 0, 1 ether);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(backer1);
        distributor.claim(0, 1 ether, proof);

        assertEq(backer1.balance, 1 ether);
        assertEq(token.balanceOf(backer1), 0);
    }

    function test_claim_revertsZeroBoth() public {
        distributor = _deployDistributor();

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(0), uint256(0)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.prank(founder);
        distributor.setDistributionRoot(root, 0, 0);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(backer1);
        vm.expectRevert(VibesTokenDistributorV2.InvalidAmount.selector);
        distributor.claim(0, 0, proof);
    }

    // ============ Deposit ETH for Refunds ============

    function test_depositEthForRefunds_multipleDeposits() public {
        distributor = _deployDistributor();

        vm.deal(backer1, 5 ether);

        vm.prank(backer1);
        distributor.depositEthForRefunds{value: 2 ether}();

        vm.prank(backer1);
        distributor.depositEthForRefunds{value: 3 ether}();

        assertEq(address(distributor).balance, 5 ether);
    }

    // ============ Receive ETH ============

    function test_receiveEth_directTransfer() public {
        distributor = _deployDistributor();

        vm.deal(address(this), 1 ether);
        (bool sent, ) = address(distributor).call{value: 1 ether}("");
        assertTrue(sent, "Distributor should accept ETH");
        assertEq(address(distributor).balance, 1 ether);
    }

    // ============ Malicious Recipient Tests ============

    function test_batchDistribute_reentrantRecipient_blocked() public {
        distributor = _deployDistributor();

        ReentrantDistributionRecipient attacker = new ReentrantDistributionRecipient(address(distributor));
        address atkAddr = address(attacker);

        // Build single-leaf tree for attacker: 100k tokens + 1 ETH refund
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(atkAddr, uint256(100_000 ether), uint256(1 ether)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.deal(address(distributor), 1 ether);
        vm.prank(founder);
        distributor.setDistributionRoot(root, DIST_TOKENS, 1 ether);

        address[] memory r = new address[](1);
        r[0] = atkAddr;
        uint256[] memory t = new uint256[](1);
        t[0] = 100_000 ether;
        uint256[] memory e = new uint256[](1);
        e[0] = 1 ether;
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = new bytes32[](0);

        vm.prank(founder);
        distributor.batchDistribute(r, t, e, p);

        // Attacker received tokens
        assertEq(token.balanceOf(atkAddr), 100_000 ether, "Should receive tokens");

        // ETH was either sent or tracked as pending (reentrancy in receive may cause failure)
        uint256 atkBalance = atkAddr.balance;
        uint256 pendingEth = distributor.pendingEthRefunds(atkAddr);
        assertEq(atkBalance + pendingEth, 1 ether, "Total owed ETH should be accounted for");
    }

    function test_batchDistribute_gasGuzzlingRecipient() public {
        distributor = _deployDistributor();

        GasGuzzler guzzler = new GasGuzzler();
        address gAddr = address(guzzler);

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(gAddr, uint256(100_000 ether), uint256(1 ether)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.deal(address(distributor), 1 ether);
        vm.prank(founder);
        distributor.setDistributionRoot(root, DIST_TOKENS, 1 ether);

        address[] memory r = new address[](1);
        r[0] = gAddr;
        uint256[] memory t = new uint256[](1);
        t[0] = 100_000 ether;
        uint256[] memory e = new uint256[](1);
        e[0] = 1 ether;
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = new bytes32[](0);

        vm.prank(founder);
        distributor.batchDistribute(r, t, e, p);

        // Gas guzzler should still receive tokens
        assertEq(token.balanceOf(gAddr), 100_000 ether, "Gas guzzler should receive tokens");
        // ETH either sent or pending
        uint256 total = gAddr.balance + distributor.pendingEthRefunds(gAddr);
        assertEq(total, 1 ether, "ETH accounted for");
    }

    function test_batchDistribute_101recipients_reverts() public {
        distributor = _deployDistributor();

        // setDistributionRoot reverts on bytes32(0) (ZeroAddress). Use a dummy
        // non-zero root so distributionSet flips true and we actually reach
        // the length check instead of hitting DistributionNotSet first.
        bytes32 dummyRoot = keccak256("batch-size-guard-test");
        vm.prank(founder);
        distributor.setDistributionRoot(dummyRoot, 0, 0);

        address[] memory r = new address[](101);
        uint256[] memory t = new uint256[](101);
        uint256[] memory e = new uint256[](101);
        bytes32[][] memory p = new bytes32[][](101);
        for (uint256 i = 0; i < 101; i++) {
            r[i] = address(uint160(i + 1));
            t[i] = 0;
            e[i] = 0;
            p[i] = new bytes32[](0);
        }

        vm.prank(founder);
        vm.expectRevert("Batch too large");
        distributor.batchDistribute(r, t, e, p);
    }

    function test_claimPendingEth_afterBatchFailure() public {
        distributor = _deployDistributor();

        ConditionalRejector rejector = new ConditionalRejector();
        address rejAddr = address(rejector);

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(rejAddr, uint256(0), uint256(2 ether)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.deal(address(distributor), 2 ether);
        vm.prank(founder);
        distributor.setDistributionRoot(root, 0, 2 ether);

        address[] memory r = new address[](1);
        r[0] = rejAddr;
        uint256[] memory t = new uint256[](1);
        t[0] = 0;
        uint256[] memory e = new uint256[](1);
        e[0] = 2 ether;
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = new bytes32[](0);

        vm.prank(founder);
        distributor.batchDistribute(r, t, e, p);

        assertEq(distributor.pendingEthRefunds(rejAddr), 2 ether);

        // Now enable receiving and claim
        rejector.setAcceptETH(true);
        vm.prank(rejAddr);
        distributor.claimPendingEth();

        assertEq(rejAddr.balance, 2 ether, "Should claim pending ETH");
        assertEq(distributor.pendingEthRefunds(rejAddr), 0, "Pending should be cleared");
        assertEq(distributor.totalPendingEthRefunds(), 0, "Total pending should decrease");
    }

    function test_batchDistribute_zeroEthRefund_withToken() public {
        distributor = _deployDistributor();

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(200_000 ether), uint256(0)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.prank(founder);
        distributor.setDistributionRoot(root, DIST_TOKENS, 0);

        address[] memory r = new address[](1);
        r[0] = backer1;
        uint256[] memory t = new uint256[](1);
        t[0] = 200_000 ether;
        uint256[] memory e = new uint256[](1);
        e[0] = 0;
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = new bytes32[](0);

        vm.prank(founder);
        distributor.batchDistribute(r, t, e, p);

        assertEq(token.balanceOf(backer1), 200_000 ether, "Token transfer should succeed with 0 ETH");
        assertEq(backer1.balance, 0, "No ETH should be sent");
    }
}

// ============ Mock ERC20 Tokens ============

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that reverts on transfer to specific blacklisted addresses
contract MockBlacklistERC20 is ERC20 {
    mapping(address => bool) public blacklisted;

    constructor(uint256 supply) ERC20("Blacklist", "BL") {
        _mint(msg.sender, supply);
    }

    function setBlacklist(address addr, bool blocked) external {
        blacklisted[addr] = blocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[to], "Blacklisted recipient");
        require(!blacklisted[from], "Blacklisted sender");
        super._update(from, to, value);
    }
}

/// @notice ERC20 that always reverts on transfer
contract MockRevertingERC20 is ERC20 {
    bool public shouldRevertTransfers;

    constructor(uint256 supply) ERC20("Reverting", "REV") {
        _mint(msg.sender, supply);
    }

    function setShouldRevert(bool _revert) external {
        shouldRevertTransfers = _revert;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (shouldRevertTransfers && from != address(0)) {
            revert("Transfer blocked");
        }
        super._update(from, to, value);
    }
}

/**
 * @title Distributor tests with reverting/blacklisting ERC20 tokens
 */
contract VibesDistributorTokenEdgeCasesTest is Test {
    address public founder = makeAddr("founder");
    address public campaign = makeAddr("campaign");
    address public opsWallet = makeAddr("opsWallet");
    address public admin = makeAddr("admin");
    address public backer1 = makeAddr("backer1");

    uint256 public constant TOTAL_SUPPLY = 10_000_000 ether;
    uint256 public constant DIST_TOKENS = 700_000 ether;

    function _singleLeafRoot(bytes32 leaf) internal pure returns (bytes32) {
        return leaf;
    }

    function test_batchDistribute_revertingToken() public {
        MockRevertingERC20 revToken = new MockRevertingERC20(TOTAL_SUPPLY);

        VibesTokenDistributorV2 dist = new VibesTokenDistributorV2(
            address(revToken), founder, campaign, opsWallet, admin
        );
        revToken.transfer(address(dist), DIST_TOKENS);

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(100_000 ether), uint256(0)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.prank(founder);
        dist.setDistributionRoot(root, DIST_TOKENS, 0);

        // Now make token revert on transfers
        revToken.setShouldRevert(true);

        address[] memory r = new address[](1);
        r[0] = backer1;
        uint256[] memory t = new uint256[](1);
        t[0] = 100_000 ether;
        uint256[] memory e = new uint256[](1);
        e[0] = 0;
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = new bytes32[](0);

        // SafeERC20 wraps the revert — batchDistribute should revert
        vm.prank(founder);
        vm.expectRevert();
        dist.batchDistribute(r, t, e, p);
    }

    function test_claim_revertingToken() public {
        MockRevertingERC20 revToken = new MockRevertingERC20(TOTAL_SUPPLY);

        VibesTokenDistributorV2 dist = new VibesTokenDistributorV2(
            address(revToken), founder, campaign, opsWallet, admin
        );
        revToken.transfer(address(dist), DIST_TOKENS);

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(100_000 ether), uint256(0)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.prank(founder);
        dist.setDistributionRoot(root, DIST_TOKENS, 0);

        // Make token revert
        revToken.setShouldRevert(true);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(backer1);
        vm.expectRevert();
        dist.claim(100_000 ether, 0, proof);
    }

    function test_batchDistribute_blacklistToken() public {
        MockBlacklistERC20 blToken = new MockBlacklistERC20(TOTAL_SUPPLY);

        VibesTokenDistributorV2 dist = new VibesTokenDistributorV2(
            address(blToken), founder, campaign, opsWallet, admin
        );
        blToken.transfer(address(dist), DIST_TOKENS);

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(100_000 ether), uint256(0)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.prank(founder);
        dist.setDistributionRoot(root, DIST_TOKENS, 0);

        // Blacklist backer1
        blToken.setBlacklist(backer1, true);

        address[] memory r = new address[](1);
        r[0] = backer1;
        uint256[] memory t = new uint256[](1);
        t[0] = 100_000 ether;
        uint256[] memory e = new uint256[](1);
        e[0] = 0;
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = new bytes32[](0);

        // SafeERC20.safeTransfer to blacklisted address should revert
        vm.prank(founder);
        vm.expectRevert();
        dist.batchDistribute(r, t, e, p);
    }

    function test_sweep_revertingToken() public {
        MockRevertingERC20 revToken = new MockRevertingERC20(TOTAL_SUPPLY);

        VibesTokenDistributorV2 dist = new VibesTokenDistributorV2(
            address(revToken), founder, campaign, opsWallet, admin
        );
        revToken.transfer(address(dist), DIST_TOKENS);

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(backer1, uint256(100_000 ether), uint256(0)))));
        bytes32 root = _singleLeafRoot(leaf);

        vm.prank(founder);
        dist.setDistributionRoot(root, DIST_TOKENS, 0);

        // Advance past sweep delay
        vm.warp(block.timestamp + 181 days);

        // Make token revert
        revToken.setShouldRevert(true);

        // Sweep should revert when token transfer fails
        vm.prank(admin);
        vm.expectRevert();
        dist.sweepUnclaimed();
    }
}
