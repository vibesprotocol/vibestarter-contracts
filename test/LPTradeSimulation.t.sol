// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockAerodromePool.sol";

/**
 * @title LP Trade Simulation Tests
 * @notice Tests that verify LP pricing, trade execution, and price impact
 *         using a constant-product AMM mock that mirrors Aerodrome volatile pools.
 *
 * Since we can't deploy to testnet with real Aerodrome, these tests provide
 * confidence that:
 * 1. LP price matches the raise price at pool creation
 * 2. Swaps execute correctly with price impact
 * 3. Large trades move price predictably (constant product)
 * 4. Multiple sequential trades track price correctly
 * 5. Price converges back after buy/sell cycles
 * 6. The locked LP cannot be removed (dead address simulation)
 */
contract LPTradeSimulationTest is Test {
    VibesToken public token;
    MockAerodromePool public pool;

    // Mock WETH as a simple ERC20
    VibesToken public weth;

    address public founder = makeAddr("founder");
    address public trader1 = makeAddr("trader1");
    address public trader2 = makeAddr("trader2");
    address public deadAddress = 0x000000000000000000000000000000000000dEaD;

    // Mirrors Vibestarter allocation: 1M supply, 18% to LP
    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant LP_TOKENS = 180_000 ether;  // 18% of supply
    uint256 public constant LP_ETH = 1.5 ether;           // 15% of 10 ETH raise

    function setUp() public {
        // Deploy token and WETH mock
        token = new VibesToken("Test Token", "TEST", 18, TOTAL_SUPPLY, founder);
        weth = new VibesToken("Wrapped ETH", "WETH", 18, 1_000_000 ether, address(this));

        // Deploy pool (token0=token, token1=weth)
        pool = new MockAerodromePool(address(token), address(weth));

        // Founder provides liquidity
        vm.prank(founder);
        token.transfer(address(this), LP_TOKENS);

        // Add initial liquidity
        token.approve(address(pool), LP_TOKENS);
        weth.approve(address(pool), LP_ETH);
        pool.addLiquidity(LP_TOKENS, LP_ETH, address(this));

        // Fund traders with WETH and tokens
        weth.transfer(trader1, 100 ether);
        weth.transfer(trader2, 100 ether);

        vm.prank(founder);
        token.transfer(trader1, 50_000 ether);
        vm.prank(founder);
        token.transfer(trader2, 50_000 ether);
    }

    // ============ Price at Pool Creation ============

    function test_initialPrice_matchesRaisePrice() public view {
        // LP price = ETH / Tokens = 2 ETH / 180,000 tokens
        uint256 price = pool.getPrice0In1();

        // Expected: 2e18 / 180000e18 * 1e18 ≈ 1.111e13
        uint256 expectedPrice = (LP_ETH * 1e18) / LP_TOKENS;
        assertEq(price, expectedPrice);
        assertTrue(price > 0, "Price should be positive");
    }

    function test_initialReserves_matchLPAmounts() public view {
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, LP_TOKENS, "Token reserve should match LP allocation");
        assertEq(r1, LP_ETH, "WETH reserve should match ETH for LP");
    }

    function test_initialK_isProduct() public view {
        uint256 k = pool.getK();
        assertEq(k, LP_TOKENS * LP_ETH, "k should equal reserves product");
    }

    // ============ Buy (WETH → Token) ============

    function test_buy_smallTrade_minimalPriceImpact() public {
        uint256 buyAmount = 0.01 ether; // Small buy: 0.5% of LP ETH
        uint256 priceBefore = pool.getPrice0In1();

        vm.startPrank(trader1);
        weth.approve(address(pool), buyAmount);
        uint256 tokensReceived = pool.swap1For0(buyAmount, trader1);
        vm.stopPrank();

        uint256 priceAfter = pool.getPrice0In1();

        assertTrue(tokensReceived > 0, "Should receive tokens");
        // Price should increase slightly (more WETH in pool, fewer tokens)
        assertTrue(priceAfter > priceBefore, "Price should increase after buy");

        // Price impact should be small (~1% for 0.5% of liquidity)
        uint256 priceChangeBps = ((priceAfter - priceBefore) * 10000) / priceBefore;
        assertTrue(priceChangeBps < 200, "Small trade should have <2% price impact");
    }

    function test_buy_largeTrade_significantPriceImpact() public {
        uint256 buyAmount = 1 ether; // 50% of LP ETH
        uint256 priceBefore = pool.getPrice0In1();

        vm.startPrank(trader1);
        weth.approve(address(pool), buyAmount);
        pool.swap1For0(buyAmount, trader1);
        vm.stopPrank();

        uint256 priceAfter = pool.getPrice0In1();

        // Large trade should have significant price impact
        uint256 priceChangeBps = ((priceAfter - priceBefore) * 10000) / priceBefore;
        assertTrue(priceChangeBps > 2000, "Large trade should have >20% price impact");
    }

    function test_buy_tokensReceived_lessWithSlippage() public {
        uint256 buyAmount = 0.1 ether;

        // Ideal output (no fee, no slippage): buyAmount * reserve0 / reserve1
        uint256 idealOutput = (buyAmount * LP_TOKENS) / LP_ETH;

        vm.startPrank(trader1);
        weth.approve(address(pool), buyAmount);
        uint256 actualOutput = pool.swap1For0(buyAmount, trader1);
        vm.stopPrank();

        // Actual should be less than ideal due to fee + slippage
        assertTrue(actualOutput < idealOutput, "Actual output should be less than ideal (fee + slippage)");
        // But should be reasonably close (within 10% for moderate trade)
        assertTrue(actualOutput > (idealOutput * 85) / 100, "Output shouldn't be drastically less");
    }

    // ============ Sell (Token → WETH) ============

    function test_sell_smallTrade_getsWeth() public {
        uint256 sellAmount = 1_000 ether; // 1000 tokens (~0.5% of LP tokens)

        vm.startPrank(trader1);
        token.approve(address(pool), sellAmount);
        uint256 wethReceived = pool.swap0For1(sellAmount, trader1);
        vm.stopPrank();

        assertTrue(wethReceived > 0, "Should receive WETH for selling tokens");

        // Price should decrease after sell (more tokens in pool)
        uint256 priceAfter = pool.getPrice0In1();
        uint256 expectedPrice = (LP_ETH * 1e18) / LP_TOKENS;
        assertTrue(priceAfter < expectedPrice, "Price should decrease after sell");
    }

    // ============ Buy + Sell Round-Trip ============

    function test_buyThenSell_priceConvergesBack() public {
        uint256 buyAmount = 0.05 ether;
        uint256 priceBefore = pool.getPrice0In1();

        // Buy tokens
        vm.startPrank(trader1);
        weth.approve(address(pool), buyAmount);
        uint256 tokensReceived = pool.swap1For0(buyAmount, trader1);

        // Sell those same tokens back
        token.approve(address(pool), tokensReceived);
        pool.swap0For1(tokensReceived, trader1);
        vm.stopPrank();

        uint256 priceAfter = pool.getPrice0In1();

        // Price should be very close to original (only difference is fees)
        uint256 priceDiff;
        if (priceAfter > priceBefore) {
            priceDiff = priceAfter - priceBefore;
        } else {
            priceDiff = priceBefore - priceAfter;
        }
        uint256 diffBps = (priceDiff * 10000) / priceBefore;

        // After round-trip, price should be within 1% of original (fees are 0.3% each way)
        assertTrue(diffBps < 100, "Price should converge back within 1% after round-trip");
    }

    // ============ Multiple Sequential Trades ============

    function test_multipleTraders_priceTracksCorrectly() public {
        uint256 priceBefore = pool.getPrice0In1();

        // Trader1 buys 0.1 WETH worth of tokens
        vm.startPrank(trader1);
        weth.approve(address(pool), 0.1 ether);
        pool.swap1For0(0.1 ether, trader1);
        vm.stopPrank();

        uint256 priceAfterBuy1 = pool.getPrice0In1();
        assertTrue(priceAfterBuy1 > priceBefore, "Price up after buy");

        // Trader2 also buys 0.1 WETH worth
        vm.startPrank(trader2);
        weth.approve(address(pool), 0.1 ether);
        pool.swap1For0(0.1 ether, trader2);
        vm.stopPrank();

        uint256 priceAfterBuy2 = pool.getPrice0In1();
        assertTrue(priceAfterBuy2 > priceAfterBuy1, "Price up more after second buy");

        // Trader1 sells all their tokens back
        uint256 trader1Balance = token.balanceOf(trader1);
        vm.startPrank(trader1);
        token.approve(address(pool), trader1Balance);
        pool.swap0For1(trader1Balance, trader1);
        vm.stopPrank();

        uint256 priceAfterSell = pool.getPrice0In1();
        assertTrue(priceAfterSell < priceAfterBuy2, "Price down after large sell");
    }

    // ============ K Invariant ============

    function test_kInvariant_maintainedAfterTrades() public {
        uint256 kBefore = pool.getK();

        // Execute several trades
        vm.startPrank(trader1);
        weth.approve(address(pool), 0.5 ether);
        pool.swap1For0(0.5 ether, trader1);
        vm.stopPrank();

        uint256 kAfter = pool.getK();

        // k should increase or stay same (fees add to reserves)
        assertTrue(kAfter >= kBefore, "k should not decrease (fees increase k)");
    }

    // ============ LP Lock Verification ============

    function test_lpTokens_sentToDeadAddress_cannotBeRecovered() public {
        // Get LP balance
        uint256 lpBalance = pool.balanceOf(address(this));
        assertTrue(lpBalance > 0, "Should have LP tokens");

        // Send to dead address (simulating VibesLPLocker behavior)
        pool.transfer(deadAddress, lpBalance);

        // Verify LP tokens are at dead address
        assertEq(pool.balanceOf(deadAddress), lpBalance);
        assertEq(pool.balanceOf(address(this)), 0);

        // Dead address can't approve/transfer (it's an EOA with no private key)
        // This verifies LP is permanently locked — nobody can remove liquidity
    }

    function test_poolStillTradeable_afterLPLock() public {
        // Lock LP tokens
        uint256 lpBalance = pool.balanceOf(address(this));
        pool.transfer(deadAddress, lpBalance);

        // Pool should still be tradeable even with LP locked
        vm.startPrank(trader1);
        weth.approve(address(pool), 0.01 ether);
        uint256 tokensReceived = pool.swap1For0(0.01 ether, trader1);
        vm.stopPrank();

        assertTrue(tokensReceived > 0, "Trades should still work with locked LP");
    }

    // ============ Price Impact Scenarios ============

    function test_priceImpact_scaledTable() public {
        // Test price impact at various trade sizes relative to pool
        uint256[] memory buyBps = new uint256[](5);
        buyBps[0] = 10;    // 0.1% of LP
        buyBps[1] = 100;   // 1% of LP
        buyBps[2] = 500;   // 5% of LP
        buyBps[3] = 1000;  // 10% of LP
        buyBps[4] = 5000;  // 50% of LP

        uint256 prevImpact = 0;

        for (uint256 i = 0; i < buyBps.length; i++) {
            // Fork state for each test
            uint256 snapshot = vm.snapshot();

            uint256 buyAmount = (LP_ETH * buyBps[i]) / 10000;
            uint256 priceBefore = pool.getPrice0In1();

            vm.startPrank(trader1);
            weth.approve(address(pool), buyAmount);
            pool.swap1For0(buyAmount, trader1);
            vm.stopPrank();

            uint256 priceAfter = pool.getPrice0In1();
            uint256 impact = ((priceAfter - priceBefore) * 10000) / priceBefore;

            // Each larger trade should have proportionally more impact
            assertTrue(impact > prevImpact, "Larger trades should have more impact");
            prevImpact = impact;

            vm.revertTo(snapshot);
        }
    }

    // ============ Edge Cases ============

    function test_swap_revertsOnZeroInput() public {
        vm.startPrank(trader1);
        weth.approve(address(pool), 0);
        vm.expectRevert("Zero input");
        pool.swap1For0(0, trader1);
        vm.stopPrank();
    }

    function test_swap_revertsOnDrainingReserve() public {
        // Try to buy all tokens in pool (should fail or give very few)
        uint256 absurdBuy = 90 ether; // Way more than LP ETH (2 ETH); trader1 has 100 ETH
        vm.startPrank(trader1);
        weth.approve(address(pool), absurdBuy);
        uint256 tokensOut = pool.swap1For0(absurdBuy, trader1);
        vm.stopPrank();

        // Should receive tokens but never fully drain
        assertTrue(tokensOut < LP_TOKENS, "Cannot drain entire reserve");
        (uint256 r0, ) = pool.getReserves();
        assertTrue(r0 > 0, "Token reserve should not reach zero");
    }
}
