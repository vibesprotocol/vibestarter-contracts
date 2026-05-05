// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VibesLPLocker.sol";
import "../src/VibesLPFeeClaimer.sol";
import "../src/VibesToken.sol";
import "./mocks/MockAerodromeRouter.sol";

contract VibesLPLockerTest is Test {
    VibesLPLocker public locker;
    VibesLPFeeClaimer public claimerImpl;
    MockAerodromeRouter public router;
    VibesToken public token;

    address public founder = address(0x1);
    address public campaign = address(0x2);
    address public campaign2 = address(0x3);
    address public weth = address(0x4444);
    address public factory = address(0x5555);
    address public platformRecipient = address(0x7777);

    uint256 public constant TOKEN_SUPPLY = 1_000_000 ether;
    uint256 public constant LP_TOKENS = 150_000 ether; // 15% of supply
    uint256 public constant LP_ETH = 7.5 ether; // 15% of 50 ETH raised

    function setUp() public {
        // Deploy mock router
        router = new MockAerodromeRouter(weth, factory);

        // Deploy locker
        locker = new VibesLPLocker(address(router), factory);

        // Register the VibesLPFeeClaimer implementation for EIP-1167 cloning
        claimerImpl = new VibesLPFeeClaimer();
        locker.setFeeClaimerImplementation(address(claimerImpl));

        // Authorize test contract as the router so it can call createAndLockLP
        locker.setAuthorizedRouter(address(this));

        // Deploy test token
        token = new VibesToken("Test Token", "TEST", 18, TOKEN_SUPPLY, founder);

        // Give founder tokens
        vm.prank(founder);
        token.transfer(address(this), LP_TOKENS);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsAddresses() public view {
        assertEq(locker.aerodromeRouter(), address(router));
        assertEq(locker.aerodromeFactory(), factory);
        assertEq(locker.DEAD_ADDRESS(), 0x000000000000000000000000000000000000dEaD);
    }

    function test_constructor_revertsZeroRouter() public {
        vm.expectRevert(VibesLPLocker.ZeroAddress.selector);
        new VibesLPLocker(address(0), factory);
    }

    function test_constructor_revertsZeroFactory() public {
        vm.expectRevert(VibesLPLocker.ZeroAddress.selector);
        new VibesLPLocker(address(router), address(0));
    }

    // ============ createAndLockLP Tests ============

    function test_createAndLockLP_success() public {
        // Approve locker to spend tokens
        token.approve(address(locker), LP_TOKENS);

        // Create and lock LP
        (address pool, uint256 lpAmount) = locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        // Verify LP was created
        assertTrue(pool != address(0), "Pool should be created");
        assertTrue(lpAmount > 0, "LP amount should be positive");

        // Verify LP is soulbound to the per-campaign fee claimer (replaces the 0xdead sink)
        address claimer = locker.campaignToFeeClaimer(campaign);
        assertTrue(claimer != address(0), "Claimer should be deployed");
        uint256 claimerBalance = IERC20(pool).balanceOf(claimer);
        assertEq(claimerBalance, lpAmount, "LP tokens should be at claimer");

        // Verify locker has no LP tokens
        uint256 lockerBalance = IERC20(pool).balanceOf(address(locker));
        assertEq(lockerBalance, 0, "Locker should have 0 LP tokens");

        // Verify campaign is marked as having locked LP
        assertTrue(locker.hasLockedLP(campaign), "Campaign should have locked LP");
    }

    function test_createAndLockLP_recordsPosition() public {
        token.approve(address(locker), LP_TOKENS);

        (address pool, uint256 lpAmount) = locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        // Check position details
        VibesLPLocker.LockedLP memory position = locker.getLockedPosition(campaign);
        assertEq(position.token, address(token));
        assertEq(position.pool, pool);
        assertEq(position.tokenAmount, LP_TOKENS);
        assertEq(position.ethAmount, LP_ETH);
        assertEq(position.lpAmount, lpAmount);
        assertEq(position.campaign, campaign);
        assertEq(position.timestamp, block.timestamp);
    }

    event LPCreatedAndLocked(
        address indexed token,
        address indexed pool,
        address indexed campaign,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 lpAmount
    );

    function test_createAndLockLP_emitsEvent() public {
        token.approve(address(locker), LP_TOKENS);

        // We can't predict exact pool address, so just check event is emitted
        vm.expectEmit(true, false, true, false);
        emit LPCreatedAndLocked(
            address(token),
            address(0), // We don't know pool address yet
            campaign,
            LP_TOKENS,
            LP_ETH,
            0 // LP amount unknown
        );

        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );
    }

    function test_createAndLockLP_revertsZeroToken() public {
        vm.expectRevert(VibesLPLocker.ZeroAddress.selector);
        locker.createAndLockLP{value: LP_ETH}(
            address(0),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );
    }

    function test_createAndLockLP_revertsZeroAmount() public {
        token.approve(address(locker), LP_TOKENS);

        vm.expectRevert(VibesLPLocker.ZeroAmount.selector);
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            0,
            campaign,
            platformRecipient,
            address(0)
        );
    }

    function test_createAndLockLP_revertsNoETH() public {
        token.approve(address(locker), LP_TOKENS);

        vm.expectRevert(VibesLPLocker.InsufficientETH.selector);
        locker.createAndLockLP{value: 0}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );
    }

    function test_createAndLockLP_revertsAlreadyLocked() public {
        token.approve(address(locker), LP_TOKENS * 2);

        // First lock
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        // Second lock for same campaign should fail
        vm.expectRevert(VibesLPLocker.AlreadyLocked.selector);
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );
    }

    function test_createAndLockLP_multipleCampaigns() public {
        // Give more tokens
        vm.prank(founder);
        token.transfer(address(this), LP_TOKENS);

        token.approve(address(locker), LP_TOKENS * 2);

        // Lock for first campaign
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        // Lock for second campaign should work
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign2,
            platformRecipient,
            address(0)
        );

        // Verify both are locked
        assertTrue(locker.hasLockedLP(campaign));
        assertTrue(locker.hasLockedLP(campaign2));
        assertEq(locker.totalLockedPositions(), 2);
    }

    function test_createAndLockLP_rescuesWhenRouterFails() public {
        token.approve(address(locker), LP_TOKENS);

        // Make router fail — now rescues instead of reverting (MEV protection)
        router.setShouldFail(true);

        (address pool, uint256 lpAmount) = locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        // Rescued, not reverted
        assertEq(pool, address(0));
        assertEq(lpAmount, 0);
        assertTrue(locker.hasRescuedFunds(campaign));
    }

    // ============ View Function Tests ============

    function test_totalLockedPositions() public {
        assertEq(locker.totalLockedPositions(), 0);

        token.approve(address(locker), LP_TOKENS);
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        assertEq(locker.totalLockedPositions(), 1);
    }

    function test_getLockedPosition_revertsNoLP() public {
        vm.expectRevert("No locked LP for campaign");
        locker.getLockedPosition(campaign);
    }

    function test_getAllLockedPositions() public {
        // Give more tokens
        vm.prank(founder);
        token.transfer(address(this), LP_TOKENS);

        token.approve(address(locker), LP_TOKENS * 2);

        // Create two positions
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign2,
            platformRecipient,
            address(0)
        );

        VibesLPLocker.LockedLP[] memory positions = locker.getAllLockedPositions();
        assertEq(positions.length, 2);
        assertEq(positions[0].campaign, campaign);
        assertEq(positions[1].campaign, campaign2);
    }

    function test_verifyLPLocked_noLP() public view {
        (bool locked, uint256 balance) = locker.verifyLPLocked(campaign);
        assertFalse(locked);
        assertEq(balance, 0);
    }

    function test_verifyLPLocked_withLP() public {
        token.approve(address(locker), LP_TOKENS);
        (address pool, uint256 lpAmount) = locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        (bool locked, uint256 balance) = locker.verifyLPLocked(campaign);
        assertTrue(locked);
        assertEq(balance, lpAmount);
    }

    function test_getInitialPrice() public {
        token.approve(address(locker), LP_TOKENS);
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        uint256 price = locker.getInitialPrice(campaign);

        // Price should be ETH/Tokens * 1e18
        // 10 ETH / 200,000 tokens = 0.00005 ETH per token
        // In wei: 10e18 / 200000e18 * 1e18 = 0.00005e18 = 5e13
        uint256 expectedPrice = (LP_ETH * 1e18) / LP_TOKENS;
        assertEq(price, expectedPrice);
    }

    function test_getInitialPrice_revertsNoLP() public {
        vm.expectRevert("No locked LP");
        locker.getInitialPrice(campaign);
    }

    // ============ Edge Cases ============

    function test_createAndLockLP_smallAmounts() public {
        uint256 smallTokens = 1 ether;
        uint256 smallETH = 0.001 ether;

        token.approve(address(locker), smallTokens);

        (address pool, uint256 lpAmount) = locker.createAndLockLP{value: smallETH}(
            address(token),
            smallTokens,
            campaign,
            platformRecipient,
            address(0)
        );

        assertTrue(lpAmount > 0);
        assertTrue(locker.hasLockedLP(campaign));
    }

    function test_createAndLockLP_largeAmounts() public {
        // Give max tokens
        vm.prank(founder);
        token.transfer(address(this), TOKEN_SUPPLY - LP_TOKENS);

        uint256 largeTokens = TOKEN_SUPPLY - 1 ether; // Almost all supply
        uint256 largeETH = 1000 ether;

        token.approve(address(locker), largeTokens);
        deal(address(this), largeETH);

        (address pool, uint256 lpAmount) = locker.createAndLockLP{value: largeETH}(
            address(token),
            largeTokens,
            campaign,
            platformRecipient,
            address(0)
        );

        assertTrue(lpAmount > 0);
        assertTrue(locker.hasLockedLP(campaign));
    }

    // ============ Integration-style Tests ============

    function test_fullFlow_matchesRaisePrice() public {
        // Scenario: 50 ETH raised, 1M token supply
        // 15% tokens (150k) + 15% ETH (7.5 ETH) goes to LP
        // Price should be: 7.5 ETH / 150k tokens = 0.00005 ETH/token
        //
        // With 5% founder, 0% treasury:
        // Total supply: 1,000,000
        // Backers: 77.5% = 775,000 tokens
        // LP: 15% = 150,000 tokens
        // Founder: 5% = 50,000 tokens (vested)
        // Ecosystem: 2.5% = 25,000 tokens (stakers)
        //
        // If 50 ETH raised and 15% (7.5 ETH) goes to LP:
        // LP price = 7.5 ETH / 150,000 tokens = 0.00005 ETH/token
        //
        // Backer who contributed 1 ETH gets:
        // (1/50) * 775,000 = 15,500 tokens
        // Effective backer price: 1 ETH / 15,500 = 0.0000645 ETH/token
        //
        // LP price is LOWER than backer price - backers get a discount

        token.approve(address(locker), LP_TOKENS);

        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        uint256 lpPrice = locker.getInitialPrice(campaign);
        uint256 expectedPrice = (LP_ETH * 1e18) / LP_TOKENS;
        assertEq(lpPrice, expectedPrice);

        // Verify the price matches expectation
        // 10e18 / 200000e18 * 1e18 = 5e13 (0.00005 ETH per token)
        assertEq(lpPrice, 5e13);
    }

    // ============ Receive ETH ============

    function test_canReceiveETH() public {
        (bool success, ) = address(locker).call{value: 1 ether}("");
        assertTrue(success);
    }

    // ============ Rescue Tests (MEV front-running protection) ============

    function test_createAndLockLP_rescuesOnFailure() public {
        token.approve(address(locker), LP_TOKENS);

        // Make router fail (simulates pool pre-seeded with skewed ratio)
        router.setShouldFail(true);

        // Should NOT revert — funds are rescued instead
        (address pool, uint256 lpAmount) = locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        // Returns zero pool/lpAmount
        assertEq(pool, address(0));
        assertEq(lpAmount, 0);

        // Audit fix F7: Campaign is marked as rescued (NOT locked) to prevent view function corruption
        assertFalse(locker.hasLockedLP(campaign)); // No real locked position exists
        assertTrue(locker.hasRescuedLP(campaign));  // Rescued flag is set instead

        // Rescue funds are stored
        assertTrue(locker.hasRescuedFunds(campaign));
        VibesLPLocker.RescueFunds memory rescue = locker.getRescuedFunds(campaign);
        assertEq(rescue.token, address(token));
        assertEq(rescue.tokenAmount, LP_TOKENS);
        assertEq(rescue.ethAmount, LP_ETH);
        assertEq(rescue.campaign, campaign);
        assertFalse(rescue.resolved);
    }

    function test_resolveRescuedFunds_success() public {
        token.approve(address(locker), LP_TOKENS);
        router.setShouldFail(true);

        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        address recipient = address(0x9999);
        uint256 recipientBalBefore = recipient.balance;
        uint256 recipientTokensBefore = token.balanceOf(recipient);

        // Owner resolves
        locker.resolveRescuedFunds(campaign, recipient);

        // Recipient receives rescued funds
        assertEq(recipient.balance - recipientBalBefore, LP_ETH);
        assertEq(token.balanceOf(recipient) - recipientTokensBefore, LP_TOKENS);

        // Marked as resolved
        VibesLPLocker.RescueFunds memory rescue = locker.getRescuedFunds(campaign);
        assertTrue(rescue.resolved);
    }

    function test_resolveRescuedFunds_revertsIfNoRescue() public {
        vm.expectRevert(VibesLPLocker.NoRescuedFunds.selector);
        locker.resolveRescuedFunds(campaign, address(0x9999));
    }

    function test_resolveRescuedFunds_revertsIfAlreadyResolved() public {
        token.approve(address(locker), LP_TOKENS);
        router.setShouldFail(true);

        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        locker.resolveRescuedFunds(campaign, address(0x9999));

        vm.expectRevert(VibesLPLocker.AlreadyResolved.selector);
        locker.resolveRescuedFunds(campaign, address(0x9999));
    }

    function test_resolveRescuedFunds_onlyOwner() public {
        token.approve(address(locker), LP_TOKENS);
        router.setShouldFail(true);

        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );

        vm.prank(founder);
        vm.expectRevert(VibesLPLocker.OnlyOwner.selector);
        locker.resolveRescuedFunds(campaign, founder);
    }

    // ============ Audit Fix F7: Rescue tracking tests ============

    /// @notice Audit fix F7a: After rescue, getLockedPosition should NOT return wrong campaign data
    function test_F7_GetLockedPosition_AfterRescue_DoesNotReturnWrongCampaign() public {
        // First, create a real locked LP for campaign1
        token.approve(address(locker), LP_TOKENS);
        (address pool1, uint256 lpAmount1) = locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign,
            platformRecipient,
            address(0)
        );
        assertTrue(pool1 != address(0));
        assertTrue(lpAmount1 > 0);

        // Now force a rescue for campaign2
        VibesToken token2 = new VibesToken("Test2", "T2", 18, TOKEN_SUPPLY, address(this));
        token2.approve(address(locker), LP_TOKENS);
        router.setShouldFail(true);
        locker.createAndLockLP{value: LP_ETH}(address(token2), LP_TOKENS, campaign2, platformRecipient, address(0));
        router.setShouldFail(false);

        // campaign2 should be rescued, not locked
        assertTrue(locker.hasRescuedLP(campaign2), "Campaign2 should be rescued");
        assertFalse(locker.hasLockedLP(campaign2), "Campaign2 should NOT be marked as locked");

        // getLockedPosition for campaign2 should revert, NOT return campaign1's data
        vm.expectRevert("No locked LP for campaign");
        locker.getLockedPosition(campaign2);

        // verifyLPLocked for campaign2 should return false
        (bool locked, ) = locker.verifyLPLocked(campaign2);
        assertFalse(locked, "Rescued campaign should not verify as locked");

        // campaign1 should still work correctly
        VibesLPLocker.LockedLP memory pos = locker.getLockedPosition(campaign);
        assertEq(pos.campaign, campaign, "Campaign1 position should be correct");
    }

    /// @notice Audit fix F7a: verifyLPLocked returns false for rescued campaigns
    function test_F7_VerifyLPLocked_ReturnsFalse_ForRescuedCampaign() public {
        token.approve(address(locker), LP_TOKENS);
        router.setShouldFail(true);
        locker.createAndLockLP{value: LP_ETH}(address(token), LP_TOKENS, campaign, platformRecipient, address(0));
        router.setShouldFail(false);

        assertTrue(locker.hasRescuedLP(campaign));
        (bool locked, uint256 balance) = locker.verifyLPLocked(campaign);
        assertFalse(locked, "Should not report as locked");
        assertEq(balance, 0, "Balance should be 0");
    }

    // Allow test contract to receive ETH refunds
    receive() external payable {}
}
