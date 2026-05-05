// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {VibesToken} from "../src/VibesToken.sol";

// Rescue-path mock router: swallows completeFinalization so lpCreated stays false.
// This mimics the real-world "deferred LP" scenario that lets us reach the
// freeze-with-redeemable-supply-zero branch in freezeCampaign.
contract RescueRouter {
    function completeFinalization(address) external {}
    function completeDistribution(address) external {}
    function finalizationPhase(address) external pure returns (uint8) { return 0; }
    receive() external payable {}
}

/// @title Audit 2026-04 regression tests for findings F-1 and F-2
/// @notice These tests pin the patched behavior so the bugs cannot regress silently.
///
/// F-1 (High): freezeCampaign's "redeemableSupply == 0" fall-through used to transition
///             the campaign to Failed without checking that the escrow held enough ETH
///             to pay all contributor refunds. After `lpWithdrawn == true` the escrow
///             is short by the LP portion (15% of effective raised), so a first-mover
///             claim would drain the pot and later claimers would revert. The patch
///             mirrors emergencyRefundFunded()'s solvency check.
///
/// F-2 (Medium): _calculateRedeemableSupply previously excluded vesting / stakerRewards
///               / router / lpLocker / escrow / dead, but not the treasury escrow. A
///               non-trivial chunk of tokens sits in the treasury post-launch, and
///               including it in the denominator dilutes holder ETH refunds on freeze.
///               The patch adds `treasuryContract` + an owner/router-callable setter,
///               and the RouterExtension wires it during Phase 2.
contract Audit2026_04_FindingsTest is Test {
    VibesTranchEscrow public implementation;
    VibesTranchEscrowFactory public factory;
    MockTimeOracle public timeOracle;
    VibesToken public token;
    RescueRouter public rescueRouter;

    address public admin = makeAddr("admin");
    address public platformWallet = makeAddr("platform");
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");

    uint256 public constant GOAL = 10 ether;
    uint256 public constant TOKEN_SUPPLY = 1_000_000 ether;

    function setUp() public {
        vm.prank(admin);
        timeOracle = new MockTimeOracle();
        vm.prank(admin);
        timeOracle.setRealTimeMode(true);

        rescueRouter = new RescueRouter();
        implementation = new VibesTranchEscrow();

        factory = new VibesTranchEscrowFactory(
            address(implementation),
            admin,
            platformWallet,
            address(timeOracle),
            address(rescueRouter),
            makeAddr("lpLocker"),
            address(0)
        );

        vm.prank(founder);
        token = new VibesToken("Test Token", "TEST", 18, TOKEN_SUPPLY, founder);

        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);
    }

    // ============ Helpers ============

    function _createEscrow() internal returns (VibesTranchEscrow esc) {
        vm.prank(address(rescueRouter));
        address escrowAddr = factory.createEscrow(
            founder,
            address(token),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 7 days,
            0
        );
        esc = VibesTranchEscrow(payable(escrowAddr));
    }

    function _fundToGoal(VibesTranchEscrow esc, address backer, uint256 amount) internal {
        vm.prank(backer);
        esc.contribute{value: amount}(0, 0, "");
        skip(8 days);
        esc.finalize();
    }

    // ============ F-1: freezeCampaign fall-through solvency ============

    /// Without the F-1 patch: freezeCampaign falls through to Failed with the escrow
    /// short by the LP portion, and the first claimContributorRefund() drains it.
    /// With the patch: freezeCampaign reverts until admin tops up.
    function test_F1_freezeFallthrough_revertsWhenUnderfunded() public {
        VibesTranchEscrow esc = _createEscrow();
        _fundToGoal(esc, backer1, GOAL);

        // Park every token at the (excluded) router so redeemableSupply == 0.
        // This is the production reality before backers claim: the router extension
        // holds the circulating tokens pending claimTokens().
        vm.prank(founder);
        token.transfer(address(rescueRouter), TOKEN_SUPPLY);

        // Sanity: escrow is underfunded by at least the LP amount.
        uint256 lpAmount = esc.getLPAmount();
        assertGt(lpAmount, 0, "test precondition: LP portion must be > 0");
        assertLt(address(esc).balance, GOAL, "escrow should be short by LP amount");

        vm.prank(admin);
        vm.expectRevert(bytes("Insufficient balance - top up first"));
        esc.freezeCampaign("abandoned");
    }

    /// Confirms the escape hatch works: once admin tops up the missing LP portion,
    /// the freeze completes and contributors can claim their full refunds.
    function test_F1_freezeFallthrough_succeedsAfterTopUp() public {
        VibesTranchEscrow esc = _createEscrow();
        _fundToGoal(esc, backer1, GOAL);

        vm.prank(founder);
        token.transfer(address(rescueRouter), TOKEN_SUPPLY);

        uint256 missing = GOAL - address(esc).balance;
        vm.deal(admin, missing);
        vm.prank(admin);
        esc.adminTopUp{value: missing}();

        vm.prank(admin);
        esc.freezeCampaign("abandoned");

        VibesTranchEscrow.Campaign memory c = esc.getCampaign();
        assertEq(uint8(c.state), uint8(VibesTranchEscrow.CampaignState.Failed), "should land in Failed");

        uint256 backerBalBefore = backer1.balance;
        vm.prank(backer1);
        esc.claimContributorRefund();
        assertEq(backer1.balance, backerBalBefore + GOAL, "backer receives full refund");
    }

    /// Ensures the guard still allows a freeze when the campaign is fully solvent
    /// (e.g. nothing drawn against it yet, so balance >= totalRaised).
    function test_F1_freezeFallthrough_allowsWhenFullySolvent() public {
        VibesTranchEscrow esc = _createEscrow();
        _fundToGoal(esc, backer1, GOAL);

        // Top up the LP portion to make the escrow fully solvent.
        uint256 missing = GOAL - address(esc).balance;
        vm.deal(admin, missing);
        vm.prank(admin);
        esc.adminTopUp{value: missing}();

        // Park tokens at the router so redeemableSupply == 0.
        vm.prank(founder);
        token.transfer(address(rescueRouter), TOKEN_SUPPLY);

        vm.prank(admin);
        esc.freezeCampaign("abandoned");

        VibesTranchEscrow.Campaign memory c = esc.getCampaign();
        assertEq(uint8(c.state), uint8(VibesTranchEscrow.CampaignState.Failed));
    }

    // ============ F-2: treasury balance excluded from redeemableSupply ============

    /// When a treasury is wired, its token balance must be excluded from the frozen
    /// supply denominator. Otherwise those locked tokens dilute holder ETH refunds.
    function test_F2_treasuryBalance_excludedFromFrozenSupply() public {
        VibesTranchEscrow esc = _createEscrow();
        _fundToGoal(esc, backer1, GOAL);

        // Make the escrow fully solvent so the freeze path isn't blocked by F-1.
        uint256 missing = GOAL - address(esc).balance;
        vm.deal(admin, missing);
        vm.prank(admin);
        esc.adminTopUp{value: missing}();

        // Allocation layout:
        //   - 50% to treasury  (should be excluded)
        //   - 25% to backer2   (real holder, in redeemable supply)
        //   - 25% stays with founder (also in redeemable supply)
        address treasury = makeAddr("treasury");
        uint256 treasuryAlloc = TOKEN_SUPPLY / 2;
        uint256 holderAlloc = TOKEN_SUPPLY / 4;
        vm.prank(founder);
        token.transfer(treasury, treasuryAlloc);
        vm.prank(founder);
        token.transfer(backer2, holderAlloc);

        // Wire the treasury (admin path; router path is exercised via the
        // RouterExtension wiring — covered in a separate extension test).
        vm.prank(admin);
        esc.setTreasuryContract(treasury);
        assertEq(esc.treasuryContract(), treasury, "treasury wired");

        vm.prank(admin);
        esc.freezeCampaign("abandoned by founder");

        // Expected redeemable supply = founder balance + backer2 balance
        // (router balance is 0 here because we never transferred to it — founder
        //  still holds the remainder). Treasury balance must NOT appear.
        uint256 expected = token.balanceOf(founder) + token.balanceOf(backer2);
        assertEq(esc.frozenTotalSupply(), expected, "treasury excluded from denominator");
        assertLt(esc.frozenTotalSupply(), TOKEN_SUPPLY, "denominator strictly less than totalSupply");
    }

    /// When treasury is NOT wired, its balance still shows up in the denominator.
    /// This documents the pre-patch hazard and guards the counterfactual.
    function test_F2_withoutWiring_treasuryBalanceLeaksIn() public {
        VibesTranchEscrow esc = _createEscrow();
        _fundToGoal(esc, backer1, GOAL);

        uint256 missing = GOAL - address(esc).balance;
        vm.deal(admin, missing);
        vm.prank(admin);
        esc.adminTopUp{value: missing}();

        address treasury = makeAddr("treasury");
        uint256 treasuryAlloc = TOKEN_SUPPLY / 2;
        vm.prank(founder);
        token.transfer(treasury, treasuryAlloc);

        // Do NOT call setTreasuryContract.
        vm.prank(admin);
        esc.freezeCampaign("abandoned");

        // Treasury balance is still counted as redeemable because it's not wired.
        // This is the pre-F-2 behavior that dilutes real holders.
        uint256 redeemable = esc.frozenTotalSupply();
        assertGe(redeemable, treasuryAlloc, "treasury balance leaks into denominator when unwired");
    }

    /// setTreasuryContract is guarded: strangers can't wire it, and it rejects
    /// addresses that overlap with previously-registered locked contracts.
    function test_F2_setTreasuryContract_accessControlAndOverlap() public {
        VibesTranchEscrow esc = _createEscrow();
        _fundToGoal(esc, backer1, GOAL);

        // Stranger cannot call it.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(VibesTranchEscrow.OnlyAdmin.selector);
        esc.setTreasuryContract(makeAddr("t"));

        // Router CAN call it (RouterExtension uses this path in Phase 2).
        vm.prank(address(rescueRouter));
        esc.setTreasuryContract(makeAddr("t-via-router"));
        assertEq(esc.treasuryContract(), makeAddr("t-via-router"));

        // Admin CAN call it.
        address treasury = makeAddr("treasury-2");
        vm.prank(admin);
        esc.setTreasuryContract(treasury);
        assertEq(esc.treasuryContract(), treasury);

        // Wiring the same address as vesting should revert to prevent
        // double-counting the exclusion (matches setLockedAddresses' M-02 fix intent).
        address vesting = makeAddr("vesting");
        address stakerRewards = makeAddr("stakerRewards");
        vm.prank(admin);
        esc.setLockedAddresses(vesting, stakerRewards);

        vm.prank(admin);
        vm.expectRevert(bytes("Overlaps vesting"));
        esc.setTreasuryContract(vesting);

        vm.prank(admin);
        vm.expectRevert(bytes("Overlaps stakerRewards"));
        esc.setTreasuryContract(stakerRewards);

        vm.prank(admin);
        vm.expectRevert(bytes("Overlaps router"));
        esc.setTreasuryContract(address(rescueRouter));

        vm.prank(admin);
        vm.expectRevert(bytes("Overlaps escrow"));
        esc.setTreasuryContract(address(esc));
    }
}
