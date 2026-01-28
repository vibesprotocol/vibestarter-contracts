// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ITimeOracle
/// @notice Interface for time oracle used in testnet deployments
interface ITimeOracle {
    /// @notice Returns the current time (mock or real)
    function getTime() external view returns (uint256);
}
