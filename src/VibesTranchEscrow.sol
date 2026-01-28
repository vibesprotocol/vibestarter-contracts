// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./interfaces/ITimeOracle.sol";

/// @title VibesTranchEscrow
/// @notice Escrow contract with time-based tranche releases, challenge system, and admin controls
/// @dev Supports Fixed Goal, Open-Ended, and Pro-Rata raise types. Uses initializer for clone pattern.
contract VibesTranchEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum RaiseType {
        FixedGoal,    // Must reach goal or full refund
        OpenEnded,    // Keep what you raise (optional soft cap)
        ProRata       // Fair allocation when oversubscribed
    }

    enum CampaignState {
        Uninitialized, // Default state before initialization
        Active,        // Accepting contributions
        Paused,        // Temporarily paused by admin
        Funded,        // Goal met, tranches releasing
        Failed,        // Goal not met, refunds available
        Frozen,        // Admin froze after funding (challenge upheld or abandoned)
        Refunding      // Frozen + refund merkle root set, holders can claim
    }

    enum ChallengeState {
        None,
        Pending,      // Challenge raised, 72hr review period
        Upheld,       // Admin upheld - campaign frozen
        Rejected      // Admin rejected - challenger slashed
    }

    // ============ Structs ============

    struct Campaign {
        address founder;
        address token;
        RaiseType raiseType;
        uint256 goal;              // Required for FixedGoal, hard cap for ProRata, 0 for OpenEnded
        uint256 softCap;           // Optional minimum for OpenEnded
        uint256 deadline;
        uint256 totalRaised;
        uint256 totalCommitted;    // For ProRata: total committed before allocation
        uint256 startTime;         // When campaign was funded (tranches start)
        uint8 nextTranche;         // Next tranche to claim (0-6)
        CampaignState state;
        bytes32 refundMerkleRoot;  // Set when entering Refunding state
        uint256 snapshotBlock;     // Block number of holder snapshot for refunds
    }

    struct Challenge {
        address challenger;
        uint256 amount;            // Tokens staked (0.5% of supply)
        uint256 tranche;           // Which tranche was challenged
        uint256 timestamp;         // When challenge was raised
        ChallengeState state;
    }

    struct Contribution {
        uint256 amount;            // ETH contributed
        bool refundClaimed;        // For failed raises
        bool excessClaimed;        // For ProRata excess
    }

    // ============ Constants ============

    uint256 public constant KICKSTART_BPS = 1000;        // 10%
    uint256 public constant MONTHLY_BPS = 1500;          // 15%
    uint256 public constant PLATFORM_FEE_BPS = 250;      // 2.5%
    uint256 public constant CHALLENGE_THRESHOLD_BPS = 50; // 0.5% of supply
    uint256 public constant CHALLENGE_SLASH_BPS = 2000;   // 20% of stake
    uint256 public constant TRANCHE_DURATION = 30 days;
    uint256 public constant CHALLENGE_WINDOW = 72 hours;
    uint256 public constant MIN_CONTRIBUTION = 0.01 ether;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant NUM_MONTHLY_TRANCHES = 6;

    // ============ State ============

    bool private _initialized;

    address public admin;
    address public platformWallet;
    address public timeOracle;    // 0x0 in production, mock for testnet

    Campaign public campaign;
    Challenge public activeChallenge;

    mapping(address => Contribution) public contributions;
    mapping(address => bool) public refundClaimedFromMerkle;  // For holder refunds
    mapping(uint8 => bool) public trancheClaimed;

    // ============ Events ============

    event CampaignInitialized(
        address indexed founder,
        address indexed token,
        RaiseType raiseType,
        uint256 goal,
        uint256 softCap,
        uint256 deadline
    );
    event ContributionMade(address indexed contributor, uint256 amount, uint256 totalRaised);
    event CampaignFunded(uint256 totalRaised, uint256 timestamp);
    event CampaignFailed(uint256 totalRaised, uint256 goal);
    event CampaignPaused(address indexed by);
    event CampaignResumed(address indexed by);
    event CampaignFrozen(address indexed by, string reason);
    event RefundMerkleRootSet(bytes32 merkleRoot, uint256 snapshotBlock);

    event TrancheClaimed(uint8 indexed tranche, uint256 amount, uint256 fee);
    event ChallengeRaised(address indexed challenger, uint8 tranche, uint256 stake);
    event ChallengeUpheld(address indexed challenger, uint8 tranche);
    event ChallengeRejected(address indexed challenger, uint8 tranche, uint256 slashed);

    event ContributorRefund(address indexed contributor, uint256 amount);
    event HolderRefund(address indexed holder, uint256 ethAmount, uint256 tokensBurned);
    event ExcessRefund(address indexed contributor, uint256 amount);

    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ============ Errors ============

    error OnlyAdmin();
    error OnlyFounder();
    error InvalidState(CampaignState current, CampaignState required);
    error CampaignEnded();
    error CampaignNotEnded();
    error GoalNotReached();
    error BelowMinContribution();
    error ExceedsHardCap();
    error TrancheNotReady(uint8 tranche, uint256 unlockTime);
    error TrancheAlreadyClaimed(uint8 tranche);
    error ChallengePending();
    error NoChallengeActive();
    error ChallengeWindowClosed();
    error InsufficientTokensToChallenge();
    error NotAContributor();
    error AlreadyClaimed();
    error InvalidProof();
    error NoExcessToRefund();
    error ZeroAddress();
    error InvalidTranche();
    error AlreadyInitialized();

    // ============ Modifiers ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyFounder() {
        if (msg.sender != campaign.founder) revert OnlyFounder();
        _;
    }

    modifier inState(CampaignState _state) {
        if (campaign.state != _state) revert InvalidState(campaign.state, _state);
        _;
    }

    // ============ Constructor (for implementation) ============

    /// @notice Constructor disables initialization for implementation contract
    constructor() {
        _initialized = true;
    }

    // ============ Initializer ============

    /// @notice Initialize the escrow (called by factory for clones)
    /// @param _founder Founder address
    /// @param _token Project token address
    /// @param _raiseType Type of raise
    /// @param _goal Funding goal
    /// @param _softCap Soft cap (for OpenEnded)
    /// @param _deadline Campaign deadline
    /// @param _admin Admin address
    /// @param _platformWallet Platform fee wallet
    /// @param _timeOracle Time oracle (0x0 for production)
    function initialize(
        address _founder,
        address _token,
        RaiseType _raiseType,
        uint256 _goal,
        uint256 _softCap,
        uint256 _deadline,
        address _admin,
        address _platformWallet,
        address _timeOracle
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        if (_founder == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        if (_platformWallet == address(0)) revert ZeroAddress();

        admin = _admin;
        platformWallet = _platformWallet;
        timeOracle = _timeOracle;

        campaign = Campaign({
            founder: _founder,
            token: _token,
            raiseType: _raiseType,
            goal: _goal,
            softCap: _softCap,
            deadline: _deadline,
            totalRaised: 0,
            totalCommitted: 0,
            startTime: 0,
            nextTranche: 0,
            state: CampaignState.Active,
            refundMerkleRoot: bytes32(0),
            snapshotBlock: 0
        });

        emit CampaignInitialized(_founder, _token, _raiseType, _goal, _softCap, _deadline);
    }

    // ============ Time Helper ============

    function _currentTime() internal view returns (uint256) {
        if (timeOracle == address(0)) {
            return block.timestamp;
        }
        return ITimeOracle(timeOracle).getTime();
    }

    // ============ Contribution Functions ============

    /// @notice Contribute ETH to the campaign
    function contribute() external payable nonReentrant {
        CampaignState state = campaign.state;
        if (state != CampaignState.Active) revert InvalidState(state, CampaignState.Active);
        if (_currentTime() >= campaign.deadline) revert CampaignEnded();
        if (msg.value < MIN_CONTRIBUTION) revert BelowMinContribution();

        // For FixedGoal with hard cap, reject excess
        if (campaign.raiseType == RaiseType.FixedGoal && campaign.goal > 0) {
            if (campaign.totalRaised + msg.value > campaign.goal) revert ExceedsHardCap();
        }

        contributions[msg.sender].amount += msg.value;
        campaign.totalRaised += msg.value;

        // For ProRata, also track committed amount
        if (campaign.raiseType == RaiseType.ProRata) {
            campaign.totalCommitted += msg.value;
        }

        emit ContributionMade(msg.sender, msg.value, campaign.totalRaised);
    }

    // ============ Finalization ============

    /// @notice Finalize the campaign after deadline
    /// @dev Anyone can call this after deadline
    function finalize() external nonReentrant {
        CampaignState state = campaign.state;
        if (state != CampaignState.Active && state != CampaignState.Paused) {
            revert InvalidState(state, CampaignState.Active);
        }
        if (_currentTime() < campaign.deadline) revert CampaignNotEnded();

        bool success = _checkFundingSuccess();

        if (success) {
            campaign.state = CampaignState.Funded;
            campaign.startTime = _currentTime();
            emit CampaignFunded(campaign.totalRaised, campaign.startTime);
        } else {
            campaign.state = CampaignState.Failed;
            emit CampaignFailed(campaign.totalRaised, campaign.goal);
        }
    }

    function _checkFundingSuccess() internal view returns (bool) {
        if (campaign.raiseType == RaiseType.FixedGoal) {
            return campaign.totalRaised >= campaign.goal;
        } else if (campaign.raiseType == RaiseType.OpenEnded) {
            // Success if no soft cap OR soft cap reached
            return campaign.softCap == 0 || campaign.totalRaised >= campaign.softCap;
        } else {
            // ProRata: always succeeds if any contributions (goal is hard cap)
            return campaign.totalRaised > 0;
        }
    }

    // ============ Tranche Functions ============

    /// @notice Get the unlock time for a specific tranche
    /// @param _tranche Tranche number (0 = kickstart, 1-6 = monthly)
    function getTrancheUnlockTime(uint8 _tranche) public view returns (uint256) {
        if (_tranche == 0) {
            return campaign.startTime; // Kickstart available immediately
        }
        return campaign.startTime + (_tranche * TRANCHE_DURATION);
    }

    /// @notice Get the amount for a specific tranche
    /// @param _tranche Tranche number (0 = kickstart, 1-6 = monthly)
    function getTrancheAmount(uint8 _tranche) public view returns (uint256) {
        // Calculate escrow amount (80% of raised, 20% goes to LP)
        uint256 escrowAmount = (campaign.totalRaised * 8000) / BPS_DENOMINATOR;

        if (_tranche == 0) {
            return (escrowAmount * KICKSTART_BPS) / BPS_DENOMINATOR;
        }
        return (escrowAmount * MONTHLY_BPS) / BPS_DENOMINATOR;
    }

    /// @notice Get total number of tranches (1 kickstart + 6 monthly)
    function getTotalTranches() external pure returns (uint8) {
        return 1 + uint8(NUM_MONTHLY_TRANCHES); // 7 total
    }

    /// @notice Claim a tranche (founder only)
    /// @param _tranche Tranche number to claim
    function claimTranche(uint8 _tranche) external nonReentrant onlyFounder inState(CampaignState.Funded) {
        if (_tranche > NUM_MONTHLY_TRANCHES) revert InvalidTranche();
        if (trancheClaimed[_tranche]) revert TrancheAlreadyClaimed(_tranche);

        // Check no pending challenge
        if (activeChallenge.state == ChallengeState.Pending) revert ChallengePending();

        uint256 unlockTime = getTrancheUnlockTime(_tranche);
        if (_currentTime() < unlockTime) revert TrancheNotReady(_tranche, unlockTime);

        // Must claim in order
        if (_tranche != campaign.nextTranche) revert TrancheNotReady(_tranche, unlockTime);

        uint256 amount = getTrancheAmount(_tranche);
        uint256 fee = (amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 founderAmount = amount - fee;

        trancheClaimed[_tranche] = true;
        campaign.nextTranche = _tranche + 1;

        // Transfer fee to platform
        (bool feeSuccess, ) = platformWallet.call{value: fee}("");
        require(feeSuccess, "Fee transfer failed");

        // Transfer to founder
        (bool success, ) = campaign.founder.call{value: founderAmount}("");
        require(success, "Founder transfer failed");

        emit TrancheClaimed(_tranche, founderAmount, fee);
    }

    /// @notice Check if a tranche can be claimed (includes challenge window check)
    /// @param _tranche Tranche number
    function canClaimTranche(uint8 _tranche) external view returns (bool, string memory) {
        if (campaign.state != CampaignState.Funded) {
            return (false, "Campaign not funded");
        }
        if (trancheClaimed[_tranche]) {
            return (false, "Already claimed");
        }
        if (_tranche > NUM_MONTHLY_TRANCHES) {
            return (false, "Invalid tranche");
        }
        if (_tranche != campaign.nextTranche) {
            return (false, "Must claim in order");
        }
        if (activeChallenge.state == ChallengeState.Pending) {
            return (false, "Challenge pending");
        }
        uint256 unlockTime = getTrancheUnlockTime(_tranche);
        if (_currentTime() < unlockTime) {
            return (false, "Not yet unlocked");
        }
        return (true, "");
    }

    // ============ Challenge Functions ============

    /// @notice Raise a challenge against the current claimable tranche
    /// @dev Challenger must hold >= 0.5% of token supply
    function raiseChallenge() external nonReentrant inState(CampaignState.Funded) {
        if (activeChallenge.state == ChallengeState.Pending) revert ChallengePending();

        uint8 tranche = campaign.nextTranche;
        if (tranche > NUM_MONTHLY_TRANCHES) revert InvalidTranche();
        if (trancheClaimed[tranche]) revert TrancheAlreadyClaimed(tranche);

        // Check unlock time has passed (can only challenge when tranche is claimable)
        uint256 unlockTime = getTrancheUnlockTime(tranche);
        if (_currentTime() < unlockTime) revert TrancheNotReady(tranche, unlockTime);

        // Check challenger has enough tokens
        IERC20 token = IERC20(campaign.token);
        uint256 totalSupply = token.totalSupply();
        uint256 requiredTokens = (totalSupply * CHALLENGE_THRESHOLD_BPS) / BPS_DENOMINATOR;
        uint256 challengerBalance = token.balanceOf(msg.sender);

        if (challengerBalance < requiredTokens) revert InsufficientTokensToChallenge();

        // Transfer tokens to escrow as stake
        token.safeTransferFrom(msg.sender, address(this), requiredTokens);

        activeChallenge = Challenge({
            challenger: msg.sender,
            amount: requiredTokens,
            tranche: tranche,
            timestamp: _currentTime(),
            state: ChallengeState.Pending
        });

        emit ChallengeRaised(msg.sender, tranche, requiredTokens);
    }

    /// @notice Admin upholds the challenge - freezes campaign
    function upholdChallenge() external onlyAdmin {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();

        activeChallenge.state = ChallengeState.Upheld;
        campaign.state = CampaignState.Frozen;
        campaign.snapshotBlock = block.number;

        // Return stake to challenger
        IERC20(campaign.token).safeTransfer(activeChallenge.challenger, activeChallenge.amount);

        emit ChallengeUpheld(activeChallenge.challenger, uint8(activeChallenge.tranche));
        emit CampaignFrozen(msg.sender, "Challenge upheld");
    }

    /// @notice Admin rejects the challenge - slash challenger
    function rejectChallenge() external onlyAdmin {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();

        activeChallenge.state = ChallengeState.Rejected;

        // Calculate slash (20% of stake)
        uint256 slashAmount = (activeChallenge.amount * CHALLENGE_SLASH_BPS) / BPS_DENOMINATOR;
        uint256 returnAmount = activeChallenge.amount - slashAmount;

        IERC20 token = IERC20(campaign.token);

        // Burn slashed tokens (send to dead address)
        token.safeTransfer(address(0xdead), slashAmount);

        // Return remainder to challenger
        token.safeTransfer(activeChallenge.challenger, returnAmount);

        emit ChallengeRejected(activeChallenge.challenger, uint8(activeChallenge.tranche), slashAmount);
    }

    /// @notice Check if challenge window has expired (auto-reject after 72hr if no action)
    function expireChallengeIfNeeded() external {
        if (activeChallenge.state != ChallengeState.Pending) return;

        if (_currentTime() > activeChallenge.timestamp + CHALLENGE_WINDOW) {
            // Auto-reject: return full stake (no slash for timeout)
            activeChallenge.state = ChallengeState.Rejected;
            IERC20(campaign.token).safeTransfer(activeChallenge.challenger, activeChallenge.amount);
            emit ChallengeRejected(activeChallenge.challenger, uint8(activeChallenge.tranche), 0);
        }
    }

    // ============ Admin Functions ============

    /// @notice Pause the campaign (during raise only)
    function pauseCampaign() external onlyAdmin inState(CampaignState.Active) {
        campaign.state = CampaignState.Paused;
        emit CampaignPaused(msg.sender);
    }

    /// @notice Resume a paused campaign
    function resumeCampaign() external onlyAdmin inState(CampaignState.Paused) {
        campaign.state = CampaignState.Active;
        emit CampaignResumed(msg.sender);
    }

    /// @notice Force refund during raise (before funding)
    function forceRefundDuringRaise() external onlyAdmin {
        CampaignState state = campaign.state;
        if (state != CampaignState.Active && state != CampaignState.Paused) {
            revert InvalidState(state, CampaignState.Active);
        }
        campaign.state = CampaignState.Failed;
        emit CampaignFailed(campaign.totalRaised, campaign.goal);
    }

    /// @notice Freeze campaign after funding (for abandoned projects)
    /// @param _reason Reason for freezing
    function freezeCampaign(string calldata _reason) external onlyAdmin inState(CampaignState.Funded) {
        campaign.state = CampaignState.Frozen;
        campaign.snapshotBlock = block.number;
        emit CampaignFrozen(msg.sender, _reason);
    }

    /// @notice Set merkle root for holder refunds (after freeze)
    /// @param _merkleRoot Merkle root of holder balances at snapshot
    function setRefundMerkleRoot(bytes32 _merkleRoot) external onlyAdmin inState(CampaignState.Frozen) {
        campaign.refundMerkleRoot = _merkleRoot;
        campaign.state = CampaignState.Refunding;
        emit RefundMerkleRootSet(_merkleRoot, campaign.snapshotBlock);
    }

    /// @notice Transfer admin role
    /// @param _newAdmin New admin address
    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert ZeroAddress();
        address oldAdmin = admin;
        admin = _newAdmin;
        emit AdminTransferred(oldAdmin, _newAdmin);
    }

    // ============ Refund Functions ============

    /// @notice Claim refund for failed raise (contributor refund)
    function claimContributorRefund() external nonReentrant inState(CampaignState.Failed) {
        Contribution storage contrib = contributions[msg.sender];
        if (contrib.amount == 0) revert NotAContributor();
        if (contrib.refundClaimed) revert AlreadyClaimed();

        uint256 refundAmount = contrib.amount;
        contrib.refundClaimed = true;

        (bool success, ) = msg.sender.call{value: refundAmount}("");
        require(success, "Refund transfer failed");

        emit ContributorRefund(msg.sender, refundAmount);
    }

    /// @notice Claim refund for frozen campaign (holder refund via merkle proof)
    /// @param _tokenAmount Token amount at snapshot
    /// @param _merkleProof Merkle proof for the claim
    function claimHolderRefund(uint256 _tokenAmount, bytes32[] calldata _merkleProof)
        external
        nonReentrant
        inState(CampaignState.Refunding)
    {
        if (refundClaimedFromMerkle[msg.sender]) revert AlreadyClaimed();

        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, _tokenAmount));
        if (!MerkleProof.verify(_merkleProof, campaign.refundMerkleRoot, leaf)) {
            revert InvalidProof();
        }

        refundClaimedFromMerkle[msg.sender] = true;

        // Calculate proportional ETH refund
        IERC20 token = IERC20(campaign.token);
        uint256 totalSupply = token.totalSupply();
        uint256 ethBalance = address(this).balance;
        uint256 ethRefund = (ethBalance * _tokenAmount) / totalSupply;

        // Burn tokens from holder (they must have approved this contract)
        token.safeTransferFrom(msg.sender, address(0xdead), _tokenAmount);

        // Send ETH
        (bool success, ) = msg.sender.call{value: ethRefund}("");
        require(success, "Refund transfer failed");

        emit HolderRefund(msg.sender, ethRefund, _tokenAmount);
    }

    /// @notice Claim excess ETH for ProRata oversubscription
    function claimExcessRefund() external nonReentrant inState(CampaignState.Funded) {
        if (campaign.raiseType != RaiseType.ProRata) revert NoExcessToRefund();

        Contribution storage contrib = contributions[msg.sender];
        if (contrib.amount == 0) revert NotAContributor();
        if (contrib.excessClaimed) revert AlreadyClaimed();

        // Calculate allocation ratio
        uint256 goal = campaign.goal; // Hard cap for ProRata
        uint256 totalCommitted = campaign.totalCommitted;

        if (totalCommitted <= goal) revert NoExcessToRefund();

        // User's allocation = (contribution * goal) / totalCommitted
        uint256 allocation = (contrib.amount * goal) / totalCommitted;
        uint256 excess = contrib.amount - allocation;

        if (excess == 0) revert NoExcessToRefund();

        contrib.excessClaimed = true;

        (bool success, ) = msg.sender.call{value: excess}("");
        require(success, "Excess refund failed");

        emit ExcessRefund(msg.sender, excess);
    }

    // ============ View Functions ============

    /// @notice Get campaign details
    function getCampaign() external view returns (Campaign memory) {
        return campaign;
    }

    /// @notice Get active challenge details
    function getActiveChallenge() external view returns (Challenge memory) {
        return activeChallenge;
    }

    /// @notice Get contribution for an address
    function getContribution(address _contributor) external view returns (Contribution memory) {
        return contributions[_contributor];
    }

    /// @notice Get current time (respects time oracle)
    function getCurrentTime() external view returns (uint256) {
        return _currentTime();
    }

    /// @notice Calculate ProRata allocation for a contributor
    function getProRataAllocation(address _contributor) external view returns (uint256 allocation, uint256 excess) {
        if (campaign.raiseType != RaiseType.ProRata) return (0, 0);

        uint256 contribution = contributions[_contributor].amount;
        uint256 goal = campaign.goal;
        uint256 totalCommitted = campaign.totalCommitted;

        if (totalCommitted <= goal) {
            return (contribution, 0);
        }

        allocation = (contribution * goal) / totalCommitted;
        excess = contribution - allocation;
    }

    /// @notice Get remaining escrow balance
    function getEscrowBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Check if all tranches have been claimed
    function allTranchesClaimed() external view returns (bool) {
        return campaign.nextTranche > NUM_MONTHLY_TRANCHES;
    }

    // ============ Receive ============

    receive() external payable {}
}
