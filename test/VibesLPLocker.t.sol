// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VibesLPLocker.sol";
import "../src/VibesToken.sol";
import "./mocks/MockAerodromeRouter.sol";

contract VibesLPLockerTest is Test {
    VibesLPLocker public locker;
    MockAerodromeRouter public router;
    VibesToken public token;

    address public founder = address(0x1);
    address public campaign = address(0x2);
    address public campaign2 = address(0x3);
    address public weth = address(0x4444);
    address public factory = address(0x5555);

    uint256 public constant TOKEN_SUPPLY = 1_000_000 ether;
    uint256 public constant LP_TOKENS = 200_000 ether; // 20% of supply
    uint256 public constant LP_ETH = 10 ether; // 20% of 50 ETH raised

    function setUp() public {
        // Deploy mock router
        router = new MockAerodromeRouter(weth, factory);

        // Deploy locker
        locker = new VibesLPLocker(address(router), factory);

        // Set this test contract as authorized router
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
            campaign
        );

        // Verify LP was created
        assertTrue(pool != address(0), "Pool should be created");
        assertTrue(lpAmount > 0, "LP amount should be positive");

        // Verify LP is locked (sent to dead address)
        uint256 deadBalance = IERC20(pool).balanceOf(locker.DEAD_ADDRESS());
        assertEq(deadBalance, lpAmount, "LP tokens should be at dead address");

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
            campaign
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
            campaign
        );
    }

    function test_createAndLockLP_revertsZeroToken() public {
        vm.expectRevert(VibesLPLocker.ZeroAddress.selector);
        locker.createAndLockLP{value: LP_ETH}(
            address(0),
            LP_TOKENS,
            campaign
        );
    }

    function test_createAndLockLP_revertsZeroAmount() public {
        token.approve(address(locker), LP_TOKENS);

        vm.expectRevert(VibesLPLocker.ZeroAmount.selector);
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            0,
            campaign
        );
    }

    function test_createAndLockLP_revertsNoETH() public {
        token.approve(address(locker), LP_TOKENS);

        vm.expectRevert(VibesLPLocker.InsufficientETH.selector);
        locker.createAndLockLP{value: 0}(
            address(token),
            LP_TOKENS,
            campaign
        );
    }

    function test_createAndLockLP_revertsAlreadyLocked() public {
        token.approve(address(locker), LP_TOKENS * 2);

        // First lock
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign
        );

        // Second lock for same campaign should fail
        vm.expectRevert(VibesLPLocker.AlreadyLocked.selector);
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign
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
            campaign
        );

        // Lock for second campaign should work
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign2
        );

        // Verify both are locked
        assertTrue(locker.hasLockedLP(campaign));
        assertTrue(locker.hasLockedLP(campaign2));
        assertEq(locker.totalLockedPositions(), 2);
    }

    function test_createAndLockLP_revertsWhenRouterFails() public {
        token.approve(address(locker), LP_TOKENS);

        // Make router fail
        router.setShouldFail(true);

        vm.expectRevert("Mock: LP creation failed");
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign
        );
    }

    // ============ View Function Tests ============

    function test_totalLockedPositions() public {
        assertEq(locker.totalLockedPositions(), 0);

        token.approve(address(locker), LP_TOKENS);
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign
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
            campaign
        );
        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign2
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
            campaign
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
            campaign
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
            campaign
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
            campaign
        );

        assertTrue(lpAmount > 0);
        assertTrue(locker.hasLockedLP(campaign));
    }

    // ============ Integration-style Tests ============

    function test_fullFlow_matchesRaisePrice() public {
        // Scenario: 50 ETH raised, 1M token supply
        // 20% tokens (200k) + 20% ETH (10 ETH) goes to LP
        // Price should be: 10 ETH / 200k tokens = 0.00005 ETH/token

        // If backer contributed 1 ETH at fixed goal, they get:
        // (1 ETH / 50 ETH total) * 720,000 backer tokens = 14,400 tokens
        // Implied price: 1 ETH / 14,400 tokens = 0.0000694 ETH/token

        // Wait, let me recalculate for the 72/18/10 split:
        // Total supply: 1,000,000
        // Backers: 72% = 720,000 tokens
        // LP: 18% = 180,000 tokens
        // Founder: 10% = 100,000 tokens (vested)
        //
        // If 50 ETH raised and 20% (10 ETH) goes to LP:
        // LP price = 10 ETH / 180,000 tokens = 0.0000556 ETH/token
        //
        // Backer who contributed 1 ETH gets:
        // (1/50) * 720,000 = 14,400 tokens
        // Effective backer price: 1 ETH / 14,400 = 0.0000694 ETH/token
        //
        // LP price is LOWER than backer price - this is correct for 72/18/10 split

        // For 80/20 backer/LP split (no founder):
        // Backers: 80% = 800,000 tokens
        // LP: 20% = 200,000 tokens
        // LP price = 10 ETH / 200,000 = 0.00005 ETH/token
        // Backer price: 1 ETH / 16,000 = 0.0000625 ETH/token
        // LP price is still lower - this is expected since LP gets same ETH % but more tokens %

        token.approve(address(locker), LP_TOKENS);

        locker.createAndLockLP{value: LP_ETH}(
            address(token),
            LP_TOKENS,
            campaign
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

    // Allow test contract to receive ETH refunds
    receive() external payable {}
}
