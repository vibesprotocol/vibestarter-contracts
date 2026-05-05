// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesStakerRewards} from "../src/VibesStakerRewards.sol";
import {VibesStaking} from "../src/VibesStaking.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VibesStakerRewardsTest is Test {
    VibesStakerRewards public rewards;
    VibesStaking public staking;
    VibesToken public vibesToken;
    VibesToken public vibetoken1; // reward token from raise 1
    VibesToken public vibetoken2; // reward token from raise 2

    address public admin = makeAddr("admin");
    address public router = makeAddr("router");
    address public escrow1 = makeAddr("escrow1");
    address public escrow2 = makeAddr("escrow2");
    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");
    address public staker3 = makeAddr("staker3");
    address public stranger = makeAddr("stranger");

    uint256 public constant VIBES_SUPPLY = 1_000_000_000 ether;
    uint256 public constant REWARD_AMOUNT = 25_000 ether; // 2.5% of 1M supply

    function setUp() public {
        // Deploy $VIBES token
        vibesToken = new VibesToken("Vibes", "VIBES", 18, VIBES_SUPPLY, address(this));

        // Deploy staking contract (trustedSigner = address(0) for bypass)
        staking = new VibesStaking(address(vibesToken), address(0));

        // Deploy rewards contract
        rewards = new VibesStakerRewards(admin, address(staking), router);

        // Audit fix F4: Authorize rewards contract to take snapshots on staking
        staking.setSnapshotAuthorized(address(rewards), true);

        // Deploy reward tokens (these represent vibetokens from raises)
        vibetoken1 = new VibesToken("VToken1", "VT1", 18, 1_000_000 ether, address(this));
        vibetoken2 = new VibesToken("VToken2", "VT2", 18, 1_000_000 ether, address(this));

        // Give stakers some $VIBES
        vibesToken.transfer(staker1, 100_000 ether);
        vibesToken.transfer(staker2, 50_000 ether);
        vibesToken.transfer(staker3, 50_000 ether);
    }

    // ============ Helpers ============

    function _stakeAs(address staker, uint256 amount) internal {
        vm.startPrank(staker);
        vibesToken.approve(address(staking), amount);
        staking.stake(amount, 0, 0, "");
        vm.stopPrank();
    }

    /// @dev Advances time by 1 second after staking so firstStakeTime < notifiedAt
    function _stakeAsAndAdvance(address staker, uint256 amount) internal {
        _stakeAs(staker, amount);
        vm.warp(block.timestamp + 1);
    }

    function _notifyRewardAs(address token, uint256 amount, address escrow) internal {
        // Transfer tokens to rewards contract first (as router would)
        IERC20(token).transfer(address(rewards), amount);
        // Then notify
        vm.prank(router);
        rewards.notifyReward(token, amount, escrow);
    }

    // ============ Constructor ============

    function test_constructor() public view {
        assertEq(rewards.admin(), admin);
        assertEq(rewards.stakingContract(), address(staking));
        assertEq(rewards.authorizedRouter(), router);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert(VibesStakerRewards.ZeroAddress.selector);
        new VibesStakerRewards(address(0), address(staking), router);
    }

    function test_constructor_revertsZeroStaking() public {
        vm.expectRevert(VibesStakerRewards.ZeroAddress.selector);
        new VibesStakerRewards(admin, address(0), router);
    }

    function test_constructor_revertsZeroRouter() public {
        vm.expectRevert(VibesStakerRewards.ZeroAddress.selector);
        new VibesStakerRewards(admin, address(staking), address(0));
    }

    // ============ notifyReward ============

    function test_notifyReward() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        (address token, uint256 total, uint256 claimed, uint256 snapshot, , bool active) =
            rewards.getRewardsInfo(escrow1);

        assertEq(token, address(vibetoken1));
        assertEq(total, REWARD_AMOUNT);
        assertEq(claimed, 0);
        assertEq(snapshot, 100_000 ether); // staker1's stake
        assertTrue(active);
        assertEq(rewards.getRewardedRaisesCount(), 1);
    }

    function test_notifyReward_revertsNotRouter() public {
        vm.prank(stranger);
        vm.expectRevert(VibesStakerRewards.OnlyRouter.selector);
        rewards.notifyReward(address(vibetoken1), REWARD_AMOUNT, escrow1);
    }

    function test_notifyReward_revertsAlreadySet() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        vibetoken1.transfer(address(rewards), REWARD_AMOUNT);
        vm.prank(router);
        vm.expectRevert(VibesStakerRewards.RewardAlreadySet.selector);
        rewards.notifyReward(address(vibetoken1), REWARD_AMOUNT, escrow1);
    }

    function test_notifyReward_revertsZeroToken() public {
        vm.prank(router);
        vm.expectRevert(VibesStakerRewards.ZeroAddress.selector);
        rewards.notifyReward(address(0), REWARD_AMOUNT, escrow1);
    }

    function test_notifyReward_revertsZeroEscrow() public {
        vm.prank(router);
        vm.expectRevert(VibesStakerRewards.ZeroAddress.selector);
        rewards.notifyReward(address(vibetoken1), REWARD_AMOUNT, address(0));
    }

    function test_notifyReward_zeroTotalStaked() public {
        // No one staking — tokens land but snapshot is 0
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        (, , , uint256 snapshot, , bool active) = rewards.getRewardsInfo(escrow1);
        assertEq(snapshot, 0);
        assertTrue(active);
    }

    // ============ Claim — Single Staker ============

    function test_claim_singleStaker() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        vm.prank(staker1);
        rewards.claim(escrow1);

        assertTrue(rewards.hasClaimed(escrow1, staker1));
        assertEq(vibetoken1.balanceOf(staker1), REWARD_AMOUNT); // Gets 100% since only staker
    }

    // ============ Claim — Multiple Stakers, Proportional ============

    function test_claim_proportionalDistribution() public {
        // staker1: 100k, staker2: 50k → 2:1 ratio
        _stakeAs(staker1, 100_000 ether);
        _stakeAsAndAdvance(staker2, 50_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        vm.prank(staker1);
        rewards.claim(escrow1);

        vm.prank(staker2);
        rewards.claim(escrow1);

        // staker1 gets 2/3, staker2 gets 1/3
        uint256 expected1 = (100_000 ether * REWARD_AMOUNT) / 150_000 ether;
        uint256 expected2 = (50_000 ether * REWARD_AMOUNT) / 150_000 ether;

        assertEq(vibetoken1.balanceOf(staker1), expected1);
        assertEq(vibetoken1.balanceOf(staker2), expected2);

        // Verify claimed totals
        (, , uint256 claimed, , ,) = rewards.getRewardsInfo(escrow1);
        assertEq(claimed, expected1 + expected2);
    }

    function test_claim_threeStakers_equalShares() public {
        // Equal stakes
        _stakeAs(staker1, 50_000 ether);
        _stakeAs(staker2, 50_000 ether);
        _stakeAsAndAdvance(staker3, 50_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        vm.prank(staker1);
        rewards.claim(escrow1);
        vm.prank(staker2);
        rewards.claim(escrow1);
        vm.prank(staker3);
        rewards.claim(escrow1);

        uint256 expectedEach = REWARD_AMOUNT / 3;
        assertEq(vibetoken1.balanceOf(staker1), expectedEach);
        assertEq(vibetoken1.balanceOf(staker2), expectedEach);
        // staker3 might get +1 wei due to rounding — cap to remaining
        assertTrue(vibetoken1.balanceOf(staker3) <= expectedEach + 1);
    }

    // ============ Claim — Edge Cases ============

    function test_claim_revertsAlreadyClaimed() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        vm.prank(staker1);
        rewards.claim(escrow1);

        vm.prank(staker1);
        vm.expectRevert(VibesStakerRewards.AlreadyClaimed.selector);
        rewards.claim(escrow1);
    }

    function test_claim_revertsNotActive() public {
        vm.prank(staker1);
        vm.expectRevert(VibesStakerRewards.RewardNotActive.selector);
        rewards.claim(escrow1);
    }

    function test_claim_revertsNoStake() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // stranger never staked
        vm.prank(stranger);
        vm.expectRevert(VibesStakerRewards.NoStakeAtSnapshot.selector);
        rewards.claim(escrow1);
    }

    function test_claim_zeroTotalStaked_cannotClaim() public {
        // No stakers when reward notified
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // Even if someone stakes after, they can't claim — firstStakeTime >= notifiedAt
        _stakeAs(staker1, 100_000 ether);

        (bool canClaimResult, ) = rewards.canClaim(escrow1, staker1);
        assertFalse(canClaimResult);

        // claim() should also revert with NoStakeAtSnapshot
        vm.prank(staker1);
        vm.expectRevert(VibesStakerRewards.NoStakeAtSnapshot.selector);
        rewards.claim(escrow1);
    }

    // ============ Claim — Multiple Raises ============

    function test_claim_multipleRaises() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);
        _notifyRewardAs(address(vibetoken2), REWARD_AMOUNT, escrow2);

        vm.startPrank(staker1);
        rewards.claim(escrow1);
        rewards.claim(escrow2);
        vm.stopPrank();

        assertEq(vibetoken1.balanceOf(staker1), REWARD_AMOUNT);
        assertEq(vibetoken2.balanceOf(staker1), REWARD_AMOUNT);
    }

    // ============ Batch Claim ============

    function test_claimMultiple() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);
        _notifyRewardAs(address(vibetoken2), REWARD_AMOUNT, escrow2);

        address[] memory escrows = new address[](2);
        escrows[0] = escrow1;
        escrows[1] = escrow2;

        vm.prank(staker1);
        rewards.claimMultiple(escrows);

        assertTrue(rewards.hasClaimed(escrow1, staker1));
        assertTrue(rewards.hasClaimed(escrow2, staker1));
        assertEq(vibetoken1.balanceOf(staker1), REWARD_AMOUNT);
        assertEq(vibetoken2.balanceOf(staker1), REWARD_AMOUNT);
    }

    function test_claimMultiple_skipsAlreadyClaimed() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // Claim once
        vm.prank(staker1);
        rewards.claim(escrow1);

        // Batch with same escrow — should skip, not revert
        address[] memory escrows = new address[](1);
        escrows[0] = escrow1;

        vm.prank(staker1);
        rewards.claimMultiple(escrows);
        // No revert = success
    }

    function test_claimMultiple_skipsInactive() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);

        // Only escrow1 has rewards
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        address[] memory escrows = new address[](2);
        escrows[0] = escrow1;
        escrows[1] = escrow2; // not active

        vm.prank(staker1);
        rewards.claimMultiple(escrows);

        assertTrue(rewards.hasClaimed(escrow1, staker1));
        assertFalse(rewards.hasClaimed(escrow2, staker1));
    }

    function test_claimMultiple_revertsEmpty() public {
        address[] memory escrows = new address[](0);
        vm.prank(staker1);
        vm.expectRevert(VibesStakerRewards.NoRewardsToClaim.selector);
        rewards.claimMultiple(escrows);
    }

    function test_claimMultiple_skipNoStake() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        address[] memory escrows = new address[](1);
        escrows[0] = escrow1;

        // stranger has no stake — batch skips gracefully
        vm.prank(stranger);
        rewards.claimMultiple(escrows);

        assertFalse(rewards.hasClaimed(escrow1, stranger));
    }

    // ============ Snapshot Isolation ============

    function test_snapshot_stakeAfterNotify_cannotClaim() public {
        // staker1 stakes before raise
        _stakeAsAndAdvance(staker1, 100_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // staker2 stakes AFTER the raise — firstStakeTime >= notifiedAt → ineligible
        _stakeAs(staker2, 50_000 ether);

        // canClaim returns false for staker2
        (bool canClaimResult, ) = rewards.canClaim(escrow1, staker2);
        assertFalse(canClaimResult);

        // claim() reverts for staker2
        vm.prank(staker2);
        vm.expectRevert(VibesStakerRewards.NoStakeAtSnapshot.selector);
        rewards.claim(escrow1);

        // staker1 claims — gets 100%
        vm.prank(staker1);
        rewards.claim(escrow1);
        assertEq(vibetoken1.balanceOf(staker1), REWARD_AMOUNT);
    }

    function test_snapshot_unstakeFullyThenClaim() public {
        // staker1 stakes, raise happens, staker1 fully unstakes
        _stakeAsAndAdvance(staker1, 100_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // Request unstake, advance past cooldown, then fully unstake
        vm.prank(staker1);
        staking.requestUnstake();
        vm.warp(block.timestamp + 8 days);
        vm.prank(staker1);
        staking.unstake(100_000 ether);

        // After full unstake, firstStakeTime is reset to 0 → ineligible
        (bool canClaimResult, ) = rewards.canClaim(escrow1, staker1);
        assertFalse(canClaimResult);
    }

    function test_snapshot_partialUnstakeAfterNotify_canStillClaim() public {
        // staker1 stakes 100k, raise happens, staker1 partially unstakes to 50k
        _stakeAsAndAdvance(staker1, 100_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // Request unstake, advance past cooldown, then partially unstake
        vm.prank(staker1);
        staking.requestUnstake();
        vm.warp(block.timestamp + 8 days);
        vm.prank(staker1);
        staking.unstake(50_000 ether);

        // firstStakeTime is NOT reset (still has balance) → still eligible
        // Audit fix F4: Snapshot captures notification-time balance (100k), not current (50k)
        vm.prank(staker1);
        rewards.claim(escrow1);

        // Gets full reward because snapshot balance was 100k when they were the only staker
        assertEq(vibetoken1.balanceOf(staker1), REWARD_AMOUNT);
    }

    function test_snapshot_topUpAfterNotify_getsOriginalShare() public {
        // staker1 stakes 50k, raise happens, staker1 adds 50k more
        _stakeAsAndAdvance(staker1, 50_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // Top up — firstStakeTime does NOT change (already had balance)
        vibesToken.transfer(staker1, 50_000 ether);
        _stakeAs(staker1, 50_000 ether);

        // Still eligible because firstStakeTime hasn't changed
        (bool canClaimResult, uint256 amt) = rewards.canClaim(escrow1, staker1);
        assertTrue(canClaimResult);

        // Audit fix F4: Snapshot captures notification-time balance (50k), not current (100k)
        // Gets full reward because snapshot balance was 50k = totalStakedSnapshot
        vm.prank(staker1);
        rewards.claim(escrow1);
        assertEq(vibetoken1.balanceOf(staker1), REWARD_AMOUNT);
    }

    function test_snapshot_batchSkipsPostNotifyStaker() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // staker2 stakes after notify
        _stakeAs(staker2, 50_000 ether);

        address[] memory escrows = new address[](1);
        escrows[0] = escrow1;

        // Batch claim for staker2 — should skip gracefully (not revert)
        vm.prank(staker2);
        rewards.claimMultiple(escrows);

        assertFalse(rewards.hasClaimed(escrow1, staker2));
    }

    // ============ canClaim View ============

    function test_canClaim_returnsCorrectAmount() public {
        _stakeAs(staker1, 100_000 ether);
        _stakeAsAndAdvance(staker2, 50_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        (bool can1, uint256 amt1) = rewards.canClaim(escrow1, staker1);
        assertTrue(can1);
        assertEq(amt1, (100_000 ether * REWARD_AMOUNT) / 150_000 ether);

        (bool can2, uint256 amt2) = rewards.canClaim(escrow1, staker2);
        assertTrue(can2);
        assertEq(amt2, (50_000 ether * REWARD_AMOUNT) / 150_000 ether);
    }

    function test_canClaim_falseAfterClaimed() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        vm.prank(staker1);
        rewards.claim(escrow1);

        (bool can, ) = rewards.canClaim(escrow1, staker1);
        assertFalse(can);
    }

    function test_canClaim_falseNotActive() public {
        (bool can, ) = rewards.canClaim(escrow1, staker1);
        assertFalse(can);
    }

    function test_canClaim_falseNoStake() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        (bool can, ) = rewards.canClaim(escrow1, stranger);
        assertFalse(can);
    }

    // ============ Admin Functions ============

    function test_transferAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        rewards.transferAdmin(newAdmin);
        assertEq(rewards.pendingAdmin(), newAdmin);
        assertEq(rewards.admin(), admin); // not yet

        vm.prank(newAdmin);
        rewards.acceptAdmin();
        assertEq(rewards.admin(), newAdmin);
        assertEq(rewards.pendingAdmin(), address(0));
    }

    function test_transferAdmin_revertsNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(VibesStakerRewards.OnlyAdmin.selector);
        rewards.transferAdmin(stranger);
    }

    function test_acceptAdmin_revertsNotPending() public {
        vm.prank(stranger);
        vm.expectRevert(VibesStakerRewards.OnlyAdmin.selector);
        rewards.acceptAdmin();
    }

    function test_setAuthorizedRouter() public {
        address newRouter = makeAddr("newRouter");

        vm.prank(admin);
        rewards.setAuthorizedRouter(newRouter);
        assertEq(rewards.authorizedRouter(), newRouter);
    }

    function test_setAuthorizedRouter_revertsNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(VibesStakerRewards.OnlyAdmin.selector);
        rewards.setAuthorizedRouter(stranger);
    }

    // ============ Rescue Unclaimable ============

    function test_rescueUnclaimable() public {
        // No stakers when reward notified
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        (, , , uint256 snapshot, , ) = rewards.getRewardsInfo(escrow1);
        assertEq(snapshot, 0);

        address recipient = makeAddr("recipient");
        vm.prank(admin);
        rewards.rescueUnclaimable(escrow1, recipient);

        assertEq(vibetoken1.balanceOf(recipient), REWARD_AMOUNT);
    }

    function test_rescueUnclaimable_revertsHasStakers() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        vm.prank(admin);
        vm.expectRevert("Has stakers");
        rewards.rescueUnclaimable(escrow1, admin);
    }

    function test_rescueUnclaimable_revertsNotAdmin() public {
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        vm.prank(stranger);
        vm.expectRevert(VibesStakerRewards.OnlyAdmin.selector);
        rewards.rescueUnclaimable(escrow1, stranger);
    }

    // ============ View Functions ============

    function test_getRewardedEscrows_paginated() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);
        _notifyRewardAs(address(vibetoken2), REWARD_AMOUNT, escrow2);

        address[] memory page1 = rewards.getRewardedEscrows(0, 1);
        assertEq(page1.length, 1);
        assertEq(page1[0], escrow1);

        address[] memory page2 = rewards.getRewardedEscrows(1, 1);
        assertEq(page2.length, 1);
        assertEq(page2[0], escrow2);

        address[] memory outOfBounds = rewards.getRewardedEscrows(5, 10);
        assertEq(outOfBounds.length, 0);
    }

    function test_getClaimStatuses() public {
        _stakeAsAndAdvance(staker1, 100_000 ether);
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        vm.prank(staker1);
        rewards.claim(escrow1);

        address[] memory escrows = new address[](2);
        escrows[0] = escrow1;
        escrows[1] = escrow2;

        bool[] memory statuses = rewards.getClaimStatuses(staker1, escrows);
        assertTrue(statuses[0]);
        assertFalse(statuses[1]);
    }

    function test_getClaimableAmounts() public {
        _stakeAs(staker1, 100_000 ether);
        _stakeAsAndAdvance(staker2, 50_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        address[] memory escrows = new address[](2);
        escrows[0] = escrow1;
        escrows[1] = escrow2; // not active

        uint256[] memory amounts = rewards.getClaimableAmounts(staker1, escrows);
        assertEq(amounts[0], (100_000 ether * REWARD_AMOUNT) / 150_000 ether);
        assertEq(amounts[1], 0);
    }

    // ============ Audit Fix F4: Snapshot-based reward distribution ============

    /// @notice F4: Staker who increases stake after notification should NOT get inflated reward
    function test_F4_stakeIncrease_afterNotification_doesNotInflateReward() public {
        // Two stakers: staker1=100k, staker2=50k
        _stakeAs(staker1, 100_000 ether);
        _stakeAsAndAdvance(staker2, 50_000 ether);

        // Raise finalized → notify reward (totalStaked=150k snapshot taken)
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // staker1 tries to game: adds 100k more AFTER notification
        vibesToken.transfer(staker1, 100_000 ether);
        _stakeAs(staker1, 100_000 ether);

        // staker1 claims — should get share based on 100k (snapshot), not 200k (current)
        vm.prank(staker1);
        rewards.claim(escrow1);

        uint256 expected = (100_000 ether * REWARD_AMOUNT) / 150_000 ether;
        assertEq(vibetoken1.balanceOf(staker1), expected, "Should get 100k/150k share, not 200k/150k");

        // staker2 claims — should get their fair share too
        vm.prank(staker2);
        rewards.claim(escrow1);

        uint256 expected2 = (50_000 ether * REWARD_AMOUNT) / 150_000 ether;
        assertEq(vibetoken1.balanceOf(staker2), expected2, "Should get 50k/150k share");
    }

    /// @notice F4: Staker who decreases stake after notification should still get original share
    function test_F4_stakeDecrease_afterNotification_getsOriginalShare() public {
        // staker1=100k, staker2=50k
        _stakeAs(staker1, 100_000 ether);
        _stakeAsAndAdvance(staker2, 50_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // staker1 partially unstakes AFTER notification (100k → 10k)
        vm.prank(staker1);
        staking.requestUnstake();
        vm.warp(block.timestamp + 8 days);
        vm.prank(staker1);
        staking.unstake(90_000 ether);

        // staker1 claims — should get share based on 100k (snapshot), not 10k (current)
        vm.prank(staker1);
        rewards.claim(escrow1);

        uint256 expected = (100_000 ether * REWARD_AMOUNT) / 150_000 ether;
        assertEq(vibetoken1.balanceOf(staker1), expected, "Should get 100k/150k share despite unstaking");
    }

    /// @notice F4: Multiple raises with different snapshots
    function test_F4_multipleRaises_independentSnapshots() public {
        // staker1 stakes 100k
        _stakeAsAndAdvance(staker1, 100_000 ether);

        // Raise 1 notified (snapshot: staker1=100k, total=100k)
        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // staker1 increases to 200k
        vibesToken.transfer(staker1, 100_000 ether);
        _stakeAs(staker1, 100_000 ether);

        // staker2 stakes 100k
        _stakeAsAndAdvance(staker2, 50_000 ether);

        // Raise 2 notified (snapshot: staker1=200k, staker2=50k, total=250k)
        _notifyRewardAs(address(vibetoken2), REWARD_AMOUNT, escrow2);

        // Raise 1: staker1 should get full reward (100k/100k from snapshot 1)
        vm.prank(staker1);
        rewards.claim(escrow1);
        assertEq(vibetoken1.balanceOf(staker1), REWARD_AMOUNT, "Full reward from raise 1");

        // Raise 2: staker1 should get 200k/250k share (from snapshot 2)
        vm.prank(staker1);
        rewards.claim(escrow2);
        uint256 expected2 = (200_000 ether * REWARD_AMOUNT) / 250_000 ether;
        assertEq(vibetoken2.balanceOf(staker1), expected2, "200k/250k share from raise 2");
    }

    /// @notice F4: Total claimed across all stakers never exceeds total reward tokens
    function test_F4_totalClaimed_neverExceedsTotalTokens() public {
        // 3 stakers with different amounts
        _stakeAs(staker1, 100_000 ether);
        _stakeAs(staker2, 50_000 ether);
        _stakeAsAndAdvance(staker3, 50_000 ether);

        _notifyRewardAs(address(vibetoken1), REWARD_AMOUNT, escrow1);

        // All gaming: increase stakes after notification
        vibesToken.transfer(staker1, 100_000 ether);
        _stakeAs(staker1, 100_000 ether);
        vibesToken.transfer(staker2, 100_000 ether);
        _stakeAs(staker2, 100_000 ether);

        // All claim
        vm.prank(staker1);
        rewards.claim(escrow1);
        vm.prank(staker2);
        rewards.claim(escrow1);
        vm.prank(staker3);
        rewards.claim(escrow1);

        uint256 totalClaimed = vibetoken1.balanceOf(staker1) + vibetoken1.balanceOf(staker2) + vibetoken1.balanceOf(staker3);
        assertLe(totalClaimed, REWARD_AMOUNT, "Total claimed must not exceed total reward");

        // Also verify rewards contract has minimal dust remaining
        uint256 remaining = vibetoken1.balanceOf(address(rewards));
        assertLe(remaining, 3, "At most 3 wei of rounding dust");
    }
}
