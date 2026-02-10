// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVibesLaunchRouter
/// @notice Interface for the VibesLaunchRouter contract
interface IVibesLaunchRouter {
    /// @notice Complete finalization of a successful campaign - creates LP and distributor atomically
    /// @dev Called by escrow during finalize(). Only callable by the escrow contract.
    /// @param token Token address
    function completeFinalization(address token) external;
}
