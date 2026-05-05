// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
// VibesVesting invariants
//
// Handler-driven fuzzer that advances time, releases tokens, and (sometimes)
// freezes the schedule, then asserts the core safety properties:
//
//   V1 — released <= vestedAmount at all times.
//   V2 — released is monotonic (only increases).
//   V3 — vestedAmount is monotonic in time (only increases as time advances
//        while not frozen).
//   V4 — vestedAmount <= totalAmount at all times.
//   V5 — Once frozen, released cannot grow.
//   V6 — Token conservation: beneficiary + contract + dead balances == TOTAL.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VibesVesting} from "../../src/VibesVesting.sol";
import {VibesToken} from "../../src/VibesToken.sol";

contract VestingHandler is Test {
    VibesVesting public vesting;
    VibesToken public token;
    address public freezer;

    uint256 public ghost_maxVested;
    uint256 public ghost_maxReleased;
    uint256 public ghost_releasedAtFreeze;

    constructor(VibesVesting _vesting, VibesToken _token, address _freezer) {
        vesting = _vesting;
        token = _token;
        freezer = _freezer;
    }

    function skipTime(uint256 daysSeed) external {
        uint256 d = bound(daysSeed, 1, 20);
        skip(d * 1 days);
        if (!vesting.frozen()) {
            uint256 v = vesting.vestedAmount();
            if (v > ghost_maxVested) ghost_maxVested = v;
        }
    }

    function release() external {
        try vesting.release() {
            if (vesting.released() > ghost_maxReleased) {
                ghost_maxReleased = vesting.released();
            }
        } catch { }
    }

    function freezeVesting() external {
        if (vesting.frozen()) return;
        vm.prank(freezer);
        try vesting.freeze() {
            ghost_releasedAtFreeze = vesting.released();
        } catch { }
    }
}

contract VibesVestingInvariants is Test {
    VibesVesting vesting;
    VibesToken token;
    VestingHandler handler;

    address beneficiary = makeAddr("v_ben");
    address freezer = makeAddr("v_freezer");

    uint256 constant TOTAL = 75_000 ether;
    uint256 constant CLIFF = 1 days;
    uint256 constant DURATION = 10 days;
    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;

    function setUp() public {
        token = new VibesToken("Vest", "VST", 18, TOTAL_SUPPLY, address(this));
        vesting = new VibesVesting(address(token), beneficiary, CLIFF, DURATION);
        // Fund the vesting contract, then initialize and start.
        token.transfer(address(vesting), TOTAL);
        vesting.initializeAmount();
        vesting.setAuthorizedFreezer(freezer);
        vesting.startVesting();

        handler = new VestingHandler(vesting, token, freezer);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.skipTime.selector;
        selectors[1] = handler.release.selector;
        selectors[2] = handler.freezeVesting.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// V1 — released never exceeds vested.
    function invariant_releasedLeqVested() public view {
        assertLe(
            vesting.released(),
            vesting.vestedAmount(),
            "released exceeds vestedAmount"
        );
    }

    /// V2 — released is monotonic. ghost_maxReleased captures the peak; assert
    /// the contract's released has never dropped below it.
    function invariant_releasedMonotonic() public view {
        assertGe(
            vesting.released(),
            handler.ghost_maxReleased(),
            "released regressed"
        );
    }

    /// V3 — vestedAmount is monotonic (while not frozen). When frozen, vested
    /// is still well-defined via the linear curve; we only assert monotonicity
    /// over observed non-frozen samples.
    function invariant_vestedMonotonic() public view {
        if (!vesting.frozen()) {
            assertGe(
                vesting.vestedAmount(),
                handler.ghost_maxVested(),
                "vestedAmount regressed"
            );
        }
    }

    /// V4 — vested <= total.
    function invariant_vestedLeqTotal() public view {
        assertLe(
            vesting.vestedAmount(),
            vesting.totalAmount(),
            "vestedAmount exceeds totalAmount"
        );
    }

    /// V5 — Once frozen, released cannot grow.
    function invariant_frozenFreezesReleases() public view {
        if (vesting.frozen()) {
            assertEq(
                vesting.released(),
                handler.ghost_releasedAtFreeze(),
                "released grew after freeze"
            );
        }
    }

    /// V6 — Token conservation across the three sinks.
    function invariant_tokenConservation() public view {
        uint256 atBen = token.balanceOf(beneficiary);
        uint256 atVest = token.balanceOf(address(vesting));
        uint256 atDead = token.balanceOf(address(0xdead));
        assertEq(atBen + atVest + atDead, TOTAL, "vesting token conservation broken");
    }
}
