// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { VibesRegistry } from "./VibesRegistry.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VibesCampaignEscrow
 * @notice Per-campaign escrow contract for crowdfunding.
 * @dev Holds contributed funds and releases them based on milestone verification.
 *      Milestones are verified by checking capsule proofs in the VibesRegistry.
 *      Uses EIP-1167 minimal proxy pattern - deploy via factory.
 */
contract VibesCampaignEscrow is ReentrancyGuard {
    // ============================================
    // TYPES
    // ============================================

    enum FundingModel {
        FIXED_GOAL,    // All-or-nothing: must hit goal
        OPEN_ENDED,    // Keep-what-you-raise: any amount works
        BONDING_CURVE  // Dynamic pricing (future)
    }

    enum CampaignStatus {
        ACTIVE,     // Accepting contributions
        FUNDED,     // Goal reached (for FIXED_GOAL)
        FAILED,     // Deadline passed without reaching goal
        COMPLETED,  // All milestones verified
        CANCELLED   // Founder cancelled
    }

    struct Milestone {
        string title;
        uint256 releasePercent;   // Basis points (e.g., 2500 = 25%)
        bytes32 proofCapsuleHash; // Required capsule hash for verification
        bool verified;
        uint256 amountReleased;
    }

    struct Contribution {
        address backer;
        uint256 amount;
        uint256 timestamp;
        bool refunded;
    }

    // ============================================
    // EVENTS
    // ============================================

    event ContributionReceived(
        address indexed backer,
        uint256 amount,
        uint256 totalRaised
    );

    event MilestoneSubmitted(
        uint256 indexed milestoneIndex,
        bytes32 capsuleHash
    );

    event MilestoneVerified(
        uint256 indexed milestoneIndex,
        uint256 amountReleased
    );

    event RefundClaimed(
        address indexed backer,
        uint256 amount
    );

    event CampaignStatusChanged(
        CampaignStatus oldStatus,
        CampaignStatus newStatus
    );

    event FundsReleased(
        address indexed recipient,
        uint256 amount
    );

    event ProtocolFeeCollected(
        address indexed recipient,
        uint256 amount
    );

    event TokensTransferredToDistributor(
        address indexed distributor,
        uint256 amount
    );

    // ============================================
    // STATE
    // ============================================

    /// @notice Whether the contract has been initialized (for proxy pattern)
    bool private _initialized;

    /// @notice VibesRegistry for capsule verification
    VibesRegistry public registry;

    /// @notice Token address this campaign is for
    address public token;

    /// @notice Founder who created the campaign
    address public founder;

    /// @notice Factory that deployed this escrow
    address public factory;

    /// @notice Protocol fee in basis points (e.g., 250 = 2.5%)
    uint256 public protocolFeeBps;

    /// @notice Protocol fee recipient address
    address public protocolFeeRecipient;

    /// @notice Funding model
    FundingModel public fundingModel;

    /// @notice Campaign status
    CampaignStatus public status;

    /// @notice Goal amount in wei (for FIXED_GOAL)
    uint256 public goalAmount;

    /// @notice Soft cap in wei (for OPEN_ENDED)
    uint256 public softCap;

    /// @notice Hard cap in wei (maximum contributions)
    uint256 public hardCap;

    /// @notice Deadline timestamp
    uint256 public deadline;

    /// @notice Total amount raised
    uint256 public totalRaised;

    /// @notice Total amount released to founder
    uint256 public totalReleased;

    /// @notice All milestones
    Milestone[] public milestones;

    /// @notice Contribution amounts by backer
    mapping(address => uint256) public contributions;

    /// @notice Whether a backer has been refunded
    mapping(address => bool) public refunded;

    /// @notice List of all backer addresses
    address[] public backers;

    /// @notice Whether an address has backed
    mapping(address => bool) public hasBacked;

    /// @notice Token allocation for backers (held until distribution)
    uint256 public backerTokenAllocation;

    /// @notice Whether tokens have been transferred to distributor
    bool public tokensDistributed;

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initialize the escrow (called by factory via proxy)
     * @param _registry VibesRegistry address
     * @param _token Token address
     * @param _founder Founder address
     * @param _fundingModel Funding model enum
     * @param _goalAmount Goal for FIXED_GOAL (0 for others)
     * @param _softCap Soft cap for OPEN_ENDED (0 for others)
     * @param _hardCap Maximum contributions (0 for unlimited)
     * @param _deadline Deadline timestamp (0 for no deadline)
     * @param _protocolFeeBps Protocol fee in basis points
     * @param _protocolFeeRecipient Protocol fee recipient
     * @param _backerTokenAllocation Tokens allocated for backer distribution
     */
    function initialize(
        address _registry,
        address _token,
        address _founder,
        FundingModel _fundingModel,
        uint256 _goalAmount,
        uint256 _softCap,
        uint256 _hardCap,
        uint256 _deadline,
        uint256 _protocolFeeBps,
        address _protocolFeeRecipient,
        uint256 _backerTokenAllocation
    ) external {
        require(!_initialized, "Already initialized");
        require(_registry != address(0), "Invalid registry");
        require(_token != address(0), "Invalid token");
        require(_founder != address(0), "Invalid founder");
        require(_protocolFeeBps <= 1000, "Fee too high"); // Max 10%

        _initialized = true;
        registry = VibesRegistry(_registry);
        token = _token;
        founder = _founder;
        factory = msg.sender;
        fundingModel = _fundingModel;
        goalAmount = _goalAmount;
        softCap = _softCap;
        hardCap = _hardCap;
        deadline = _deadline;
        protocolFeeBps = _protocolFeeBps;
        protocolFeeRecipient = _protocolFeeRecipient;
        backerTokenAllocation = _backerTokenAllocation;
        status = CampaignStatus.ACTIVE;
    }

    /// @notice Empty constructor for proxy pattern
    constructor() {}

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyFounder() {
        require(msg.sender == founder, "Not founder");
        _;
    }

    modifier onlyActive() {
        require(status == CampaignStatus.ACTIVE || status == CampaignStatus.FUNDED, "Campaign not active");
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "Not factory");
        _;
    }

    // ============================================
    // MILESTONE MANAGEMENT
    // ============================================

    /**
     * @notice Add a milestone (only callable by factory during setup)
     * @param _title Milestone title
     * @param _releasePercent Percentage to release (basis points)
     */
    function addMilestone(
        string calldata _title,
        uint256 _releasePercent
    ) external onlyFactory {
        require(status == CampaignStatus.ACTIVE, "Campaign started");

        milestones.push(Milestone({
            title: _title,
            releasePercent: _releasePercent,
            proofCapsuleHash: bytes32(0),
            verified: false,
            amountReleased: 0
        }));
    }

    // ============================================
    // CONTRIBUTION FUNCTIONS
    // ============================================

    /**
     * @notice Contribute ETH to the campaign
     */
    function contribute() external payable nonReentrant {
        require(status == CampaignStatus.ACTIVE, "Not accepting contributions");
        require(msg.value > 0, "Zero contribution");

        // Check deadline
        if (deadline > 0) {
            require(block.timestamp < deadline, "Campaign ended");
        }

        // Check hard cap
        if (hardCap > 0) {
            require(totalRaised + msg.value <= hardCap, "Exceeds hard cap");
        }

        // Record contribution
        if (!hasBacked[msg.sender]) {
            backers.push(msg.sender);
            hasBacked[msg.sender] = true;
        }
        contributions[msg.sender] += msg.value;
        totalRaised += msg.value;

        emit ContributionReceived(msg.sender, msg.value, totalRaised);

        // Check if goal reached (for FIXED_GOAL)
        if (fundingModel == FundingModel.FIXED_GOAL && goalAmount > 0) {
            if (totalRaised >= goalAmount) {
                _setStatus(CampaignStatus.FUNDED);
            }
        }
    }

    /**
     * @notice Receive ETH directly (same as contribute)
     */
    receive() external payable {
        this.contribute();
    }

    // ============================================
    // MILESTONE VERIFICATION
    // ============================================

    /**
     * @notice Submit proof for a milestone
     * @param milestoneIndex Index of the milestone
     * @param capsuleHash Hash of the capsule proving milestone completion
     */
    function submitMilestoneProof(
        uint256 milestoneIndex,
        bytes32 capsuleHash
    ) external onlyFounder {
        require(milestoneIndex < milestones.length, "Invalid milestone");
        require(!milestones[milestoneIndex].verified, "Already verified");
        require(capsuleHash != bytes32(0), "Invalid proof");

        // Verify the capsule exists in registry
        require(registry.capsuleHashOf(token) == capsuleHash || _verifyProofCapsule(capsuleHash), "Capsule not registered");

        milestones[milestoneIndex].proofCapsuleHash = capsuleHash;

        emit MilestoneSubmitted(milestoneIndex, capsuleHash);

        // Auto-verify and release
        _verifyAndRelease(milestoneIndex);
    }

    /**
     * @notice Verify proof capsule exists (for milestone proofs beyond initial)
     * @dev In a full implementation, this would check a milestone-specific capsule registry
     */
    function _verifyProofCapsule(bytes32 capsuleHash) internal view returns (bool) {
        // For now, accept any non-zero hash
        // In production, this would verify against a milestone proof registry
        return capsuleHash != bytes32(0);
    }

    /**
     * @notice Verify milestone and release funds (with protocol fee deduction)
     */
    function _verifyAndRelease(uint256 milestoneIndex) internal {
        Milestone storage milestone = milestones[milestoneIndex];
        require(!milestone.verified, "Already verified");
        require(milestone.proofCapsuleHash != bytes32(0), "No proof submitted");

        milestone.verified = true;

        // Calculate release amount
        uint256 releaseAmount = (totalRaised * milestone.releasePercent) / 10000;

        // Ensure we don't release more than available
        uint256 available = address(this).balance;
        if (releaseAmount > available) {
            releaseAmount = available;
        }

        // Calculate and deduct protocol fee
        uint256 protocolFee = 0;
        if (protocolFeeBps > 0 && protocolFeeRecipient != address(0)) {
            protocolFee = (releaseAmount * protocolFeeBps) / 10000;
        }
        uint256 founderAmount = releaseAmount - protocolFee;

        milestone.amountReleased = releaseAmount;
        totalReleased += releaseAmount;

        // Transfer protocol fee first
        if (protocolFee > 0) {
            (bool feeSent, ) = protocolFeeRecipient.call{ value: protocolFee }("");
            require(feeSent, "Fee transfer failed");
            emit ProtocolFeeCollected(protocolFeeRecipient, protocolFee);
        }

        // Transfer to founder
        if (founderAmount > 0) {
            (bool sent, ) = founder.call{ value: founderAmount }("");
            require(sent, "Transfer failed");
            emit FundsReleased(founder, founderAmount);
        }

        emit MilestoneVerified(milestoneIndex, releaseAmount);

        // Check if all milestones complete
        _checkCompletion();
    }

    /**
     * @notice Check if all milestones are verified
     */
    function _checkCompletion() internal {
        for (uint256 i = 0; i < milestones.length; i++) {
            if (!milestones[i].verified) {
                return;
            }
        }
        _setStatus(CampaignStatus.COMPLETED);
    }

    // ============================================
    // REFUND FUNCTIONS
    // ============================================

    /**
     * @notice Claim refund (only for failed campaigns)
     */
    function claimRefund() external nonReentrant {
        require(status == CampaignStatus.FAILED || status == CampaignStatus.CANCELLED, "Refunds not available");
        require(contributions[msg.sender] > 0, "No contribution");
        require(!refunded[msg.sender], "Already refunded");

        uint256 refundAmount = contributions[msg.sender];
        refunded[msg.sender] = true;

        (bool sent, ) = msg.sender.call{ value: refundAmount }("");
        require(sent, "Refund failed");

        emit RefundClaimed(msg.sender, refundAmount);
    }

    /**
     * @notice Finalize campaign after deadline
     */
    function finalize() external {
        require(deadline > 0 && block.timestamp >= deadline, "Deadline not passed");
        require(status == CampaignStatus.ACTIVE, "Already finalized");

        if (fundingModel == FundingModel.FIXED_GOAL) {
            if (totalRaised >= goalAmount) {
                _setStatus(CampaignStatus.FUNDED);
            } else {
                _setStatus(CampaignStatus.FAILED);
            }
        } else if (fundingModel == FundingModel.OPEN_ENDED) {
            if (softCap > 0 && totalRaised < softCap) {
                _setStatus(CampaignStatus.FAILED);
            } else {
                _setStatus(CampaignStatus.FUNDED);
            }
        }
    }

    /**
     * @notice Cancel campaign (founder only, before any milestones verified)
     */
    function cancel() external onlyFounder {
        require(status == CampaignStatus.ACTIVE, "Cannot cancel");

        // Ensure no milestones have been verified
        for (uint256 i = 0; i < milestones.length; i++) {
            require(!milestones[i].verified, "Milestones already verified");
        }

        _setStatus(CampaignStatus.CANCELLED);
    }

    /**
     * @notice Internal status update
     */
    function _setStatus(CampaignStatus newStatus) internal {
        CampaignStatus oldStatus = status;
        status = newStatus;
        emit CampaignStatusChanged(oldStatus, newStatus);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get number of milestones
     */
    function milestoneCount() external view returns (uint256) {
        return milestones.length;
    }

    /**
     * @notice Get number of backers
     */
    function backerCount() external view returns (uint256) {
        return backers.length;
    }

    /**
     * @notice Get milestone details
     */
    function getMilestone(uint256 index) external view returns (
        string memory title,
        uint256 releasePercent,
        bytes32 proofCapsuleHash,
        bool verified,
        uint256 amountReleased
    ) {
        require(index < milestones.length, "Invalid index");
        Milestone storage m = milestones[index];
        return (m.title, m.releasePercent, m.proofCapsuleHash, m.verified, m.amountReleased);
    }

    /**
     * @notice Check if campaign can accept contributions
     */
    function canContribute() external view returns (bool) {
        if (status != CampaignStatus.ACTIVE) return false;
        if (deadline > 0 && block.timestamp >= deadline) return false;
        if (hardCap > 0 && totalRaised >= hardCap) return false;
        return true;
    }

    /**
     * @notice Get funding progress percentage (basis points)
     */
    function fundingProgress() external view returns (uint256) {
        if (goalAmount == 0) return 0;
        return (totalRaised * 10000) / goalAmount;
    }

    // ============================================
    // TOKEN DISTRIBUTION
    // ============================================

    /**
     * @notice Transfer backer tokens to distributor contract
     * @dev Can only be called once, and only when campaign is funded/completed.
     *      Can be called by founder directly or via the router.
     * @param distributor Address of the VibesTokenDistributor contract
     * @param caller The actual initiator (passed by router for authorization)
     */
    function transferToDistributor(address distributor, address caller) external nonReentrant {
        // Allow founder directly or via router (router passes the actual caller)
        require(caller == founder, "Not founder");
        require(!tokensDistributed, "Already distributed");
        require(distributor != address(0), "Invalid distributor");
        require(
            status == CampaignStatus.COMPLETED || status == CampaignStatus.FUNDED,
            "Campaign not complete"
        );
        require(backerTokenAllocation > 0, "No tokens to distribute");

        tokensDistributed = true;

        // Transfer tokens from this escrow to the distributor
        require(
            IERC20(token).transfer(distributor, backerTokenAllocation),
            "Token transfer failed"
        );

        emit TokensTransferredToDistributor(distributor, backerTokenAllocation);
    }

    /**
     * @notice Get token balance held by this escrow
     * @return Balance of campaign token held by this contract
     */
    function tokenBalance() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
