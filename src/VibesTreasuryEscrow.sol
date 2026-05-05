// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VibesVesting} from "./VibesVesting.sol";

/// @title VibesTreasuryEscrow
/// @notice Proposal-based token escrow for project treasury allocations.
/// @dev Configurable cliff from activation. After cliff, founder requests withdrawals
///      (max 10% per request, configurable cooldown).
///      Each request opens a challenge window. Challenges have 4 outcomes:
///      1. UpheldRework — proposal blocked, founder can rework (cooldown)
///      2. UpheldMalicious — treasury burned, founder vesting frozen (nuclear option)
///      3. Rejected — challenger slashed 20%, proposal proceeds
///      4. Expired — admin didn't act in challenge window, full stake returned, proposal proceeds
///      Mainnet: 180-day cliff, 14-day cooldown, 72-hour challenge window.
///      Testnet: 6-day cliff, 2-hour cooldown, 2-hour challenge window.
contract VibesTreasuryEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum ProposalState {
        None,
        Pending,       // Founder requested, 72hr challenge window open
        Challenged,    // Challenge raised, awaiting admin review
        Executed,      // Tokens released to founder
        Blocked,       // Challenge upheld (rework), proposal blocked
        Terminated     // Challenge upheld (malicious), treasury burned
    }

    enum ChallengeState {
        None,
        Pending,          // Challenge raised, awaiting admin
        UpheldRework,     // Admin upheld — needs rework, stake returned
        UpheldMalicious,  // Admin upheld — malicious/abandoned, treasury burned
        Rejected          // Admin rejected — challenger slashed 20%
    }

    // ============ Structs ============

    struct Proposal {
        uint256 amount;            // Tokens requested
        bytes32 reasonHash;        // IPFS CID or reason hash
        uint256 timestamp;         // When proposal was created
        ProposalState state;
    }

    struct Challenge {
        address challenger;
        string reason;
        uint256 amount;            // Tokens staked
        uint256 timestamp;
        ChallengeState state;
    }

    // ============ Constants ============

    uint256 public constant MAX_CLAIM_BPS = 1000;              // 10% of current balance per request
    uint256 public constant CHALLENGE_THRESHOLD_BPS = 50;      // 0.5% of token supply to challenge
    uint256 public constant CHALLENGE_SLASH_BPS = 2000;        // 20% of stake slashed on rejected challenge
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Immutables (configurable per deployment) ============

    /// @notice Cliff before any withdrawals (mainnet: 180 days, testnet: 6 days)
    uint256 public immutable RELEASE_CLIFF;

    /// @notice Cooldown between claims (mainnet: 14 days, testnet: 2 hours)
    uint256 public immutable COOLDOWN;

    /// @notice Challenge window duration (mainnet: 72 hours, testnet: 2 hours)
    uint256 public immutable CHALLENGE_WINDOW;

    // ============ State ============

    IERC20 public immutable token;
    address public founder;
    address public admin;
    address public pendingAdmin;

    bool public active;
    bool public terminated;
    uint256 public activatedAt;
    address public immutable authorizedStarter;

    /// @notice Linked vesting contract (frozen on malicious upheld)
    address public vestingContract;

    Proposal public currentProposal;
    uint256 public proposalCount;

    Challenge public activeChallenge;

    uint256 public lastClaimTime;
    uint256 public totalWithdrawn;

    /// @notice Audit fix F6: True after a challenge on the current proposal was rejected/expired.
    ///         Blocks further challenges on the same proposal and allows immediate execution.
    bool public proposalChallengeResolved;

    // ============ Events ============

    event TreasuryActivated(uint256 balance);
    event ProposalCreated(uint256 indexed proposalId, uint256 amount, bytes32 reasonHash);
    event ProposalExecuted(uint256 indexed proposalId, uint256 amount);
    event ProposalBlocked(uint256 indexed proposalId);
    event TreasuryTerminated(uint256 indexed proposalId, uint256 burnedAmount);

    event ChallengeRaised(address indexed challenger, uint256 indexed proposalId, uint256 stake, string reason);
    event ChallengeUpheldRework(address indexed challenger, uint256 indexed proposalId);
    event ChallengeUpheldMalicious(address indexed challenger, uint256 indexed proposalId, uint256 burnedAmount);
    event ChallengeRejected(address indexed challenger, uint256 indexed proposalId, uint256 slashed);
    event ChallengeSupported(address indexed supporter, uint256 indexed proposalId, string context);
    event ChallengeExpired(uint256 indexed proposalId);

    event VestingLinked(address indexed vestingContract);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ============ Errors ============

    error OnlyAdmin();
    error OnlyFounder();
    error OnlyPendingAdmin();
    error ZeroAddress();
    error AlreadyActive();
    error NotActive();
    error NoTokensDeposited();
    error ProposalAlreadyActive();
    error NoActiveProposal();
    error CooldownNotElapsed();
    error ExceedsMaxClaim();
    error AmountZero();
    error ChallengeWindowOpen();
    error ChallengeWindowClosed();
    error ChallengePending();
    error NoChallengeActive();
    error InsufficientTokensToChallenge();
    error ProposalNotPending();
    error ProposalNotChallenged();
    error InsufficientBalance();
    error OnlyAuthorizedStarter();
    error TreasuryIsTerminated();
    error ReleaseCliffNotElapsed();
    error ChallengeAlreadyResolved();  // Audit fix F6: max 1 challenge per proposal

    // ============ Modifiers ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyFounder() {
        if (msg.sender != founder) revert OnlyFounder();
        _;
    }

    modifier onlyActive() {
        if (!active) revert NotActive();
        if (terminated) revert TreasuryIsTerminated();
        _;
    }

    // ============ Constructor ============

    /**
     * @param _token Token address
     * @param _founder Founder address
     * @param _admin Platform admin address
     * @param _releaseCliff Cliff before withdrawals (mainnet: 180 days, testnet: 6 days)
     * @param _cooldown Cooldown between claims (mainnet: 14 days, testnet: 2 hours)
     * @param _challengeWindow Challenge window duration (mainnet: 72 hours, testnet: 2 hours)
     */
    constructor(
        address _token,
        address _founder,
        address _admin,
        uint256 _releaseCliff,
        uint256 _cooldown,
        uint256 _challengeWindow
    ) {
        if (_token == address(0)) revert ZeroAddress();
        if (_founder == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        token = IERC20(_token);
        founder = _founder;
        admin = _admin;
        RELEASE_CLIFF = _releaseCliff;
        COOLDOWN = _cooldown;
        CHALLENGE_WINDOW = _challengeWindow;
        authorizedStarter = msg.sender;
    }

    // ============ Activation ============

    /// @notice Activate the treasury after tokens have been deposited
    function activate() external {
        if (msg.sender != authorizedStarter) revert OnlyAuthorizedStarter();
        if (active) revert AlreadyActive();

        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NoTokensDeposited();

        active = true;
        activatedAt = block.timestamp;
        emit TreasuryActivated(balance);
    }

    /// @notice Link the founder vesting contract (frozen on malicious upheld)
    function setVestingContract(address _vesting) external {
        if (msg.sender != authorizedStarter) revert OnlyAuthorizedStarter();
        if (_vesting == address(0)) revert ZeroAddress();
        vestingContract = _vesting;
        emit VestingLinked(_vesting);
    }

    // ============ Proposal Functions ============

    /// @notice Create a withdrawal proposal
    /// @param _amount Tokens to withdraw (max 10% of current balance)
    /// @param _reasonHash IPFS CID or hash of reason/plan
    function createProposal(uint256 _amount, bytes32 _reasonHash) external onlyFounder onlyActive nonReentrant {
        if (_amount == 0) revert AmountZero();
        if (currentProposal.state == ProposalState.Pending ||
            currentProposal.state == ProposalState.Challenged) revert ProposalAlreadyActive();

        // Enforce 6-month cliff from activation
        if (block.timestamp < activatedAt + RELEASE_CLIFF) revert ReleaseCliffNotElapsed();

        // Enforce cooldown (skip for first proposal)
        if (lastClaimTime > 0) {
            if (block.timestamp < lastClaimTime + COOLDOWN) revert CooldownNotElapsed();
        }

        // Enforce 10% max of current balance
        uint256 balance = token.balanceOf(address(this));
        uint256 maxAmount = (balance * MAX_CLAIM_BPS) / BPS_DENOMINATOR;
        if (_amount > maxAmount) revert ExceedsMaxClaim();
        if (_amount > balance) revert InsufficientBalance();

        proposalCount++;
        proposalChallengeResolved = false; // Audit fix F6: reset for new proposal

        currentProposal = Proposal({
            amount: _amount,
            reasonHash: _reasonHash,
            timestamp: block.timestamp,
            state: ProposalState.Pending
        });

        emit ProposalCreated(proposalCount, _amount, _reasonHash);
    }

    /// @notice Execute proposal after challenge window passes unchallenged
    /// @dev Audit fix F6: If challenge was already rejected/expired, skip the window — execute immediately
    function executeProposal() external onlyActive nonReentrant {
        if (currentProposal.state != ProposalState.Pending) revert ProposalNotPending();
        // Audit fix F6: Only enforce window if no challenge has been resolved on this proposal
        if (!proposalChallengeResolved) {
            if (block.timestamp < currentProposal.timestamp + CHALLENGE_WINDOW) revert ChallengeWindowOpen();
        }

        currentProposal.state = ProposalState.Executed;
        lastClaimTime = block.timestamp;
        totalWithdrawn += currentProposal.amount;

        token.safeTransfer(founder, currentProposal.amount);

        emit ProposalExecuted(proposalCount, currentProposal.amount);
    }

    // ============ Challenge Functions ============

    /// @notice Challenge the current pending proposal
    /// @dev Audit fix F6: Only one challenge allowed per proposal. After rejection/expiry,
    ///      the proposal becomes immediately executable — no further challenges.
    /// @param _reason Why the proposal should be blocked
    function raiseChallenge(string calldata _reason) external onlyActive nonReentrant {
        if (currentProposal.state != ProposalState.Pending) revert ProposalNotPending();
        if (activeChallenge.state == ChallengeState.Pending) revert ChallengePending();
        if (proposalChallengeResolved) revert ChallengeAlreadyResolved(); // Audit fix F6

        // Audit fix M-3: Close window at `>=` so the exact boundary block cannot be both
        // challenged and executed. Matches VibesTranchEscrow's asymmetric boundary pattern
        // and the `timeUntilExecutable` view getter at :466 which already uses `>=`.
        uint256 windowEnd = currentProposal.timestamp + CHALLENGE_WINDOW;
        if (block.timestamp >= windowEnd) revert ChallengeWindowClosed();

        uint256 totalSupply = token.totalSupply();
        uint256 requiredTokens = (totalSupply * CHALLENGE_THRESHOLD_BPS) / BPS_DENOMINATOR;
        uint256 challengerBalance = token.balanceOf(msg.sender);
        if (challengerBalance < requiredTokens) revert InsufficientTokensToChallenge();

        token.safeTransferFrom(msg.sender, address(this), requiredTokens);

        currentProposal.state = ProposalState.Challenged;

        activeChallenge = Challenge({
            challenger: msg.sender,
            reason: _reason,
            amount: requiredTokens,
            timestamp: block.timestamp,
            state: ChallengeState.Pending
        });

        emit ChallengeRaised(msg.sender, proposalCount, requiredTokens, _reason);
    }

    /// @notice Support an existing challenge with additional context
    function supportChallenge(string calldata _context) external onlyActive {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();
        require(token.balanceOf(msg.sender) > 0, "Not a token holder");
        emit ChallengeSupported(msg.sender, proposalCount, _context);
    }

    /// @notice Admin upholds (rework) — proposal blocked, stake returned, 14-day cooldown
    /// @dev Founder's request wasn't malicious but needs reworking. They can try again after cooldown.
    // Audit fix M-2: nonReentrant for defense-in-depth against future non-vanilla project tokens.
    function upholdChallengeRework() external onlyAdmin nonReentrant {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();

        activeChallenge.state = ChallengeState.UpheldRework;
        currentProposal.state = ProposalState.Blocked;

        // Set cooldown so founder must wait 14 days before resubmitting
        lastClaimTime = block.timestamp;

        token.safeTransfer(activeChallenge.challenger, activeChallenge.amount);

        emit ChallengeUpheldRework(activeChallenge.challenger, proposalCount);
        emit ProposalBlocked(proposalCount);
    }

    /// @notice Admin upholds (malicious/abandoned) — treasury burned, vesting frozen, stake returned
    /// @dev Nuclear option. Founder acted maliciously or abandoned project.
    // Audit fix M-2: nonReentrant for defense-in-depth.
    function upholdChallengeMalicious() external onlyAdmin nonReentrant {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();

        activeChallenge.state = ChallengeState.UpheldMalicious;
        currentProposal.state = ProposalState.Terminated;
        terminated = true;

        // Return stake to challenger first
        token.safeTransfer(activeChallenge.challenger, activeChallenge.amount);

        // Burn all remaining treasury tokens
        uint256 burnAmount = token.balanceOf(address(this));
        if (burnAmount > 0) {
            token.safeTransfer(address(0xdead), burnAmount);
        }

        // Freeze founder vesting if linked
        if (vestingContract != address(0)) {
            VibesVesting(vestingContract).freeze();
        }

        emit ChallengeUpheldMalicious(activeChallenge.challenger, proposalCount, burnAmount);
        emit TreasuryTerminated(proposalCount, burnAmount);
    }

    /// @notice Admin rejects — challenger slashed 20%, proposal re-enters pending
    /// @dev Audit fix F6: No longer resets the challenge window. Sets proposalChallengeResolved
    ///      so the proposal becomes immediately executable and cannot be re-challenged.
    // Audit fix M-2: nonReentrant for defense-in-depth.
    function rejectChallenge() external onlyAdmin nonReentrant {
        if (activeChallenge.state != ChallengeState.Pending) revert NoChallengeActive();

        activeChallenge.state = ChallengeState.Rejected;
        currentProposal.state = ProposalState.Pending;
        // Audit fix F6: Do NOT reset timestamp — proposal keeps its original window
        proposalChallengeResolved = true; // Block further challenges, allow immediate execution

        uint256 slashAmount = (activeChallenge.amount * CHALLENGE_SLASH_BPS) / BPS_DENOMINATOR;
        uint256 returnAmount = activeChallenge.amount - slashAmount;

        token.safeTransfer(address(0xdead), slashAmount);
        token.safeTransfer(activeChallenge.challenger, returnAmount);

        emit ChallengeRejected(activeChallenge.challenger, proposalCount, slashAmount);
    }

    /// @notice Auto-expire challenge if admin hasn't acted within 72 hours
    /// @dev Audit fix F6: No longer resets the challenge window. Sets proposalChallengeResolved
    ///      so the proposal becomes immediately executable and cannot be re-challenged.
    // Audit fix M-2: nonReentrant for defense-in-depth. Permissionless (anyone can expire).
    function expireChallengeIfNeeded() external nonReentrant {
        if (activeChallenge.state != ChallengeState.Pending) return;

        if (block.timestamp > activeChallenge.timestamp + CHALLENGE_WINDOW) {
            activeChallenge.state = ChallengeState.Rejected;
            currentProposal.state = ProposalState.Pending;
            // Audit fix F6: Do NOT reset timestamp
            proposalChallengeResolved = true; // Block further challenges, allow immediate execution

            token.safeTransfer(activeChallenge.challenger, activeChallenge.amount);

            emit ChallengeExpired(proposalCount);
        }
    }

    // ============ Admin Functions ============

    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferInitiated(admin, _newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert OnlyPendingAdmin();
        emit AdminTransferred(admin, pendingAdmin);
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    // ============ View Functions ============

    function treasuryBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function maxClaimable() external view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        return (balance * MAX_CLAIM_BPS) / BPS_DENOMINATOR;
    }

    function canCreateProposal() external view returns (bool, string memory) {
        if (terminated) return (false, "Treasury terminated");
        if (!active) return (false, "Treasury not active");
        if (block.timestamp < activatedAt + RELEASE_CLIFF) return (false, "Release cliff not elapsed (6 months)");
        if (currentProposal.state == ProposalState.Pending) return (false, "Proposal already pending");
        if (currentProposal.state == ProposalState.Challenged) return (false, "Proposal challenged");
        if (lastClaimTime > 0 && block.timestamp < lastClaimTime + COOLDOWN) {
            return (false, "Cooldown period active");
        }
        if (token.balanceOf(address(this)) == 0) return (false, "Treasury empty");
        return (true, "");
    }

    function canExecuteProposal() external view returns (bool, string memory) {
        if (currentProposal.state != ProposalState.Pending) return (false, "No pending proposal");
        // Audit fix L-04: If challenge was resolved, proposal is immediately executable
        if (proposalChallengeResolved) return (true, "");
        if (block.timestamp < currentProposal.timestamp + CHALLENGE_WINDOW) {
            return (false, "Challenge window still open");
        }
        return (true, "");
    }

    function cliffRemaining() external view returns (uint256) {
        if (!active) return RELEASE_CLIFF;
        uint256 cliffEnd = activatedAt + RELEASE_CLIFF;
        if (block.timestamp >= cliffEnd) return 0;
        return cliffEnd - block.timestamp;
    }

    function cooldownRemaining() external view returns (uint256) {
        if (lastClaimTime == 0) return 0;
        uint256 cooldownEnd = lastClaimTime + COOLDOWN;
        if (block.timestamp >= cooldownEnd) return 0;
        return cooldownEnd - block.timestamp;
    }

    function challengeWindowRemaining() external view returns (uint256) {
        if (currentProposal.state != ProposalState.Pending) return 0;
        uint256 windowEnd = currentProposal.timestamp + CHALLENGE_WINDOW;
        if (block.timestamp >= windowEnd) return 0;
        return windowEnd - block.timestamp;
    }

    function getTreasuryStatus() external view returns (
        uint256 _balance,
        uint256 _totalWithdrawn,
        uint256 _proposalCount,
        uint256 _lastClaimTime,
        bool _active,
        bool _terminated,
        ProposalState _proposalState,
        ChallengeState _challengeState
    ) {
        return (
            token.balanceOf(address(this)),
            totalWithdrawn,
            proposalCount,
            lastClaimTime,
            active,
            terminated,
            currentProposal.state,
            activeChallenge.state
        );
    }

    function getProposal() external view returns (
        uint256 _amount,
        bytes32 _reasonHash,
        uint256 _timestamp,
        ProposalState _state
    ) {
        return (
            currentProposal.amount,
            currentProposal.reasonHash,
            currentProposal.timestamp,
            currentProposal.state
        );
    }

    function getChallenge() external view returns (
        address _challenger,
        string memory _reason,
        uint256 _amount,
        uint256 _timestamp,
        ChallengeState _state
    ) {
        return (
            activeChallenge.challenger,
            activeChallenge.reason,
            activeChallenge.amount,
            activeChallenge.timestamp,
            activeChallenge.state
        );
    }
}
