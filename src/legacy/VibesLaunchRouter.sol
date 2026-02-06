// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { VibesTokenFactory } from "./VibesTokenFactory.sol";
import { VibesRegistry } from "./VibesRegistry.sol";
import { VibesCampaignFactory } from "./VibesCampaignFactory.sol";
import { VibesCampaignEscrow } from "./VibesCampaignEscrow.sol";
import { VibesTokenDistributor } from "./VibesTokenDistributor.sol";
import { VibesVesting } from "./VibesVesting.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VibesLaunchRouter
 * @notice Main entrypoint for launching VibesCertified tokens.
 * @dev Deploys token via factory, registers provenance in registry,
 *      and emits the canonical VibesCertified event.
 *      Optionally creates a crowdfunding campaign for the token.
 */
contract VibesLaunchRouter {
    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Canonical event emitted for every VibesCertified launch
     * @param token The deployed token address
     * @param founder The founder who launched the token
     * @param capsuleHash Hash of the off-chain capsule JSON
     * @param agentTool AI tool used (enum value)
     * @param modelProvider AI model provider (enum value)
     * @param proofType Type of proof artifact (enum value)
     * @param artifactHash Hash of the proof artifact
     */
    event VibesCertified(
        address indexed token,
        address indexed founder,
        bytes32 capsuleHash,
        uint8 agentTool,
        uint8 modelProvider,
        uint8 proofType,
        bytes32 artifactHash
    );

    /**
     * @notice Emitted when a campaign is created alongside token launch
     * @param token The token address
     * @param escrow The campaign escrow address
     * @param founder The founder who created the campaign
     */
    event CampaignLaunched(
        address indexed token,
        address indexed escrow,
        address indexed founder
    );

    /**
     * @notice Emitted when a token distributor is created
     * @param token The token address
     * @param distributor The distributor contract address
     * @param founder The founder who created it
     */
    event DistributorCreated(
        address indexed token,
        address indexed distributor,
        address indexed founder
    );

    /**
     * @notice Emitted when a vesting contract is created for founder
     * @param token The token address
     * @param vesting The vesting contract address
     * @param founder The founder beneficiary
     * @param amount Amount of tokens vesting
     */
    event VestingCreated(
        address indexed token,
        address indexed vesting,
        address indexed founder,
        uint256 amount
    );

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Default backer allocation (50%)
    uint256 public constant DEFAULT_BACKER_ALLOCATION_BPS = 5000;

    /// @notice Default founder allocation (30%)
    uint256 public constant DEFAULT_FOUNDER_ALLOCATION_BPS = 3000;

    /// @notice Default liquidity allocation (20%)
    uint256 public constant DEFAULT_LIQUIDITY_ALLOCATION_BPS = 2000;

    /// @notice Default vesting duration (12 months)
    uint256 public constant DEFAULT_VESTING_DURATION = 365 days;

    // ============================================
    // STATE
    // ============================================

    /// @notice Token factory contract
    VibesTokenFactory public immutable factory;

    /// @notice Provenance registry contract
    VibesRegistry public immutable registry;

    /// @notice Campaign factory contract (optional, can be zero)
    VibesCampaignFactory public campaignFactory;

    /// @notice Owner address for admin functions
    address public owner;

    /// @notice Whether fees are enabled
    bool public feesEnabled;

    /// @notice Flat fee in wei (if fees enabled)
    uint256 public flatFeeWei;

    /// @notice Address to receive fees
    address public feeRecipient;

    /// @notice Liquidity tokens held per token address (for future LP pairing)
    mapping(address => uint256) public liquidityTokens;

    /// @notice Vesting contract per token address
    mapping(address => address) public vestingByToken;

    // ============================================
    // CONSTRUCTOR
    // ============================================
    
    /**
     * @param _factory Address of the VibesTokenFactory
     * @param _registry Address of the VibesRegistry
     */
    constructor(address _factory, address _registry) {
        require(_factory != address(0), "Invalid factory");
        require(_registry != address(0), "Invalid registry");
        
        factory = VibesTokenFactory(_factory);
        registry = VibesRegistry(_registry);
        owner = msg.sender;
        
        // Fees disabled by default
        feesEnabled = false;
        flatFeeWei = 0;
        feeRecipient = msg.sender;
    }

    // ============================================
    // MODIFIERS
    // ============================================
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ============================================
    // LAUNCH FUNCTION
    // ============================================
    
    /**
     * @notice Launch a VibesCertified token
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals Token decimals (typically 18)
     * @param totalSupply Total supply to mint
     * @param recipient Address to receive tokens (use address(0) for msg.sender)
     * @param capsuleHash Hash of the off-chain capsule JSON
     * @param agentTool AI tool enum value
     * @param modelProvider AI provider enum value
     * @param proofType Proof type enum value
     * @param proofArtifactHash Hash of the proof artifact
     * @return token Address of the deployed token
     */
    function launch(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 totalSupply,
        address recipient,
        bytes32 capsuleHash,
        uint8 agentTool,
        uint8 modelProvider,
        uint8 proofType,
        bytes32 proofArtifactHash
    ) external payable returns (address token) {
        // Handle fees if enabled
        if (feesEnabled) {
            require(msg.value >= flatFeeWei, "Insufficient fee");
            if (flatFeeWei > 0) {
                (bool sent, ) = feeRecipient.call{ value: flatFeeWei }("");
                require(sent, "Fee transfer failed");
            }
            // Refund excess
            if (msg.value > flatFeeWei) {
                (bool refunded, ) = msg.sender.call{ value: msg.value - flatFeeWei }("");
                require(refunded, "Refund failed");
            }
        }
        
        // Validate required fields
        require(capsuleHash != bytes32(0), "Capsule hash required");
        require(proofArtifactHash != bytes32(0), "Proof hash required");
        
        // Use msg.sender if recipient is zero address
        address tokenRecipient = recipient == address(0) ? msg.sender : recipient;
        
        // Deploy token
        token = factory.deployToken(name, symbol, decimals, totalSupply, tokenRecipient);
        
        // Build attestation struct
        VibesRegistry.Attestation memory attestation = VibesRegistry.Attestation({
            version: 1,
            agentTool: agentTool,
            modelProvider: modelProvider,
            proofType: proofType,
            proofArtifactHash: proofArtifactHash
        });
        
        // Register provenance with founder as original caller
        registry.registerFromRouter(token, msg.sender, capsuleHash, attestation);
        
        // Emit canonical event
        emit VibesCertified(
            token,
            msg.sender,
            capsuleHash,
            agentTool,
            modelProvider,
            proofType,
            proofArtifactHash
        );
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================
    
    /**
     * @notice Transfer ownership
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }
    
    /**
     * @notice Configure fee settings
     * @param _enabled Whether fees are enabled
     * @param _flatFeeWei Fee amount in wei
     * @param _recipient Address to receive fees
     */
    function setFeeConfig(
        bool _enabled,
        uint256 _flatFeeWei,
        address _recipient
    ) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient");
        feesEnabled = _enabled;
        flatFeeWei = _flatFeeWei;
        feeRecipient = _recipient;
    }

    /**
     * @notice Set the campaign factory address
     * @param _campaignFactory Address of the VibesCampaignFactory
     */
    function setCampaignFactory(address _campaignFactory) external onlyOwner {
        campaignFactory = VibesCampaignFactory(_campaignFactory);
    }

    // ============================================
    // LAUNCH WITH CAMPAIGN
    // ============================================

    /**
     * @notice Launch a VibesCertified token with a crowdfunding campaign
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals Token decimals
     * @param totalSupply Total supply to mint
     * @param capsuleHash Hash of the off-chain capsule JSON
     * @param agentTool AI tool enum value
     * @param modelProvider AI provider enum value
     * @param proofType Proof type enum value
     * @param proofArtifactHash Hash of the proof artifact
     * @param fundingModel Funding model (0=FIXED_GOAL, 1=OPEN_ENDED, 2=BONDING_CURVE)
     * @param goalAmount Goal amount in wei
     * @param deadline Campaign deadline timestamp
     * @param milestoneTitles Array of milestone titles
     * @param milestonePercents Array of milestone release percentages (basis points)
     * @param backerAllocationBps Backer allocation in basis points (0 for default 50%)
     * @param founderAllocationBps Founder allocation in basis points (0 for default 30%)
     * @param liquidityAllocationBps Liquidity allocation in basis points (0 for default 20%)
     * @return token Address of the deployed token
     * @return escrow Address of the campaign escrow
     * @return vesting Address of the founder vesting contract (address(0) if no founder allocation)
     */
    function launchWithCampaign(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 totalSupply,
        bytes32 capsuleHash,
        uint8 agentTool,
        uint8 modelProvider,
        uint8 proofType,
        bytes32 proofArtifactHash,
        uint8 fundingModel,
        uint256 goalAmount,
        uint256 deadline,
        string[] calldata milestoneTitles,
        uint256[] calldata milestonePercents,
        uint256 backerAllocationBps,
        uint256 founderAllocationBps,
        uint256 liquidityAllocationBps
    ) external payable returns (address token, address escrow, address vesting) {
        require(address(campaignFactory) != address(0), "Campaign factory not set");

        // Handle fees if enabled
        if (feesEnabled) {
            require(msg.value >= flatFeeWei, "Insufficient fee");
            if (flatFeeWei > 0) {
                (bool sent, ) = feeRecipient.call{ value: flatFeeWei }("");
                require(sent, "Fee transfer failed");
            }
            // Refund excess
            if (msg.value > flatFeeWei) {
                (bool refunded, ) = msg.sender.call{ value: msg.value - flatFeeWei }("");
                require(refunded, "Refund failed");
            }
        }

        // Validate required fields
        require(capsuleHash != bytes32(0), "Capsule hash required");
        require(proofArtifactHash != bytes32(0), "Proof hash required");

        // Use defaults if all allocations are zero
        if (backerAllocationBps == 0 && founderAllocationBps == 0 && liquidityAllocationBps == 0) {
            backerAllocationBps = DEFAULT_BACKER_ALLOCATION_BPS;
            founderAllocationBps = DEFAULT_FOUNDER_ALLOCATION_BPS;
            liquidityAllocationBps = DEFAULT_LIQUIDITY_ALLOCATION_BPS;
        }
        require(
            backerAllocationBps + founderAllocationBps + liquidityAllocationBps == 10000,
            "Allocations must sum to 100%"
        );

        // Deploy token - ALL tokens go to this contract initially
        token = factory.deployToken(name, symbol, decimals, totalSupply, address(this));

        // Calculate token allocations
        uint256 backerTokens = (totalSupply * backerAllocationBps) / 10000;
        uint256 founderTokens = (totalSupply * founderAllocationBps) / 10000;
        uint256 liquidityTokenAmount = totalSupply - backerTokens - founderTokens;

        // Build attestation struct
        VibesRegistry.Attestation memory attestation = VibesRegistry.Attestation({
            version: 1,
            agentTool: agentTool,
            modelProvider: modelProvider,
            proofType: proofType,
            proofArtifactHash: proofArtifactHash
        });

        // Register provenance with founder as original caller
        registry.registerFromRouter(token, msg.sender, capsuleHash, attestation);

        // Create campaign escrow with backer token allocation
        escrow = campaignFactory.createCampaign(
            token,
            msg.sender, // Pass actual founder, not router
            VibesCampaignEscrow.FundingModel(fundingModel),
            goalAmount,
            0, // softCap
            0, // hardCap
            deadline,
            milestoneTitles,
            milestonePercents,
            backerTokens
        );

        // Transfer backer tokens to escrow
        require(
            IERC20(token).transfer(escrow, backerTokens),
            "Backer token transfer failed"
        );

        // Create vesting contract for founder (if they get tokens)
        if (founderTokens > 0) {
            VibesVesting newVesting = new VibesVesting(
                token,
                msg.sender,
                DEFAULT_VESTING_DURATION
            );
            vesting = address(newVesting);
            vestingByToken[token] = vesting;

            // Transfer founder tokens to vesting
            require(
                IERC20(token).transfer(vesting, founderTokens),
                "Founder token transfer failed"
            );

            // Initialize vesting amount
            newVesting.initializeAmount();

            emit VestingCreated(token, vesting, msg.sender, founderTokens);
        }

        // Track liquidity tokens (stay in router for future LP pairing)
        if (liquidityTokenAmount > 0) {
            liquidityTokens[token] = liquidityTokenAmount;
        }

        // Emit canonical event
        emit VibesCertified(
            token,
            msg.sender,
            capsuleHash,
            agentTool,
            modelProvider,
            proofType,
            proofArtifactHash
        );

        emit CampaignLaunched(token, escrow, msg.sender);
    }

    // ============================================
    // TOKEN DISTRIBUTION
    // ============================================

    /**
     * @notice Create a token distributor for a campaign
     * @dev Founder calls this after campaign completes to set up token claims.
     *      Tokens are transferred from the escrow (which holds backer allocation).
     * @param token Token address
     * @param escrow Campaign escrow address
     * @return distributor Address of the deployed distributor
     */
    function createDistributor(
        address token,
        address escrow
    ) external returns (address distributor) {
        require(token != address(0), "Invalid token");
        require(escrow != address(0), "Invalid escrow");

        // Verify caller is the founder of this escrow
        VibesCampaignEscrow campaignEscrow = VibesCampaignEscrow(payable(escrow));
        require(campaignEscrow.founder() == msg.sender, "Not founder");
        require(campaignEscrow.token() == token, "Token mismatch");
        require(campaignEscrow.backerTokenAllocation() > 0, "No tokens to distribute");

        // Deploy distributor
        VibesTokenDistributor newDistributor = new VibesTokenDistributor(
            token,
            msg.sender,
            escrow
        );
        distributor = address(newDistributor);

        // Transfer tokens from escrow to distributor (escrow holds backer allocation)
        campaignEscrow.transferToDistributor(distributor, msg.sender);

        emit DistributorCreated(token, distributor, msg.sender);
    }

    // ============================================
    // LIQUIDITY MANAGEMENT
    // ============================================

    /**
     * @notice Withdraw liquidity tokens for LP pairing
     * @dev Only owner can withdraw for now. Phase 2 will add automated LP.
     * @param token Token address
     * @param recipient Address to receive tokens
     * @param amount Amount to withdraw (0 for all)
     */
    function withdrawLiquidityTokens(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        uint256 available = liquidityTokens[token];
        require(available > 0, "No liquidity tokens");

        if (amount == 0 || amount > available) {
            amount = available;
        }

        liquidityTokens[token] -= amount;

        require(
            IERC20(token).transfer(recipient, amount),
            "Transfer failed"
        );
    }

    /**
     * @notice Get liquidity token balance for a token
     * @param token Token address
     * @return Balance of liquidity tokens held
     */
    function getLiquidityTokens(address token) external view returns (uint256) {
        return liquidityTokens[token];
    }
}
