// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VibesRegistry
 * @notice Immutable registry of VibesCertified token provenance.
 * @dev Stores founder identity, capsule hash, and AI agent attestation.
 *      Once registered, a token's provenance cannot be changed.
 */
contract VibesRegistry {
    // ============================================
    // TYPES
    // ============================================
    
    /**
     * @notice AI agent attestation struct
     * @param version Attestation schema version (for future-proofing)
     * @param agentTool Tool used (0=Other, 1=ClaudeCode, 2=Cursor, 3=Windsurf, 4=Replit)
     * @param modelProvider Provider (0=Other, 1=Anthropic, 2=OpenAI, 3=Google, 4=Local)
     * @param proofType Type of proof (0=Other, 1=Transcript, 2=PRD, 3=RepoCommit, 4=CodeZip)
     * @param proofArtifactHash Keccak256 hash of the proof artifact
     */
    struct Attestation {
        uint8 version;
        uint8 agentTool;
        uint8 modelProvider;
        uint8 proofType;
        bytes32 proofArtifactHash;
    }

    // ============================================
    // EVENTS
    // ============================================
    
    /**
     * @notice Emitted when a token's provenance is registered
     * @param token Address of the registered token
     * @param founder Address of the founding developer
     * @param capsuleHash Keccak256 hash of the off-chain capsule JSON
     */
    event VibesRegistered(
        address indexed token,
        address indexed founder,
        bytes32 capsuleHash
    );

    /**
     * @notice Emitted when an AI agent attestation is recorded for a token
     * @param token Address of the attested token
     * @param founder Address of the founding developer
     * @param agentTool Tool used (0=Other, 1=ClaudeCode, 2=Cursor, 3=Windsurf, 4=Replit)
     * @param modelProvider AI provider (0=Other, 1=Anthropic, 2=OpenAI, 3=Google, 4=Local)
     * @param proofType Type of proof (0=Other, 1=Transcript, 2=PRD, 3=RepoCommit, 4=CodeZip)
     * @param artifactHash Keccak256 hash of the proof artifact
     */
    event AgentAttested(
        address indexed token,
        address indexed founder,
        uint8 agentTool,
        uint8 modelProvider,
        uint8 proofType,
        bytes32 artifactHash
    );

    /// @notice Emitted when a router is authorized to register tokens
    /// @param router Address of the authorized router
    event RouterAuthorized(address indexed router);

    /// @notice Emitted when a router's authorization is revoked
    /// @param router Address of the revoked router
    event RouterRevoked(address indexed router);

    // ============================================
    // STATE
    // ============================================
    
    /// @notice Contract owner
    address public owner;

    /// @notice Pending owner for two-step ownership transfer
    address public pendingOwner;

    /// @notice Authorized routers that can register on behalf of founders
    mapping(address => bool) public authorizedRouters;
    
    /// @notice Founder address for each registered token
    mapping(address => address) public founderOf;
    
    /// @notice Capsule hash for each registered token
    mapping(address => bytes32) public capsuleHashOf;
    
    /// @notice AI agent attestation for each registered token
    mapping(address => Attestation) public attestationOf;
    
    /// @notice Check if a token is registered
    mapping(address => bool) public isRegistered;

    // ============================================
    // CONSTRUCTOR
    // ============================================
    
    /// @notice Deploy the registry with the deployer as owner
    constructor() {
        owner = msg.sender;
    }

    // ============================================
    // MODIFIERS
    // ============================================
    
    /// @dev Restricts access to the contract owner
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================
    
    /**
     * @notice Authorize a router to register tokens
     * @param router Address of the router to authorize
     */
    function authorizeRouter(address router) external onlyOwner {
        require(router != address(0), "Invalid router");
        authorizedRouters[router] = true;
        emit RouterAuthorized(router);
    }
    
    /**
     * @notice Revoke router authorization
     * @param router Address of the router to revoke
     */
    function revokeRouter(address router) external onlyOwner {
        authorizedRouters[router] = false;
        emit RouterRevoked(router);
    }
    
    /**
     * @notice Propose a new owner (two-step transfer, step 1)
     * @dev The new owner must call acceptOwnership() to complete the transfer.
     *      This prevents accidental ownership loss from typos or wrong addresses.
     * @param newOwner Address of the proposed new owner
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        pendingOwner = newOwner;
    }

    /**
     * @notice Accept ownership transfer (two-step transfer, step 2)
     * @dev Only the pending owner can call this to complete the transfer.
     */
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ============================================
    // REGISTRATION FUNCTIONS
    // ============================================
    
    /**
     * @notice Register a token with its provenance data (called by authorized router)
     * @dev Only authorized routers can call this function.
     * @param token Address of the token to register
     * @param founder Address of the founder (the original caller)
     * @param capsuleHash Keccak256 hash of the off-chain capsule JSON
     * @param attestation AI agent attestation data
     */
    function registerFromRouter(
        address token,
        address founder,
        bytes32 capsuleHash,
        Attestation calldata attestation
    ) external {
        require(authorizedRouters[msg.sender], "Not authorized router");
        _register(token, founder, capsuleHash, attestation);
    }
    
    /**
     * @notice Register a token directly (founder calls directly)
     * @dev Founder is set to msg.sender.
     * @param token Address of the token to register
     * @param capsuleHash Keccak256 hash of the off-chain capsule JSON
     * @param attestation AI agent attestation data
     */
    function register(
        address token,
        bytes32 capsuleHash,
        Attestation calldata attestation
    ) external {
        _register(token, msg.sender, capsuleHash, attestation);
    }
    
    /**
     * @notice Internal registration logic shared by register() and registerFromRouter()
     * @dev Validates inputs, stores provenance data, and emits registration events.
     *      Once registered, a token's provenance cannot be changed.
     * @param token Address of the token to register
     * @param founder Address of the founding developer
     * @param capsuleHash Keccak256 hash of the off-chain capsule JSON
     * @param attestation AI agent attestation data
     */
    function _register(
        address token,
        address founder,
        bytes32 capsuleHash,
        Attestation calldata attestation
    ) internal {
        // Validation
        require(token != address(0), "Invalid token");
        require(founder != address(0), "Invalid founder");
        require(!isRegistered[token], "Already registered");
        require(capsuleHash != bytes32(0), "Capsule hash required");
        require(attestation.proofArtifactHash != bytes32(0), "Proof hash required");
        
        // Store provenance
        isRegistered[token] = true;
        founderOf[token] = founder;
        capsuleHashOf[token] = capsuleHash;
        attestationOf[token] = attestation;
        
        // Emit events
        emit VibesRegistered(token, founder, capsuleHash);
        emit AgentAttested(
            token,
            founder,
            attestation.agentTool,
            attestation.modelProvider,
            attestation.proofType,
            attestation.proofArtifactHash
        );
    }
    
    /**
     * @notice Get full attestation data for a token
     * @param token Token address to query
     * @return Attestation struct
     */
    function getAttestation(address token) external view returns (Attestation memory) {
        return attestationOf[token];
    }
}
