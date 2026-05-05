// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesIdentityRegistry} from "../src/VibesIdentityRegistry.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract VibesIdentityRegistryTest is Test, IERC721Receiver {
    VibesIdentityRegistry public registry;
    address public owner;
    address public stranger = makeAddr("stranger");

    function setUp() public {
        owner = address(this);
        registry = new VibesIdentityRegistry();
    }

    /// @dev Required to receive ERC-721 tokens via _safeMint
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ============ Constructor ============

    function test_constructor() public view {
        assertEq(registry.name(), "Vibestarter Agent Registry");
        assertEq(registry.symbol(), "VIBE-AGENT");
        assertEq(registry.owner(), owner);
        assertEq(registry.totalAgents(), 0);
        assertEq(registry.nextAgentId(), 1);
    }

    // ============ Register with URI ============

    function test_registerWithURI() public {
        uint256 id = registry.register("ipfs://agent1");

        assertEq(id, 1);
        assertEq(registry.totalAgents(), 1);
        assertEq(registry.nextAgentId(), 2);
        assertEq(registry.ownerOf(1), owner);
        assertEq(registry.tokenURI(1), "ipfs://agent1");
        assertEq(registry.agentURI(1), "ipfs://agent1");
    }

    function test_registerWithURI_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.register("ipfs://agent");
    }

    // ============ Register without URI ============

    function test_registerWithoutURI() public {
        uint256 id = registry.register();
        assertEq(id, 1);
        assertEq(registry.totalAgents(), 1);
    }

    function test_registerWithoutURI_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.register();
    }

    // ============ Batch Register ============

    function test_registerBatch() public {
        string[] memory uris = new string[](3);
        uris[0] = "ipfs://a1";
        uris[1] = "ipfs://a2";
        uris[2] = "ipfs://a3";

        uint256 startId = registry.registerBatch(uris);

        assertEq(startId, 1);
        assertEq(registry.totalAgents(), 3);
        assertEq(registry.nextAgentId(), 4);
        assertEq(registry.agentURI(1), "ipfs://a1");
        assertEq(registry.agentURI(2), "ipfs://a2");
        assertEq(registry.agentURI(3), "ipfs://a3");
    }

    function test_registerBatch_revertsNotOwner() public {
        string[] memory uris = new string[](1);
        uris[0] = "ipfs://a1";

        vm.prank(stranger);
        vm.expectRevert();
        registry.registerBatch(uris);
    }

    function test_registerBatch_emptyArray() public {
        string[] memory uris = new string[](0);
        uint256 startId = registry.registerBatch(uris);
        assertEq(startId, 1);
        assertEq(registry.totalAgents(), 0);
    }

    // ============ URI Management ============

    function test_setAgentURI() public {
        registry.register("ipfs://old");

        registry.setAgentURI(1, "ipfs://new");
        assertEq(registry.agentURI(1), "ipfs://new");
    }

    function test_setAgentURI_revertsNotTokenOwner() public {
        registry.register("ipfs://old");

        vm.prank(stranger);
        vm.expectRevert("Not agent owner");
        registry.setAgentURI(1, "ipfs://new");
    }

    // ============ Sequential IDs ============

    function test_sequentialIds() public {
        uint256 id1 = registry.register("a");
        uint256 id2 = registry.register("b");
        uint256 id3 = registry.register();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }

    // ============ ERC-8004 View ============

    function test_getAgentRegistry() public view {
        string memory reg = registry.getAgentRegistry();
        // Should contain "eip155:" prefix and contract address
        assertTrue(bytes(reg).length > 0);
    }

    // ============ ERC-165 ============

    function test_supportsInterface() public view {
        // ERC721 interface
        assertTrue(registry.supportsInterface(0x80ac58cd));
        // ERC165 interface
        assertTrue(registry.supportsInterface(0x01ffc9a7));
    }
}
