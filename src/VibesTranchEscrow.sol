// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./interfaces/ITimeOracle.sol";
import "./interfaces/IVibesLaunchRouter.sol";

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
        Refunding,     // Frozen + refund merkle root set, holders can claim
        Completed      // All tranches claimed
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
        uint256 raiseStart;        // When contributions begin (0 = immediate)
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
        string reason;             // Why the challenge was raised
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
    mapping(uint8 => bool) public trancheChallenged;  // Track if a tranche has already been challenged

    // Snapshot values for holder refunds (set when campaign is frozen)
    uint256 public frozenEthBalance;
    uint256 public frozenTotalSupply;  // Redeemable supply (excludes permanently locked tokens)

    // LP withdrawal tracking
    bool public lpWithdrawn;
    address public authorizedRouter;
    address public lpLocker;  // LP locker address for direct LP ETH transfer
    uint256 public lpEthAmount;  // Amount of ETH sent to LP locker during finalization

    // Effective raised amount (after pro-rata calculations for oversubscribed campaigns)
    uint256 public effectiveRaised;

    // ============ Events ============

    event CampaignInitialized(
        address indexed founder,
        address indexed token,
        RaiseType raiseType,
        uint256 goal,
        uint256 softCap,
        uint256 deadline,
        uint256 raiseStart
    );
    event ContributionMade(address indexed contributor, uint256 amount, uint256 totalRaised);
    event CampaignFunded(uint256 totalRaised, uint256 timestamp);
    event CampaignFailed(uint256 totalRaised, uint256 goal);
    event CampaignPaused(address indexed by);
    event CampaignResumed(address indexed by);
    event CampaignFrozen(address indexed by, string reason);
    event RefundMerkleRootSet(bytes32 merkleRoot, uint256 snapshotBlock);

    event TrancheClaimed(uint8 indexed tranche, uint256 amount, uint256 fee);
    event ChallengeRaised(address indexed challenger, uint8 tranche, uint256 stake, string reason);
    event ChallengeUpheld(address indexed challenger, uint8 tranche);
    event ChallengeRejected(address indexed challenger, uint8 tranche, uint256 slashed);

    event ContributorRefund(address indexed contributor, uint256 amount);
    event HolderRefund(address indexed holder, uint256 ethAmount, uint256 tokensBurned);
    event ExcessRefund(address indexed contributor, uint256 amount);
    event ChallengeSupported(address indexed supporter, uint8 tranche, string additionalContext);
    event CampaignCompleted(uint256 totalPaid);

    event FounderUpdate(address indexed founder, string ipfsCid, uint256 timestamp);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event LPWithdrawn(address indexed lpLocker, uint256 amount);
    event CampaignFinalized(uint256 effectiveRaised, uint256 excessForRefunds);
    event FrozenBalanceRecorded(uint256 ethBalance, uint256 tokenSupply);

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
    error LPAlreadyWithdrawn();
    error OnlyRouter();
    error ChallengeWindowOpen();
    error TrancheAlreadyChallenged();
    error CampaignCompleteCannotFreeze();
    error RaiseNotStarted();

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
    /// @param _authorizedRouter Router authorized to withdraw LP funds
    function initialize(
        address _founder,
        address _token,
        RaiseType _raiseType,
        uint256 _goal,
        uint256 _softCap,
        uint256 _deadline,
        uint256 _raiseStart,
        address _admin,
        address _platformWallet,
        address _timeOracle,
        address _authorizedRouter,
        address _lpLocker
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        if (_founder == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        if (_platformWallet == address(0)) revert ZeroAddress();
        if (_authorizedRouter == address(0)) revert ZeroAddress();
        if (_lpLocker == address(0)) revert ZeroAddress();

        admin = _admin;
        platformWallet = _platformWallet;
        timeOracle = _timeOracle;
        authorizedRouter = _authorizedRouter;
        lpLocker = _lpLocker;

        campaign = Campaign({
            founder: _founder,
            token: _token,
            raiseType: _raiseType,
            goal: _goal,
            softCap: _softCap,
            deadline: _deadline,
            raiseStart: _raiseStart,
            totalRaised: 0,
            totalCommitted: 0,
            startTime: 0,
            nextTranche: 0,
            state: CampaignState.Active,
            refundMerkleRoot: bytes32(0),
            snapshotBlock: 0
        });

        emit CampaignInitialized(_founder, _token, _raiseType, _goal, _softCap, _deadline, _raiseStart);
    }

    // ============ Time Helper ============

    function _currentTime() internal view returns (uint256) {
        if (timeOracle == address(0)) {
            return block.timestamp;
        }
        return ITimeOracle(timeOracle).getTime();
    }

    // ============ Supply Helper ============

    /// @dev Calculate redeemable token supply (excludes permanently locked tokens)
    /// @param _excludeAddresses Addresses holding non-redeemable tokens (vesting, staker rewards, router, 0xdead)
    function _calculateRedeemableSupply(address[] memory _excludeAddresses) internal view returns (uint256) {
        IERC20 token = IERC20(campaign.token);
        uint256 totalSupply = token.totalSupply();
        uint256 excludedBalance = 0;

        for (uint256 i = 0; i < _excludeAddresses.length; i++) {
            if (_excludeAddresses[i] != address(0)) {
                excludedBalance += token.balanceOf(_excludeAddresses[i]);
            }
        }

        // Also always exclude the dead address (LP tokens)
        excludedBalance += token.balanceOf(address(0x000000000000000000000000000000000000dEaD));

        return totalSupply > excludedBalance ? totalSupply - excludedBalance : 0;
    }

    // ============ Contribution Functions ============

    /// @notice Contribute ETH to the campaign
    function contribute() external payable nonReentrant {
        _contribute(msg.sender, msg.value);
    }

    /// @dev Internal contribution logic - single source of truth
    function _contribute(address contributor, uint256 amount) internal {
        CampaignState state = campaign.state;
        if (state != CampaignState.Active) revert InvalidState(state, CampaignState.Active);
        if (campaign.raiseStart > 0 && _currentTime() < campaign.raiseStart) revert RaiseNotStarted();
        if (_currentTime() >= campaign.deadline) revert CampaignEnded();
        if (amount < MIN_CONTRIBUTION) revert BelowMinContribution();

        // For FixedGoal with hard cap, reject excess
        if (campaign.raiseType == RaiseType.FixedGoal && campaign.goal > 0) {
            if (campaign.totalRaised + amount > campaign.goal) revert ExceedsHardCap();
        }

        contributions[contributor].amount += amount;
        campaign.totalRaised += amount;

        // For ProRata, also track committed amount
        if (campaign.raiseType == RaiseType.ProRata) {
            campaign.totalCommitted += amount;
        }

        emit ContributionMade(contributor, amount, campaign.totalRaised);
    }

    // ============ Finalization ============

    /// @notice Finalize the campaign after deadline (or early for Fixed Goal when goal reached)
    /// @dev Anyone can call this after deadline, or early for Fixed Goal raises that hit their goal.
    ///      For successful campaigns, automatically creates LP and token distributor via the router.
    function finalize() external nonReentrant {
        CampaignState state = campaign.state;
        if (state != CampaignState.Active && state != CampaignState.Paused) {
            revert InvalidState(state, CampaignState.Active);
        }

        // Allow early finalization for Fixed Goal raises that have reached their goal
        bool canFinalizeEarly = campaign.raiseType == RaiseType.FixedGoal &&
                                campaign.totalRaised >= campaign.goal;

        if (!canFinalizeEarly && _currentTime() < campaign.deadline) revert CampaignNotEnded();

        bool success = _checkFundingSuccess();

        if (success) {
            campaign.state = CampaignState.Funded;
            campaign.startTime = _currentTime();

            // Calculate effective raised amount (handles pro-rata oversubscription)
            _calculateEffectiveRaised();

            // Send LP ETH to the router (avoids router needing to call back into escrow)
            uint256 lpAmount = getLPAmount();
            if (lpAmount > 0 && authorizedRouter != address(0)) {
                lpWithdrawn = true;
                lpEthAmount = lpAmount;
                (bool lpSuccess, ) = authorizedRouter.call{value: lpAmount}("");
                require(lpSuccess, "LP ETH transfer failed");
                emit LPWithdrawn(authorizedRouter, lpAmount);
            }

            emit CampaignFunded(campaign.totalRaised, campaign.startTime);

            // Complete finalization via router: creates LP from forwarded ETH, distributes tokens
            // Router no longer calls back into escrow (LP ETH already forwarded above)
            if (authorizedRouter != address(0)) {
                IVibesLaunchRouter(authorizedRouter).completeFinalization(campaign.token);
            }
        } else {
            campaign.state = CampaignState.Failed;
            emit CampaignFailed(campaign.totalRaised, campaign.goal);
        }
    }

    /// @notice Calculate effective raised amount, accounting for pro-rata excess
    /// @dev For ProRata campaigns, effective = min(totalCommitted, goal)
    ///      For others, effective = totalRaised
    function _calculateEffectiveRaised() internal {
        if (campaign.raiseType == RaiseType.ProRata) {
            // For oversubscribed pro-rata, effective is capped at goal
            if (campaign.totalCommitted > campaign.goal) {
                effectiveRaised = campaign.goal;
            } else {
                effectiveRaised = campaign.totalCommitted;
            }
        } else {
            effectiveRaised = campaign.totalRaised;
        }

        uint256 excessForRefunds = campaign.totalRaised - effectiveRaised;
        emit CampaignFinalized(effectiveRaised, excessForRefunds);
    }

    function _checkFundingSuccess() internal view returns (bool) {
        if (campaign.raiseType == RaiseType.FixedGoal) {
            return campaign.totalRaised >= campaign.goal;
        } else if (campaign.raiseType == RaiseType.OpenEnded) {
            // Must have at least some contributions, and either no soft cap OR soft cap reached
            return campaign.totalRaised > 0 && (campaign.softCap == 0 || campaign.totalRaised >= campaign.softCap);
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
        // Calculate escrow amount (80% of effective raised, 20% goes to LP)
        // effectiveRaised accounts for pro-rata excess that stays for refunds
        uint256 escrowAmount = (effectiveRaised * 8000) / BPS_DENOMINATOR;

        if (_tranche == 0) {
            return (escrowAmount * KICKSTART_BPS) / BPS_DENOMINATOR;
        }
        return (escrowAmount * MONTHLY_BPS) / BPS_DENOMINATOR;
    }

    /// @notice Get the amount of ETH designated for LP creation (20% of effective raised)
    function getLPAmount() public view returns (uint256) {
        return (effectiveRaised * 2000) / BPS_DENOMINATOR;
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

        // LP must be created before any tranches can be claimed
        if (!lpWithdrawn) revert TrancheNotReady(_tranche, 0);

        uint256 unlockTime = getTrancheUnlockTime(_tranche);
        if (_currentTime() < unlockTime) revert TrancheNotReady(_tranche, unlockTime);

        // Must claim in order
        if (_tranche != campaign.nextTranche) revert TrancheNotReady(_tranche, unlockTime);

        // Enforce 72-hour challenge window after unlock time
        uint256 claimableTime = unlockTime + CHALLENGE_WINDOW;
        if (_currentTime() < claimableTime) revert ChallengeWindowOpen();

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

        // Transition to Completed after last tranche
        if (campaign.nextTranche > NUM_MONTHLY_TRANCHES) {
            campaign.state = CampaignState.Completed;
            emit CampaignCompleted(effectiveRaised);
        }
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
        if (!lpWithdrawn) {
            return (false, "LP not yet created");
        }
        uint256 unlockTime = getTrancheUnlockTime(_tranche);
        if (_currentTime() < unlockTime) {
            return (false, "Not yet unlocked");
        }
        // Check 72-hour challenge window has passed
        uint256 claimableTime = unlockTime + CHALLENGE_WINDOW;
        if (_currentTime() < claimableTime) {
            return (false, "Challenge window still open");
        }
        return (true, "");
    }

    // ============ LP Info ============

    /// @notice Get the amount of ETH that was sent to LP locker during finalization
    /// @return amount Amount of ETH sent to LP locker
    /// @dev LP ETH is now sent directly during finalize(), eliminating the callback re-entry pattern
    function getLPEthSent() external view returns (uint256 amount) {
        return lpEthAmount;
    }

    // ============ Challenge Functions ============

    /// @notice Raise a challenge against the current claimable tranche
    /// @dev Challenger must hold >= 0.5% of token supply
    /// @param _reason Description of why the challenge is being raised
    function raiseChallenge(string calldata _reason) external nonReentrant inState(CampaignState.Funded) {
        if (activeChallenge.state == ChallengeState.Pending) revert ChallengePending();

        uint8 tranche = campaign.nextTranche;
        if (tranche > NUM_MONTHLY_TRANCHES) revert InvalidTranche();
        if (trancheClaimed[tranche]) revert TrancheAlreadyClaimed(tranche);
        if (trancheChallenged[tranche]) revert TrancheAlreadyChallenged();

        // Check unlock time has passed (can only challenge when tranche is claimable)
        uint256 unlockTime = getTrancheUnlockTime(tranche);
        if (_currentTime() < unlockTime) revert TrancheNotReady(tranche, unlockTime);

        // Check challenger has enough tokens (graduated threshold by tranche)
        IERC20 token = IERC20(campaign.token);
        uint256 totalSupply = token.totalSupply();
        uint256 thresholdBps = getChallengeThreshold(tranche);
        uint256 requiredTokens = (totalSupply * thresholdBps) / BPS_DENOMINATOR;
        uint256 challengerBalance = token.balanceOf(msg.sender);

        if (challengerBalance < requiredTokens) revert InsufficientTokensToChallenge();

        // Transfer tokens to escrow as stake
        token.safeTransferFrom(msg.sender, address(this), requiredTokens);

        trancheChallenged[tranche] = true;

        activeChallenge = Challenge({
            challenger: msg.sender,
            reason: _reason,
            amount: requiredTokens,
            tranche: tranche,
            timestamp: _currentTime(),
            state: ChallengeState.Pending
        });

        emit ChallengeRaised(msg.sender, tranche, requiredTokens, _reason);
    }

    /// @notice Support an existing pending challenge with additional context
    /// @dev Allows other backers to strengthen a challenge without creating a new one
    /// @param _additionalContext Additional evidence or reasoning
    function supportChallenge(string calldata _additionalContext) external inState(CampaignState.Funded) {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();

        emit ChallengeSupported(msg.sender, uint8(activeChallenge.tranche), _additionalContext);
    }

    /// @notice Admin upholds the challenge - freezes campaign
    /// @param _excludeAddresses Addresses holding non-redeemable tokens (vesting, staker rewards, router)
    function upholdChallenge(address[] calldata _excludeAddresses) external onlyAdmin {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();

        activeChallenge.state = ChallengeState.Upheld;
        campaign.state = CampaignState.Frozen;
        campaign.snapshotBlock = block.number;

        // Record frozen balances for holder refund calculations
        // Use redeemable supply (excludes LP at 0xdead, vesting, staker rewards, router)
        frozenEthBalance = address(this).balance;
        frozenTotalSupply = _calculateRedeemableSupply(_excludeAddresses);

        // Return stake to challenger
        IERC20(campaign.token).safeTransfer(activeChallenge.challenger, activeChallenge.amount);

        emit FrozenBalanceRecorded(frozenEthBalance, frozenTotalSupply);
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

    /// @notice Freeze raise after funding (for abandoned projects)
    /// @dev Cannot freeze a completed raise (all tranches claimed)
    /// @param _reason Reason for freezing
    /// @param _excludeAddresses Addresses holding non-redeemable tokens (vesting, staker rewards, router)
    function freezeCampaign(string calldata _reason, address[] calldata _excludeAddresses) external onlyAdmin inState(CampaignState.Funded) {
        if (campaign.nextTranche > NUM_MONTHLY_TRANCHES) revert CampaignCompleteCannotFreeze();
        campaign.state = CampaignState.Frozen;
        campaign.snapshotBlock = block.number;

        // Record frozen balances for holder refund calculations
        // Use redeemable supply (excludes LP at 0xdead, vesting, staker rewards, router)
        frozenEthBalance = address(this).balance;
        frozenTotalSupply = _calculateRedeemableSupply(_excludeAddresses);

        emit FrozenBalanceRecorded(frozenEthBalance, frozenTotalSupply);
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

        // Calculate proportional ETH refund using frozen snapshot values
        // This ensures consistent refund amounts regardless of claim order
        uint256 ethRefund = (frozenEthBalance * _tokenAmount) / frozenTotalSupply;

        // Burn tokens from holder (they must have approved this contract)
        IERC20(campaign.token).safeTransferFrom(msg.sender, address(0xdead), _tokenAmount);

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

    /// @notice Check if the raise has started accepting contributions
    function isRaiseStarted() external view returns (bool) {
        if (campaign.raiseStart == 0) return true;
        return _currentTime() >= campaign.raiseStart;
    }

    /// @notice Get the graduated challenge threshold for a given tranche
    /// @dev Early tranches are easier to challenge, later ones harder
    function getChallengeThreshold(uint8 tranche) public pure returns (uint256) {
        if (tranche <= 2) return 25;   // 0.25% for early tranches (0-2)
        if (tranche <= 4) return 50;   // 0.50% for mid tranches (3-4)
        return 100;                     // 1.00% for late tranches (5-6)
    }

    // ============ Founder Updates ============

    /// @notice Post an on-chain update (emits event with IPFS CID)
    /// @param ipfsCid IPFS CID pointing to update JSON { title, body, links }
    function postUpdate(string calldata ipfsCid) external {
        if (msg.sender != campaign.founder) revert OnlyFounder();
        if (campaign.state != CampaignState.Funded && campaign.state != CampaignState.Completed) {
            revert InvalidState(campaign.state, CampaignState.Funded);
        }
        emit FounderUpdate(msg.sender, ipfsCid, _currentTime());
    }

    // ============ Receive ============

    /// @notice Accept direct ETH transfers as contributions
    /// @dev Uses _contribute() for single source of truth, with nonReentrant for safety
    receive() external payable nonReentrant {
        _contribute(msg.sender, msg.value);
    }
}
