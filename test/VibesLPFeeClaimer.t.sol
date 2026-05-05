// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/VibesLPFeeClaimer.sol";
import "./mocks/MockAerodromeRouter.sol";

/// @dev Active treasury — `terminated()` returns false so the claimer routes fees to it.
contract ActiveTreasury {
    function terminated() external pure returns (bool) {
        return false;
    }
}

/// @dev Terminated treasury — `terminated()` returns true so the claimer burns instead.
contract TerminatedTreasury {
    function terminated() external pure returns (bool) {
        return true;
    }
}

/// @dev Treasury without a terminated() ABI; the claimer must fall back to burn.
contract NonConformingTreasury {}

/// @dev Reentrancy probe: on receiving tokens, tries to re-enter claimAndDistribute.
contract ReentrantWethToken is ERC20 {
    VibesLPFeeClaimer public claimer;
    bool public armed;

    constructor() ERC20("Re-WETH", "rWETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address _claimer) external {
        claimer = VibesLPFeeClaimer(_claimer);
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && to == claimer.platformFeeRecipient()) {
            armed = false; // one-shot
            claimer.claimAndDistribute();
        }
    }
}

/// @dev Simple ERC20 for the project-token side in tests.
contract TestERC20 is ERC20 {
    constructor(string memory name, string memory sym) ERC20(name, sym) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VibesLPFeeClaimerTest is Test {
    VibesLPFeeClaimer public claimer;
    MockLPToken public pool;
    TestERC20 public projectToken;
    TestERC20 public wethToken;

    address public platformRecipient = address(0xFEE);
    address public treasury;
    address public campaign = address(0xCA);

    function setUp() public {
        projectToken = new TestERC20("Project", "PRJ");
        wethToken = new TestERC20("WETH", "WETH");

        // token0 = projectToken, token1 = wethToken — exercises the branch
        // where projectToken == token0. See test_claim_projectTokenIsToken1 for the flip.
        pool = new MockLPToken(address(projectToken), address(wethToken));

        claimer = new VibesLPFeeClaimer();

        // Default treasury is "active" (terminated()=false) so happy-path claim tests
        // route project-side fees to it. Burn-path tests deploy their own treasury.
        treasury = address(new ActiveTreasury());
    }

    function _initialize(address _treasury) internal {
        claimer.initialize(address(pool), campaign, address(projectToken), platformRecipient, _treasury);
    }

    // ============ initialize ============

    function test_initialize_success() public {
        _initialize(treasury);
        assertEq(claimer.pool(), address(pool));
        assertEq(claimer.token0(), address(projectToken));
        assertEq(claimer.token1(), address(wethToken));
        assertEq(claimer.projectToken(), address(projectToken));
        assertEq(claimer.campaign(), campaign);
        assertEq(claimer.platformFeeRecipient(), platformRecipient);
        assertEq(claimer.treasuryEscrow(), treasury);
        assertTrue(claimer.initialized());
    }

    function test_initialize_twice_reverts() public {
        _initialize(treasury);
        vm.expectRevert(VibesLPFeeClaimer.AlreadyInitialized.selector);
        _initialize(treasury);
    }

    function test_initialize_zeroPool_reverts() public {
        vm.expectRevert(VibesLPFeeClaimer.ZeroAddress.selector);
        claimer.initialize(address(0), campaign, address(projectToken), platformRecipient, treasury);
    }

    function test_initialize_zeroCampaign_reverts() public {
        vm.expectRevert(VibesLPFeeClaimer.ZeroAddress.selector);
        claimer.initialize(address(pool), address(0), address(projectToken), platformRecipient, treasury);
    }

    function test_initialize_zeroProjectToken_reverts() public {
        vm.expectRevert(VibesLPFeeClaimer.ZeroAddress.selector);
        claimer.initialize(address(pool), campaign, address(0), platformRecipient, treasury);
    }

    function test_initialize_zeroPlatformRecipient_reverts() public {
        vm.expectRevert(VibesLPFeeClaimer.ZeroAddress.selector);
        claimer.initialize(address(pool), campaign, address(projectToken), address(0), treasury);
    }

    function test_initialize_treasuryMayBeZero() public {
        // address(0) treasury is the "burn project-token fees" configuration and must be legal.
        _initialize(address(0));
        assertEq(claimer.treasuryEscrow(), address(0));
    }

    function test_initialize_poolTokenMismatch_reverts() public {
        TestERC20 stranger = new TestERC20("Stranger", "STR");
        vm.expectRevert(VibesLPFeeClaimer.PoolTokenMismatch.selector);
        claimer.initialize(address(pool), campaign, address(stranger), platformRecipient, treasury);
    }

    // ============ claimAndDistribute — basic ============

    function test_claim_zeroFees_noTransfers() public {
        _initialize(treasury);
        // No setClaimableFees() call → both claimable amounts are 0.
        claimer.claimAndDistribute();
        assertEq(projectToken.balanceOf(treasury), 0);
        assertEq(wethToken.balanceOf(platformRecipient), 0);
    }

    function test_claim_projectTokenIsToken0_routesCorrectly() public {
        _initialize(treasury);
        projectToken.mint(address(pool), 100 ether);
        wethToken.mint(address(pool), 10 ether);
        pool.setClaimableFees(100 ether, 10 ether); // c0=project, c1=weth

        claimer.claimAndDistribute();

        assertEq(projectToken.balanceOf(treasury), 100 ether, "project-side -> treasury");
        assertEq(wethToken.balanceOf(platformRecipient), 10 ether, "weth-side -> platform");
    }

    function test_claim_projectTokenIsToken1_routesCorrectly() public {
        // Fresh pool with token order flipped.
        MockLPToken flippedPool = new MockLPToken(address(wethToken), address(projectToken));
        VibesLPFeeClaimer c2 = new VibesLPFeeClaimer();
        c2.initialize(address(flippedPool), campaign, address(projectToken), platformRecipient, treasury);

        projectToken.mint(address(flippedPool), 50 ether);
        wethToken.mint(address(flippedPool), 5 ether);
        flippedPool.setClaimableFees(5 ether, 50 ether); // c0=weth, c1=project

        c2.claimAndDistribute();

        assertEq(projectToken.balanceOf(treasury), 50 ether, "project-side (token1) -> treasury");
        assertEq(wethToken.balanceOf(platformRecipient), 5 ether, "weth-side (token0) -> platform");
    }

    // ============ claimAndDistribute — project-token destination ============

    function test_claim_noTreasury_burnsProjectTokens() public {
        _initialize(address(0));
        projectToken.mint(address(pool), 42 ether);
        pool.setClaimableFees(42 ether, 0);

        claimer.claimAndDistribute();

        assertEq(projectToken.balanceOf(claimer.DEAD_ADDRESS()), 42 ether, "project-side burned");
        assertEq(projectToken.balanceOf(treasury), 0, "treasury received nothing");
    }

    function test_claim_terminatedTreasury_burnsProjectTokens() public {
        TerminatedTreasury t = new TerminatedTreasury();
        _initialize(address(t));

        projectToken.mint(address(pool), 7 ether);
        pool.setClaimableFees(7 ether, 0);

        claimer.claimAndDistribute();

        assertEq(projectToken.balanceOf(claimer.DEAD_ADDRESS()), 7 ether, "burned, not sent to terminated");
        assertEq(projectToken.balanceOf(address(t)), 0);
    }

    function test_claim_nonConformingTreasury_burnsProjectTokens() public {
        NonConformingTreasury nc = new NonConformingTreasury();
        _initialize(address(nc));

        projectToken.mint(address(pool), 3 ether);
        pool.setClaimableFees(3 ether, 0);

        // Must not revert; must fall through to DEAD_ADDRESS.
        claimer.claimAndDistribute();

        assertEq(projectToken.balanceOf(claimer.DEAD_ADDRESS()), 3 ether);
        assertEq(projectToken.balanceOf(address(nc)), 0);
    }

    // ============ claimAndDistribute — idempotence / cadence ============

    function test_claim_repeated_isNoOpAfterFirst() public {
        _initialize(treasury);
        projectToken.mint(address(pool), 10 ether);
        wethToken.mint(address(pool), 1 ether);
        pool.setClaimableFees(10 ether, 1 ether);

        claimer.claimAndDistribute();
        uint256 pAfter = projectToken.balanceOf(treasury);
        uint256 wAfter = wethToken.balanceOf(platformRecipient);

        // Second call — pool's claimable is now (0,0); nothing should move.
        claimer.claimAndDistribute();
        assertEq(projectToken.balanceOf(treasury), pAfter);
        assertEq(wethToken.balanceOf(platformRecipient), wAfter);
    }

    function test_claim_permissionless() public {
        _initialize(treasury);
        projectToken.mint(address(pool), 5 ether);
        pool.setClaimableFees(5 ether, 0);

        // Random caller — succeeds.
        vm.prank(address(0xDECAF));
        claimer.claimAndDistribute();

        assertEq(projectToken.balanceOf(treasury), 5 ether);
    }

    // ============ lpBalance view ============

    function test_lpBalance_reflectsPoolBalance() public {
        _initialize(treasury);
        assertEq(claimer.lpBalance(), 0);

        pool.mint(address(claimer), 999 ether);
        assertEq(claimer.lpBalance(), 999 ether);
    }

    // ============ reentrancy ============

    function test_claim_reentrancy_blocked() public {
        // Build a claimer whose WETH-side token re-enters on receive.
        ReentrantWethToken rweth = new ReentrantWethToken();
        MockLPToken rpool = new MockLPToken(address(projectToken), address(rweth));
        VibesLPFeeClaimer rclaimer = new VibesLPFeeClaimer();
        rclaimer.initialize(address(rpool), campaign, address(projectToken), platformRecipient, treasury);

        // Arm the token and fund the pool.
        rweth.arm(address(rclaimer));
        projectToken.mint(address(rpool), 1 ether);
        rweth.mint(address(rpool), 1 ether);
        rpool.setClaimableFees(1 ether, 1 ether);

        // The reentrant transfer triggers claimAndDistribute() again, which must revert.
        // OZ ReentrancyGuard uses its custom error when entered, bubbled by safeTransfer.
        vm.expectRevert();
        rclaimer.claimAndDistribute();
    }
}
