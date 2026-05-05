// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVibesLaunchRouter
/// @notice Interface for the VibesLaunchRouter contract
interface IVibesLaunchRouter {
    /// @notice Phase 1: Create and lock LP for a funded campaign
    /// @dev Called by escrow during finalize(). Only callable by the escrow contract.
    /// @param token Token address
    function completeFinalization(address token) external;

    /// @notice Phase 2: Distribute tokens (vesting, treasury, staker rewards, backer pool)
    /// @dev Called by escrow during finalize() or by admin for retry.
    /// @param token Token address
    function completeDistribution(address token) external;

    /// @notice Audit fix H-3: router-side finalization progress for a token
    /// @dev Used by escrow's emergencyRefundFunded() to ensure admin cannot roll a
    ///      campaign back to Failed once router finalization has progressed. Returns
    ///      0 = None (safe to emergency-refund), 1 = LPComplete, 2 = FullyComplete.
    /// @param token Token address
    function finalizationPhase(address token) external view returns (uint8);
}
