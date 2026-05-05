// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VibesVesting
 * @notice Linear vesting contract for founder token allocations with configurable cliff.
 * @dev Tokens vest over CLIFF + VESTING_DURATION total. True delayed start — at the cliff
 *      boundary, 0% is vested. Tokens then vest linearly from 0% to 100% over VESTING_DURATION.
 *      Mainnet: 6-month cliff + 12-month linear = 18 months. Testnet: 6-day cliff + 12-day linear = 18 days.
 *      Founder can claim vested tokens at any time via release().
 */
contract VibesVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;
    // ============================================
    // EVENTS
    // ============================================

    event TokensReleased(address indexed beneficiary, uint256 amount);
    event VestingStarted(uint256 startTime);
    event VestingInitialized(uint256 totalAmount);
    event VestingFrozen(address indexed frozenBy, uint256 unvestedAmount);

    // ============================================
    // IMMUTABLES (configurable per deployment)
    // ============================================

    /// @notice Cliff period before any tokens vest (mainnet: 180 days, testnet: 6 days)
    uint256 public immutable CLIFF;

    /// @notice Linear vesting duration after cliff ends (mainnet: 365 days, testnet: 6 days)
    uint256 public immutable VESTING_DURATION;

    // ============================================
    // STATE
    // ============================================

    /// @notice The token being vested
    IERC20 public immutable token;

    /// @notice The beneficiary who receives vested tokens
    address public immutable beneficiary;

    /// @notice The address authorized to start vesting (typically the router)
    address public immutable authorizedStarter;

    /// @notice Timestamp when vesting starts (set when campaign is funded)
    uint256 public start;

    /// @notice Total amount of tokens to vest
    uint256 public totalAmount;

    /// @notice Amount of tokens already released
    uint256 public released;

    /// @notice Whether the total amount has been set
    bool public initialized;

    /// @notice Whether vesting has been frozen (malicious/abandoned founder)
    bool public frozen;

    /// @notice Address authorized to freeze vesting (treasury escrow)
    address public authorizedFreezer;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @param _token Token to vest
     * @param _beneficiary Address that will receive vested tokens
     * @param _cliff Cliff period in seconds (mainnet: 180 days, testnet: 6 days)
     * @param _vestingDuration Linear vesting duration in seconds (mainnet: 365 days, testnet: 12 days)
     */
    constructor(
        address _token,
        address _beneficiary,
        uint256 _cliff,
        uint256 _vestingDuration
    ) {
        require(_token != address(0), "Invalid token");
        require(_beneficiary != address(0), "Invalid beneficiary");
        require(_vestingDuration > 0, "Invalid duration");

        token = IERC20(_token);
        beneficiary = _beneficiary;
        CLIFF = _cliff;
        VESTING_DURATION = _vestingDuration;
        authorizedStarter = msg.sender; // The router that deploys this contract
        // start is NOT set here - it's set when startVesting() is called
        // This ensures vesting begins when campaign is funded, not at deployment
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initialize the total vesting amount
     * @dev Must be called after tokens are transferred to this contract.
     *      Can only be called once. Sets totalAmount to current balance.
     */
    // L11 fix: restrict to authorized starter (the router that deployed this contract)
    function initializeAmount() external {
        require(msg.sender == authorizedStarter, "Only authorized starter");
        require(!initialized, "Already initialized");

        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No tokens to vest");

        totalAmount = balance;
        initialized = true;

        emit VestingInitialized(balance);
    }

    /**
     * @notice Start the vesting clock
     * @dev Only callable by the authorized starter (the router that deployed this contract).
     *      Should be called when raise reaches Funded state.
     *      Can only be called once. If not called, vesting never starts.
     */
    function startVesting() external {
        require(msg.sender == authorizedStarter, "Only authorized starter");
        require(initialized, "Not initialized");
        require(start == 0, "Vesting already started");

        start = block.timestamp;
        emit VestingStarted(start);
    }

    /**
     * @notice Set the address authorized to freeze vesting (treasury escrow)
     * @dev Only callable by the authorized starter (router). Can only be set once.
     */
    function setAuthorizedFreezer(address _freezer) external {
        require(msg.sender == authorizedStarter, "Only authorized starter");
        require(_freezer != address(0), "Invalid freezer");
        require(authorizedFreezer == address(0), "Freezer already set");
        authorizedFreezer = _freezer;
    }

    /**
     * @notice Freeze vesting — burns unvested tokens, prevents future releases
     * @dev Called by treasury escrow when a malicious/abandoned challenge is upheld.
     *      Already-released tokens are unaffected.
     */
    function freeze() external {
        require(msg.sender == authorizedFreezer, "Only authorized freezer");
        require(!frozen, "Already frozen");

        frozen = true;

        // Burn all unvested tokens still held by this contract
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            token.safeTransfer(address(0xdead), balance);
        }

        emit VestingFrozen(msg.sender, balance);
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
        require(!frozen, "Vesting frozen");

        uint256 unreleased = releasable();
        require(unreleased > 0, "Nothing to release");

        released += unreleased;

        // L10 fix: use safeTransfer for non-standard ERC20 compatibility
        token.safeTransfer(beneficiary, unreleased);

        emit TokensReleased(beneficiary, unreleased);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Calculate amount of tokens that have vested
     * @dev True delayed start: 0% at cliff end, then linear over VESTING_DURATION.
     *      At start + CLIFF: vested = 0
     *      At start + CLIFF + VESTING_DURATION: vested = totalAmount
     * @return Amount of vested tokens (may include already released)
     */
    function vestedAmount() public view returns (uint256) {
        if (!initialized) return 0;
        if (start == 0) return 0; // Vesting hasn't started yet
        if (block.timestamp < start + CLIFF) return 0; // During cliff: nothing vested

        uint256 elapsed = block.timestamp - start - CLIFF; // Time since cliff ended
        if (elapsed >= VESTING_DURATION) return totalAmount; // Fully vested

        return (totalAmount * elapsed) / VESTING_DURATION; // Linear from cliff end
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
     * @dev Progress across the full 18-month period (CLIFF + VESTING_DURATION)
     * @return Progress in basis points (0-10000)
     */
    function vestingProgress() external view returns (uint256) {
        if (!initialized) return 0;
        if (start == 0) return 0; // Vesting hasn't started yet
        uint256 totalDuration = CLIFF + VESTING_DURATION;
        if (block.timestamp >= start + totalDuration) return 10000;
        if (block.timestamp <= start) return 0;

        return ((block.timestamp - start) * 10000) / totalDuration;
    }

    /**
     * @notice Get remaining time until fully vested
     * @return Seconds until fully vested (0 if already vested)
     */
    function remainingTime() external view returns (uint256) {
        uint256 end = start + CLIFF + VESTING_DURATION;
        if (block.timestamp >= end) return 0;
        return end - block.timestamp;
    }

    /**
     * @notice Get vesting schedule details
     * @return _start Start timestamp
     * @return _duration Total duration in seconds (CLIFF + VESTING_DURATION)
     * @return _cliff Cliff period in seconds
     * @return _totalAmount Total tokens to vest
     * @return _released Tokens already released
     * @return _releasable Tokens available to release now
     */
    function getVestingSchedule() external view returns (
        uint256 _start,
        uint256 _duration,
        uint256 _cliff,
        uint256 _totalAmount,
        uint256 _released,
        uint256 _releasable
    ) {
        return (start, CLIFF + VESTING_DURATION, CLIFF, totalAmount, released, releasable());
    }
}
