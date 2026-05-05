// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VibesStaking
 * @notice Staking contract for $VIBES token holders to earn rewards from platform raises
 * @dev Stakers receive 2.5% of every new vibetoken launched on the platform, proportional to their stake.
 *      Features:
 *      - 7-day unstake cooldown to prevent flash-stake attacks
 *      - Events for off-chain indexing and snapshot generation
 *      - Simple stake/unstake mechanics
 */
contract VibesStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a user stakes VIBES tokens
    /// @param staker Address of the staker
    /// @param amount Amount staked in this transaction
    /// @param newBalance Total staked balance after this stake
    event Staked(address indexed staker, uint256 amount, uint256 newBalance);

    /// @notice Emitted when a user unstakes VIBES tokens
    /// @param staker Address of the staker
    /// @param amount Amount unstaked
    /// @param newBalance Total staked balance after this unstake
    event Unstaked(address indexed staker, uint256 amount, uint256 newBalance);

    /// @notice Emitted when a user requests to unstake (starts cooldown)
    /// @param staker Address of the staker
    /// @param cooldownEndsAt When the cooldown expires
    event UnstakeRequested(address indexed staker, uint256 cooldownEndsAt);

    /// @notice Emitted when an unstake request is cancelled (by staking more)
    /// @param staker Address of the staker
    event UnstakeRequestCancelled(address indexed staker);

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Cooldown period before unstaking is allowed (7 days)
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice EIP-712 typehash for terms acceptance (includes nonce for replay protection)
    bytes32 public constant TERMS_TYPEHASH = keccak256("TermsAcceptance(address user,uint256 nonce,uint256 deadline)");

    // ============================================
    // STATE
    // ============================================

    /// @notice The VIBES token contract
    IERC20 public immutable vibesToken;

    /// @notice EIP-712 domain separator
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice Backend signer for terms acceptance (address(0) = gating disabled)
    address public trustedSigner;

    /// @notice Staked balance per address
    mapping(address => uint256) public stakedBalance;

    /// @notice Timestamp of last stake action per address (informational, not used for cooldown)
    mapping(address => uint256) public lastStakeTime;

    /// @notice Timestamp when unstake was requested per address (0 = no active request)
    /// @dev Cooldown is calculated from this timestamp. Cleared when user stakes more.
    mapping(address => uint256) public unstakeRequestTime;

    /// @notice Timestamp when staker first opened their position (0 → nonzero balance)
    /// @dev Only set on initial stake or re-stake after full unstake. Used by StakerRewards
    ///      to determine reward eligibility — stakers must have been staking before a raise
    ///      finalized to claim rewards for that raise.
    mapping(address => uint256) public firstStakeTime;

    /// @notice Total VIBES tokens staked across all stakers
    uint256 public totalStaked;

    /// @notice Sequential per-user nonce for EIP-712 replay protection
    mapping(address => uint256) public nonces;

    // ============================================
    // SNAPSHOT STATE (Audit fix F4)
    // ============================================

    /// @notice Current snapshot ID (incremented by takeSnapshot)
    uint256 public currentSnapshotId;

    /// @notice Total staked at each snapshot
    mapping(uint256 => uint256) public snapshotTotalStaked;

    /// @notice Per-user staked balance at each snapshot (lazy — written on first balance change after snapshot)
    mapping(uint256 => mapping(address => uint256)) public snapshotBalance;

    /// @notice Whether a user's balance has been recorded for a given snapshot
    mapping(uint256 => mapping(address => bool)) public snapshotBalanceWritten;

    /// @notice The last snapshot ID at which each user's balance was written
    /// @dev Post-fix invariant (2026-04 snapshot hardening): all snapshot IDs
    ///      1..lastSnapshotWritten[user] have snapshotBalanceWritten[s][user] = true,
    ///      because _writeSnapshotsBeforeBalanceChange writes eagerly across the
    ///      whole range. For snapshot IDs > lastSnapshotWritten[user], the user's
    ///      balance hasn't changed since that snapshot, so their current
    ///      stakedBalance is their balance at all those snapshots.
    mapping(address => uint256) public lastSnapshotWritten;

    /// @notice Contracts authorized to call takeSnapshot()
    mapping(address => bool) public snapshotAuthorized;

    // ============================================
    // ERRORS
    // ============================================

    error ZeroAmount();
    error InsufficientBalance();
    error CooldownActive(uint256 cooldownEndsAt);
    error UnstakeNotRequested();
    error NothingStaked();
    error SignatureExpired();
    error InvalidSignature();
    error InvalidNonce();
    error NotSnapshotAuthorized();

    event TrustedSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event SnapshotTaken(uint256 indexed snapshotId, uint256 totalStaked);
    event SnapshotAuthorizationUpdated(address indexed account, bool authorized);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Initialize the staking contract
    /// @param _vibesToken Address of the VIBES token contract
    /// @param _trustedSigner Backend signer for terms acceptance (address(0) = gating disabled)
    constructor(address _vibesToken, address _trustedSigner) Ownable(msg.sender) {
        require(_vibesToken != address(0), "Invalid token address");
        vibesToken = IERC20(_vibesToken);
        trustedSigner = _trustedSigner;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("VibesStaking"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ============================================
    // STAKING FUNCTIONS
    // ============================================

    // ============================================
    // EIP-712 SIGNATURE VERIFICATION
    // ============================================

    function _verifyTermsSignature(address user, uint256 nonce, uint256 deadline, bytes calldata signature) internal {
        if (trustedSigner == address(0)) return;

        if (nonce != nonces[user]) revert InvalidNonce();
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash = keccak256(abi.encode(TERMS_TYPEHASH, user, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        address recovered = ECDSA.recover(digest, signature);
        if (recovered != trustedSigner) revert InvalidSignature();

        nonces[user]++;
    }

    /// @notice Update the trusted signer address (owner only)
    /// @param _newSigner New signer address (address(0) disables gating)
    function setTrustedSigner(address _newSigner) external onlyOwner {
        address oldSigner = trustedSigner;
        trustedSigner = _newSigner;
        emit TrustedSignerUpdated(oldSigner, _newSigner);
    }

    // ============================================
    // SNAPSHOT FUNCTIONS (Audit fix F4)
    // ============================================

    /// @notice Authorize or revoke an address to call takeSnapshot()
    function setSnapshotAuthorized(address account, bool authorized) external onlyOwner {
        snapshotAuthorized[account] = authorized;
        emit SnapshotAuthorizationUpdated(account, authorized);
    }

    /// @notice Take a snapshot of the current staking state
    /// @dev Called by StakerRewards (or router) atomically during notifyReward().
    ///      Records totalStaked. Per-user balances are lazily captured on next balance change.
    /// @return snapshotId The new snapshot ID
    function takeSnapshot() external returns (uint256) {
        if (!snapshotAuthorized[msg.sender]) revert NotSnapshotAuthorized();

        currentSnapshotId++;
        snapshotTotalStaked[currentSnapshotId] = totalStaked;

        emit SnapshotTaken(currentSnapshotId, totalStaked);
        return currentSnapshotId;
    }

    /// @notice Get a staker's balance at a specific snapshot
    /// @dev If the user's balance was written for this snapshot, return it.
    ///      Otherwise, their balance hasn't changed since the snapshot — return current balance.
    ///      If snapshotId is 0 or doesn't exist, returns 0.
    /// @param snapshotId Snapshot ID to query
    /// @param staker Address to query
    /// @return balance Staker's balance at the snapshot
    function balanceAtSnapshot(uint256 snapshotId, address staker) external view returns (uint256) {
        if (snapshotId == 0 || snapshotId > currentSnapshotId) return 0;

        // If balance was explicitly written for this snapshot, use it
        if (snapshotBalanceWritten[snapshotId][staker]) {
            return snapshotBalance[snapshotId][staker];
        }

        // Balance hasn't changed since this snapshot — current balance is accurate
        // But only if the user was staking at the time (check lastSnapshotWritten)
        // If user's last write was AFTER this snapshot, we need to find the right value.
        // Since we write lazily on balance change, if written[snapshotId] is false,
        // then the user's balance at snapshotId == their balance at the time they
        // next changed it. We use _findSnapshotBalance for this.
        return _findSnapshotBalance(snapshotId, staker);
    }

    /// @notice Get totalStaked at a specific snapshot
    function totalStakedAtSnapshot(uint256 snapshotId) external view returns (uint256) {
        if (snapshotId == 0 || snapshotId > currentSnapshotId) return 0;
        return snapshotTotalStaked[snapshotId];
    }

    /// @dev Find a staker's balance at a snapshot when no entry was explicitly written
    ///      for that snapshot ID. Audit fix (2026-04, snapshot hardening): bounded by
    ///      lastSnapshotWritten[staker] rather than currentSnapshotId.
    ///      Post-fix, _writeSnapshotsBeforeBalanceChange writes every snapshot up to
    ///      lastSnapshotWritten eagerly, so the only unwritten case for snapshotId <
    ///      lastSnapshotWritten is legacy data — and the walk terminates at the first
    ///      written slot. For snapshotId >= lastSnapshotWritten, the user's balance
    ///      hasn't changed since, so current balance is correct (O(1)).
    function _findSnapshotBalance(uint256 snapshotId, address staker) internal view returns (uint256) {
        uint256 lastWritten = lastSnapshotWritten[staker];

        // Snapshots after the user's last balance change reflect current balance
        // (no change has occurred). This is the hot path for active stakers.
        if (snapshotId >= lastWritten) {
            return stakedBalance[staker];
        }

        // Bounded fallback for legacy data: walk forward only to lastWritten
        // (strictly tighter than the pre-fix bound of currentSnapshotId).
        // For new data with eager writes, this terminates in 1 iteration since
        // the next slot is always populated.
        for (uint256 i = snapshotId + 1; i <= lastWritten; i++) {
            if (snapshotBalanceWritten[i][staker]) {
                return snapshotBalance[i][staker];
            }
        }

        // Defensive: with eager writes the loop above always terminates with a hit.
        // Reaching here implies legacy data with no writes between snapshotId+1
        // and lastWritten, which means the user's balance at snapshotId equals
        // their current balance.
        return stakedBalance[staker];
    }

    /// @dev Write the user's CURRENT balance to every unwritten snapshot since their
    ///      last balance change. Audit fix (2026-04, snapshot hardening): pre-fix this
    ///      function only wrote the LATEST unwritten snapshot, leaving intermediates
    ///      blank and forcing _findSnapshotBalance to walk forward at read time. Walks
    ///      from a state-changing path (claimRewards in VibesStakerRewards) made the
    ///      cost grow O(snapshotCount) on every first-time claim per raise, eventually
    ///      DOS'ing claims as snapshot count grew. Eager writes here pay the cost
    ///      bounded by the user's own activity (their next stake/unstake/claim) and
    ///      keep balanceAtSnapshot O(1) on the read path.
    function _writeSnapshotsBeforeBalanceChange(address staker) internal {
        uint256 lastWritten = lastSnapshotWritten[staker];
        uint256 current = currentSnapshotId;

        if (current == 0 || lastWritten >= current) return; // No new snapshots to write

        uint256 currentBalance = stakedBalance[staker];
        // Eager: write current balance to every snapshot since last write so the
        // read path can be O(1). Skip already-written slots to remain idempotent
        // (defensive against partial-state from any future migration).
        for (uint256 i = lastWritten + 1; i <= current; i++) {
            if (!snapshotBalanceWritten[i][staker]) {
                snapshotBalance[i][staker] = currentBalance;
                snapshotBalanceWritten[i][staker] = true;
            }
        }

        lastSnapshotWritten[staker] = current;
    }

    /**
     * @notice Stake VIBES tokens to earn rewards from platform raises
     * @dev Transfers tokens from sender to this contract. Clears any pending unstake request.
     * @param amount Amount of VIBES tokens to stake
     * @param nonce Sequential nonce for replay protection
     * @param deadline Signature expiry timestamp
     * @param signature EIP-712 signature from trusted signer
     */
    function stake(uint256 amount, uint256 nonce, uint256 deadline, bytes calldata signature) external nonReentrant {
        _verifyTermsSignature(msg.sender, nonce, deadline, signature);
        if (amount == 0) revert ZeroAmount();

        // Transfer tokens to this contract
        vibesToken.safeTransferFrom(msg.sender, address(this), amount);

        // Audit fix F4: Record pre-change balance for any pending snapshots
        _writeSnapshotsBeforeBalanceChange(msg.sender);

        // Track when staking position was first opened (for reward eligibility)
        if (stakedBalance[msg.sender] == 0) {
            firstStakeTime[msg.sender] = block.timestamp;
        }

        // Clear any pending unstake request (staking more = recommitment)
        if (unstakeRequestTime[msg.sender] != 0) {
            unstakeRequestTime[msg.sender] = 0;
            emit UnstakeRequestCancelled(msg.sender);
        }

        // Update state
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
        lastStakeTime[msg.sender] = block.timestamp;

        emit Staked(msg.sender, amount, stakedBalance[msg.sender]);
    }

    /**
     * @notice Request to unstake — starts the 7-day cooldown
     * @dev Cooldown only begins when explicitly requested, not on stake.
     *      Staking more tokens during cooldown cancels the request.
     */
    function requestUnstake() external {
        if (stakedBalance[msg.sender] == 0) revert NothingStaked();

        unstakeRequestTime[msg.sender] = block.timestamp;
        emit UnstakeRequested(msg.sender, block.timestamp + UNSTAKE_COOLDOWN);
    }

    /**
     * @notice Unstake VIBES tokens after cooldown has elapsed
     * @dev Requires requestUnstake() to have been called at least 7 days ago.
     *      After cooldown, user can unstake any amount any number of times
     *      until they stake again (which clears the request).
     * @param amount Amount of VIBES tokens to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (stakedBalance[msg.sender] < amount) revert InsufficientBalance();

        // Must have an active unstake request
        uint256 requestedAt = unstakeRequestTime[msg.sender];
        if (requestedAt == 0) revert UnstakeNotRequested();

        // Check cooldown (must wait 7 days since unstake request)
        uint256 cooldownEndsAt = requestedAt + UNSTAKE_COOLDOWN;
        if (block.timestamp < cooldownEndsAt) {
            revert CooldownActive(cooldownEndsAt);
        }

        // Audit fix F4: Record pre-change balance for any pending snapshots
        _writeSnapshotsBeforeBalanceChange(msg.sender);

        // Update state
        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;

        // Reset firstStakeTime and unstakeRequestTime when fully unstaked
        if (stakedBalance[msg.sender] == 0) {
            firstStakeTime[msg.sender] = 0;
            unstakeRequestTime[msg.sender] = 0;
        }

        // Transfer tokens back to user
        vibesToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount, stakedBalance[msg.sender]);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get staking info for an address
     * @param staker Address to query
     * @return balance Current staked balance
     * @return lastStake Timestamp of last stake action
     * @return cooldownEndsAt When unstaking becomes available (0 if no request pending)
     * @return canUnstake Whether the staker can currently unstake
     * @return firstStake Timestamp when staking position was first opened
     * @return unstakeRequested Whether an unstake request is active
     */
    function getStakingInfo(address staker) external view returns (
        uint256 balance,
        uint256 lastStake,
        uint256 cooldownEndsAt,
        bool canUnstake,
        uint256 firstStake,
        bool unstakeRequested
    ) {
        balance = stakedBalance[staker];
        lastStake = lastStakeTime[staker];
        firstStake = firstStakeTime[staker];

        uint256 requestedAt = unstakeRequestTime[staker];
        unstakeRequested = requestedAt != 0;

        if (unstakeRequested) {
            cooldownEndsAt = requestedAt + UNSTAKE_COOLDOWN;
            canUnstake = block.timestamp >= cooldownEndsAt && balance > 0;
        } else {
            cooldownEndsAt = 0;
            canUnstake = false;
        }
    }

    /**
     * @notice Calculate a staker's share of the total staked pool
     * @param staker Address to query
     * @return shareBps Share in basis points (0-10000)
     */
    function getStakerShare(address staker) external view returns (uint256 shareBps) {
        if (totalStaked == 0) return 0;
        return (stakedBalance[staker] * 10000) / totalStaked;
    }

    /**
     * @notice Check if an address is currently staking
     * @param staker Address to check
     * @return True if the address has a non-zero staked balance
     */
    function isStaking(address staker) external view returns (bool) {
        return stakedBalance[staker] > 0;
    }
}
