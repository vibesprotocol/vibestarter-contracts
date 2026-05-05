// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesVesting} from "../src/VibesVesting.sol";
import {VibesToken} from "../src/VibesToken.sol";

/**
 * @title VibesVestingFreeze Tests
 * @notice Tests for freeze functionality, authorized freezer, and edge cases
 *         that were identified as coverage gaps in the vesting contract.
 */
contract VibesVestingFreezeTest is Test {
    VibesVesting public vesting;
    VibesToken public token;

    address public router = makeAddr("router");
    address public beneficiary = makeAddr("beneficiary");
    address public treasuryEscrow = makeAddr("treasuryEscrow");

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant VESTING_AMOUNT = 100_000 ether;

    function setUp() public {
        token = new VibesToken("Test", "TST", 18, TOTAL_SUPPLY, address(this));

        vm.prank(router);
        vesting = new VibesVesting(address(token), beneficiary, 180 days, 365 days);

        token.transfer(address(vesting), VESTING_AMOUNT);
    }

    function _initAndStart() internal {
        vm.prank(router);
        vesting.initializeAmount();
        vm.prank(router);
        vesting.startVesting();
    }

    // ============ setAuthorizedFreezer Tests ============

    function test_setAuthorizedFreezer_success() public {
        vm.prank(router);
        vesting.setAuthorizedFreezer(treasuryEscrow);
        assertEq(vesting.authorizedFreezer(), treasuryEscrow);
    }

    function test_setAuthorizedFreezer_revertsNotRouter() public {
        vm.prank(beneficiary);
        vm.expectRevert("Only authorized starter");
        vesting.setAuthorizedFreezer(treasuryEscrow);
    }

    function test_setAuthorizedFreezer_revertsZeroAddress() public {
        vm.prank(router);
        vm.expectRevert("Invalid freezer");
        vesting.setAuthorizedFreezer(address(0));
    }

    function test_setAuthorizedFreezer_revertsAlreadySet() public {
        vm.prank(router);
        vesting.setAuthorizedFreezer(treasuryEscrow);

        vm.prank(router);
        vm.expectRevert("Freezer already set");
        vesting.setAuthorizedFreezer(makeAddr("other"));
    }

    // ============ Freeze Tests ============

    function test_freeze_burnsUnvestedTokens() public {
        _initAndStart();

        vm.prank(router);
        vesting.setAuthorizedFreezer(treasuryEscrow);

        // Move to middle of cliff (3 months) — 0% vested
        vm.warp(block.timestamp + 90 days);

        uint256 vestingBalBefore = token.balanceOf(address(vesting));
        uint256 deadBalBefore = token.balanceOf(address(0xdead));

        vm.prank(treasuryEscrow);
        vesting.freeze();

        assertTrue(vesting.frozen());
        // All tokens should be burned (0% vested during cliff)
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(token.balanceOf(address(0xdead)), deadBalBefore + vestingBalBefore);
    }

    function test_freeze_afterPartialRelease() public {
        _initAndStart();

        vm.prank(router);
        vesting.setAuthorizedFreezer(treasuryEscrow);

        // Move past cliff + 6 months of linear vesting (6mo cliff + 6mo = 12mo)
        // Linear portion: 6/12 months = 50% of total vested
        vm.warp(block.timestamp + 180 days + 182.5 days);

        // Release what's vested
        uint256 releasable = vesting.releasable();
        assertTrue(releasable > 0, "Should have releasable tokens");
        vesting.release();

        uint256 beneficiaryBal = token.balanceOf(beneficiary);
        assertTrue(beneficiaryBal > 0, "Beneficiary should have received tokens");

        uint256 remainingInVesting = token.balanceOf(address(vesting));
        assertTrue(remainingInVesting > 0, "Should still have unvested tokens");
        uint256 deadBefore = token.balanceOf(address(0xdead));

        // Now freeze — remaining tokens burned
        vm.prank(treasuryEscrow);
        vesting.freeze();

        assertEq(token.balanceOf(address(vesting)), 0, "Vesting should be empty after freeze");
        assertEq(token.balanceOf(address(0xdead)), deadBefore + remainingInVesting);
        // Beneficiary keeps what was already released
        assertEq(token.balanceOf(beneficiary), beneficiaryBal);
    }

    function test_freeze_revertsNotAuthorized() public {
        _initAndStart();

        vm.prank(router);
        vesting.setAuthorizedFreezer(treasuryEscrow);

        vm.prank(beneficiary);
        vm.expectRevert("Only authorized freezer");
        vesting.freeze();
    }

    function test_freeze_revertsAlreadyFrozen() public {
        _initAndStart();

        vm.prank(router);
        vesting.setAuthorizedFreezer(treasuryEscrow);

        vm.prank(treasuryEscrow);
        vesting.freeze();

        vm.prank(treasuryEscrow);
        vm.expectRevert("Already frozen");
        vesting.freeze();
    }

    function test_release_revertsWhenFrozen() public {
        _initAndStart();

        vm.prank(router);
        vesting.setAuthorizedFreezer(treasuryEscrow);

        // Move past cliff so there would be releasable tokens
        vm.warp(block.timestamp + 180 days + 30 days);

        // Freeze first
        vm.prank(treasuryEscrow);
        vesting.freeze();

        // Now try to release
        vm.expectRevert("Vesting frozen");
        vesting.release();
    }

    function test_freeze_afterFullVest_zeroBalance() public {
        _initAndStart();

        vm.prank(router);
        vesting.setAuthorizedFreezer(treasuryEscrow);

        // Move past full vesting period (18 months total)
        vm.warp(block.timestamp + 180 days + 365 days + 1);

        // Release everything
        vesting.release();
        assertEq(token.balanceOf(address(vesting)), 0, "Everything should be released");

        uint256 deadBefore = token.balanceOf(address(0xdead));

        // Freeze — nothing left to burn, but should not revert
        vm.prank(treasuryEscrow);
        vesting.freeze();

        assertTrue(vesting.frozen());
        // Nothing extra burned (was already 0)
        assertEq(token.balanceOf(address(0xdead)), deadBefore);
    }

    function test_freeze_beforeVestingStart() public {
        // Initialize but don't start
        vm.prank(router);
        vesting.initializeAmount();

        vm.prank(router);
        vesting.setAuthorizedFreezer(treasuryEscrow);

        uint256 vestingBal = token.balanceOf(address(vesting));
        uint256 deadBefore = token.balanceOf(address(0xdead));

        // Freeze before start — all tokens burned
        vm.prank(treasuryEscrow);
        vesting.freeze();

        assertTrue(vesting.frozen());
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(token.balanceOf(address(0xdead)), deadBefore + vestingBal);
    }

    // ============ Release Edge Cases ============

    function test_release_multipleReleasesBeforeFreeze() public {
        _initAndStart();

        vm.prank(router);
        vesting.setAuthorizedFreezer(treasuryEscrow);

        // Release at cliff + 3 months
        vm.warp(block.timestamp + 180 days + 91 days);
        vesting.release();
        uint256 firstRelease = token.balanceOf(beneficiary);

        // Release again at cliff + 6 months
        vm.warp(block.timestamp + 91 days);
        vesting.release();
        uint256 secondRelease = token.balanceOf(beneficiary) - firstRelease;
        assertTrue(secondRelease > 0, "Should have more to release");

        // Freeze
        uint256 remaining = token.balanceOf(address(vesting));
        vm.prank(treasuryEscrow);
        vesting.freeze();

        // Beneficiary keeps both releases
        assertEq(token.balanceOf(beneficiary), firstRelease + secondRelease);
        // Remaining burned
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_release_nothingDuringCliff() public {
        _initAndStart();

        // At cliff boundary (exactly 180 days) — true delayed start means 0%
        vm.warp(block.timestamp + 180 days);

        assertEq(vesting.releasable(), 0, "Should be 0 at cliff end");

        vm.expectRevert("Nothing to release");
        vesting.release();
    }

    function test_vest_verySmallAmount() public {
        // Create a new vesting with only 1000 wei
        VibesToken smallToken = new VibesToken("Small", "SM", 18, TOTAL_SUPPLY, address(this));

        vm.prank(router);
        VibesVesting smallVesting = new VibesVesting(address(smallToken), beneficiary, 180 days, 365 days);

        smallToken.transfer(address(smallVesting), 1000);

        vm.prank(router);
        smallVesting.initializeAmount();
        vm.prank(router);
        smallVesting.startVesting();

        // After full vest, beneficiary gets everything
        vm.warp(block.timestamp + 180 days + 365 days + 1);

        uint256 releasable = smallVesting.releasable();
        assertEq(releasable, 1000, "Full amount should be releasable");

        smallVesting.release();
        assertEq(smallToken.balanceOf(beneficiary), 1000);
    }
}
