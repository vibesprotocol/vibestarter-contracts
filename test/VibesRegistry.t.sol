// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesRegistry} from "../src/VibesRegistry.sol";

contract VibesRegistryTest is Test {
    VibesRegistry public registry;

    address public owner;
    address public router = makeAddr("router");
    address public founder = makeAddr("founder");
    address public tokenAddr = makeAddr("token");
    address public stranger = makeAddr("stranger");

    bytes32 public capsuleHash = keccak256("capsule");
    bytes32 public proofHash = keccak256("proof");

    function setUp() public {
        owner = address(this);
        registry = new VibesRegistry();
    }

    function _defaultAttestation() internal view returns (VibesRegistry.Attestation memory) {
        return VibesRegistry.Attestation({
            version: 1,
            agentTool: 1, // ClaudeCode
            modelProvider: 1, // Anthropic
            proofType: 1, // Transcript
            proofArtifactHash: proofHash
        });
    }

    // ============ Constructor ============

    function test_constructor_setsOwner() public view {
        assertEq(registry.owner(), owner);
    }

    // ============ Router Authorization ============

    function test_authorizeRouter() public {
        registry.authorizeRouter(router);
        assertTrue(registry.authorizedRouters(router));
    }

    function test_revokeRouter() public {
        registry.authorizeRouter(router);
        registry.revokeRouter(router);
        assertFalse(registry.authorizedRouters(router));
    }

    function test_authorizeRouter_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        registry.authorizeRouter(router);
    }

    function test_authorizeRouter_revertsZeroAddress() public {
        vm.expectRevert("Invalid router");
        registry.authorizeRouter(address(0));
    }

    // ============ Registration via Router ============

    function test_registerFromRouter() public {
        registry.authorizeRouter(router);

        vm.prank(router);
        registry.registerFromRouter(tokenAddr, founder, capsuleHash, _defaultAttestation());

        assertTrue(registry.isRegistered(tokenAddr));
        assertEq(registry.founderOf(tokenAddr), founder);
        assertEq(registry.capsuleHashOf(tokenAddr), capsuleHash);
    }

    function test_registerFromRouter_revertsNotAuthorized() public {
        vm.prank(stranger);
        vm.expectRevert("Not authorized router");
        registry.registerFromRouter(tokenAddr, founder, capsuleHash, _defaultAttestation());
    }

    function test_registerFromRouter_revertsAlreadyRegistered() public {
        registry.authorizeRouter(router);

        vm.prank(router);
        registry.registerFromRouter(tokenAddr, founder, capsuleHash, _defaultAttestation());

        vm.prank(router);
        vm.expectRevert("Already registered");
        registry.registerFromRouter(tokenAddr, founder, capsuleHash, _defaultAttestation());
    }

    // ============ Direct Registration ============

    function test_register_direct() public {
        vm.prank(founder);
        registry.register(tokenAddr, capsuleHash, _defaultAttestation());

        assertTrue(registry.isRegistered(tokenAddr));
        assertEq(registry.founderOf(tokenAddr), founder);
    }

    // ============ Validation ============

    function test_register_revertsZeroToken() public {
        vm.expectRevert("Invalid token");
        registry.register(address(0), capsuleHash, _defaultAttestation());
    }

    function test_register_revertsZeroCapsuleHash() public {
        vm.expectRevert("Capsule hash required");
        registry.register(tokenAddr, bytes32(0), _defaultAttestation());
    }

    function test_register_revertsZeroProofHash() public {
        VibesRegistry.Attestation memory att = _defaultAttestation();
        att.proofArtifactHash = bytes32(0);
        vm.expectRevert("Proof hash required");
        registry.register(tokenAddr, capsuleHash, att);
    }

    // ============ Attestation Storage ============

    function test_getAttestation() public {
        vm.prank(founder);
        registry.register(tokenAddr, capsuleHash, _defaultAttestation());

        VibesRegistry.Attestation memory att = registry.getAttestation(tokenAddr);
        assertEq(att.version, 1);
        assertEq(att.agentTool, 1);
        assertEq(att.modelProvider, 1);
        assertEq(att.proofType, 1);
        assertEq(att.proofArtifactHash, proofHash);
    }

    // ============ Ownership ============

    function test_transferOwnership_setsPendingOwner() public {
        address newOwner = makeAddr("newOwner");
        registry.transferOwnership(newOwner);
        assertEq(registry.pendingOwner(), newOwner);
        assertEq(registry.owner(), address(this)); // not transferred yet
    }

    function test_acceptOwnership_completesTransfer() public {
        address newOwner = makeAddr("newOwner");
        registry.transferOwnership(newOwner);
        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_acceptOwnership_revertsNotPending() public {
        address newOwner = makeAddr("newOwner");
        registry.transferOwnership(newOwner);
        vm.prank(stranger);
        vm.expectRevert("Not pending owner");
        registry.acceptOwnership();
    }

    function test_transferOwnership_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        registry.transferOwnership(stranger);
    }

    function test_transferOwnership_revertsZeroAddress() public {
        vm.expectRevert("Invalid owner");
        registry.transferOwnership(address(0));
    }
}
