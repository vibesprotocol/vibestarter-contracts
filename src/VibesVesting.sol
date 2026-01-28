// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VibesVesting
 * @notice Linear vesting contract for founder token allocations.
 * @dev Tokens vest linearly over a specified duration (default 12 months).
 *      Founder can claim vested tokens at any time via release().
 */
contract VibesVesting is ReentrancyGuard {
    // ============================================
    // EVENTS
    // ============================================

    event TokensReleased(address indexed beneficiary, uint256 amount);

    // ============================================
    // STATE
    // ============================================

    /// @notice The token being vested
    IERC20 public immutable token;

    /// @notice The beneficiary who receives vested tokens
    address public immutable beneficiary;

    /// @notice Timestamp when vesting starts
    uint256 public immutable start;

    /// @notice Duration of vesting in seconds
    uint256 public immutable duration;

    /// @notice Total amount of tokens to vest
    uint256 public totalAmount;

    /// @notice Amount of tokens already released
    uint256 public released;

    /// @notice Whether the total amount has been set
    bool public initialized;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @param _token Token to vest
     * @param _beneficiary Address that will receive vested tokens
     * @param _duration Vesting duration in seconds (e.g., 365 days for 1 year)
     */
    constructor(
        address _token,
        address _beneficiary,
        uint256 _duration
    ) {
        require(_token != address(0), "Invalid token");
        require(_beneficiary != address(0), "Invalid beneficiary");
        require(_duration > 0, "Invalid duration");

        token = IERC20(_token);
        beneficiary = _beneficiary;
        start = block.timestamp;
        duration = _duration;
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initialize the total vesting amount
     * @dev Must be called after tokens are transferred to this contract.
     *      Can only be called once. Sets totalAmount to current balance.
     */
    function initializeAmount() external {
        require(!initialized, "Already initialized");

        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No tokens to vest");

        totalAmount = balance;
        initialized = true;
    }

    // ============================================
    // RELEASE FUNCTIONS
    // ============================================

    /**
     * @notice Release vested tokens to beneficiary
     * @dev Anyone can call this, but tokens always go to beneficiary
     */
    function release() external nonReentrant {
        require(initialized, "Not initialized");

        uint256 unreleased = releasable();
        require(unreleased > 0, "Nothing to release");

        released += unreleased;

        require(token.transfer(beneficiary, unreleased), "Transfer failed");

        emit TokensReleased(beneficiary, unreleased);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Calculate amount of tokens that have vested
     * @return Amount of vested tokens (may include already released)
     */
    function vestedAmount() public view returns (uint256) {
        if (!initialized) return 0;
        if (block.timestamp < start) return 0;
        if (block.timestamp >= start + duration) return totalAmount;

        return (totalAmount * (block.timestamp - start)) / duration;
    }

    /**
     * @notice Calculate amount of tokens available to release
     * @return Amount of tokens that can be released now
     */
    function releasable() public view returns (uint256) {
        return vestedAmount() - released;
    }

    /**
     * @notice Get vesting progress as percentage (basis points)
     * @return Progress in basis points (0-10000)
     */
    function vestingProgress() external view returns (uint256) {
        if (!initialized) return 0;
        if (block.timestamp >= start + duration) return 10000;

        return ((block.timestamp - start) * 10000) / duration;
    }

    /**
     * @notice Get remaining time until fully vested
     * @return Seconds until fully vested (0 if already vested)
     */
    function remainingTime() external view returns (uint256) {
        uint256 end = start + duration;
        if (block.timestamp >= end) return 0;
        return end - block.timestamp;
    }

    /**
     * @notice Get vesting schedule details
     * @return _start Start timestamp
     * @return _duration Duration in seconds
     * @return _totalAmount Total tokens to vest
     * @return _released Tokens already released
     * @return _releasable Tokens available to release now
     */
    function getVestingSchedule() external view returns (
        uint256 _start,
        uint256 _duration,
        uint256 _totalAmount,
        uint256 _released,
        uint256 _releasable
    ) {
        return (start, duration, totalAmount, released, releasable());
    }
}
