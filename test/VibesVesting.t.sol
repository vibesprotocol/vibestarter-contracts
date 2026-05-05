// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesVesting} from "../src/VibesVesting.sol";
import {VibesToken} from "../src/VibesToken.sol";

contract VibesVestingTest is Test {
    VibesVesting public vesting;
    VibesToken public token;

    address public router = makeAddr("router");
    address public beneficiary = makeAddr("beneficiary");
    address public stranger = makeAddr("stranger");

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant VESTING_AMOUNT = 100_000 ether;

    function setUp() public {
        token = new VibesToken("Test", "TST", 18, TOTAL_SUPPLY, address(this));

        // Deploy vesting as the router (authorizedStarter = msg.sender)
        vm.prank(router);
        vesting = new VibesVesting(address(token), beneficiary, 180 days, 365 days);

        // Transfer tokens to vesting contract
        token.transfer(address(vesting), VESTING_AMOUNT);
    }

    // Helper: initialize as the authorized router
    function _initialize() internal {
        vm.prank(router);
        vesting.initializeAmount();
    }

    // ============ Constructor Tests ============

    function test_constructor_setsImmutables() public view {
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.beneficiary(), beneficiary);
        assertEq(vesting.authorizedStarter(), router);
        assertEq(vesting.CLIFF(), 180 days);
        assertEq(vesting.VESTING_DURATION(), 365 days);
        assertEq(vesting.start(), 0);
        assertFalse(vesting.initialized());
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert("Invalid token");
        new VibesVesting(address(0), beneficiary, 180 days, 365 days);
    }

    function test_constructor_revertsZeroBeneficiary() public {
        vm.expectRevert("Invalid beneficiary");
        new VibesVesting(address(token), address(0), 180 days, 365 days);
    }

    // ============ Constants Tests ============

    function test_cliff_is_180_days() public view {
        assertEq(vesting.CLIFF(), 180 days);
    }

    function test_vestingDuration_is_365_days() public view {
        assertEq(vesting.VESTING_DURATION(), 365 days);
    }

    // ============ Initialize Tests ============

    function test_initializeAmount() public {
        _initialize();
        assertTrue(vesting.initialized());
        assertEq(vesting.totalAmount(), VESTING_AMOUNT);
    }

    function test_initializeAmount_revertsDoubleInit() public {
        _initialize();
        vm.expectRevert("Already initialized");
        _initialize();
    }

    function test_initializeAmount_revertsNoTokens() public {
        vm.prank(router);
        VibesVesting emptyVesting = new VibesVesting(address(token), beneficiary, 180 days, 365 days);
        vm.expectRevert("No tokens to vest");
        vm.prank(router);
        emptyVesting.initializeAmount();
    }

    // ============ Start Vesting Tests ============

    function test_startVesting() public {
        _initialize();

        vm.prank(router);
        vesting.startVesting();

        assertEq(vesting.start(), block.timestamp);
    }

    function test_startVesting_revertsUnauthorized() public {
        _initialize();

        vm.prank(stranger);
        vm.expectRevert("Only authorized starter");
        vesting.startVesting();
    }

    function test_startVesting_revertsNotInitialized() public {
        vm.prank(router);
        vm.expectRevert("Not initialized");
        vesting.startVesting();
    }

    function test_startVesting_revertsAlreadyStarted() public {
        _initialize();

        vm.prank(router);
        vesting.startVesting();

        vm.prank(router);
        vm.expectRevert("Vesting already started");
        vesting.startVesting();
    }

    // ============ Vested Amount Tests ============

    function test_vestedAmount_beforeInit() public view {
        assertEq(vesting.vestedAmount(), 0);
    }

    function test_vestedAmount_beforeStart() public {
        _initialize();
        assertEq(vesting.vestedAmount(), 0);
    }

    function test_vestedAmount_duringCliff() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        // Advance to middle of cliff
        vm.warp(block.timestamp + vesting.CLIFF() / 2);
        assertEq(vesting.vestedAmount(), 0);

        // Right before cliff ends
        vm.warp(vesting.start() + vesting.CLIFF() - 1);
        assertEq(vesting.vestedAmount(), 0);
    }

    function test_vestedAmount_zeroAtCliffEnd() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        // Exactly at cliff end: true delayed start means 0% vested
        vm.warp(vesting.start() + vesting.CLIFF());
        assertEq(vesting.vestedAmount(), 0);
    }

    function test_trueDelayedStart_noRetroactive() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        // At cliff boundary, vested should be exactly 0 (NOT retroactive)
        vm.warp(vesting.start() + vesting.CLIFF());
        assertEq(vesting.vestedAmount(), 0, "Should NOT retroactively vest at cliff end");

        // 1 second after cliff: tiny amount vested
        vm.warp(vesting.start() + vesting.CLIFF() + 1);
        uint256 vestedAfter1s = vesting.vestedAmount();
        assertTrue(vestedAfter1s > 0, "Should vest after cliff");
        assertEq(vestedAfter1s, (VESTING_AMOUNT * 1) / vesting.VESTING_DURATION());
    }

    function test_vestedAmount_linearFromCliff() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        // Halfway through the vesting period (6 months after cliff)
        uint256 halfVesting = vesting.VESTING_DURATION() / 2;
        vm.warp(vesting.start() + vesting.CLIFF() + halfVesting);
        uint256 expected = (VESTING_AMOUNT * halfVesting) / vesting.VESTING_DURATION();
        assertEq(vesting.vestedAmount(), expected);
    }

    function test_vestedAmount_fullAt18Months() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        // At start + CLIFF + VESTING_DURATION (18 months total)
        vm.warp(vesting.start() + vesting.CLIFF() + vesting.VESTING_DURATION());
        assertEq(vesting.vestedAmount(), VESTING_AMOUNT);

        // Well past duration
        vm.warp(vesting.start() + vesting.CLIFF() + vesting.VESTING_DURATION() * 2);
        assertEq(vesting.vestedAmount(), VESTING_AMOUNT);
    }

    // ============ Release Tests ============

    function test_release() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        // Advance past cliff + some time
        vm.warp(vesting.start() + vesting.CLIFF() + 30 days);

        uint256 releasable = vesting.releasable();
        assertTrue(releasable > 0);

        vesting.release();

        assertEq(token.balanceOf(beneficiary), releasable);
        assertEq(vesting.released(), releasable);
    }

    function test_release_afterCliff_smallAmount() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        // 1 day after cliff: small linear amount
        vm.warp(vesting.start() + vesting.CLIFF() + 1 days);

        uint256 expected = (VESTING_AMOUNT * 1 days) / vesting.VESTING_DURATION();
        assertEq(vesting.releasable(), expected);

        vesting.release();
        assertEq(token.balanceOf(beneficiary), expected);
    }

    function test_release_multipleReleases() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        // First release: 1 day after cliff
        vm.warp(vesting.start() + vesting.CLIFF() + 1 days);
        uint256 first = vesting.releasable();
        assertTrue(first > 0, "Should have releasable tokens after cliff");
        vesting.release();
        assertEq(token.balanceOf(beneficiary), first);

        // Second release 30 days later
        vm.warp(vesting.start() + vesting.CLIFF() + 31 days);
        uint256 second = vesting.releasable();
        assertTrue(second > 0);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), first + second);
    }

    function test_release_fullVest() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        vm.warp(vesting.start() + vesting.CLIFF() + vesting.VESTING_DURATION());
        vesting.release();

        assertEq(token.balanceOf(beneficiary), VESTING_AMOUNT);
        assertEq(vesting.releasable(), 0);
    }

    function test_release_revertsNothingToRelease() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        // During cliff, nothing to release
        vm.expectRevert("Nothing to release");
        vesting.release();
    }

    function test_release_revertsNotInitialized() public {
        vm.expectRevert("Not initialized");
        vesting.release();
    }

    function test_release_anyoneCanCall() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();
        vm.warp(vesting.start() + vesting.CLIFF() + 30 days);

        // Stranger calls release, but tokens go to beneficiary
        vm.prank(stranger);
        vesting.release();
        assertTrue(token.balanceOf(beneficiary) > 0);
        assertEq(token.balanceOf(stranger), 0);
    }

    // ============ View Functions ============

    function test_vestingProgress() public {
        _initialize();
        assertEq(vesting.vestingProgress(), 0);

        vm.prank(router);
        vesting.startVesting();

        uint256 totalDuration = vesting.CLIFF() + vesting.VESTING_DURATION();

        // At halfway through total 18-month period
        vm.warp(vesting.start() + totalDuration / 2);
        assertEq(vesting.vestingProgress(), 5000);

        // At end
        vm.warp(vesting.start() + totalDuration);
        assertEq(vesting.vestingProgress(), 10000);
    }

    function test_vestingProgress_duringCliff() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        uint256 totalDuration = vesting.CLIFF() + vesting.VESTING_DURATION();

        // At end of cliff (180 days into 545 day total)
        vm.warp(vesting.start() + vesting.CLIFF());
        uint256 expected = (vesting.CLIFF() * 10000) / totalDuration;
        assertEq(vesting.vestingProgress(), expected);
    }

    function test_remainingTime() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        uint256 totalDuration = vesting.CLIFF() + vesting.VESTING_DURATION();

        // At start: remaining = full 18 months
        assertEq(vesting.remainingTime(), totalDuration);

        // At cliff end: remaining = VESTING_DURATION (12 months)
        vm.warp(vesting.start() + vesting.CLIFF());
        assertEq(vesting.remainingTime(), vesting.VESTING_DURATION());

        // Halfway through vesting period
        vm.warp(vesting.start() + vesting.CLIFF() + vesting.VESTING_DURATION() / 2);
        assertEq(vesting.remainingTime(), vesting.VESTING_DURATION() / 2);

        // At end
        vm.warp(vesting.start() + totalDuration);
        assertEq(vesting.remainingTime(), 0);
    }

    function test_remainingTime_from18months() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        uint256 totalDuration = vesting.CLIFF() + vesting.VESTING_DURATION();
        assertEq(totalDuration, 545 days, "Total duration should be 545 days (~18 months)");
        assertEq(vesting.remainingTime(), totalDuration);
    }

    function test_getVestingSchedule() public {
        _initialize();
        vm.prank(router);
        vesting.startVesting();

        (
            uint256 _start,
            uint256 _duration,
            uint256 _cliff,
            uint256 _totalAmount,
            uint256 _released,
            uint256 _releasable
        ) = vesting.getVestingSchedule();

        assertEq(_start, block.timestamp);
        assertEq(_duration, vesting.CLIFF() + vesting.VESTING_DURATION());
        assertEq(_cliff, vesting.CLIFF());
        assertEq(_totalAmount, VESTING_AMOUNT);
        assertEq(_released, 0);
        assertEq(_releasable, 0);
    }
}
