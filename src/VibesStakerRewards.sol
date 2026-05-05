// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VibesStakerRewards
 * @notice Accumulator-based reward distribution for $VIBES stakers from platform raises
 * @dev For each raise that finalizes successfully, 2.5% of the vibetoken is allocated to stakers.
 *      Uses a Synthetix-style reward-per-token accumulator — fully atomic, no admin action needed.
 *
 *      Flow:
 *      1. Router calls safeTransfer(tokens) to this contract during completeFinalization()
 *      2. Router calls notifyReward(token, amount, escrow) atomically in the same tx
 *      3. Contract snapshots rewardPerToken for that raise using current staking state
 *      4. Stakers claim proportional share whenever they want — no Merkle, no admin
 *
 *      Key invariant: A staker's share of raise R = (stakedBalance at time of R) / totalStaked at time of R
 *      This is captured atomically via the accumulator snapshot at notifyReward() time.
 */
contract VibesStakerRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when rewards are registered for a raise (called atomically by router)
    event RewardNotified(
        address indexed escrow,
        address indexed token,
        uint256 totalTokens,
        uint256 totalStakedAtSnapshot
    );

    /// @notice Emitted when a staker claims rewards for a raise
    event RewardClaimed(
        address indexed staker,
        address indexed escrow,
        address indexed token,
        uint256 amount
    );

    // ============================================
    // STRUCTS
    // ============================================

    /// @notice Reward data for a single raise
    struct RaiseReward {
        address token;              // The vibetoken address
        uint256 totalTokens;        // Total tokens allocated (2.5% of supply)
        uint256 claimedTokens;      // Tokens claimed so far
        uint256 totalStakedSnapshot; // Total staked at notification time
        uint256 notifiedAt;         // block.timestamp when notifyReward was called
        bool active;                // Whether reward has been registered
    }

    // ============================================
    // STATE
    // ============================================

    /// @notice The VibesStaking contract (read staker balances from here)
    address public immutable stakingContract;

    /// @notice Authorized router that can call notifyReward
    address public authorizedRouter;

    /// @notice Admin address (can update router, two-step transfer)
    address public admin;

    /// @notice Pending admin for two-step transfer
    address public pendingAdmin;

    /// @notice Rewards data per raise (escrow address => reward)
    mapping(address => RaiseReward) public raiseRewards;

    /// @notice Track claimed status per raise per staker (escrow => staker => claimed)
    mapping(address => mapping(address => bool)) public hasClaimed;

    /// @notice Staker's staked balance snapshot at each raise (escrow => staker => balance)
    /// @dev Populated lazily from staking contract at claim time if not already set
    mapping(address => mapping(address => uint256)) public stakerSnapshot;

    /// @notice Whether a staker's snapshot has been taken for a raise
    mapping(address => mapping(address => bool)) public snapshotTaken;

    /// @notice List of all escrows with rewards (for enumeration)
    address[] public rewardedEscrows;

    /// @notice Audit fix F4: Snapshot ID from VibesStaking for each raise
    /// @dev Taken atomically during notifyReward() to capture staker balances at notification time
    mapping(address => uint256) public raiseSnapshotId;

    // ============================================
    // ERRORS
    // ============================================

    error OnlyAdmin();
    error OnlyRouter();
    error ZeroAddress();
    error RewardAlreadySet();
    error RewardNotActive();
    error AlreadyClaimed();
    error NothingToClaim();
    error NoRewardsToClaim();
    error NoStakeAtSnapshot();
    // Audit fix L-3
    error NoSnapshotForRaise();

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyRouter() {
        if (msg.sender != authorizedRouter) revert OnlyRouter();
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Initialize the rewards contract
    /// @param _admin Admin address
    /// @param _stakingContract VibesStaking contract to read balances from
    /// @param _authorizedRouter Router that can call notifyReward
    constructor(address _admin, address _stakingContract, address _authorizedRouter) {
        if (_admin == address(0)) revert ZeroAddress();
        if (_stakingContract == address(0)) revert ZeroAddress();
        if (_authorizedRouter == address(0)) revert ZeroAddress();
        admin = _admin;
        stakingContract = _stakingContract;
        authorizedRouter = _authorizedRouter;
    }

    // ============================================
    // ROUTER FUNCTION (called atomically during finalization)
    // ============================================

    /**
     * @notice Register a reward for a raise — called by router during completeFinalization()
     * @dev Tokens MUST be transferred to this contract BEFORE this call.
     *      Snapshots the current totalStaked from the staking contract.
     *      If totalStaked == 0, tokens remain in the contract for future admin recovery.
     * @param token Vibetoken address
     * @param amount Amount of tokens allocated
     * @param escrow Escrow address (unique identifier for the raise)
     */
    function notifyReward(address token, uint256 amount, address escrow) external onlyRouter {
        if (token == address(0)) revert ZeroAddress();
        if (escrow == address(0)) revert ZeroAddress();
        if (raiseRewards[escrow].active) revert RewardAlreadySet();

        // Audit fix F4: Take a snapshot of staker balances atomically with reward notification.
        // This captures the exact staking state at notification time, preventing stakers from
        // increasing their balance post-notification to claim a larger share.
        uint256 snapId = IVibesStakingSnapshot(stakingContract).takeSnapshot();
        raiseSnapshotId[escrow] = snapId;

        // Read total staked from the snapshot (same value, but now immutably recorded)
        uint256 currentTotalStaked = IVibesStakingSnapshot(stakingContract).totalStakedAtSnapshot(snapId);

        raiseRewards[escrow] = RaiseReward({
            token: token,
            totalTokens: amount,
            claimedTokens: 0,
            totalStakedSnapshot: currentTotalStaked,
            notifiedAt: block.timestamp,
            active: true
        });

        rewardedEscrows.push(escrow);

        emit RewardNotified(escrow, token, amount, currentTotalStaked);
    }

    // ============================================
    // CLAIM FUNCTIONS
    // ============================================

    /**
     * @notice Claim staker rewards for a single raise
     * @param escrow Escrow address identifying the raise
     */
    function claim(address escrow) external nonReentrant {
        _claimInternal(escrow, msg.sender);
    }

    /**
     * @notice Batch claim rewards across multiple raises
     * @param escrows Array of escrow addresses to claim from
     */
    function claimMultiple(address[] calldata escrows) external nonReentrant {
        if (escrows.length == 0) revert NoRewardsToClaim();
        require(escrows.length <= 100, "Batch too large");

        for (uint256 i = 0; i < escrows.length; i++) {
            // Skip if already claimed or not active (don't revert, just continue)
            if (hasClaimed[escrows[i]][msg.sender]) continue;
            if (!raiseRewards[escrows[i]].active) continue;

            // Skip if staker had no stake (avoid revert in batch)
            uint256 stakerBal = _getStakerBalance(escrows[i], msg.sender);
            if (stakerBal == 0) continue;

            _claimInternalUnchecked(escrows[i], msg.sender, stakerBal);
        }
    }

    /**
     * @notice Internal claim logic with full validation
     */
    function _claimInternal(address escrow, address staker) internal {
        RaiseReward storage reward = raiseRewards[escrow];

        if (!reward.active) revert RewardNotActive();
        if (hasClaimed[escrow][staker]) revert AlreadyClaimed();

        uint256 stakerBal = _getStakerBalance(escrow, staker);
        if (stakerBal == 0) revert NoStakeAtSnapshot();

        _claimInternalUnchecked(escrow, staker, stakerBal);
    }

    /**
     * @notice Internal claim without validation (for batch use after pre-checks)
     */
    function _claimInternalUnchecked(address escrow, address staker, uint256 stakerBal) internal {
        RaiseReward storage reward = raiseRewards[escrow];

        // Guard against division by zero (no stakers when reward was notified)
        if (reward.totalStakedSnapshot == 0) return;

        // Calculate proportional share: (stakerBalance / totalStaked) * totalTokens
        uint256 amount = (stakerBal * reward.totalTokens) / reward.totalStakedSnapshot;

        if (amount == 0) return; // Rounding to zero for tiny stakes

        // Cap to remaining balance (handles rounding dust on last claimer)
        uint256 remaining = IERC20(reward.token).balanceOf(address(this));
        if (amount > remaining) {
            amount = remaining;
        }

        if (amount == 0) return;

        // Mark as claimed and transfer
        hasClaimed[escrow][staker] = true;
        reward.claimedTokens += amount;

        IERC20(reward.token).safeTransfer(staker, amount);

        emit RewardClaimed(staker, escrow, reward.token, amount);
    }

    /**
     * @notice Get the staker's balance for a raise using snapshot data
     * @dev Audit fix F4: Uses snapshot-based balance instead of current balance to prevent
     *      stakers from increasing their stake post-notification and claiming a larger share.
     *      On first call for a (escrow, staker) pair, reads from staking snapshot and caches.
     *      Eligibility check: staker's firstStakeTime must be strictly before the raise's
     *      notifiedAt timestamp.
     */
    function _getStakerBalance(address escrow, address staker) internal returns (uint256) {
        if (snapshotTaken[escrow][staker]) {
            return stakerSnapshot[escrow][staker];
        }

        // Check eligibility: staker must have been staking before this raise was notified
        uint256 stakerFirstStake = IVibesStakingReadOnly(stakingContract).firstStakeTime(staker);
        uint256 notifiedAt = raiseRewards[escrow].notifiedAt;
        if (stakerFirstStake == 0 || stakerFirstStake >= notifiedAt) {
            // Not staking, or started staking at/after notification — ineligible
            stakerSnapshot[escrow][staker] = 0;
            snapshotTaken[escrow][staker] = true;
            return 0;
        }

        // Audit fix F4: Read balance from snapshot (notification-time balance), not current balance.
        // This prevents gaming where a staker increases their position after notification.
        // Audit fix L-3: The previous `snapId == 0` backwards-compatibility fallback read the
        // current stakedBalance, which silently re-introduced the F4 late-stake gaming vector.
        // Any raise reaching this code path MUST have a snapshot, since notifyReward() always
        // invokes takeSnapshot() and stores a non-zero id. Fail closed if somehow it doesn't.
        uint256 snapId = raiseSnapshotId[escrow];
        if (snapId == 0) revert NoSnapshotForRaise();
        uint256 balance = IVibesStakingSnapshot(stakingContract).balanceAtSnapshot(snapId, staker);

        // Cache it
        stakerSnapshot[escrow][staker] = balance;
        snapshotTaken[escrow][staker] = true;

        return balance;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Update the authorized router address
     * @param _router New authorized router address
     */
    function setAuthorizedRouter(address _router) external onlyAdmin {
        if (_router == address(0)) revert ZeroAddress();
        authorizedRouter = _router;
    }

    /**
     * @notice Transfer admin role (two-step process)
     * @param newAdmin New admin address
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin;
    }

    /**
     * @notice Accept admin role
     */
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert OnlyAdmin();
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    /**
     * @notice Rescue tokens from raises where totalStaked was 0 (no stakers to claim)
     * @dev Only callable by admin. Only allows rescue from raises with zero stakers.
     * @param escrow Escrow address
     * @param to Recipient address
     */
    function rescueUnclaimable(address escrow, address to) external onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        RaiseReward storage reward = raiseRewards[escrow];
        if (!reward.active) revert RewardNotActive();
        require(reward.totalStakedSnapshot == 0, "Has stakers");

        uint256 amount = reward.totalTokens - reward.claimedTokens;
        if (amount == 0) revert NothingToClaim();

        reward.claimedTokens += amount;
        IERC20(reward.token).safeTransfer(to, amount);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if a staker can claim for a specific raise
     * @param escrow Escrow address
     * @param staker Staker address
     * @return canClaimReward True if claim would succeed
     * @return amount Estimated claimable amount
     */
    function canClaim(
        address escrow,
        address staker
    ) external view returns (bool canClaimReward, uint256 amount) {
        RaiseReward storage reward = raiseRewards[escrow];

        if (!reward.active) return (false, 0);
        if (hasClaimed[escrow][staker]) return (false, 0);
        if (reward.totalStakedSnapshot == 0) return (false, 0);

        // Read staker balance (view-only — doesn't cache)
        uint256 stakerBal;
        if (snapshotTaken[escrow][staker]) {
            stakerBal = stakerSnapshot[escrow][staker];
        } else {
            // Check eligibility: must have been staking before notification
            uint256 stakerFirstStake = IVibesStakingReadOnly(stakingContract).firstStakeTime(staker);
            if (stakerFirstStake == 0 || stakerFirstStake >= reward.notifiedAt) return (false, 0);
            // Audit fix F4: Use snapshot balance for accurate view
            uint256 snapId = raiseSnapshotId[escrow];
            if (snapId > 0) {
                stakerBal = IVibesStakingSnapshot(stakingContract).balanceAtSnapshot(snapId, staker);
            } else {
                stakerBal = IVibesStakingReadOnly(stakingContract).stakedBalance(staker);
            }
        }

        if (stakerBal == 0) return (false, 0);

        amount = (stakerBal * reward.totalTokens) / reward.totalStakedSnapshot;
        if (amount == 0) return (false, 0);

        return (true, amount);
    }

    /**
     * @notice Get rewards info for a raise
     * @param escrow Escrow address
     * @return token Vibetoken address
     * @return totalTokens Total allocated
     * @return claimedTokens Total claimed
     * @return totalStakedSnapshot Total staked at notification
     * @return notifiedAt Timestamp of notification
     * @return active Whether reward is active
     */
    function getRewardsInfo(address escrow) external view returns (
        address token,
        uint256 totalTokens,
        uint256 claimedTokens,
        uint256 totalStakedSnapshot,
        uint256 notifiedAt,
        bool active
    ) {
        RaiseReward storage reward = raiseRewards[escrow];
        return (
            reward.token,
            reward.totalTokens,
            reward.claimedTokens,
            reward.totalStakedSnapshot,
            reward.notifiedAt,
            reward.active
        );
    }

    /**
     * @notice Get number of raises with rewards
     * @return Count of rewarded raises
     */
    function getRewardedRaisesCount() external view returns (uint256) {
        return rewardedEscrows.length;
    }

    /**
     * @notice Get all escrows with rewards (paginated)
     * @param offset Start index
     * @param limit Max items to return
     * @return escrows Array of escrow addresses
     */
    function getRewardedEscrows(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory escrows) {
        uint256 total = rewardedEscrows.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        escrows = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            escrows[i - offset] = rewardedEscrows[i];
        }
    }

    /**
     * @notice Check claim status for multiple raises
     * @param staker Staker address
     * @param escrows Array of escrow addresses to check
     * @return claimed Array of claim statuses
     */
    function getClaimStatuses(
        address staker,
        address[] calldata escrows
    ) external view returns (bool[] memory claimed) {
        claimed = new bool[](escrows.length);
        for (uint256 i = 0; i < escrows.length; i++) {
            claimed[i] = hasClaimed[escrows[i]][staker];
        }
    }

    /**
     * @notice Get claimable amounts for a staker across multiple raises
     * @param staker Staker address
     * @param escrows Array of escrow addresses to check
     * @return amounts Array of claimable token amounts
     */
    function getClaimableAmounts(
        address staker,
        address[] calldata escrows
    ) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](escrows.length);
        for (uint256 i = 0; i < escrows.length; i++) {
            (, amounts[i]) = this.canClaim(escrows[i], staker);
        }
    }
}

/// @notice Minimal read-only interface for VibesStaking
interface IVibesStakingReadOnly {
    function stakedBalance(address staker) external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function firstStakeTime(address staker) external view returns (uint256);
}

/// @notice Audit fix F4: Snapshot interface for VibesStaking
interface IVibesStakingSnapshot {
    function takeSnapshot() external returns (uint256);
    function balanceAtSnapshot(uint256 snapshotId, address staker) external view returns (uint256);
    function totalStakedAtSnapshot(uint256 snapshotId) external view returns (uint256);
}
