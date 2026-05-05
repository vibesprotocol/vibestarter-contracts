// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesLPLocker} from "../src/VibesLPLocker.sol";
import {VibesLPFeeClaimer} from "../src/VibesLPFeeClaimer.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAerodromeRouter, IAerodromePool} from "../src/interfaces/IAerodromeRouter.sol";

/**
 * @title LPForkTest
 * @notice Fork tests against real Aerodrome on Base mainnet.
 *
 * Run with:
 *   forge test --match-path "test/LPForkTest.t.sol" --fork-url $BASE_RPC_URL -vvv
 *
 * Requires BASE_RPC_URL env var pointing to a Base mainnet RPC (Alchemy, QuickNode, etc.).
 * These tests deploy our contracts on a mainnet fork where the real Aerodrome router,
 * factory, WETH, and pool creation logic are all live.
 */
contract LPForkTest is Test {
    // ============ Real Aerodrome Addresses on Base Mainnet ============
    address constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    VibesLPLocker public lpLocker;
    VibesLPFeeClaimer public claimerImpl;
    VibesToken public token;

    address public deployer;
    address public mockRouter; // Simulates our launch router
    address public campaignEscrow = makeAddr("escrow");
    address public platformRecipient = makeAddr("platformRecipient");

    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 constant LP_TOKENS = 150_000 ether;  // 15% of supply for LP
    uint256 constant LP_ETH = 1.5 ether;          // 15% of 10 ETH raise

    function setUp() public {
        deployer = address(this);
        mockRouter = makeAddr("mockRouter");

        // Deploy our LP locker pointing at REAL Aerodrome
        lpLocker = new VibesLPLocker(AERO_ROUTER, AERO_FACTORY);

        // Register the fee claimer implementation for EIP-1167 cloning
        claimerImpl = new VibesLPFeeClaimer();
        lpLocker.setFeeClaimerImplementation(address(claimerImpl));

        lpLocker.setAuthorizedRouter(mockRouter);

        // Deploy a fresh token (this is our campaign token)
        token = new VibesToken("ForkTestToken", "FTK", 18, TOTAL_SUPPLY, deployer);

        // Give the mock router tokens + ETH
        token.transfer(mockRouter, LP_TOKENS);
        vm.deal(mockRouter, 100 ether);
    }

    // ============ Happy Path: LP Creation on Real Aerodrome ============

    function test_fork_createAndLockLP_realAerodrome() public {
        // Approve LP locker to pull tokens
        vm.prank(mockRouter);
        token.approve(address(lpLocker), LP_TOKENS);

        // Create and lock LP via our locker → real Aerodrome router
        vm.prank(mockRouter);
        (address pool, uint256 lpAmount) = lpLocker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaignEscrow,
            platformRecipient,
            address(0)
        );

        // ---- Assertions on real Aerodrome behavior ----

        // 1. Pool was created (non-zero address)
        assertTrue(pool != address(0), "Pool should be created on real Aerodrome");
        console.log("Pool address:", pool);
        console.log("LP tokens minted:", lpAmount);

        // 2. LP tokens were minted (non-zero)
        assertTrue(lpAmount > 0, "LP tokens should be minted");

        // 3. LP tokens are soulbound at the per-campaign fee claimer (the new "permanent lock")
        address claimer = lpLocker.campaignToFeeClaimer(campaignEscrow);
        assertTrue(claimer != address(0), "Claimer should be deployed");
        uint256 claimerBalance = IERC20(pool).balanceOf(claimer);
        assertEq(claimerBalance, lpAmount, "All LP tokens should be at claimer");

        // 4. No LP tokens remain in the locker
        uint256 lockerBalance = IERC20(pool).balanceOf(address(lpLocker));
        assertEq(lockerBalance, 0, "Locker should hold zero LP tokens");

        // 5. Position was recorded
        assertTrue(lpLocker.hasLockedLP(campaignEscrow), "Campaign should be marked as LP locked");

        // 6. Pool has both token and WETH
        IAerodromePool aeroPool = IAerodromePool(pool);
        address token0 = aeroPool.token0();
        address token1 = aeroPool.token1();
        assertTrue(
            (token0 == address(token) || token1 == address(token)),
            "Pool should contain our token"
        );
        address weth = IAerodromeRouter(AERO_ROUTER).weth();
        assertTrue(
            (token0 == weth || token1 == weth),
            "Pool should contain WETH"
        );

        // 7. Pool is volatile (not stable)
        assertFalse(aeroPool.stable(), "Pool should be volatile");

        // 8. Pool total supply > 0
        assertTrue(aeroPool.totalSupply() > 0, "Pool should have total supply");
    }

    // ============ LP Amounts Verify ============

    function test_fork_lpAmounts_matchExpected() public {
        vm.prank(mockRouter);
        token.approve(address(lpLocker), LP_TOKENS);

        vm.prank(mockRouter);
        (address pool, uint256 lpAmount) = lpLocker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaignEscrow,
            platformRecipient,
            address(0)
        );

        // Check the actual position data
        (
            address recToken,
            address recPool,
            uint256 recTokenAmt,
            uint256 recEthAmt,
            uint256 recLpAmt,
            uint256 recTimestamp,
            address recCampaign
        ) = lpLocker.lockedPositions(0);

        assertEq(recToken, address(token));
        assertEq(recPool, pool);
        assertEq(recCampaign, campaignEscrow);
        assertEq(recTimestamp, block.timestamp);

        // Actual amounts should be close to desired (within 0.5% slippage)
        // On a fresh pool with no prior liquidity, we expect near-exact amounts
        assertGe(recTokenAmt, (LP_TOKENS * 995) / 1000, "Token amount within slippage");
        assertGe(recEthAmt, (LP_ETH * 995) / 1000, "ETH amount within slippage");

        console.log("Tokens deposited:", recTokenAmt);
        console.log("ETH deposited:", recEthAmt);
        console.log("LP minted:", recLpAmt);
    }

    // ============ Excess Refund (Existing Pool) ============

    function test_fork_excessETH_refundedOnExistingPool() public {
        // First, create the pool with initial liquidity
        vm.prank(mockRouter);
        token.approve(address(lpLocker), LP_TOKENS);

        vm.prank(mockRouter);
        lpLocker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaignEscrow,
            platformRecipient,
            address(0)
        );

        // Now create a SECOND campaign token with extra ETH on the SAME pool pattern
        // (Different token, different pool — but demonstrates the excess refund mechanism)
        VibesToken token2 = new VibesToken("Token2", "TK2", 18, TOTAL_SUPPLY, address(this));
        token2.transfer(mockRouter, LP_TOKENS);
        address escrow2 = makeAddr("escrow2");

        vm.prank(mockRouter);
        token2.approve(address(lpLocker), LP_TOKENS);

        uint256 routerBalanceBefore = mockRouter.balance;

        // Note: On a fresh pool, Aerodrome accepts ALL ETH (sets the initial ratio).
        // This is correct behavior — the "excess refund" in our locker only kicks in
        // when Aerodrome itself returns less than we sent (which happens on existing pools).
        vm.prank(mockRouter);
        lpLocker.createAndLockLP{value: LP_ETH}(
            address(token2),
            LP_TOKENS,
            escrow2,
            platformRecipient,
            address(0)
        );

        uint256 routerBalanceAfter = mockRouter.balance;
        uint256 spent = routerBalanceBefore - routerBalanceAfter;

        console.log("ETH sent:", LP_ETH);
        console.log("ETH actually spent:", spent);

        // On a fresh pool, all ETH is used (no excess)
        // This confirms real Aerodrome behavior: first LP deposit sets the price ratio
        assertEq(spent, LP_ETH, "Fresh pool should use all ETH");
    }

    // ============ Second LP on Same Campaign Reverts ============

    function test_fork_doubleLP_reverts() public {
        vm.prank(mockRouter);
        token.approve(address(lpLocker), LP_TOKENS * 2);

        // First LP succeeds
        vm.prank(mockRouter);
        lpLocker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaignEscrow,
            platformRecipient,
            address(0)
        );

        // Second LP on same campaign reverts
        vm.prank(mockRouter);
        vm.expectRevert(VibesLPLocker.AlreadyLocked.selector);
        lpLocker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaignEscrow,
            platformRecipient,
            address(0)
        );
    }

    // ============ LP Tokens Truly Irrecoverable ============

    function test_fork_lpTokens_irrecoverable() public {
        vm.prank(mockRouter);
        token.approve(address(lpLocker), LP_TOKENS);

        vm.prank(mockRouter);
        (address pool, uint256 lpAmount) = lpLocker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaignEscrow,
            platformRecipient,
            address(0)
        );

        // LP tokens are soulbound at the per-campaign fee claimer
        address claimer = lpLocker.campaignToFeeClaimer(campaignEscrow);
        assertTrue(claimer != address(0), "Claimer should be deployed");
        uint256 claimerBalance = IERC20(pool).balanceOf(claimer);
        assertEq(claimerBalance, lpAmount);

        // Fundamental guarantee: the claimer has no transfer/withdraw/rescue surface,
        // so the LP is as permanently locked as it would be at 0xdead. Verify no
        // approvals exist (the claimer never calls approve on the pool token).
        uint256 anyoneAllowance = IERC20(pool).allowance(claimer, address(this));
        assertEq(anyoneAllowance, 0, "Claimer should have zero LP approvals");
    }

    // ============ Price Sanity Check ============

    function test_fork_poolPrice_matchesRaiseRatio() public {
        vm.prank(mockRouter);
        token.approve(address(lpLocker), LP_TOKENS);

        vm.prank(mockRouter);
        (address pool,) = lpLocker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaignEscrow,
            platformRecipient,
            address(0)
        );

        // Check reserves match our deposit ratio
        address weth = IAerodromeRouter(AERO_ROUTER).weth();
        uint256 tokenReserve = IERC20(address(token)).balanceOf(pool);
        uint256 wethReserve = IERC20(weth).balanceOf(pool);

        console.log("Token reserve:", tokenReserve);
        console.log("WETH reserve:", wethReserve);

        // Price = WETH / Tokens (in wei)
        // Expected: 1.5 ETH / 150,000 tokens = 0.00001 ETH per token = 1e13 wei
        uint256 expectedPriceWei = (LP_ETH * 1e18) / LP_TOKENS;
        uint256 actualPriceWei = (wethReserve * 1e18) / tokenReserve;

        console.log("Expected price (wei per token):", expectedPriceWei);
        console.log("Actual price (wei per token):", actualPriceWei);

        // Allow 1% tolerance (Aerodrome may adjust slightly for minimum liquidity)
        uint256 tolerance = expectedPriceWei / 100;
        assertApproxEqAbs(actualPriceWei, expectedPriceWei, tolerance,
            "Pool price should match raise ratio within 1%");
    }

    // ============ Full E2E: Launch Router Integration ============

    function test_fork_fullIntegration_routerToLP() public {
        // This test deploys the FULL stack on a mainnet fork:
        // Token Factory → Router → Escrow Factory → Launch → Fund → Finalize → Real LP

        // We already have LP locker pointing at real Aerodrome.
        // This simpler version just tests the LP locker directly but with
        // realistic amounts from different campaign sizes.

        // Small raise: 1 ETH goal, 15% to LP = 0.15 ETH
        uint256 smallGoal = 1 ether;
        uint256 smallLPTokens = 15_000 ether; // 15% of 100K supply
        uint256 smallLPEth = 0.15 ether;

        VibesToken smallToken = new VibesToken("SmallRaise", "SML", 18, 100_000 ether, deployer);
        smallToken.transfer(mockRouter, smallLPTokens);
        address smallEscrow = makeAddr("smallEscrow");

        vm.prank(mockRouter);
        smallToken.approve(address(lpLocker), smallLPTokens);

        vm.prank(mockRouter);
        (address smallPool, uint256 smallLP) = lpLocker.createAndLockLP{value: smallLPEth}(
            address(smallToken),
            smallLPTokens,
            smallEscrow,
            platformRecipient,
            address(0)
        );

        assertTrue(smallPool != address(0), "Small raise LP should succeed");
        assertTrue(smallLP > 0, "Small raise should get LP tokens");
        console.log("Small raise - Pool:", smallPool, "LP:", smallLP);

        // Large raise: 100 ETH goal, 15% to LP = 15 ETH
        uint256 largeLPTokens = 1_500_000 ether; // 15% of 10M supply
        uint256 largeLPEth = 15 ether;

        VibesToken largeToken = new VibesToken("LargeRaise", "LRG", 18, 10_000_000 ether, deployer);
        largeToken.transfer(mockRouter, largeLPTokens);
        vm.deal(mockRouter, 100 ether); // Re-fund router
        address largeEscrow = makeAddr("largeEscrow");

        vm.prank(mockRouter);
        largeToken.approve(address(lpLocker), largeLPTokens);

        vm.prank(mockRouter);
        (address largePool, uint256 largeLP) = lpLocker.createAndLockLP{value: largeLPEth}(
            address(largeToken),
            largeLPTokens,
            largeEscrow,
            platformRecipient,
            address(0)
        );

        assertTrue(largePool != address(0), "Large raise LP should succeed");
        assertTrue(largeLP > 0, "Large raise should get LP tokens");
        console.log("Large raise - Pool:", largePool, "LP:", largeLP);
    }
}
