// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VibesTokenFactory} from "./VibesTokenFactory.sol";
import {VibesRegistry} from "./VibesRegistry.sol";
import {VibesTranchEscrowFactory} from "./VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "./VibesTranchEscrow.sol";
import {VibesLPLocker} from "./VibesLPLocker.sol";
import {VibesTokenDistributorV2} from "./VibesTokenDistributorV2.sol";
import {VibesVesting} from "./VibesVesting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

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
contract VibesLaunchRouterV2 is ReentrancyGuard, Pausable {
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

    event DepositCollected(
        address indexed founder,
        address indexed token,
        uint256 amount
    );

    event DepositRefunded(
        address indexed founder,
        address indexed token,
        uint256 amount
    );

    event DepositForfeited(
        address indexed founder,
        address indexed token,
        uint256 amount
    );

    event TokensClaimed(
        address indexed token,
        address indexed backer,
        uint256 amount
    );

    event StakerRewardsAllocated(
        address indexed token,
        address indexed rewardsContract,
        uint256 amount
    );

    event StakerTokensRedirectedToBackers(
        address indexed token,
        uint256 amount
    );

    event DepositReadyForClaim(
        address indexed founder,
        address indexed token,
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

    /// @notice Ops wallet for unclaimed fund sweeps
    address public opsWallet;

    /// @notice Staker rewards contract for $VIBES staker distributions
    address public stakerRewardsContract;

    /// @notice Token to escrow mapping
    mapping(address => address) public tokenToEscrow;

    /// @notice Token to vesting mapping
    mapping(address => address) public tokenToVesting;

    /// @notice Token to distributor mapping
    mapping(address => address) public tokenToDistributor;

    /// @notice Founder deposit amount (anti-spam)
    uint256 public founderDepositWei = 0.05 ether;

    /// @notice Token to deposit mapping (tracks deposit amounts per token)
    mapping(address => uint256) public tokenDeposits;

    /// @notice Pending LP data (tokens held until campaign succeeds)
    struct PendingLP {
        uint256 tokenAmount;
        uint256 backerAllocation; // To calculate ETH for LP
        uint256 stakerAllocation; // 2% for $VIBES stakers
    }
    mapping(address => PendingLP) public pendingLP;

    /// @notice Backer tokens available for claims per token
    mapping(address => uint256) public backerTokensForClaims;

    /// @notice Track whether a backer has claimed tokens for a specific campaign
    mapping(address => mapping(address => bool)) public hasClaimedTokens; // token => backer => claimed

    /// @notice Claimable deposit refunds for founders (pull-based pattern)
    mapping(address => uint256) public claimableDeposits; // founder => amount

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
    error OpsWalletNotSet();
    error LPNotCreated();
    error InsufficientDeposit();
    error NoDepositToRefund();
    error DepositAlreadyProcessed();
    error RefundFailed();
    error OnlyEscrow();
    error AlreadyClaimed();
    error NotABacker();
    error NothingToClaim();
    error CampaignNotReady();
    error NoClaimableDeposit();
    error TooManyTokens();

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
     * @param raiseStart When contributions begin (0 = immediate)
     * @param founderVestingCliff Cliff period for founder vesting in seconds (0 = no cliff)
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
        uint256 founderAllocationBps,
        uint256 raiseStart,
        uint256 founderVestingCliff
    ) external payable nonReentrant whenNotPaused returns (address token, address escrow, address vesting) {
        if (address(escrowFactory) == address(0)) revert EscrowFactoryNotSet();
        if (founderAllocationBps > MAX_FOUNDER_ALLOCATION_BPS) revert InvalidAllocation();

        // Collect deposit + fees
        _handleFeesAndDeposit();

        if (capsuleHash == bytes32(0)) revert ZeroAddress();
        if (proofArtifactHash == bytes32(0)) revert ZeroAddress();

        // Calculate token allocations
        // Remaining after founder = 100% - founderAlloc
        // Of remaining: ~77.78% to backers, ~20% to LP, ~2.22% to stakers
        // This achieves 70/18/2 split at 10% founder allocation
        uint256 remainingBps = BPS_DENOMINATOR - founderAllocationBps;
        uint256 backerAllocationBps = (remainingBps * 7778) / BPS_DENOMINATOR;
        uint256 stakerAllocationBps = (remainingBps * 222) / BPS_DENOMINATOR;
        uint256 lpAllocationBps = remainingBps - backerAllocationBps - stakerAllocationBps;

        uint256 founderTokens = (totalSupply * founderAllocationBps) / BPS_DENOMINATOR;
        uint256 backerTokens = (totalSupply * backerAllocationBps) / BPS_DENOMINATOR;
        uint256 stakerTokens = (totalSupply * stakerAllocationBps) / BPS_DENOMINATOR;
        uint256 lpTokens = totalSupply - founderTokens - backerTokens - stakerTokens;

        // Deploy token - all tokens go to this router initially
        token = tokenFactory.deployToken(name, symbol, decimals, totalSupply, address(this));

        // Track deposit for this token
        if (founderDepositWei > 0) {
            tokenDeposits[token] = founderDepositWei;
            emit DepositCollected(msg.sender, token, founderDepositWei);
        }

        // Register provenance
        _registerProvenance(token, capsuleHash, agentTool, modelProvider, proofType, proofArtifactHash);

        // Create escrow
        escrow = escrowFactory.createEscrow(
            msg.sender,
            token,
            raiseType,
            goal,
            softCap,
            deadline,
            raiseStart
        );

        tokenToEscrow[token] = escrow;

        // Store pending LP info (LP created after campaign succeeds)
        pendingLP[token] = PendingLP({
            tokenAmount: lpTokens,
            backerAllocation: backerTokens,
            stakerAllocation: stakerTokens
        });

        // Create vesting for founder if allocation > 0
        if (founderTokens > 0) {
            VibesVesting newVesting = new VibesVesting(
                token,
                msg.sender,
                DEFAULT_VESTING_DURATION,
                founderVestingCliff
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
     * @dev Called after campaign is finalized as Funded. Withdraws ETH from escrow, creates LP, locks it.
     * @param token Token address
     */
    function finalizeSuccessfulCampaign(address token) external nonReentrant {
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

        // LP ETH was already sent to this router by escrow during finalize()
        uint256 ethForLP = escrow.getLPEthSent();

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

        // Start founder vesting now that campaign is funded
        address vestingAddr = tokenToVesting[token];
        if (vestingAddr != address(0)) {
            VibesVesting(vestingAddr).startVesting();
        }

        // Make founder deposit claimable (pull-based)
        uint256 depositAmount = tokenDeposits[token];
        if (depositAmount > 0) {
            delete tokenDeposits[token];
            claimableDeposits[campaign.founder] += depositAmount;
            emit DepositReadyForClaim(campaign.founder, token, depositAmount);
        }

        emit LPCreated(token, pool, lpData.tokenAmount, ethForLP, lpAmount);
    }

    /**
     * @notice Create a token distributor for a successful campaign (permissionless)
     * @dev Anyone can call this after LP has been created. Enables backers to claim tokens
     *      even if founder is unresponsive.
     * @param token Token address
     * @return distributor Address of the deployed distributor
     */
    function createDistributor(address token) external nonReentrant returns (address distributor) {
        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) revert ZeroAddress();

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();

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

        // Ensure LP has been created first (enforces proper ordering)
        if (lpData.tokenAmount > 0) revert LPNotCreated();
        if (opsWallet == address(0)) revert OpsWalletNotSet();

        // Deploy distributor with ops wallet for sweep functionality
        VibesTokenDistributorV2 newDistributor = new VibesTokenDistributorV2(
            token,
            campaign.founder,
            escrowAddr,
            opsWallet,
            owner
        );
        distributor = address(newDistributor);
        tokenToDistributor[token] = distributor;

        // Transfer backer tokens to distributor
        uint256 backerTokens = routerBalance;
        if (backerTokens > 0) {
            IERC20(token).safeTransfer(distributor, backerTokens);
        }

        emit DistributorCreated(token, distributor, campaign.founder);
    }

    /**
     * @notice Complete finalization of a successful campaign - creates LP and distributor atomically
     * @dev Called by escrow during finalize(). Creates LP, locks it, and sets up token distribution.
     *      This allows the entire finalization to happen in one transaction when the raise ends.
     * @param token Token address
     */
    function completeFinalization(address token) external nonReentrant whenNotPaused {
        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) revert ZeroAddress();

        // Only the escrow can call this
        if (msg.sender != escrowAddr) revert OnlyEscrow();

        if (address(lpLocker) == address(0)) revert LPLockerNotSet();

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();

        // Campaign should be in Funded state (set by escrow before calling this)
        if (campaign.state != VibesTranchEscrow.CampaignState.Funded) {
            revert CampaignNotFunded();
        }

        PendingLP memory lpData = pendingLP[token];
        if (lpData.tokenAmount == 0) revert NoPendingLP();
        if (opsWallet == address(0)) revert OpsWalletNotSet();

        // === Step 1: Create and lock LP ===
        // LP ETH was already sent to this router by escrow during finalize()
        // No callback into escrow needed - eliminating cross-contract re-entry

        uint256 ethForLP = escrow.getLPEthSent();

        // Approve LP locker to take tokens
        IERC20(token).approve(address(lpLocker), lpData.tokenAmount);

        // Create and lock LP (forward ETH from escrow to lpLocker)
        (address pool, uint256 lpAmount) = lpLocker.createAndLockLP{value: ethForLP}(
            token,
            lpData.tokenAmount,
            escrowAddr
        );

        // Clear pending LP
        delete pendingLP[token];

        // Start founder vesting now that campaign is funded
        address vestingAddr = tokenToVesting[token];
        if (vestingAddr != address(0)) {
            VibesVesting(vestingAddr).startVesting();
        }

        emit LPCreated(token, pool, lpData.tokenAmount, ethForLP, lpAmount);

        // === Step 2: Transfer staker rewards if contract is set ===
        uint256 stakerTokens = lpData.stakerAllocation;
        if (stakerRewardsContract != address(0) && stakerTokens > 0) {
            IERC20(token).safeTransfer(stakerRewardsContract, stakerTokens);
            emit StakerRewardsAllocated(token, stakerRewardsContract, stakerTokens);
        } else if (stakerTokens > 0) {
            // Staker rewards contract not set - tokens remain for backers
            emit StakerTokensRedirectedToBackers(token, stakerTokens);
        }

        // === Step 3: Record backer tokens available for claims ===
        // Tokens stay in the router - backers claim directly via claimTokens()
        uint256 routerBalance = IERC20(token).balanceOf(address(this));
        backerTokensForClaims[token] = routerBalance;

        // === Step 4: Make founder deposit claimable (pull-based) ===
        // Deposit is not sent during finalization to avoid untrusted external calls
        // Founder can claim via claimDepositRefund() in a separate transaction
        uint256 depositAmount = tokenDeposits[token];
        if (depositAmount > 0) {
            delete tokenDeposits[token];
            claimableDeposits[campaign.founder] += depositAmount;
            emit DepositReadyForClaim(campaign.founder, token, depositAmount);
        }
    }

    /**
     * @notice Claim tokens for a funded campaign (auto-finalizes if needed)
     * @dev Backer calls this to claim their token allocation. If the raise has ended
     *      but hasn't been finalized yet, this will finalize it first.
     * @param token Token address of the campaign
     */
    function claimTokens(address token) external nonReentrant whenNotPaused {
        _claimTokensInternal(token);
    }

    /**
     * @notice Batch claim tokens from multiple funded campaigns
     * @dev Reverts if any individual claim fails. Frontend should pre-filter to claimable tokens.
     * @param tokens Array of token addresses to claim from
     */
    function batchClaimTokens(address[] calldata tokens) external nonReentrant whenNotPaused {
        if (tokens.length == 0) revert NothingToClaim();
        if (tokens.length > 20) revert TooManyTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            _claimTokensInternal(tokens[i]);
        }
    }

    /**
     * @dev Internal claim logic shared by claimTokens and batchClaimTokens
     */
    function _claimTokensInternal(address token) internal {
        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) revert ZeroAddress();

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();

        // Auto-finalize if campaign has ended but hasn't been finalized yet
        if (campaign.state == VibesTranchEscrow.CampaignState.Active ||
            campaign.state == VibesTranchEscrow.CampaignState.Paused) {
            // Check if deadline has passed
            if (block.timestamp < campaign.deadline) revert CampaignNotReady();
            // Finalize the campaign (this will call completeFinalization via callback)
            escrow.finalize();
            // Re-fetch campaign state after finalization
            campaign = escrow.getCampaign();
        }

        // Must be in Funded state to claim
        if (campaign.state != VibesTranchEscrow.CampaignState.Funded) {
            revert CampaignNotFunded();
        }

        // Check if already claimed
        if (hasClaimedTokens[token][msg.sender]) revert AlreadyClaimed();

        // Get backer's contribution from escrow
        VibesTranchEscrow.Contribution memory contrib = escrow.getContribution(msg.sender);
        if (contrib.amount == 0) revert NotABacker();

        // Calculate effective contribution (handles pro-rata)
        uint256 effectiveContribution = contrib.amount;
        if (campaign.raiseType == VibesTranchEscrow.RaiseType.ProRata) {
            uint256 totalCommitted = campaign.totalCommitted;
            if (totalCommitted > campaign.goal) {
                effectiveContribution = (contrib.amount * campaign.goal) / totalCommitted;
            }
        }

        // Calculate token allocation
        // tokenAmount = (effectiveContribution / effectiveRaised) * totalBackerTokens
        uint256 effectiveRaised = escrow.effectiveRaised();
        uint256 totalBackerTokens = backerTokensForClaims[token];

        if (effectiveRaised == 0 || totalBackerTokens == 0) revert NothingToClaim();

        uint256 tokenAmount = (effectiveContribution * totalBackerTokens) / effectiveRaised;

        // Cap to remaining balance to handle rounding (prevents last-claimant revert)
        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (tokenAmount > remaining) {
            tokenAmount = remaining;
        }
        if (tokenAmount == 0) revert NothingToClaim();

        // Mark as claimed, decrement pool, and transfer
        hasClaimedTokens[token][msg.sender] = true;
        backerTokensForClaims[token] -= tokenAmount;
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit TokensClaimed(token, msg.sender, tokenAmount);
    }

    /**
     * @notice Get claimable amounts for multiple tokens at once
     * @param tokens Array of token addresses
     * @param backer Backer address
     * @return amounts Array of claimable token amounts (0 for non-claimable)
     */
    function getBatchClaimableTokens(address[] calldata tokens, address backer) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = this.getClaimableTokens(tokens[i], backer);
        }
    }

    /**
     * @notice Get the token amount a backer can claim
     * @param token Token address
     * @param backer Backer address
     * @return tokenAmount Amount of tokens claimable (0 if already claimed or not eligible)
     */
    function getClaimableTokens(address token, address backer) external view returns (uint256 tokenAmount) {
        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) return 0;

        if (hasClaimedTokens[token][backer]) return 0;

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();

        // Only calculate if funded (or will be funded when finalized)
        if (campaign.state != VibesTranchEscrow.CampaignState.Funded &&
            campaign.state != VibesTranchEscrow.CampaignState.Active &&
            campaign.state != VibesTranchEscrow.CampaignState.Paused) {
            return 0;
        }

        VibesTranchEscrow.Contribution memory contrib = escrow.getContribution(backer);
        if (contrib.amount == 0) return 0;

        uint256 effectiveContribution = contrib.amount;
        if (campaign.raiseType == VibesTranchEscrow.RaiseType.ProRata) {
            uint256 totalCommitted = campaign.totalCommitted;
            if (totalCommitted > campaign.goal) {
                effectiveContribution = (contrib.amount * campaign.goal) / totalCommitted;
            }
        }

        uint256 effectiveRaised = escrow.effectiveRaised();
        uint256 totalBackerTokens = backerTokensForClaims[token];

        // If not finalized yet, estimate based on pending LP data
        if (totalBackerTokens == 0) {
            PendingLP memory lpData = pendingLP[token];
            totalBackerTokens = IERC20(token).balanceOf(address(this)) - lpData.tokenAmount;
        }

        if (effectiveRaised == 0) {
            // Use totalRaised as estimate for effectiveRaised if not set yet
            effectiveRaised = campaign.totalRaised;
        }

        if (effectiveRaised == 0 || totalBackerTokens == 0) return 0;

        tokenAmount = (effectiveContribution * totalBackerTokens) / effectiveRaised;
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

    function _handleFeesAndDeposit() internal {
        uint256 requiredAmount = flatFeeWei + founderDepositWei;
        if (feesEnabled) {
            if (msg.value < requiredAmount) revert InsufficientDeposit();

            // Transfer fee to recipient
            if (flatFeeWei > 0) {
                (bool sent, ) = feeRecipient.call{value: flatFeeWei}("");
                require(sent, "Fee transfer failed");
            }

            // Deposit stays in contract (tracked via tokenDeposits mapping)

            // Refund any excess
            uint256 excess = msg.value - requiredAmount;
            if (excess > 0) {
                (bool refunded, ) = msg.sender.call{value: excess}("");
                require(refunded, "Refund failed");
            }
        } else {
            // No fees but still require deposit
            if (msg.value < founderDepositWei) revert InsufficientDeposit();

            // Refund excess
            uint256 excess = msg.value - founderDepositWei;
            if (excess > 0) {
                (bool refunded, ) = msg.sender.call{value: excess}("");
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
    // DEPOSIT CLAIM
    // ============================================

    /**
     * @notice Claim deposit refund after successful raise finalization
     * @dev Pull-based pattern: founder calls this to receive their deposit back.
     *      Separates the deposit refund from the critical finalization chain.
     */
    function claimDepositRefund() external nonReentrant {
        uint256 amount = claimableDeposits[msg.sender];
        if (amount == 0) revert NoClaimableDeposit();

        claimableDeposits[msg.sender] = 0;

        (bool sent, ) = msg.sender.call{value: amount}("");
        if (!sent) revert RefundFailed();

        emit DepositRefunded(msg.sender, address(0), amount);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /// @notice Emergency pause - stops launches, claims, and finalization
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause after emergency is resolved
    function unpause() external onlyOwner {
        _unpause();
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

    function setOpsWallet(address _opsWallet) external onlyOwner {
        if (_opsWallet == address(0)) revert ZeroAddress();
        opsWallet = _opsWallet;
    }

    /**
     * @notice Set the staker rewards contract for $VIBES staker distributions
     * @param _stakerRewardsContract Address of VibesStakerRewards contract
     */
    function setStakerRewardsContract(address _stakerRewardsContract) external onlyOwner {
        if (_stakerRewardsContract == address(0)) revert ZeroAddress();
        stakerRewardsContract = _stakerRewardsContract;
    }

    /**
     * @notice Set the founder deposit amount
     * @param _amount New deposit amount in wei
     */
    function setFounderDepositWei(uint256 _amount) external onlyOwner {
        founderDepositWei = _amount;
    }

    /**
     * @notice Refund deposit to founder (success or cancelled raise)
     * @param token Token address to identify the deposit
     * @param founder Address to receive the refund
     */
    function refundDeposit(address token, address founder) external onlyOwner {
        uint256 depositAmount = tokenDeposits[token];
        if (depositAmount == 0) revert NoDepositToRefund();

        // Clear the deposit record
        delete tokenDeposits[token];

        // Transfer deposit back to founder
        (bool sent, ) = founder.call{value: depositAmount}("");
        if (!sent) revert RefundFailed();

        emit DepositRefunded(founder, token, depositAmount);
    }

    /**
     * @notice Forfeit deposit (spam/fraud removal)
     * @param token Token address to identify the deposit
     * @param founder Original founder address (for event)
     */
    function forfeitDeposit(address token, address founder) external onlyOwner {
        uint256 depositAmount = tokenDeposits[token];
        if (depositAmount == 0) revert NoDepositToRefund();

        // Clear the deposit record
        delete tokenDeposits[token];

        // Transfer forfeited deposit to fee recipient (platform)
        (bool sent, ) = feeRecipient.call{value: depositAmount}("");
        if (!sent) revert RefundFailed();

        emit DepositForfeited(founder, token, depositAmount);
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

    /**
     * @notice Get deposit info for a token
     * @param token Token address
     * @return depositAmount Amount of deposit held (0 if refunded/forfeited)
     */
    function getDepositInfo(address token) external view returns (uint256 depositAmount) {
        depositAmount = tokenDeposits[token];
    }

    /**
     * @notice Get current deposit requirement
     * @return Current founder deposit amount in wei
     */
    function getDepositRequirement() external view returns (uint256) {
        return founderDepositWei;
    }

    // ============================================
    // RECEIVE
    // ============================================

    receive() external payable {}
}
