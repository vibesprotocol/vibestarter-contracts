// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VibesIdentityRegistry
 * @notice ERC-8004 compliant Identity Registry for AI agents
 * @dev Minimal implementation of ERC-8004 Identity Registry.
 *      Each agent is an ERC-721 token with URI storage for metadata.
 *      Only the owner can register agents (proxy registration model).
 *
 * ERC-8004 Spec: https://eips.ethereum.org/EIPS/eip-8004
 */
contract VibesIdentityRegistry is ERC721, ERC721URIStorage, Ownable {
    // ============================================
    // EVENTS (per ERC-8004)
    // ============================================

    /// @notice Emitted when a new agent is registered
    event Registered(
        uint256 indexed agentId,
        string agentURI,
        address indexed owner
    );

    /// @notice Emitted when an agent's URI is updated
    event URIUpdated(
        uint256 indexed agentId,
        string newURI,
        address indexed updatedBy
    );

    // ============================================
    // STATE
    // ============================================

    /// @notice Counter for agent IDs (starts at 1)
    uint256 private _nextAgentId = 1;

    /// @notice Total number of registered agents
    uint256 public totalAgents;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor() ERC721("Vibestarter Agent Registry", "VIBE-AGENT") Ownable(msg.sender) {}

    // ============================================
    // REGISTRATION FUNCTIONS (ERC-8004)
    // ============================================

    /**
     * @notice Register a new agent with URI
     * @dev Only owner can register (proxy model for AI agents)
     * @param agentURI URI pointing to agent registration file (IPFS, HTTPS, etc.)
     * @return agentId The assigned agent token ID
     */
    function register(string calldata agentURI) external onlyOwner returns (uint256 agentId) {
        agentId = _nextAgentId++;
        totalAgents++;

        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);

        emit Registered(agentId, agentURI, msg.sender);
    }

    /**
     * @notice Register a new agent without URI (can set later)
     * @dev Only owner can register
     * @return agentId The assigned agent token ID
     */
    function register() external onlyOwner returns (uint256 agentId) {
        agentId = _nextAgentId++;
        totalAgents++;

        _safeMint(msg.sender, agentId);

        emit Registered(agentId, "", msg.sender);
    }

    /**
     * @notice Batch register multiple agents
     * @dev Only owner can register. More gas efficient for initial setup.
     * @param agentURIs Array of URIs for each agent
     * @return startId The first agent ID assigned
     */
    function registerBatch(string[] calldata agentURIs) external onlyOwner returns (uint256 startId) {
        startId = _nextAgentId;
        uint256 count = agentURIs.length;

        for (uint256 i = 0; i < count; i++) {
            uint256 agentId = _nextAgentId++;
            totalAgents++;

            _safeMint(msg.sender, agentId);
            _setTokenURI(agentId, agentURIs[i]);

            emit Registered(agentId, agentURIs[i], msg.sender);
        }
    }

    // ============================================
    // URI MANAGEMENT (ERC-8004)
    // ============================================

    /**
     * @notice Update an agent's URI
     * @dev Only token owner can update
     * @param agentId The agent token ID
     * @param newURI The new URI
     */
    function setAgentURI(uint256 agentId, string calldata newURI) external {
        require(ownerOf(agentId) == msg.sender, "Not agent owner");
        _setTokenURI(agentId, newURI);
        emit URIUpdated(agentId, newURI, msg.sender);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the agent URI (alias for tokenURI)
     * @param agentId The agent token ID
     * @return The agent's registration file URI
     */
    function agentURI(uint256 agentId) external view returns (string memory) {
        return tokenURI(agentId);
    }

    /**
     * @notice Get the next agent ID that will be assigned
     * @return The next agent ID
     */
    function nextAgentId() external view returns (uint256) {
        return _nextAgentId;
    }

    /**
     * @notice Build the agentRegistry identifier per ERC-8004
     * @dev Format: eip155:{chainId}:{contractAddress}
     * @return The agentRegistry string
     */
    function getAgentRegistry() external view returns (string memory) {
        return string(
            abi.encodePacked(
                "eip155:",
                _toString(block.chainid),
                ":",
                _toHexString(address(this))
            )
        );
    }

    // ============================================
    // OVERRIDES
    // ============================================

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ============================================
    // INTERNAL HELPERS
    // ============================================

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory data = abi.encodePacked(addr);
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
