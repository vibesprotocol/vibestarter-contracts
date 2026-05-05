// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ITimeOracle.sol";

/// @title MockTimeOracle
/// @notice Mock time oracle for testnet deployments - allows manual time control
/// @dev DO NOT deploy to mainnet - for testing only
contract MockTimeOracle is ITimeOracle {
    uint256 public mockTime;
    address public admin;
    bool public useRealTime;

    event TimeSet(uint256 oldTime, uint256 newTime);
    event TimeAdvanced(uint256 oldTime, uint256 newTime, uint256 delta);
    event RealTimeModeSet(bool enabled);

    error OnlyAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
        mockTime = block.timestamp;
    }

    /// @notice Returns the current time (real or mock depending on mode)
    function getTime() external view override returns (uint256) {
        if (useRealTime) {
            return block.timestamp;
        }
        return mockTime;
    }

    /// @notice Enable or disable real-time mode (uses block.timestamp directly)
    /// @param _enabled true to use block.timestamp, false to use mockTime
    function setRealTimeMode(bool _enabled) external onlyAdmin {
        useRealTime = _enabled;
        if (_enabled) {
            mockTime = block.timestamp; // sync mockTime for clean switch back
        }
        emit RealTimeModeSet(_enabled);
    }

    /// @notice Set the mock time to a specific value (only works when not in real-time mode)
    /// @param _time The new time value
    function setTime(uint256 _time) external onlyAdmin {
        uint256 oldTime = mockTime;
        mockTime = _time;
        useRealTime = false; // setting manual time disables real-time mode
        emit TimeSet(oldTime, _time);
    }

    /// @notice Advance time by a delta (only works when not in real-time mode)
    /// @param _delta Seconds to advance
    function advanceTime(uint256 _delta) external onlyAdmin {
        uint256 oldTime = mockTime;
        if (useRealTime) {
            mockTime = block.timestamp + _delta;
            useRealTime = false;
        } else {
            mockTime += _delta;
        }
        emit TimeAdvanced(oldTime, mockTime, _delta);
    }

    /// @notice Convenience: advance by days
    /// @param _days Number of days to advance
    function advanceDays(uint256 _days) external onlyAdmin {
        uint256 oldTime = mockTime;
        uint256 delta = _days * 1 days;
        if (useRealTime) {
            mockTime = block.timestamp + delta;
            useRealTime = false;
        } else {
            mockTime += delta;
        }
        emit TimeAdvanced(oldTime, mockTime, delta);
    }

    /// @notice Sync mock time to current block timestamp (legacy — prefer setRealTimeMode)
    function syncToBlockTime() external onlyAdmin {
        uint256 oldTime = mockTime;
        mockTime = block.timestamp;
        emit TimeSet(oldTime, mockTime);
    }

    /// @notice Transfer admin role
    /// @param _newAdmin New admin address
    function transferAdmin(address _newAdmin) external onlyAdmin {
        admin = _newAdmin;
    }
}
