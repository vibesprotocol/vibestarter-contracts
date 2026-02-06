// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { VibesCampaignEscrow } from "./VibesCampaignEscrow.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title VibesCampaignFactory
 * @notice Factory for deploying campaign escrow contracts.
 * @dev Uses EIP-1167 minimal proxy pattern for gas-efficient deployments.
 */
contract VibesCampaignFactory {
    // ============================================
    // EVENTS
    // ============================================

    event CampaignCreated(
        address indexed escrow,
        address indexed token,
        address indexed founder,
        VibesCampaignEscrow.FundingModel fundingModel,
        uint256 goalAmount,
        uint256 deadline
    );

    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    event ProtocolFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // ============================================
    // STATE
    // ============================================

    /// @notice Contract owner
    address public owner;

    /// @notice VibesRegistry address for capsule verification
    address public registry;

    /// @notice Escrow implementation address for cloning
    address public immutable escrowImplementation;

    /// @notice Protocol fee in basis points (e.g., 250 = 2.5%)
    uint256 public protocolFeeBps;

    /// @notice Protocol fee recipient
    address public protocolFeeRecipient;

    /// @notice All deployed escrows
    address[] public escrows;

    /// @notice Escrow address by token
    mapping(address => address) public escrowByToken;

    /// @notice Check if an address is an escrow deployed by this factory
    mapping(address => bool) public isEscrow;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @param _registry VibesRegistry address
     * @param _escrowImplementation Escrow implementation for cloning
     * @param _protocolFeeBps Protocol fee in basis points
     * @param _protocolFeeRecipient Protocol fee recipient
     */
    constructor(
        address _registry,
        address _escrowImplementation,
        uint256 _protocolFeeBps,
        address _protocolFeeRecipient
    ) {
        require(_registry != address(0), "Invalid registry");
        require(_escrowImplementation != address(0), "Invalid implementation");
        require(_protocolFeeBps <= 1000, "Fee too high"); // Max 10%

        owner = msg.sender;
        registry = _registry;
        escrowImplementation = _escrowImplementation;
        protocolFeeBps = _protocolFeeBps;
        protocolFeeRecipient = _protocolFeeRecipient;
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ============================================
    // CAMPAIGN CREATION
    // ============================================

    /**
     * @notice Create a new campaign with milestones
     * @param _token Token address
     * @param _founder Founder address (who will control the campaign)
     * @param _fundingModel Funding model enum
     * @param _goalAmount Goal for FIXED_GOAL (0 for others)
     * @param _softCap Soft cap for OPEN_ENDED (0 for others)
     * @param _hardCap Maximum contributions (0 for unlimited)
     * @param _deadline Deadline timestamp (0 for no deadline)
     * @param _milestoneTitles Array of milestone titles
     * @param _milestonePercents Array of release percentages (basis points)
     * @param _backerTokenAllocation Tokens allocated for backer distribution
     * @return escrow Address of the deployed escrow
     */
    function createCampaign(
        address _token,
        address _founder,
        VibesCampaignEscrow.FundingModel _fundingModel,
        uint256 _goalAmount,
        uint256 _softCap,
        uint256 _hardCap,
        uint256 _deadline,
        string[] calldata _milestoneTitles,
        uint256[] calldata _milestonePercents,
        uint256 _backerTokenAllocation
    ) external returns (address escrow) {
        require(_token != address(0), "Invalid token");
        require(_founder != address(0), "Invalid founder");
        require(escrowByToken[_token] == address(0), "Campaign exists for token");
        require(_milestoneTitles.length > 0, "No milestones");
        require(_milestoneTitles.length == _milestonePercents.length, "Array mismatch");

        // Validate milestone percentages sum to 100%
        uint256 totalPercent = 0;
        for (uint256 i = 0; i < _milestonePercents.length; i++) {
            totalPercent += _milestonePercents[i];
        }
        require(totalPercent == 10000, "Milestones must sum to 100%");

        // Deploy escrow using minimal proxy (EIP-1167)
        escrow = Clones.clone(escrowImplementation);
        VibesCampaignEscrow newEscrow = VibesCampaignEscrow(payable(escrow));

        // Initialize the escrow
        newEscrow.initialize(
            registry,
            _token,
            _founder,
            _fundingModel,
            _goalAmount,
            _softCap,
            _hardCap,
            _deadline,
            protocolFeeBps,
            protocolFeeRecipient,
            _backerTokenAllocation
        );

        // Add milestones
        for (uint256 i = 0; i < _milestoneTitles.length; i++) {
            newEscrow.addMilestone(_milestoneTitles[i], _milestonePercents[i]);
        }

        // Track escrow
        escrows.push(escrow);
        escrowByToken[_token] = escrow;
        isEscrow[escrow] = true;

        emit CampaignCreated(
            escrow,
            _token,
            _founder,
            _fundingModel,
            _goalAmount,
            _deadline
        );
    }

    /**
     * @notice Create campaign with simple milestone setup
     * @dev Convenience function with default 2-milestone structure
     * @param _token Token address
     * @param _founder Founder address
     * @param _goalAmount Goal amount in wei
     * @param _deadline Deadline timestamp
     * @param _backerTokenAllocation Tokens allocated for backer distribution
     */
    function createSimpleCampaign(
        address _token,
        address _founder,
        uint256 _goalAmount,
        uint256 _deadline,
        uint256 _backerTokenAllocation
    ) external returns (address escrow) {
        require(_token != address(0), "Invalid token");
        require(_founder != address(0), "Invalid founder");
        require(escrowByToken[_token] == address(0), "Campaign exists for token");

        // Deploy escrow using minimal proxy (EIP-1167)
        escrow = Clones.clone(escrowImplementation);
        VibesCampaignEscrow newEscrow = VibesCampaignEscrow(payable(escrow));

        // Initialize the escrow
        newEscrow.initialize(
            registry,
            _token,
            _founder,
            VibesCampaignEscrow.FundingModel.FIXED_GOAL,
            _goalAmount,
            0, // no soft cap
            0, // no hard cap
            _deadline,
            protocolFeeBps,
            protocolFeeRecipient,
            _backerTokenAllocation
        );

        // Add default milestones: 50% upfront, 50% on completion
        newEscrow.addMilestone("Project Launch", 5000);
        newEscrow.addMilestone("Project Completion", 5000);

        // Track escrow
        escrows.push(escrow);
        escrowByToken[_token] = escrow;
        isEscrow[escrow] = true;

        emit CampaignCreated(
            escrow,
            _token,
            _founder,
            VibesCampaignEscrow.FundingModel.FIXED_GOAL,
            _goalAmount,
            _deadline
        );
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get total number of campaigns
     */
    function campaignCount() external view returns (uint256) {
        return escrows.length;
    }

    /**
     * @notice Get escrow for a token
     */
    function getEscrow(address _token) external view returns (address) {
        return escrowByToken[_token];
    }

    /**
     * @notice Get all escrows
     */
    function getAllEscrows() external view returns (address[] memory) {
        return escrows;
    }

    /**
     * @notice Get escrows in range (for pagination)
     */
    function getEscrows(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = escrows.length;
        if (offset >= total) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = escrows[i];
        }
        return result;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Update registry address
     * @param _registry New registry address
     */
    function setRegistry(address _registry) external onlyOwner {
        require(_registry != address(0), "Invalid registry");
        address oldRegistry = registry;
        registry = _registry;
        emit RegistryUpdated(oldRegistry, _registry);
    }

    /**
     * @notice Transfer ownership
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }

    /**
     * @notice Update protocol fee
     * @param _protocolFeeBps New fee in basis points
     */
    function setProtocolFee(uint256 _protocolFeeBps) external onlyOwner {
        require(_protocolFeeBps <= 1000, "Fee too high"); // Max 10%
        uint256 oldFee = protocolFeeBps;
        protocolFeeBps = _protocolFeeBps;
        emit ProtocolFeeUpdated(oldFee, _protocolFeeBps);
    }

    /**
     * @notice Update protocol fee recipient
     * @param _protocolFeeRecipient New recipient address
     */
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external onlyOwner {
        address oldRecipient = protocolFeeRecipient;
        protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(oldRecipient, _protocolFeeRecipient);
    }
}
