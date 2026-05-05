// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {VibesTokenFactory} from "../src/VibesTokenFactory.sol";

contract VibesTokenTest is Test {
    VibesToken public token;
    address public recipient = makeAddr("recipient");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant SUPPLY = 1_000_000 ether;

    function setUp() public {
        token = new VibesToken("TestToken", "TT", 18, SUPPLY, recipient);
    }

    // ============ Constructor ============

    function test_constructor() public view {
        assertEq(token.name(), "TestToken");
        assertEq(token.symbol(), "TT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(recipient), SUPPLY);
    }

    function test_constructor_revertsEmptyName() public {
        vm.expectRevert("Name required");
        new VibesToken("", "TT", 18, SUPPLY, recipient);
    }

    function test_constructor_revertsEmptySymbol() public {
        vm.expectRevert("Symbol required");
        new VibesToken("Test", "", 18, SUPPLY, recipient);
    }

    function test_constructor_revertsZeroSupply() public {
        vm.expectRevert("Supply must be > 0");
        new VibesToken("Test", "TT", 18, 0, recipient);
    }

    function test_constructor_revertsZeroRecipient() public {
        vm.expectRevert("Invalid recipient");
        new VibesToken("Test", "TT", 18, SUPPLY, address(0));
    }

    // ============ Transfer ============

    function test_transfer() public {
        vm.prank(recipient);
        token.transfer(alice, 100 ether);

        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(recipient), SUPPLY - 100 ether);
    }

    function test_transfer_revertsInsufficientBalance() public {
        vm.prank(alice); // alice has 0
        vm.expectRevert("Insufficient balance");
        token.transfer(bob, 1);
    }

    function test_transfer_revertsZeroAddress() public {
        vm.prank(recipient);
        vm.expectRevert("Invalid recipient");
        token.transfer(address(0), 100);
    }

    // ============ Approve & TransferFrom ============

    function test_approve() public {
        vm.prank(recipient);
        token.approve(alice, 500 ether);
        assertEq(token.allowance(recipient, alice), 500 ether);
    }

    function test_transferFrom() public {
        vm.prank(recipient);
        token.approve(alice, 500 ether);

        vm.prank(alice);
        token.transferFrom(recipient, bob, 100 ether);

        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.allowance(recipient, alice), 400 ether);
    }

    function test_transferFrom_maxAllowance() public {
        vm.prank(recipient);
        token.approve(alice, type(uint256).max);

        vm.prank(alice);
        token.transferFrom(recipient, bob, 100 ether);

        // Max allowance should not decrease
        assertEq(token.allowance(recipient, alice), type(uint256).max);
    }

    function test_transferFrom_revertsInsufficientAllowance() public {
        vm.prank(recipient);
        token.approve(alice, 50 ether);

        vm.prank(alice);
        vm.expectRevert("Insufficient allowance");
        token.transferFrom(recipient, bob, 100 ether);
    }
}

contract VibesTokenFactoryTest is Test {
    VibesTokenFactory public factory;
    address public recipient = makeAddr("recipient");

    function setUp() public {
        factory = new VibesTokenFactory();
    }

    function test_deployToken() public {
        address token = factory.deployToken("Test", "TST", 18, 1_000_000 ether, recipient);

        assertTrue(token != address(0));
        assertEq(VibesToken(token).name(), "Test");
        assertEq(VibesToken(token).symbol(), "TST");
        assertEq(VibesToken(token).totalSupply(), 1_000_000 ether);
        assertEq(VibesToken(token).balanceOf(recipient), 1_000_000 ether);
    }

    function test_deployToken_multipleTokens() public {
        address token1 = factory.deployToken("T1", "T1", 18, 1000, recipient);
        address token2 = factory.deployToken("T2", "T2", 18, 2000, recipient);

        assertTrue(token1 != token2);
        assertEq(VibesToken(token1).totalSupply(), 1000);
        assertEq(VibesToken(token2).totalSupply(), 2000);
    }
}
