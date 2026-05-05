// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
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
    uint256 public constant MAX_TIME_DRIFT = 1 hours; // Audit fix H-06: sanity bound on time oracle

    // ============ State ============

    bool private _initialized;

    address public admin;
    address public pendingAdmin;
    address public platformWallet;
    address public timeOracle;    // 0x0 in production, mock for testnet

    Campaign public campaign;
    Challenge public activeChallenge;

    mapping(address => Contribution) public contributions;
    mapping(address => bool) public refundClaimedFromMerkle;  // For holder refunds
    mapping(uint8 => bool) public trancheClaimed;
    mapping(uint8 => bool) public trancheChallenged;  // Track if a tranche has already been challenged
    mapping(uint8 => uint256) public trancheRequestedAt;  // When founder requested payout (starts 72h window)

    // Challenge vote direction per voter per tranche: 0=none, 1=support, 2=oppose
    mapping(address => mapping(uint8 => uint8)) public challengeVoteDirection;

    // Snapshot values for holder refunds (set when campaign is frozen)
    uint256 public frozenEthBalance;
    uint256 public frozenTotalSupply;  // Redeemable supply (excludes permanently locked tokens)

    // Audit fix F4: Track unclaimed pro-rata excess refund liability
    uint256 public totalExcessRefundLiability;

    // LP withdrawal tracking
    bool public lpWithdrawn;
    address public authorizedRouter;
    address public lpLocker;  // LP locker address for direct LP ETH transfer
    uint256 public lpEthAmount;  // Amount of ETH sent to LP locker during finalization

    // Known locked contract addresses for onchain redeemable supply calculation (audit fix)
    address public vestingContract;     // Founder vesting contract
    address public stakerRewards;       // Staker rewards contract
    address public treasuryContract;    // Audit fix F-2 (2026-04): treasury escrow holds a large illiquid
                                        // allocation; without exclusion, its balance dilutes holder refunds.

    // Effective raised amount (after pro-rata calculations for oversubscribed campaigns)
    uint256 public effectiveRaised;

    // Accumulated platform fees (pull pattern — audit fix)
    uint256 public pendingPlatformFees;

    // EIP-712 terms signature gating
    address public trustedSigner;        // Backend signer for terms acceptance (address(0) = gating disabled)
    bytes32 private _DOMAIN_SEPARATOR;   // EIP-712 domain separator (set during initialize)

    // Audit fix H-04: LP creation verified flag — blocks tranche claims until LP is truly locked
    bool public lpCreated;

    // Per-challenger cooldown to prevent serial challenge griefing (audit response)
    mapping(address => uint256) public lastChallengeTime;
    uint256 public constant CHALLENGE_COOLDOWN = 7 days;

    // EIP-712 nonce replay protection — sequential per-user nonce
    mapping(address => uint256) public nonces;

    // Audit fix F10: Commit-reveal for merkle root — 24hr delay between commit and finalize
    bytes32 public pendingMerkleRoot;
    uint256 public merkleRootCommitTime;
    uint256 public constant MERKLE_ROOT_DELAY = 24 hours;

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

    event TrancheRequested(uint8 indexed tranche, uint256 timestamp);
    event TrancheClaimed(uint8 indexed tranche, uint256 amount, uint256 fee);
    event ChallengeRaised(address indexed challenger, uint8 tranche, uint256 stake, string reason);
    event ChallengeUpheld(address indexed challenger, uint8 tranche);
    event ChallengeRejected(address indexed challenger, uint8 tranche, uint256 slashed);

    event ContributorRefund(address indexed contributor, uint256 amount);
    event HolderRefund(address indexed holder, uint256 ethAmount, uint256 tokensBurned);
    event ExcessRefund(address indexed contributor, uint256 amount);
    event ChallengeSupported(address indexed supporter, uint8 tranche, string additionalContext);
    event ChallengeOpposed(address indexed opposer, uint8 tranche, string additionalContext);
    event CampaignCompleted(uint256 totalPaid);

    event FounderUpdate(address indexed founder, string ipfsCid, uint256 timestamp);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event LPWithdrawn(address indexed lpLocker, uint256 amount);
    event CampaignFinalized(uint256 effectiveRaised, uint256 excessForRefunds);
    event FrozenBalanceRecorded(uint256 ethBalance, uint256 tokenSupply);
    event LockedAddressesUpdated(address vestingContract, address stakerRewards);
    event TreasuryContractUpdated(address treasuryContract);
    event MerkleRootCommitted(bytes32 merkleRoot, uint256 commitTime);
    event MerkleRootCancelled(bytes32 merkleRoot);
    event PlatformFeesAccrued(uint8 indexed tranche, uint256 amount);
    event PlatformFeesClaimed(address indexed claimedBy, uint256 amount);
    event TrustedSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event FinalizationDeferred(address indexed token, bytes reason); // Phase 1 (LP) failed
    event DistributionDeferred(address indexed token, bytes reason); // Phase 2 (distribution) failed

    // ============ Errors ============

    error OnlyAdmin();
    error OnlyPendingAdmin();
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
    error TrancheNotRequested();
    error TrancheAlreadyRequested();
    error TrancheAlreadyChallenged();
    error CampaignCompleteCannotFreeze();
    error RaiseNotStarted();
    error SignatureExpired();
    error InvalidSignature();
    error UseContributeFunction();
    error ChallengeCooldownActive();
    error LPNotCreated();  // Audit fix H-04: tranche claims blocked until LP is verified created
    error InvalidNonce();
    error MerkleRootDelayNotElapsed();
    error NoPendingMerkleRoot();

    // ============ Constants (EIP-712) ============

    bytes32 public constant TERMS_TYPEHASH = keccak256("TermsAcceptance(address user,uint256 nonce,uint256 deadline)");

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

    modifier requiresTermsSignature(uint256 nonce, uint256 deadline, bytes calldata signature) {
        _verifyTermsSignature(msg.sender, nonce, deadline, signature);
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
    /// @param _lpLocker LP locker address
    /// @param _trustedSigner Backend signer for terms acceptance (address(0) = gating disabled)
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
        address _lpLocker,
        address _trustedSigner
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
        trustedSigner = _trustedSigner;

        // Compute EIP-712 domain separator
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("VibesTranchEscrow"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );

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
        uint256 oracleTime = ITimeOracle(timeOracle).getTime();
        // Audit fix H-06: Prevent malicious oracle from jumping time forward
        require(oracleTime <= block.timestamp + MAX_TIME_DRIFT, "Oracle drift exceeded");
        return oracleTime;
    }

    /// @notice Public accessor for effective current time (audit fix F8)
    /// @dev Used by router for auto-finalization deadline check so it respects the time oracle
    function currentTime() external view returns (uint256) {
        return _currentTime();
    }

    // ============ Supply Helper ============

    /// @dev Calculate redeemable token supply using known locked contract addresses
    /// @notice Excludes tokens held by: dead address (LP), vesting, staker rewards, router, LP locker, and this escrow
    function _calculateRedeemableSupply() internal view returns (uint256) {
        IERC20 token = IERC20(campaign.token);
        uint256 totalSupply = token.totalSupply();
        uint256 excludedBalance = 0;

        // Always exclude the dead address (permanently locked LP tokens)
        excludedBalance += token.balanceOf(address(0x000000000000000000000000000000000000dEaD));

        // Exclude known locked contracts (set via setLockedAddresses or at init)
        if (vestingContract != address(0)) {
            excludedBalance += token.balanceOf(vestingContract);
        }
        if (stakerRewards != address(0)) {
            excludedBalance += token.balanceOf(stakerRewards);
        }
        if (authorizedRouter != address(0)) {
            excludedBalance += token.balanceOf(authorizedRouter);
        }
        if (lpLocker != address(0)) {
            excludedBalance += token.balanceOf(lpLocker);
        }
        // Audit fix F-2 (2026-04): exclude the treasury escrow — its allocation is custody, not circulating supply.
        if (treasuryContract != address(0)) {
            excludedBalance += token.balanceOf(treasuryContract);
        }
        // Exclude tokens held by this escrow itself (e.g., challenge stakes)
        excludedBalance += token.balanceOf(address(this));

        return totalSupply > excludedBalance ? totalSupply - excludedBalance : 0;
    }

    // ============ EIP-712 Signature Verification ============

    /// @notice Verify that the backend trusted signer authorized this user
    /// @dev If trustedSigner is address(0), gating is disabled (backwards compatible)
    /// @dev Nonce must match current value for user; incremented after successful verification
    function _verifyTermsSignature(address user, uint256 nonce, uint256 deadline, bytes calldata signature) internal {
        if (trustedSigner == address(0)) return; // Gating disabled

        if (nonce != nonces[user]) revert InvalidNonce();
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash = keccak256(abi.encode(TERMS_TYPEHASH, user, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));

        address recovered = ECDSA.recover(digest, signature);
        if (recovered != trustedSigner) revert InvalidSignature();

        nonces[user]++;
    }

    /// @notice Update the trusted signer address (admin only)
    /// @param _newSigner New signer address (address(0) disables gating)
    function setTrustedSigner(address _newSigner) external onlyAdmin {
        address oldSigner = trustedSigner;
        trustedSigner = _newSigner;
        emit TrustedSignerUpdated(oldSigner, _newSigner);
    }

    // ============ Contribution Functions ============

    /// @notice Contribute ETH to the campaign
    /// @param nonce Sequential nonce for replay protection
    /// @param deadline Signature expiry timestamp
    /// @param signature EIP-712 signature from trusted signer
    function contribute(uint256 nonce, uint256 deadline, bytes calldata signature) external payable nonReentrant requiresTermsSignature(nonce, deadline, signature) {
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

            // Audit fix F4: Track total excess refund liability for pro-rata raises
            if (campaign.raiseType == RaiseType.ProRata && campaign.totalCommitted > campaign.goal) {
                totalExcessRefundLiability = campaign.totalCommitted - campaign.goal;
            }

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
            // Audit fix H-02: try/catch so finalization completes even if router is paused
            if (authorizedRouter != address(0)) {
                // Phase 1: LP creation (~800K gas)
                try IVibesLaunchRouter(authorizedRouter).completeFinalization(campaign.token) {
                } catch (bytes memory reason) {
                    emit FinalizationDeferred(campaign.token, reason);
                }
                // Phase 2: Distribution (~400K gas)
                try IVibesLaunchRouter(authorizedRouter).completeDistribution(campaign.token) {
                } catch (bytes memory reason) {
                    emit DistributionDeferred(campaign.token, reason);
                }
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
            // ProRata: must reach the hard cap (goal) to be funded
            return campaign.totalRaised >= campaign.goal;
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
        // Calculate escrow amount (85% of effective raised, 15% goes to LP)
        // effectiveRaised accounts for pro-rata excess that stays for refunds
        uint256 escrowAmount = (effectiveRaised * 8500) / BPS_DENOMINATOR;

        if (_tranche == 0) {
            return (escrowAmount * KICKSTART_BPS) / BPS_DENOMINATOR;
        }
        return (escrowAmount * MONTHLY_BPS) / BPS_DENOMINATOR;
    }

    /// @notice Get the amount of ETH designated for LP creation (15% of effective raised)
    function getLPAmount() public view returns (uint256) {
        return (effectiveRaised * 1500) / BPS_DENOMINATOR;
    }

    /// @notice Get total number of tranches (1 kickstart + 6 monthly)
    function getTotalTranches() external pure returns (uint8) {
        return 1 + uint8(NUM_MONTHLY_TRANCHES); // 7 total
    }

    /// @notice Request payout for a monthly tranche (founder only) — starts 72h challenge window
    /// @param _tranche Tranche number to request (1-6, kickstart is claimed directly)
    function requestTranche(uint8 _tranche) external onlyFounder inState(CampaignState.Funded) {
        if (_tranche == 0) revert InvalidTranche(); // Kickstart doesn't need a request
        if (_tranche > NUM_MONTHLY_TRANCHES) revert InvalidTranche();
        if (trancheClaimed[_tranche]) revert TrancheAlreadyClaimed(_tranche);
        if (trancheRequestedAt[_tranche] > 0) revert TrancheAlreadyRequested();

        // Auto-expire stale challenges so founders aren't blocked by timed-out disputes
        _expireChallengeIfNeeded();
        if (activeChallenge.state == ChallengeState.Pending) revert ChallengePending();

        // Audit fix F5: LP must be actually created (not just withdrawn) before tranches can be requested.
        // Previously checked lpWithdrawn, but in deferred LP scenarios (lpWithdrawn=true, lpCreated=false),
        // this allowed requests that would later fail on claim, creating confusing state.
        if (!lpCreated && authorizedRouter != address(0)) revert LPNotCreated();

        uint256 unlockTime = getTrancheUnlockTime(_tranche);
        if (_currentTime() < unlockTime) revert TrancheNotReady(_tranche, unlockTime);

        // Must request in order
        if (_tranche != campaign.nextTranche) revert TrancheNotReady(_tranche, unlockTime);

        trancheRequestedAt[_tranche] = _currentTime();

        emit TrancheRequested(_tranche, _currentTime());
    }

    /// @notice Claim a tranche (founder only)
    /// @param _tranche Tranche number to claim
    function claimTranche(uint8 _tranche) external nonReentrant onlyFounder inState(CampaignState.Funded) {
        if (_tranche > NUM_MONTHLY_TRANCHES) revert InvalidTranche();
        if (trancheClaimed[_tranche]) revert TrancheAlreadyClaimed(_tranche);

        // Audit fix H-04: Block tranche claims if LP was not created (rescue scenario)
        if (!lpCreated && authorizedRouter != address(0)) revert LPNotCreated();

        // Auto-expire stale challenges before checking — prevents founders from being
        // permanently blocked by challenges that exceeded the window without admin action.
        _expireChallengeIfNeeded();
        if (activeChallenge.state == ChallengeState.Pending) revert ChallengePending();

        // LP must be created before any tranches can be claimed
        if (!lpWithdrawn) revert TrancheNotReady(_tranche, 0);

        uint256 unlockTime = getTrancheUnlockTime(_tranche);
        if (_currentTime() < unlockTime) revert TrancheNotReady(_tranche, unlockTime);

        // Must claim in order
        if (_tranche != campaign.nextTranche) revert TrancheNotReady(_tranche, unlockTime);

        // Kickstart (tranche 0) has no challenge window — available immediately on completion.
        // Monthly tranches (1-6) require requestTranche() first, then 72h challenge window.
        if (_tranche > 0) {
            if (trancheRequestedAt[_tranche] == 0) revert TrancheNotRequested();
            uint256 claimableTime = trancheRequestedAt[_tranche] + CHALLENGE_WINDOW;
            if (_currentTime() <= claimableTime) revert ChallengeWindowOpen(); // Audit fix H-01: strictly after window
        }

        uint256 amount = getTrancheAmount(_tranche);
        uint256 fee = (amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 founderAmount = amount - fee;

        trancheClaimed[_tranche] = true;
        campaign.nextTranche = _tranche + 1;

        // Accrue platform fee for later withdrawal (pull pattern — audit fix)
        // This ensures a reverting platformWallet cannot DoS the founder.
        pendingPlatformFees += fee;

        // Transfer to founder
        (bool success, ) = campaign.founder.call{value: founderAmount}("");
        require(success, "Founder transfer failed");

        emit PlatformFeesAccrued(_tranche, fee);
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
        // Audit fix F5 (view alignment): mirror claimTranche — lpCreated, not lpWithdrawn.
        // In deferred-LP scenarios (lpWithdrawn=true, lpCreated=false), the previous
        // check returned a false-positive and integrators saw "claim ready" while the
        // actual claimTranche would revert with LPNotCreated.
        if (!lpCreated && authorizedRouter != address(0)) {
            return (false, "LP not yet created");
        }
        uint256 unlockTime = getTrancheUnlockTime(_tranche);
        if (_currentTime() < unlockTime) {
            return (false, "Not yet unlocked");
        }
        // Kickstart (tranche 0) has no challenge window — available immediately.
        // Monthly tranches (1-6) require requestTranche() first, then 72h challenge window.
        if (_tranche > 0) {
            if (trancheRequestedAt[_tranche] == 0) {
                return (false, "Payout not yet requested");
            }
            uint256 claimableTime = trancheRequestedAt[_tranche] + CHALLENGE_WINDOW;
            if (_currentTime() <= claimableTime) { // Must match claimTranche boundary (strictly after)
                return (false, "Challenge window still open");
            }
        }
        return (true, "");
    }

    /// @notice Check if a tranche can be requested (monthly only, not yet requested)
    /// @param _tranche Tranche number
    function canRequestTranche(uint8 _tranche) external view returns (bool, string memory) {
        if (campaign.state != CampaignState.Funded) {
            return (false, "Campaign not funded");
        }
        if (_tranche == 0) {
            return (false, "Kickstart does not need request");
        }
        if (_tranche > NUM_MONTHLY_TRANCHES) {
            return (false, "Invalid tranche");
        }
        if (trancheClaimed[_tranche]) {
            return (false, "Already claimed");
        }
        if (trancheRequestedAt[_tranche] > 0) {
            return (false, "Already requested");
        }
        if (_tranche != campaign.nextTranche) {
            return (false, "Must request in order");
        }
        if (activeChallenge.state == ChallengeState.Pending) {
            return (false, "Challenge pending");
        }
        // Audit fix F5: Align with requestTranche — check lpCreated, not lpWithdrawn
        if (!lpCreated && authorizedRouter != address(0)) {
            return (false, "LP not yet created");
        }
        uint256 unlockTime = getTrancheUnlockTime(_tranche);
        if (_currentTime() < unlockTime) {
            return (false, "Not yet unlocked");
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
    /// @param nonce Sequential nonce for replay protection
    /// @param deadline Signature expiry timestamp
    /// @param signature EIP-712 signature from trusted signer
    function raiseChallenge(string calldata _reason, uint256 nonce, uint256 deadline, bytes calldata signature) external nonReentrant inState(CampaignState.Funded) requiresTermsSignature(nonce, deadline, signature) {
        if (activeChallenge.state == ChallengeState.Pending) revert ChallengePending();

        uint8 tranche = campaign.nextTranche;
        if (tranche > NUM_MONTHLY_TRANCHES) revert InvalidTranche();
        if (tranche == 0) revert InvalidTranche(); // Kickstart cannot be challenged
        if (trancheClaimed[tranche]) revert TrancheAlreadyClaimed(tranche);
        if (trancheChallenged[tranche]) revert TrancheAlreadyChallenged();

        // Per-challenger cooldown to prevent serial challenge griefing
        if (_currentTime() < lastChallengeTime[msg.sender] + CHALLENGE_COOLDOWN) revert ChallengeCooldownActive();

        // Tranche must have been requested by founder (starts 72h challenge window)
        if (trancheRequestedAt[tranche] == 0) revert TrancheNotRequested();

        // Challenge must be raised within the 72h window
        uint256 windowEnd = trancheRequestedAt[tranche] + CHALLENGE_WINDOW;
        if (_currentTime() >= windowEnd) revert ChallengeWindowClosed(); // Audit fix H-01: blocked at-or-after boundary

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
        lastChallengeTime[msg.sender] = _currentTime();

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
    /// @param nonce Sequential nonce for replay protection
    /// @param deadline Signature expiry timestamp
    /// @param signature EIP-712 signature from trusted signer
    function supportChallenge(string calldata _additionalContext, uint256 nonce, uint256 deadline, bytes calldata signature) external inState(CampaignState.Funded) requiresTermsSignature(nonce, deadline, signature) {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();
        require(IERC20(campaign.token).balanceOf(msg.sender) > 0, "Not a token holder");
        uint8 tranche = uint8(activeChallenge.tranche);
        require(challengeVoteDirection[msg.sender][tranche] != 1, "Already voted support");
        challengeVoteDirection[msg.sender][tranche] = 1;
        emit ChallengeSupported(msg.sender, tranche, _additionalContext);
    }

    /// @notice Token holder signals opposition to an active challenge
    /// @dev Caller must hold project tokens. Vote can be changed from oppose to support.
    function opposeChallenge(string calldata _additionalContext, uint256 nonce, uint256 deadline, bytes calldata signature) external inState(CampaignState.Funded) requiresTermsSignature(nonce, deadline, signature) {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();
        require(IERC20(campaign.token).balanceOf(msg.sender) > 0, "Not a token holder");
        uint8 tranche = uint8(activeChallenge.tranche);
        require(challengeVoteDirection[msg.sender][tranche] != 2, "Already voted oppose");
        challengeVoteDirection[msg.sender][tranche] = 2;
        emit ChallengeOpposed(msg.sender, tranche, _additionalContext);
    }

    /// @notice Admin upholds the challenge - freezes campaign
    /// @dev Redeemable supply is now calculated onchain from known locked addresses (audit fix)
    function upholdChallenge() external onlyAdmin {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();

        activeChallenge.state = ChallengeState.Upheld;
        campaign.state = CampaignState.Frozen;
        campaign.snapshotBlock = block.number;

        // Record frozen balances for holder refund calculations
        // Redeemable supply calculated onchain (excludes LP at 0xdead, vesting, staker rewards, router, locker)
        // Audit fix F4: Subtract unclaimed pro-rata excess liability — that ETH belongs to oversubscribed contributors
        // Audit fix M-03: Subtract pendingPlatformFees — those belong to the platform, not holders
        // Audit fix F6: Safe subtraction to prevent underflow revert when balance is depleted
        {
            uint256 liabilities = totalExcessRefundLiability + pendingPlatformFees;
            uint256 balance = address(this).balance;
            frozenEthBalance = balance > liabilities ? balance - liabilities : 0;
        }
        frozenTotalSupply = _calculateRedeemableSupply();
        require(frozenTotalSupply > 0, "No redeemable supply"); // Audit fix: prevent division by zero in claimHolderRefund

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
        _expireChallengeIfNeeded();
    }

    /// @dev Internal version so claimTranche/requestTranche can auto-expire stale challenges
    function _expireChallengeIfNeeded() internal {
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
    /// @dev Redeemable supply is now calculated onchain from known locked addresses (audit fix)
    /// @dev If no tokens are in holder hands (redeemable supply == 0), falls through to Failed
    ///      state to enable contributor refunds — the holder refund flow is impossible without holders.
    /// @param _reason Reason for freezing
    function freezeCampaign(string calldata _reason) external onlyAdmin inState(CampaignState.Funded) {
        if (campaign.nextTranche > NUM_MONTHLY_TRANCHES) revert CampaignCompleteCannotFreeze();

        campaign.snapshotBlock = block.number;
        uint256 redeemableSupply = _calculateRedeemableSupply();

        if (redeemableSupply == 0) {
            // No tokens in holder hands — holder refund flow is impossible.
            // Fall through to Failed state so contributors can claim ETH refunds directly.
            // Audit fix F-1 (2026-04): solvency check — without this, a freeze after
            // `lpWithdrawn` transitions to Failed while the escrow is underfunded, and
            // early claimers of claimContributorRefund() drain the contract, leaving
            // later claimers to revert on insufficient balance. Mirrors emergencyRefundFunded().
            uint256 totalLiability = campaign.totalRaised;
            if (totalExcessRefundLiability > 0) {
                totalLiability -= totalExcessRefundLiability;
            }
            if (pendingPlatformFees > 0) {
                totalLiability -= pendingPlatformFees;
            }
            require(address(this).balance >= totalLiability, "Insufficient balance - top up first");
            campaign.state = CampaignState.Failed;
            emit CampaignFailed(campaign.totalRaised, campaign.goal);
            emit CampaignFrozen(msg.sender, _reason);
        } else {
            // Normal freeze: record snapshot for holder refund calculations
            campaign.state = CampaignState.Frozen;
            // Audit fix F4: Subtract unclaimed pro-rata excess liability — that ETH belongs to oversubscribed contributors
            // Audit fix M-03: Subtract pendingPlatformFees — those belong to the platform, not holders
            // Audit fix F6: Safe subtraction to prevent underflow revert when balance is depleted
            {
                uint256 liabilities = totalExcessRefundLiability + pendingPlatformFees;
                uint256 balance = address(this).balance;
                frozenEthBalance = balance > liabilities ? balance - liabilities : 0;
            }
            frozenTotalSupply = redeemableSupply;
            emit FrozenBalanceRecorded(frozenEthBalance, frozenTotalSupply);
            emit CampaignFrozen(msg.sender, _reason);
        }
    }

    /// @notice Emergency refund for funded raises where finalization failed
    /// @dev Only callable when LP was never created (completeFinalization failed in try/catch).
    ///      Moves state to Failed, enabling claimContributorRefund() for backers.
    ///      Audit fix F3: Requires escrow balance to cover all contributor refund liabilities.
    ///      If lpWithdrawn is true (LP ETH sent to router but LP creation failed), admin must
    ///      first top up the escrow via adminTopUp() before calling this.
    function emergencyRefundFunded() external onlyAdmin inState(CampaignState.Funded) {
        require(!lpCreated, "LP exists - use freezeCampaign instead");

        // Audit fix H-3: Router must not have progressed finalization. Otherwise a partial
        // finalization (e.g. Phase 1 completed but Phase 2 queued) could coexist with an
        // admin-triggered rollback to Failed, opening a token+ETH double-dip window. We
        // call the router's public finalizationPhase() getter via the interface and require
        // it returns 0 (None). Wrapped in try/catch so a misconfigured router fails closed
        // rather than bricking the emergency path entirely (existence of the getter is a
        // mainnet-deployment precondition; testnet legacy routers without the selector fall
        // through to the require).
        try IVibesLaunchRouter(authorizedRouter).finalizationPhase(campaign.token) returns (uint8 phase) {
            require(phase == 0, "Router finalization progressed");
        } catch {
            // Pre-migration router without selector: best-effort fallback — do not block
            // emergency rescue (legacy escrows that never went through two-phase finalize).
        }

        // Audit fix F3: Solvency check — escrow must hold enough ETH to cover all contributor refunds.
        // totalExcessRefundLiability = unclaimed pro-rata excess (those users get reduced refund via F1 fix).
        // pendingPlatformFees = accrued fees not yet claimed (belong to platform, not contributors).
        // Without this check, early claimants succeed but later ones revert on insufficient balance.
        uint256 totalLiability = campaign.totalRaised;
        if (totalExcessRefundLiability > 0) {
            totalLiability -= totalExcessRefundLiability;
        }
        if (pendingPlatformFees > 0) {
            totalLiability -= pendingPlatformFees;
        }
        require(address(this).balance >= totalLiability, "Insufficient balance - top up first");

        campaign.state = CampaignState.Failed;
        emit CampaignFailed(campaign.totalRaised, campaign.goal);
    }

    /// @notice Allow admin to top up escrow ETH for emergency recovery
    /// @dev Audit fix F2: Required when LP ETH was forwarded out during finalize() but campaign
    ///      needs to revert to Failed state. The receive() function intentionally rejects plain
    ///      ETH transfers to prevent accidental sends, so this explicit function is needed.
    event EscrowToppedUp(address indexed sender, uint256 amount);

    function adminTopUp() external payable onlyAdmin {
        require(msg.value > 0, "Zero value");
        emit EscrowToppedUp(msg.sender, msg.value);
    }

    /// @notice Claim accumulated platform fees (pull pattern — audit fix)
    /// @dev Anyone can call, but fees always go to platformWallet. Uses pull pattern so a
    ///      reverting platformWallet cannot block founder tranche claims.
    function claimPlatformFees() external nonReentrant {
        require(
            campaign.state != CampaignState.Frozen &&
            campaign.state != CampaignState.Refunding,
            "Fees locked during refund"
        );
        uint256 fees = pendingPlatformFees;
        require(fees > 0, "No pending fees");

        pendingPlatformFees = 0;

        (bool success, ) = platformWallet.call{value: fees}("");
        require(success, "Fee transfer failed");

        emit PlatformFeesClaimed(msg.sender, fees);
    }

    /// @notice Mark LP as created (called by router after backup finalization resolves LP)
    /// @dev Audit fix H-04: Allows tranche claims after deferred LP is resolved
    function setLPCreated() external {
        if (msg.sender != authorizedRouter) revert OnlyRouter();
        lpCreated = true;
    }

    /// @notice Set known locked contract addresses for redeemable supply calculation
    /// @dev These addresses are excluded when calculating frozenTotalSupply (audit fix)
    /// @param _vestingContract Founder vesting contract address
    /// @param _stakerRewards Staker rewards contract address
    function setLockedAddresses(address _vestingContract, address _stakerRewards) external {
        if (msg.sender != admin && msg.sender != authorizedRouter) revert OnlyAdmin();
        // Audit fix M-02: Prevent overlapping addresses that would double-count excluded balances
        if (_vestingContract != address(0) && _stakerRewards != address(0)) {
            require(_vestingContract != _stakerRewards, "Overlapping locked addresses");
        }
        vestingContract = _vestingContract;
        stakerRewards = _stakerRewards;
        emit LockedAddressesUpdated(_vestingContract, _stakerRewards);
    }

    /// @notice Set the treasury escrow address (audit fix F-2, 2026-04)
    /// @dev Treasury token balance must be excluded from redeemable supply so it does not
    ///      dilute per-holder ETH refunds on freeze. Separate from setLockedAddresses to
    ///      preserve backwards-compatible signatures for existing callers and tests.
    ///      Callable by admin or the authorized router (router wires this during Phase 2).
    /// @param _treasuryContract Treasury escrow address (pass address(0) to unset).
    function setTreasuryContract(address _treasuryContract) external {
        if (msg.sender != admin && msg.sender != authorizedRouter) revert OnlyAdmin();
        // Prevent overlapping addresses that would double-count excluded balances
        if (_treasuryContract != address(0)) {
            require(_treasuryContract != vestingContract, "Overlaps vesting");
            require(_treasuryContract != stakerRewards, "Overlaps stakerRewards");
            require(_treasuryContract != lpLocker, "Overlaps lpLocker");
            require(_treasuryContract != authorizedRouter, "Overlaps router");
            require(_treasuryContract != address(this), "Overlaps escrow");
        }
        treasuryContract = _treasuryContract;
        emit TreasuryContractUpdated(_treasuryContract);
    }

    /// @notice Commit a merkle root for holder refunds (step 1 of 2)
    /// @dev Audit fix F10: 24hr delay between commit and finalize so users can verify the tree.
    ///      A compromised admin cannot instantly set an arbitrary root and drain frozen funds.
    /// @param _merkleRoot Merkle root of holder balances at snapshot
    function commitRefundMerkleRoot(bytes32 _merkleRoot) external onlyAdmin inState(CampaignState.Frozen) {
        require(_merkleRoot != bytes32(0), "Empty merkle root");
        pendingMerkleRoot = _merkleRoot;
        merkleRootCommitTime = block.timestamp;
        emit MerkleRootCommitted(_merkleRoot, block.timestamp);
    }

    /// @notice Finalize the committed merkle root after delay (step 2 of 2)
    /// @dev Transitions to Refunding state. Anyone can call after delay to prevent admin lockout.
    function finalizeRefundMerkleRoot() external inState(CampaignState.Frozen) {
        if (pendingMerkleRoot == bytes32(0)) revert NoPendingMerkleRoot();
        if (block.timestamp < merkleRootCommitTime + MERKLE_ROOT_DELAY) revert MerkleRootDelayNotElapsed();

        campaign.refundMerkleRoot = pendingMerkleRoot;
        campaign.state = CampaignState.Refunding;
        emit RefundMerkleRootSet(pendingMerkleRoot, campaign.snapshotBlock);
        pendingMerkleRoot = bytes32(0);
    }

    /// @notice Cancel a committed merkle root before finalization
    /// @dev Allows admin to correct a wrong commitment without waiting for the delay
    function cancelPendingMerkleRoot() external onlyAdmin inState(CampaignState.Frozen) {
        if (pendingMerkleRoot == bytes32(0)) revert NoPendingMerkleRoot();
        bytes32 cancelled = pendingMerkleRoot;
        pendingMerkleRoot = bytes32(0);
        merkleRootCommitTime = 0;
        emit MerkleRootCancelled(cancelled);
    }

    /// @notice Initiate admin transfer (2-step process)
    /// @param _newAdmin New admin address (must call acceptAdmin() to complete)
    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferInitiated(admin, _newAdmin);
    }

    /// @notice Accept admin transfer (must be called by pending admin)
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert OnlyPendingAdmin();
        emit AdminTransferred(admin, pendingAdmin);
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    // ============ Refund Functions ============

    /// @notice Claim refund for failed raise (contributor refund)
    /// @dev Audit fix F1: For pro-rata raises, subtracts any excess already claimed to prevent double-refund
    function claimContributorRefund() external nonReentrant inState(CampaignState.Failed) {
        Contribution storage contrib = contributions[msg.sender];
        if (contrib.amount == 0) revert NotAContributor();
        if (contrib.refundClaimed) revert AlreadyClaimed();

        uint256 refundAmount = contrib.amount;

        // Audit fix F1: If pro-rata excess was already claimed, subtract it to prevent double-refund.
        // Without this, a contributor who claimed excess before emergency rollback would extract
        // more ETH than they contributed, causing insolvency for later claimants.
        if (contrib.excessClaimed && campaign.raiseType == RaiseType.ProRata && campaign.totalCommitted > campaign.goal) {
            uint256 allocation = (contrib.amount * campaign.goal) / campaign.totalCommitted;
            uint256 excessAlreadyPaid = contrib.amount - allocation;
            refundAmount = refundAmount - excessAlreadyPaid;
        }

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

        // Verify merkle proof (double-hash to prevent leaf/node collision — audit fix C-02)
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(msg.sender, _tokenAmount))));
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
    /// @dev Audit fix F4: Also allowed in Frozen/Refunding state so excess refunds
    ///      aren't absorbed into the holder refund pool
    function claimExcessRefund() external nonReentrant {
        CampaignState state = campaign.state;
        if (state != CampaignState.Funded &&
            state != CampaignState.Completed &&
            state != CampaignState.Frozen &&
            state != CampaignState.Refunding) {
            revert InvalidState(state, CampaignState.Funded);
        }
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

        // Audit fix F4: Decrement excess liability so freeze accounting stays accurate
        // Audit fix C-01: Use min() to prevent underflow from per-user rounding gaps
        uint256 liabilityDeduction = excess > totalExcessRefundLiability ? totalExcessRefundLiability : excess;
        totalExcessRefundLiability -= liabilityDeduction;

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

    /// @notice Post an onchain update (emits event with IPFS CID)
    /// @param ipfsCid IPFS CID pointing to update JSON { title, body, links }
    function postUpdate(string calldata ipfsCid) external {
        if (msg.sender != campaign.founder) revert OnlyFounder();
        if (campaign.state != CampaignState.Funded && campaign.state != CampaignState.Completed) {
            revert InvalidState(campaign.state, CampaignState.Funded);
        }
        emit FounderUpdate(msg.sender, ipfsCid, _currentTime());
    }

    // ============ Receive ============

    /// @notice Reject direct ETH transfers — use contribute() with signature instead
    receive() external payable {
        revert UseContributeFunction();
    }
}
