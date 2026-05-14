// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { VibesCommunityRewards } from "../src/VibesCommunityRewards.sol";
import { VibesStakerRewards } from "../src/VibesStakerRewards.sol";
import { VibesStaking } from "../src/VibesStaking.sol";
import { VibesToken } from "../src/VibesToken.sol";
import { VibesTokenDistributorV2 } from "../src/VibesTokenDistributorV2.sol";

contract FundFlowAuditTest is Test {
    address internal admin = makeAddr("admin");
    address internal router = makeAddr("router");
    address internal escrow = makeAddr("escrow");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal founder = makeAddr("founder");
    address internal opsWallet = makeAddr("opsWallet");

    /// @notice ZXVC VIB-06 (2026-05) regression — rounding dust rescue path.
    /// @dev Pre-fix this PoC asserted the BUG: when every staker's proportional share
    ///      rounds to zero, the entire reward stays stranded because (a) hasClaimed never
    ///      flips (zero-amount early return) and (b) rescueUnclaimable required
    ///      totalStakedSnapshot == 0. After fix:
    ///        (a) the zero-amount path now flips hasClaimed AND increments
    ///            eligibleClaimedShares, so the "all eligible have claimed" condition can
    ///            be detected;
    ///        (b) rescueUnclaimable allows rescue when eligibleClaimedShares reaches
    ///            totalStakedSnapshot (in addition to the original totalStakedSnapshot == 0
    ///            case and the time-based RESCUE_DELAY backstop).
    ///      Result: after every eligible staker calls claim (even a zero-amount one), the
    ///      admin can rescue the stranded rounding dust.
    function test_VIB06_stakerRewardRoundingDustIsRescuable() public {
        VibesToken stakeToken = new VibesToken("Stake", "STK", 0, 2, address(this));
        VibesToken rewardToken = new VibesToken("Reward", "RWD", 0, 1, address(this));

        VibesStaking staking = new VibesStaking(address(stakeToken), address(0));
        VibesStakerRewards rewards = new VibesStakerRewards(admin, address(staking), router);
        staking.setSnapshotAuthorized(address(rewards), true);

        vm.warp(100);
        stakeToken.transfer(alice, 1);
        stakeToken.transfer(bob, 1);

        vm.startPrank(alice);
        stakeToken.approve(address(staking), 1);
        staking.stake(1, 0, 0, "");
        vm.stopPrank();

        vm.startPrank(bob);
        stakeToken.approve(address(staking), 1);
        staking.stake(1, 0, 0, "");
        vm.stopPrank();

        // notifyReward at a later block so alice + bob are NOT same-block stakers (VIB-06
        // would otherwise exclude them from the snapshot).
        vm.warp(101);
        rewardToken.transfer(address(rewards), 1);
        vm.prank(router);
        rewards.notifyReward(address(rewardToken), 1, escrow);

        // Both stakers claim. Each share = 1 * 1 / 2 = 0 (integer division). Pre-fix
        // hasClaimed stayed false. Post-fix hasClaimed flips and eligibleClaimedShares
        // accumulates the staker balances.
        vm.prank(alice);
        rewards.claim(escrow);
        vm.prank(bob);
        rewards.claim(escrow);

        assertEq(rewardToken.balanceOf(alice), 0, "alice's share rounded to zero");
        assertEq(rewardToken.balanceOf(bob), 0, "bob's share rounded to zero");
        assertEq(rewardToken.balanceOf(address(rewards)), 1, "rounding dust stranded in contract");
        assertTrue(rewards.hasClaimed(escrow, alice), "VIB-06: hasClaimed flips even on zero-amount claim");
        assertTrue(rewards.hasClaimed(escrow, bob), "VIB-06: hasClaimed flips even on zero-amount claim");

        // VIB-06: eligibleClaimedShares now equals totalStakedSnapshot — rescue allowed.
        (,, uint256 claimedTokens, uint256 totalStakedSnapshot,,) = rewards.getRewardsInfo(escrow);
        assertEq(claimedTokens, 0);
        assertEq(totalStakedSnapshot, 2);
        assertEq(rewards.eligibleClaimedShares(escrow), 2, "all eligible shares accounted");

        vm.prank(admin);
        rewards.rescueUnclaimable(escrow, admin);
        assertEq(rewardToken.balanceOf(admin), 1, "admin recovered the stranded rounding dust");
        assertEq(rewardToken.balanceOf(address(rewards)), 0, "nothing left stranded");
    }

    /// @notice ZXVC VIB-10 (2026-05) regression — over-claim attempt reverts cleanly.
    /// @dev Pre-fix this PoC asserted the BUG: a 200-token leaf could be claimed from a
    ///      batch declared as 100 tokens, draining the contract beyond its declared budget
    ///      and bricking the claimedAmount > totalAmount accounting invariant. After fix,
    ///      claim reverts with "Exceeds batch total" — accounting stays consistent and the
    ///      contract balance is preserved for the legitimate next-batch operator.
    function test_VIB10_communityRewardsOverClaimRevertsCleanly() public {
        VibesToken token = new VibesToken("Community", "COM", 0, 300, address(this));
        VibesCommunityRewards rewards = new VibesCommunityRewards(IERC20(address(token)), 0, admin);
        token.transfer(address(rewards), 200);

        bytes32 root = _communityLeaf(alice, 200);
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(admin);
        rewards.createBatch(root, 100, 30 days, keccak256("audit-overclaim"));

        // ZXVC VIB-10 fix: claim amount 200 > totalAmount 100 → revert.
        vm.expectRevert(bytes("Exceeds batch total"));
        rewards.claim(0, alice, 200, proof);

        // Accounting and balances unchanged on revert.
        assertEq(token.balanceOf(alice), 0, "alice received nothing");
        assertEq(token.balanceOf(address(rewards)), 200, "contract balance preserved");

        (, uint256 totalAmount, uint256 claimedAmount,,, bool rescued,) = rewards.batches(0);
        assertEq(totalAmount, 100);
        assertEq(claimedAmount, 0, "claim accounting not advanced");
        assertFalse(rescued);
    }

    /// @notice ZXVC Extra-2 (2026-05) regression — legacy distributor enforces aggregate caps.
    /// @dev Pre-fix this PoC asserted the BUG: a merkle leaf with amounts exceeding the
    ///      configured totalTokens / totalEthRefunds caps succeeded, draining beyond budget.
    ///      Same shape as VIB-10 but on the deprecated VibesTokenDistributorV2 path.
    ///      After fix, claim reverts with "Exceeds totalTokens" (or totalEthRefunds) and
    ///      accounting stays consistent.
    function test_Extra2_legacyDistributorEnforcesConfiguredTotals() public {
        VibesToken token = new VibesToken("Legacy", "LEG", 0, 200, address(this));
        VibesTokenDistributorV2 distributor =
            new VibesTokenDistributorV2(address(token), founder, escrow, opsWallet, admin);

        token.transfer(address(distributor), 200);
        vm.deal(address(this), 2 ether);
        distributor.depositEthForRefunds{ value: 2 ether }();

        bytes32 root = _distributorLeaf(alice, 200, 2 ether);
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(founder);
        distributor.setDistributionRoot(root, 100, 1 ether);

        // ZXVC Extra-2 fix: 200 tokens > 100 totalTokens cap → revert.
        vm.prank(alice);
        vm.expectRevert(bytes("Exceeds totalTokens"));
        distributor.claim(200, 2 ether, proof);

        // Accounting unchanged on revert.
        assertEq(token.balanceOf(alice), 0, "no tokens leaked");
        assertEq(alice.balance, 0, "no ETH leaked");
        assertEq(distributor.totalTokensClaimed(), 0, "claim accounting not advanced");
        assertEq(distributor.totalEthClaimed(), 0);
    }

    function _communityLeaf(address recipient, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(abi.encodePacked(recipient, amount))));
    }

    function _distributorLeaf(address recipient, uint256 tokenAmount, uint256 ethRefund)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(keccak256(abi.encodePacked(recipient, tokenAmount, ethRefund)))
        );
    }
}
