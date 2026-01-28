// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VibesTokenFactory} from "./VibesTokenFactory.sol";
import {VibesRegistry} from "./VibesRegistry.sol";
import {VibesTranchEscrowFactory} from "./VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "./VibesTranchEscrow.sol";
import {VibesLPLocker} from "./VibesLPLocker.sol";
import {VibesTokenDistributor} from "./VibesTokenDistributor.sol";
import {VibesVesting} from "./VibesVesting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VibesLaunchRouterV2
 * @notice Main entrypoint for launching VibesCertified tokens with tranche-based escrow and LP locking
 * @dev V2 Features:
 *      - Time-based tranche releases (10% kickstart + 15% × 6 months)
 *      - Three raise types: Fixed Goal, Open-Ended, Pro-Rata
 *      - Automatic LP creation and permanent locking via Aerodrome
 *      - Dynamic token allocation: Backers 80% * (1-founderAlloc), LP 20% * (1-founderAlloc), Founder 0-10%
 *      - LP price matches raise price
 */
contract VibesLaunchRouterV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // EVENTS
    // ============================================

    event VibesCertified(
        address indexed token,
        address indexed founder,
        bytes32 capsuleHash,
        uint8 agentTool,
        uint8 modelProvider,
        uint8 proofType,
        bytes32 artifactHash
    );

    event CampaignLaunched(
        address indexed token,
        address indexed escrow,
        address indexed founder,
        VibesTranchEscrow.RaiseType raiseType,
        uint256 goal,
        uint256 deadline
    );

    event LPCreated(
        address indexed token,
        address indexed pool,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 lpLocked
    );

    event DistributorCreated(
        address indexed token,
        address indexed distributor,
        address indexed founder
    );

    event VestingCreated(
        address indexed token,
        address indexed vesting,
        address indexed founder,
        uint256 amount
    );

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Maximum founder allocation (10%)
    uint256 public constant MAX_FOUNDER_ALLOCATION_BPS = 1000;

    /// @notice LP allocation ratio (20% of remaining after founder)
    uint256 public constant LP_ALLOCATION_RATIO = 2000; // 20% in BPS

    /// @notice ETH to LP ratio (20% of raised ETH)
    uint256 public constant ETH_TO_LP_BPS = 2000; // 20%

    /// @notice Default vesting duration (12 months)
    uint256 public constant DEFAULT_VESTING_DURATION = 365 days;

    /// @notice BPS denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============================================
    // STATE
    // ============================================

    /// @notice Token factory contract
    VibesTokenFactory public immutable tokenFactory;

    /// @notice Provenance registry contract
    VibesRegistry public immutable registry;

    /// @notice Tranche escrow factory contract
    VibesTranchEscrowFactory public escrowFactory;

    /// @notice LP locker contract
    VibesLPLocker public lpLocker;

    /// @notice Owner address for admin functions
    address public owner;

    /// @notice Fee settings
    bool public feesEnabled;
    uint256 public flatFeeWei;
    address public feeRecipient;

    /// @notice Token to escrow mapping
    mapping(address => address) public tokenToEscrow;

    /// @notice Token to vesting mapping
    mapping(address => address) public tokenToVesting;

    /// @notice Token to distributor mapping
    mapping(address => address) public tokenToDistributor;

    /// @notice Pending LP data (tokens held until campaign succeeds)
    struct PendingLP {
        uint256 tokenAmount;
        uint256 backerAllocation; // To calculate ETH for LP
    }
    mapping(address => PendingLP) public pendingLP;

    // ============================================
    // ERRORS
    // ============================================

    error OnlyOwner();
    error ZeroAddress();
    error InvalidAllocation();
    error CampaignNotFunded();
    error LPAlreadyCreated();
    error NoPendingLP();
    error EscrowFactoryNotSet();
    error LPLockerNotSet();

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(
        address _tokenFactory,
        address _registry,
        address _escrowFactory,
        address payable _lpLocker
    ) {
        if (_tokenFactory == address(0)) revert ZeroAddress();
        if (_registry == address(0)) revert ZeroAddress();

        tokenFactory = VibesTokenFactory(_tokenFactory);
        registry = VibesRegistry(_registry);

        if (_escrowFactory != address(0)) {
            escrowFactory = VibesTranchEscrowFactory(_escrowFactory);
        }
        if (_lpLocker != address(0)) {
            lpLocker = VibesLPLocker(_lpLocker);
        }

        owner = msg.sender;
        feeRecipient = msg.sender;
    }

    // ============================================
    // LAUNCH FUNCTIONS
    // ============================================

    /**
     * @notice Launch a VibesCertified token (simple, no campaign)
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
        _handleFees();

        if (capsuleHash == bytes32(0)) revert ZeroAddress();
        if (proofArtifactHash == bytes32(0)) revert ZeroAddress();

        address tokenRecipient = recipient == address(0) ? msg.sender : recipient;

        token = tokenFactory.deployToken(name, symbol, decimals, totalSupply, tokenRecipient);

        _registerProvenance(token, capsuleHash, agentTool, modelProvider, proofType, proofArtifactHash);
    }

    /**
     * @notice Launch a VibesCertified token with a tranche-based campaign
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals Token decimals
     * @param totalSupply Total supply to mint
     * @param capsuleHash Hash of the off-chain capsule JSON
     * @param agentTool AI tool enum value
     * @param modelProvider AI provider enum value
     * @param proofType Proof type enum value
     * @param proofArtifactHash Hash of the proof artifact
     * @param raiseType Raise type (0=FixedGoal, 1=OpenEnded, 2=ProRata)
     * @param goal Goal amount (required for FixedGoal, hard cap for ProRata)
     * @param softCap Soft cap (optional, only for OpenEnded)
     * @param deadline Campaign deadline timestamp
     * @param founderAllocationBps Founder allocation 0-1000 (0-10%)
     * @return token Address of the deployed token
     * @return escrow Address of the campaign escrow
     * @return vesting Address of the founder vesting contract
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
        VibesTranchEscrow.RaiseType raiseType,
        uint256 goal,
        uint256 softCap,
        uint256 deadline,
        uint256 founderAllocationBps
    ) external payable nonReentrant returns (address token, address escrow, address vesting) {
        if (address(escrowFactory) == address(0)) revert EscrowFactoryNotSet();
        if (founderAllocationBps > MAX_FOUNDER_ALLOCATION_BPS) revert InvalidAllocation();

        _handleFees();

        if (capsuleHash == bytes32(0)) revert ZeroAddress();
        if (proofArtifactHash == bytes32(0)) revert ZeroAddress();

        // Calculate token allocations
        // Remaining after founder = 100% - founderAlloc
        // Of remaining: 80% to backers, 20% to LP
        uint256 remainingBps = BPS_DENOMINATOR - founderAllocationBps;
        uint256 backerAllocationBps = (remainingBps * 8000) / BPS_DENOMINATOR;
        uint256 lpAllocationBps = remainingBps - backerAllocationBps;

        uint256 founderTokens = (totalSupply * founderAllocationBps) / BPS_DENOMINATOR;
        uint256 backerTokens = (totalSupply * backerAllocationBps) / BPS_DENOMINATOR;
        uint256 lpTokens = totalSupply - founderTokens - backerTokens;

        // Deploy token - all tokens go to this router initially
        token = tokenFactory.deployToken(name, symbol, decimals, totalSupply, address(this));

        // Register provenance
        _registerProvenance(token, capsuleHash, agentTool, modelProvider, proofType, proofArtifactHash);

        // Create escrow
        escrow = escrowFactory.createEscrow(
            msg.sender,
            token,
            raiseType,
            goal,
            softCap,
            deadline
        );

        tokenToEscrow[token] = escrow;

        // Store pending LP info (LP created after campaign succeeds)
        pendingLP[token] = PendingLP({
            tokenAmount: lpTokens,
            backerAllocation: backerTokens
        });

        // Create vesting for founder if allocation > 0
        if (founderTokens > 0) {
            VibesVesting newVesting = new VibesVesting(
                token,
                msg.sender,
                DEFAULT_VESTING_DURATION
            );
            vesting = address(newVesting);
            tokenToVesting[token] = vesting;

            IERC20(token).safeTransfer(vesting, founderTokens);
            newVesting.initializeAmount();

            emit VestingCreated(token, vesting, msg.sender, founderTokens);
        }

        // Note: Backer tokens and LP tokens stay in router until campaign succeeds
        // They are distributed/locked via finalizeSuccessfulCampaign()

        emit CampaignLaunched(token, escrow, msg.sender, raiseType, goal, deadline);
    }

    /**
     * @notice Finalize a successful campaign - creates LP and enables token distribution
     * @dev Called after campaign is finalized as Funded. Creates LP, locks it, and prepares distributor.
     * @param token Token address
     */
    function finalizeSuccessfulCampaign(address token) external payable nonReentrant {
        if (address(lpLocker) == address(0)) revert LPLockerNotSet();

        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) revert ZeroAddress();

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();

        // Verify campaign is funded
        if (campaign.state != VibesTranchEscrow.CampaignState.Funded) {
            revert CampaignNotFunded();
        }

        PendingLP memory lpData = pendingLP[token];
        if (lpData.tokenAmount == 0) revert NoPendingLP();

        // Calculate ETH for LP (20% of total raised)
        uint256 totalRaised = campaign.totalRaised;
        uint256 ethForLP = (totalRaised * ETH_TO_LP_BPS) / BPS_DENOMINATOR;

        // Withdraw ETH from escrow for LP
        // Note: The escrow holds all raised ETH. We need to transfer some to LP.
        // This requires the escrow to have a function for this, OR we call this
        // before any tranches are claimed, using ETH sent to this function.

        // For now, require ETH to be sent with this call for LP creation
        // (In production, you might want escrow to send ETH directly to LP locker)
        require(msg.value >= ethForLP, "Insufficient ETH for LP");

        // Approve LP locker to take tokens
        IERC20(token).approve(address(lpLocker), lpData.tokenAmount);

        // Create and lock LP
        (address pool, uint256 lpAmount) = lpLocker.createAndLockLP{value: ethForLP}(
            token,
            lpData.tokenAmount,
            escrowAddr
        );

        // Clear pending LP
        delete pendingLP[token];

        // Refund excess ETH
        if (msg.value > ethForLP) {
            (bool sent, ) = msg.sender.call{value: msg.value - ethForLP}("");
            require(sent, "ETH refund failed");
        }

        emit LPCreated(token, pool, lpData.tokenAmount, ethForLP, lpAmount);
    }

    /**
     * @notice Create a token distributor for a successful campaign
     * @param token Token address
     * @return distributor Address of the deployed distributor
     */
    function createDistributor(address token) external nonReentrant returns (address distributor) {
        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) revert ZeroAddress();

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();

        // Verify caller is founder
        if (campaign.founder != msg.sender) revert OnlyOwner();

        // Verify campaign is funded
        if (campaign.state != VibesTranchEscrow.CampaignState.Funded) {
            revert CampaignNotFunded();
        }

        // Calculate backer tokens (total supply - founder - LP)
        uint256 totalSupply = IERC20(token).totalSupply();
        PendingLP memory lpData = pendingLP[token];

        // If LP already created, lpData.tokenAmount will be 0
        // We need to track backer allocation differently
        // For now, get balance held by router
        uint256 routerBalance = IERC20(token).balanceOf(address(this));

        // Deploy distributor
        VibesTokenDistributor newDistributor = new VibesTokenDistributor(
            token,
            msg.sender,
            escrowAddr
        );
        distributor = address(newDistributor);
        tokenToDistributor[token] = distributor;

        // Transfer backer tokens to distributor
        // Subtract LP tokens if not yet used
        uint256 backerTokens = routerBalance - lpData.tokenAmount;
        if (backerTokens > 0) {
            IERC20(token).safeTransfer(distributor, backerTokens);
        }

        emit DistributorCreated(token, distributor, msg.sender);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _handleFees() internal {
        if (feesEnabled) {
            require(msg.value >= flatFeeWei, "Insufficient fee");
            if (flatFeeWei > 0) {
                (bool sent, ) = feeRecipient.call{value: flatFeeWei}("");
                require(sent, "Fee transfer failed");
            }
            if (msg.value > flatFeeWei) {
                (bool refunded, ) = msg.sender.call{value: msg.value - flatFeeWei}("");
                require(refunded, "Refund failed");
            }
        }
    }

    function _registerProvenance(
        address token,
        bytes32 capsuleHash,
        uint8 agentTool,
        uint8 modelProvider,
        uint8 proofType,
        bytes32 proofArtifactHash
    ) internal {
        VibesRegistry.Attestation memory attestation = VibesRegistry.Attestation({
            version: 1,
            agentTool: agentTool,
            modelProvider: modelProvider,
            proofType: proofType,
            proofArtifactHash: proofArtifactHash
        });

        registry.registerFromRouter(token, msg.sender, capsuleHash, attestation);

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

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setFeeConfig(
        bool _enabled,
        uint256 _flatFeeWei,
        address _recipient
    ) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        feesEnabled = _enabled;
        flatFeeWei = _flatFeeWei;
        feeRecipient = _recipient;
    }

    function setEscrowFactory(address _escrowFactory) external onlyOwner {
        if (_escrowFactory == address(0)) revert ZeroAddress();
        escrowFactory = VibesTranchEscrowFactory(_escrowFactory);
    }

    function setLPLocker(address payable _lpLocker) external onlyOwner {
        if (_lpLocker == address(0)) revert ZeroAddress();
        lpLocker = VibesLPLocker(_lpLocker);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    function getTokenInfo(address token) external view returns (
        address escrow,
        address vesting,
        address distributor,
        uint256 pendingLPTokens
    ) {
        escrow = tokenToEscrow[token];
        vesting = tokenToVesting[token];
        distributor = tokenToDistributor[token];
        pendingLPTokens = pendingLP[token].tokenAmount;
    }

    // ============================================
    // RECEIVE
    // ============================================

    receive() external payable {}
}
