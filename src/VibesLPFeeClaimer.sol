// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAerodromePool} from "./interfaces/IAerodromeRouter.sol";

/// @dev Minimal surface of VibesTreasuryEscrow we need to detect terminated treasuries.
interface IVibesTreasuryTerminatedCheck {
    function terminated() external view returns (bool);
}

/// @title VibesLPFeeClaimer
/// @notice Permanent LP holder that captures Aerodrome trading fees and routes them
///         to pre-configured destinations. LP tokens held here are soulbound — this
///         contract has no transfer, withdraw, rescue, pause, or admin surface.
/// @dev One instance per campaign, cloned via EIP-1167 from VibesLPLocker.
///      Fee routing (set once at initialize) is immutable for the lifetime of the contract:
///        - WETH (Aerodrome fees paid in ETH pair) → platformFeeRecipient (immutable)
///        - Project token                         → treasuryEscrow if set and not terminated,
///                                                  otherwise burned to DEAD_ADDRESS
///      claimAndDistribute() is permissionless so anyone (keeper, backer, founder) can
///      trigger settlement at any cadence.
contract VibesLPFeeClaimer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ============ Immutable-after-init state ============

    address public pool;
    address public token0;
    address public token1;
    address public projectToken;
    address public campaign;
    address public platformFeeRecipient;
    address public treasuryEscrow; // address(0) = burn project-token fees

    bool public initialized;

    // ============ Events ============

    event Initialized(
        address indexed pool,
        address indexed campaign,
        address projectToken,
        address platformFeeRecipient,
        address treasuryEscrow
    );
    event FeesClaimed(uint256 amount0, uint256 amount1);
    event ProjectTokenRouted(address indexed destination, uint256 amount, bool burned);
    event WethRouted(address indexed recipient, uint256 amount);

    // ============ Errors ============

    error AlreadyInitialized();
    error ZeroAddress();
    error PoolTokenMismatch();

    // ============ Init ============

    /// @notice One-shot initializer for the clone.
    /// @param _pool         Aerodrome pool holding our LP position.
    /// @param _campaign     Escrow address (for indexer correlation).
    /// @param _projectToken The raise's ERC-20. Must be one of pool.token0() / pool.token1().
    /// @param _platformFeeRecipient Destination for the WETH side of accrued fees.
    /// @param _treasuryEscrow Destination for the project-token side; pass address(0) to burn.
    function initialize(
        address _pool,
        address _campaign,
        address _projectToken,
        address _platformFeeRecipient,
        address _treasuryEscrow
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (_pool == address(0)) revert ZeroAddress();
        if (_campaign == address(0)) revert ZeroAddress();
        if (_projectToken == address(0)) revert ZeroAddress();
        if (_platformFeeRecipient == address(0)) revert ZeroAddress();

        initialized = true;

        address t0 = IAerodromePool(_pool).token0();
        address t1 = IAerodromePool(_pool).token1();
        if (t0 != _projectToken && t1 != _projectToken) revert PoolTokenMismatch();

        pool = _pool;
        token0 = t0;
        token1 = t1;
        projectToken = _projectToken;
        campaign = _campaign;
        platformFeeRecipient = _platformFeeRecipient;
        treasuryEscrow = _treasuryEscrow;

        emit Initialized(_pool, _campaign, _projectToken, _platformFeeRecipient, _treasuryEscrow);
    }

    // ============ Main ============

    /// @notice Claim accrued Aerodrome fees and route them to the configured destinations.
    /// @dev Permissionless. Safe to call at any cadence; pays out whatever has accrued.
    function claimAndDistribute() external nonReentrant {
        (uint256 claimed0, uint256 claimed1) = IAerodromePool(pool).claimFees();
        emit FeesClaimed(claimed0, claimed1);

        // Map claimed amounts back to (projectAmount, wethAmount) based on sort order.
        uint256 projectAmount;
        uint256 wethAmount;
        address wethToken;
        if (projectToken == token0) {
            projectAmount = claimed0;
            wethAmount = claimed1;
            wethToken = token1;
        } else {
            projectAmount = claimed1;
            wethAmount = claimed0;
            wethToken = token0;
        }

        if (wethAmount > 0) {
            IERC20(wethToken).safeTransfer(platformFeeRecipient, wethAmount);
            emit WethRouted(platformFeeRecipient, wethAmount);
        }

        if (projectAmount > 0) {
            address dest = _projectTokenDestination();
            IERC20(projectToken).safeTransfer(dest, projectAmount);
            emit ProjectTokenRouted(dest, projectAmount, dest == DEAD_ADDRESS);
        }
    }

    // ============ Internal ============

    /// @dev Treasury is used only if configured AND not terminated. A terminated treasury
    ///      cannot release deposited tokens, so sending there would strand them — burn instead.
    ///      The terminated() probe is try/catch-wrapped so a non-conforming treasury ABI
    ///      (or a destroyed contract) falls back to burn rather than reverting the whole claim.
    function _projectTokenDestination() internal view returns (address) {
        if (treasuryEscrow == address(0)) return DEAD_ADDRESS;
        try IVibesTreasuryTerminatedCheck(treasuryEscrow).terminated() returns (bool t) {
            return t ? DEAD_ADDRESS : treasuryEscrow;
        } catch {
            return DEAD_ADDRESS;
        }
    }

    // ============ Views ============

    /// @notice LP tokens held by this claimer (the permanently-locked position).
    function lpBalance() external view returns (uint256) {
        return IERC20(pool).balanceOf(address(this));
    }

    // INTENTIONALLY ABSENT: transfer, withdraw, rescue, pause, owner, upgrade.
    // LP tokens and any residual balances held by this contract are unrecoverable by design.
}
