// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesStaking} from "../src/VibesStaking.sol";
import {VibesToken} from "../src/VibesToken.sol";

contract VibesStakingTest is Test {
    VibesStaking public staking;
    VibesToken public vibesToken;

    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");

    uint256 public constant TOTAL_SUPPLY = 10_000_000 ether;
    uint256 public constant STAKE_AMOUNT = 100_000 ether;

    function setUp() public {
        vibesToken = new VibesToken("VIBES", "VIBES", 18, TOTAL_SUPPLY, address(this));
        staking = new VibesStaking(address(vibesToken), address(0));

        // Fund stakers
        vibesToken.transfer(staker1, STAKE_AMOUNT * 2);
        vibesToken.transfer(staker2, STAKE_AMOUNT * 2);

        // Approve staking contract
        vm.prank(staker1);
        vibesToken.approve(address(staking), type(uint256).max);
        vm.prank(staker2);
        vibesToken.approve(address(staking), type(uint256).max);
    }

    // ============ Constructor ============

    function test_constructor() public view {
        assertEq(address(staking.vibesToken()), address(vibesToken));
        assertEq(staking.totalStaked(), 0);
    }

    // ============ Stake Tests ============

    function test_stake() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        assertEq(staking.stakedBalance(staker1), STAKE_AMOUNT);
        assertEq(staking.totalStaked(), STAKE_AMOUNT);
        assertEq(staking.lastStakeTime(staker1), block.timestamp);
        assertEq(vibesToken.balanceOf(address(staking)), STAKE_AMOUNT);
    }

    function test_stake_multiple() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.warp(block.timestamp + 1 days);
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        assertEq(staking.stakedBalance(staker1), STAKE_AMOUNT * 2);
        assertEq(staking.totalStaked(), STAKE_AMOUNT * 2);
    }

    function test_stake_resetsLastStakeTime() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");
        uint256 firstTime = block.timestamp;

        vm.warp(block.timestamp + 5 days);
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        assertEq(staking.lastStakeTime(staker1), firstTime + 5 days);
    }

    function test_stake_multipleStakers() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker2);
        staking.stake(STAKE_AMOUNT * 2, 0, 0, "");

        assertEq(staking.totalStaked(), STAKE_AMOUNT * 3);
    }

    function test_stake_revertsZeroAmount() public {
        vm.prank(staker1);
        vm.expectRevert(VibesStaking.ZeroAmount.selector);
        staking.stake(0, 0, 0, "");
    }

    function test_stake_noCooldownOnStake() public {
        // Staking should NOT start a cooldown — unstakeRequestTime should remain 0
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        assertEq(staking.unstakeRequestTime(staker1), 0);
    }

    function test_stake_cancelsUnstakeRequest() public {
        // Stake, request unstake, then stake more → request cancelled
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        staking.requestUnstake();
        assertGt(staking.unstakeRequestTime(staker1), 0);

        // Stake more → cancels request
        vm.prank(staker1);
        staking.stake(1 ether, 0, 0, "");
        assertEq(staking.unstakeRequestTime(staker1), 0);
    }

    // ============ Request Unstake Tests ============

    function test_requestUnstake() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        staking.requestUnstake();

        assertEq(staking.unstakeRequestTime(staker1), block.timestamp);
    }

    function test_requestUnstake_emitsEvent() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        vm.expectEmit(true, false, false, true);
        emit VibesStaking.UnstakeRequested(staker1, block.timestamp + 7 days);
        staking.requestUnstake();
    }

    function test_requestUnstake_revertsNothingStaked() public {
        vm.prank(staker1);
        vm.expectRevert(VibesStaking.NothingStaked.selector);
        staking.requestUnstake();
    }

    function test_requestUnstake_canCallAgainToResetTimer() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        staking.requestUnstake();
        uint256 firstRequestTime = block.timestamp;

        vm.warp(block.timestamp + 3 days);

        // Call again → resets timer
        vm.prank(staker1);
        staking.requestUnstake();
        assertEq(staking.unstakeRequestTime(staker1), firstRequestTime + 3 days);
    }

    // ============ Unstake Tests ============

    function test_unstake() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        // Request unstake
        vm.prank(staker1);
        staking.requestUnstake();

        // Wait for cooldown
        vm.warp(block.timestamp + 7 days);

        vm.prank(staker1);
        staking.unstake(STAKE_AMOUNT);

        assertEq(staking.stakedBalance(staker1), 0);
        assertEq(staking.totalStaked(), 0);
        assertEq(vibesToken.balanceOf(staker1), STAKE_AMOUNT * 2);
    }

    function test_unstake_partial() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        staking.requestUnstake();
        vm.warp(block.timestamp + 7 days);

        vm.prank(staker1);
        staking.unstake(STAKE_AMOUNT / 2);

        assertEq(staking.stakedBalance(staker1), STAKE_AMOUNT / 2);
    }

    function test_unstake_partialThenMoreWithoutReRequest() public {
        // After cooldown, user can unstake multiple times without re-requesting
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        staking.requestUnstake();
        vm.warp(block.timestamp + 7 days);

        // First partial unstake
        vm.prank(staker1);
        staking.unstake(STAKE_AMOUNT / 4);
        assertEq(staking.stakedBalance(staker1), STAKE_AMOUNT * 3 / 4);

        // Second partial unstake — no need to re-request
        vm.prank(staker1);
        staking.unstake(STAKE_AMOUNT / 4);
        assertEq(staking.stakedBalance(staker1), STAKE_AMOUNT / 2);
    }

    function test_unstake_revertsUnstakeNotRequested() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        // Try unstake without requesting first
        vm.warp(block.timestamp + 7 days);
        vm.prank(staker1);
        vm.expectRevert(VibesStaking.UnstakeNotRequested.selector);
        staking.unstake(STAKE_AMOUNT);
    }

    function test_unstake_revertsCooldownActive() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        staking.requestUnstake();

        // Try unstake immediately (cooldown not elapsed)
        vm.prank(staker1);
        uint256 cooldownEnds = block.timestamp + 7 days;
        vm.expectRevert(abi.encodeWithSelector(VibesStaking.CooldownActive.selector, cooldownEnds));
        staking.unstake(STAKE_AMOUNT);
    }

    function test_unstake_stakeCancelsRequestRequiresReRequest() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        // Request unstake
        vm.prank(staker1);
        staking.requestUnstake();

        // Wait 6 days (almost done)
        vm.warp(block.timestamp + 6 days);

        // Stake more → cancels unstake request
        vm.prank(staker1);
        staking.stake(1 ether, 0, 0, "");

        // Even after waiting, can't unstake without new request
        vm.warp(block.timestamp + 7 days);
        vm.prank(staker1);
        vm.expectRevert(VibesStaking.UnstakeNotRequested.selector);
        staking.unstake(1 ether);

        // Must re-request
        vm.prank(staker1);
        staking.requestUnstake();
        vm.warp(block.timestamp + 7 days);
        vm.prank(staker1);
        staking.unstake(STAKE_AMOUNT + 1 ether);
    }

    function test_unstake_revertsZeroAmount() public {
        vm.prank(staker1);
        vm.expectRevert(VibesStaking.ZeroAmount.selector);
        staking.unstake(0);
    }

    function test_unstake_revertsInsufficientBalance() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        staking.requestUnstake();
        vm.warp(block.timestamp + 7 days);

        vm.prank(staker1);
        vm.expectRevert(VibesStaking.InsufficientBalance.selector);
        staking.unstake(STAKE_AMOUNT + 1);
    }

    function test_unstake_exactlyAtCooldownEnd() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        staking.requestUnstake();

        vm.warp(block.timestamp + 7 days);

        vm.prank(staker1);
        staking.unstake(STAKE_AMOUNT); // Should succeed exactly at cooldown end
    }

    function test_unstake_fullUnstakeClearsRequestTime() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        staking.requestUnstake();
        vm.warp(block.timestamp + 7 days);

        vm.prank(staker1);
        staking.unstake(STAKE_AMOUNT);

        // Full unstake should clear unstakeRequestTime
        assertEq(staking.unstakeRequestTime(staker1), 0);
        assertEq(staking.firstStakeTime(staker1), 0);
    }

    // ============ View Functions ============

    function test_getStakingInfo_noRequest() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        (uint256 balance, uint256 lastStake, uint256 cooldownEndsAt, bool canUnstake, uint256 firstStake, bool unstakeRequested) =
            staking.getStakingInfo(staker1);

        assertEq(balance, STAKE_AMOUNT);
        assertEq(lastStake, block.timestamp);
        assertEq(cooldownEndsAt, 0); // No request → no cooldown
        assertFalse(canUnstake);
        assertEq(firstStake, block.timestamp);
        assertFalse(unstakeRequested);
    }

    function test_getStakingInfo_withRequest() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker1);
        staking.requestUnstake();

        (uint256 balance, , uint256 cooldownEndsAt, bool canUnstake, , bool unstakeRequested) =
            staking.getStakingInfo(staker1);

        assertEq(balance, STAKE_AMOUNT);
        assertEq(cooldownEndsAt, block.timestamp + 7 days);
        assertFalse(canUnstake);
        assertTrue(unstakeRequested);

        // After cooldown
        vm.warp(block.timestamp + 7 days);
        (, , , canUnstake, , unstakeRequested) = staking.getStakingInfo(staker1);
        assertTrue(canUnstake);
        assertTrue(unstakeRequested);
    }

    function test_getStakerShare() public {
        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        vm.prank(staker2);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        // 50/50 split
        assertEq(staking.getStakerShare(staker1), 5000);
        assertEq(staking.getStakerShare(staker2), 5000);
    }

    function test_getStakerShare_zeroTotal() public view {
        assertEq(staking.getStakerShare(staker1), 0);
    }

    function test_isStaking() public {
        assertFalse(staking.isStaking(staker1));

        vm.prank(staker1);
        staking.stake(STAKE_AMOUNT, 0, 0, "");

        assertTrue(staking.isStaking(staker1));
    }

    function test_unstakeCooldownConstant() public view {
        assertEq(staking.UNSTAKE_COOLDOWN(), 7 days);
    }
}
