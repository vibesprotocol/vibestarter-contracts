// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VibesStaking
 * @notice Staking contract for $VIBES token holders to earn rewards from platform raises
 * @dev Stakers receive 2% of every new vibetoken launched on the platform, proportional to their stake.
 *      Features:
 *      - 7-day unstake cooldown to prevent flash-stake attacks
 *      - Events for off-chain indexing and snapshot generation
 *      - Simple stake/unstake mechanics
 */
contract VibesStaking is ReentrancyGuard {
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

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Cooldown period before unstaking is allowed (7 days)
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    // ============================================
    // STATE
    // ============================================

    /// @notice The VIBES token contract
    IERC20 public immutable vibesToken;

    /// @notice Staked balance per address
    mapping(address => uint256) public stakedBalance;

    /// @notice Timestamp of last stake action per address (for cooldown calculation)
    mapping(address => uint256) public lastStakeTime;

    /// @notice Total VIBES tokens staked across all stakers
    uint256 public totalStaked;

    // ============================================
    // ERRORS
    // ============================================

    error ZeroAmount();
    error InsufficientBalance();
    error CooldownActive(uint256 cooldownEndsAt);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Initialize the staking contract
    /// @param _vibesToken Address of the VIBES token contract
    constructor(address _vibesToken) {
        require(_vibesToken != address(0), "Invalid token address");
        vibesToken = IERC20(_vibesToken);
    }

    // ============================================
    // STAKING FUNCTIONS
    // ============================================

    /**
     * @notice Stake VIBES tokens to earn rewards from platform raises
     * @dev Transfers tokens from sender to this contract. Resets cooldown timer.
     * @param amount Amount of VIBES tokens to stake
     */
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Transfer tokens to this contract
        vibesToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update state
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
        lastStakeTime[msg.sender] = block.timestamp;

        emit Staked(msg.sender, amount, stakedBalance[msg.sender]);
    }

    /**
     * @notice Unstake VIBES tokens
     * @dev Requires 7-day cooldown since last stake action to prevent flash-stake attacks.
     *      This ensures stakers are committed before earning rewards from raise finalizations.
     * @param amount Amount of VIBES tokens to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (stakedBalance[msg.sender] < amount) revert InsufficientBalance();

        // Check cooldown (must wait 7 days since last stake)
        uint256 cooldownEndsAt = lastStakeTime[msg.sender] + UNSTAKE_COOLDOWN;
        if (block.timestamp < cooldownEndsAt) {
            revert CooldownActive(cooldownEndsAt);
        }

        // Update state
        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;

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
     * @return cooldownEndsAt When unstaking becomes available (0 if already available)
     * @return canUnstake Whether the staker can currently unstake
     */
    function getStakingInfo(address staker) external view returns (
        uint256 balance,
        uint256 lastStake,
        uint256 cooldownEndsAt,
        bool canUnstake
    ) {
        balance = stakedBalance[staker];
        lastStake = lastStakeTime[staker];
        cooldownEndsAt = lastStake + UNSTAKE_COOLDOWN;
        canUnstake = block.timestamp >= cooldownEndsAt && balance > 0;
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
