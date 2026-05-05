// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VibesTokenFactory} from "./VibesTokenFactory.sol";
import {VibesRegistry} from "./VibesRegistry.sol";
import {VibesTranchEscrowFactory} from "./VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "./VibesTranchEscrow.sol";
import {VibesLPLocker} from "./VibesLPLocker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title VibesRouterStorage
 * @notice Abstract contract containing all state variables, events, errors, and modifiers
 *         shared between VibesLaunchRouterV2 and VibesRouterExtension.
 * @dev State variable ordering MUST exactly match the original VibesLaunchRouterV2 layout.
 *      Both the router and extension inherit this so delegatecall storage is aligned.
 */
abstract contract VibesRouterStorage is ReentrancyGuard, Pausable {
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

    event TreasuryCreated(
        address indexed token,
        address indexed treasury,
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

    event TrustedLaunchSignerUpdated(
        address indexed oldSigner,
        address indexed newSigner
    );

    event VibesBurned(
        address indexed founder,
        uint256 amount
    );

    event VibesTokenUpdated(
        address indexed oldToken,
        address indexed newToken
    );

    event LaunchBurnAmountUpdated(
        uint256 oldAmount,
        uint256 newAmount
    );

    // Audit fix F1: LP rescue events
    event LPCreationRescued(address indexed token, address indexed campaign);
    event LPManuallyResolved(address indexed token);
    event OperationsAdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Maximum founder allocation (7.5%)
    uint256 public constant MAX_FOUNDER_ALLOCATION_BPS = 750;

    /// @notice Minimum treasury allocation when enabled (10%)
    uint256 public constant MIN_TREASURY_ALLOCATION_BPS = 1000;

    /// @notice Maximum treasury allocation (17.5%)
    uint256 public constant MAX_TREASURY_ALLOCATION_BPS = 1750;

    /// @notice Maximum combined founder + treasury allocation (20%). Set to
    ///         accommodate the $VIBES raise design (5% founder + 15% treasury)
    ///         while keeping founder-side extraction bounded. Backer protection
    ///         is upheld by MIN_BACKER_ALLOCATION_BPS (50% floor); this cap
    ///         additionally limits the founder-controlled portion to 20%.
    uint256 public constant MAX_FOUNDER_PLUS_TREASURY_BPS = 2000;

    /// @notice Fixed LP allocation (15%)
    uint256 public constant LP_ALLOCATION_BPS = 1500;

    /// @notice Fixed ecosystem/staker allocation (2.5%)
    uint256 public constant ECOSYSTEM_ALLOCATION_BPS = 250;

    /// @notice ETH to LP ratio (15% of raised ETH)
    uint256 public constant ETH_TO_LP_BPS = 1500; // 15%

    /// @notice BPS denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice PC-02: maximum community-rewards allocation per raise (20%).
    ///         Enforced in `setCommunityAllocationForLaunch`. Community rewards must come out
    ///         of founder + treasury + ecosystem room, never out of the backer slice — the
    ///         backer-floor check at launch time enforces this.
    uint256 public constant MAX_COMMUNITY_ALLOCATION_BPS = 2000;

    /// @notice PC-02: minimum backer allocation floor (50%). Enforced at launch time:
    ///         computed `backerBps` must be >= this value or launch reverts. Protects backers
    ///         from any combination of slices that would reduce their share below 50%.
    ///         Existing raises without community allocation always satisfy this (worst case is
    ///         ~57.5% backers). Only raises with an admin-authorized community slice that
    ///         stacks too heavily against backers can trigger the revert.
    uint256 public constant MIN_BACKER_ALLOCATION_BPS = 5000;

    // ============================================
    // STATE — ordering matches original VibesLaunchRouterV2 exactly
    // ============================================

    /// @notice Token factory contract
    VibesTokenFactory public immutable tokenFactory;

    /// @notice Provenance registry contract
    VibesRegistry public immutable registry;

    /// @notice Tranche escrow factory contract
    VibesTranchEscrowFactory public escrowFactory;

    /// @notice LP locker contract
    VibesLPLocker public lpLocker;

    /// @notice Community rewards factory — deploys per-campaign VibesCommunityRewards
    ///         out-of-band to keep the router's runtime bytecode under EIP-170 (24,576 bytes).
    address public communityRewardsFactory;

    /// @notice Owner address for admin functions
    address public owner;

    /// @notice Pending owner for two-step transfer (L6 fix)
    address public pendingOwner;

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

    /// @notice Token to treasury escrow mapping
    mapping(address => address) public tokenToTreasury;

    /// @notice Founder deposit amount (anti-spam)
    uint256 public founderDepositWei = 0.01 ether;

    /// @notice Use testnet-accelerated timings for vesting/treasury contracts
    bool public useTestnetContracts;

    /// @notice Operations admin for day-to-day resolution (challenge resolution, freeze, merkle roots)
    /// Set by master admin (owner). Passed to escrows and treasuries at creation time.
    /// Cannot move user funds — can only freeze, return stakes, or burn to 0xdead.
    address public operationsAdmin;

    /// @notice PC-01: When true, launchWithCampaign skips the 2.5% ecosystem/staker allocation
    ///         entirely and absorbs it into the backer slice. Admin-toggleable via the extension's
    ///         setStakerAllocationDisabled(). Used for the $VIBES TGE and all pre-entity raises;
    ///         admin flips off once the operating entity exists and staking rewards should begin
    ///         accruing. See docs/pending-contract-changes.md PC-01.
    bool public stakerAllocationDisabled;

    /// @notice PC-03: Per-launcher Community Rewards allocation config.
    ///         Admin pre-authorizes specific launcher wallets (e.g., the $VIBES raise launcher)
    ///         via `setCommunityAllocationForLaunch`. When that launcher calls `launchWithCampaign`,
    ///         the router atomically:
    ///           (1) deploys a fresh `VibesCommunityRewards` contract with the newly-deployed
    ///               token, `block.timestamp + cliffDuration` as unlock time, and `communityAdmin`
    ///               as admin,
    ///           (2) transfers `(totalSupply * bps / 10000)` to it,
    ///           (3) records the deployed address in `tokenToCommunityRewards[token]`,
    ///           (4) auto-clears the config (one-shot).
    ///         Other launchers' calls see no entry → no community allocation → standard behaviour.
    ///         See docs/pending-contract-changes.md PC-03.
    struct LaunchCommunityConfig {
        uint256 bps;             // Community-rewards allocation in BPS (max MAX_COMMUNITY_ALLOCATION_BPS)
        uint256 cliffDuration;   // Seconds from launch timestamp until cliff unlock
        address communityAdmin;  // Admin of the newly-deployed VibesCommunityRewards contract
    }
    mapping(address => LaunchCommunityConfig) public communityConfigForLaunch;

    /// @notice PC-03: Deployed VibesCommunityRewards contract per token (queryable).
    mapping(address => address) public tokenToCommunityRewards;

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

    /// @notice Trusted signer for launch authorization (address(0) = gating disabled)
    address public trustedLaunchSigner;

    /// @notice EIP-712 domain separator for launch signature verification
    bytes32 public _launchDomainSeparator;

    /// @notice Initial backer token allocation snapshot (audit fix: order-independent claims)
    mapping(address => uint256) public initialBackerTokens;

    /// @notice Running total of reserved ETH for founder deposits (audit fix: rescueETH liability awareness)
    uint256 public totalReservedDeposits;

    /// @notice LP creation status per token (audit fix F1: deferred LP resolution)
    enum LPStatus {
        None,       // No LP action taken
        Created,    // LP successfully created and locked
        Rescued     // LP creation failed, funds rescued in locker
    }
    mapping(address => LPStatus) public lpStatus;

    /// @notice $VIBES token address for burn-to-launch fee (address(0) = feature disabled)
    IERC20 public vibesToken;

    /// @notice Amount of $VIBES burned per launch (0 = no burn required)
    uint256 public launchBurnAmount;

    /// @notice Sequential per-founder nonce for EIP-712 launch signature replay protection
    mapping(address => uint256) public launchNonces;

    // ============================================
    // FINALIZATION PHASE TRACKING (gas-safe split)
    // ============================================

    /// @notice Tracks which finalization phases have completed per token
    enum FinalizationPhase {
        None,           // Not started (default for all tokens)
        LPComplete,     // Phase 1 done: LP created, pendingLP cleared
        FullyComplete   // Phase 2 done: distribution, claims, deposit refund
    }
    mapping(address => FinalizationPhase) public finalizationPhase;

    /// @notice Cached staker allocation from Phase 1 for use in Phase 2
    mapping(address => uint256) internal _pendingStakerAllocation;

    /// @notice Snapshotted staker rewards destination from Phase 1 (prevents config drift)
    mapping(address => address) internal _pendingStakerRecipient;

    /// @notice Whether staker tokens have been transferred (decoupled from notify for retry safety)
    mapping(address => bool) internal _stakerTokensTransferred;

    // ============================================
    // EVENTS
    // ============================================

    event FinalizationPhase1Complete(address indexed token);
    event FinalizationPhase2Complete(address indexed token);
    event FinalizationRetried(address indexed token, uint8 phase, address indexed caller);
    event StakerRewardsNotifyFailed(address indexed token, bytes reason);
    event DistributionDeferred(address indexed token, bytes reason);
    /// @notice Emitted when the global staker-allocation-disabled flag is flipped by admin.
    event StakerAllocationDisabledSet(bool disabled);
    /// @notice Emitted when a specific raise launches with the staker allocation disabled.
    ///         The 2.5% slice is absorbed into the backer allocation; no tokens flow to
    ///         VibesStakerRewards for this token.
    event StakerAllocationDisabledForLaunch(address indexed token, address indexed escrow);
    /// @notice PC-03: Emitted when admin authorizes or revokes a Community Rewards allocation
    ///         for a specific launcher wallet. `bps = 0` means revoke.
    event CommunityAllocationSet(
        address indexed launcher,
        uint256 bps,
        uint256 cliffDuration,
        address indexed communityAdmin
    );
    /// @notice PC-03: Emitted when a launch consumes its Community Rewards authorization.
    ///         The router atomically deploys a fresh VibesCommunityRewards contract and
    ///         transfers the slice to it; the deployed address is included in the event.
    ///         The authorization is deleted immediately, so the next launch by the same
    ///         wallet gets default (no community) behaviour unless re-authorized.
    event CommunityAllocationConsumed(
        address indexed token,
        address indexed launcher,
        address indexed communityRewards,
        uint256 amount
    );

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
    error CommunityRewardsFactoryNotSet();
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
    error TooManyTokens();
    error InvalidTreasuryAllocation();
    error SignatureExpired();
    error InvalidSignature();
    error LPCreationFailed();
    error TokenHasActiveClaims();   // Audit fix F2: rescueERC20 blocked — pending backer claims
    error TokenHasActiveEscrow();   // Audit fix F2: rescueERC20 blocked — active campaign escrow
    error TokenHasPendingLP();      // Audit fix F2: rescueERC20 blocked — pending LP allocation
    error DistributorDisabled();    // Audit fix F5: createDistributor deprecated
    error NotInRescuedState();      // Audit fix F1: completeLP requires rescued LP status
    error InvalidNonce();
    error Phase1NotComplete();
    error FinalizationAlreadyComplete();
    /// @notice PC-02: Thrown when a launch's computed backer slice would fall below the 50% floor.
    error BackerAllocationTooLow();

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

    constructor(address _tokenFactory, address _registry) {
        if (_tokenFactory == address(0)) revert ZeroAddress();
        if (_registry == address(0)) revert ZeroAddress();
        tokenFactory = VibesTokenFactory(_tokenFactory);
        registry = VibesRegistry(_registry);
    }
}
