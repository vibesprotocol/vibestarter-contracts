// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ITimeOracle.sol";

/// @title MockTimeOracle
/// @notice Mock time oracle for testnet deployments - allows manual time control
/// @dev DO NOT deploy to mainnet - for testing only
contract MockTimeOracle is ITimeOracle {
    uint256 public mockTime;
    address public admin;

    event TimeSet(uint256 oldTime, uint256 newTime);
    event TimeAdvanced(uint256 oldTime, uint256 newTime, uint256 delta);

    error OnlyAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
        mockTime = block.timestamp;
    }

    /// @notice Returns the mock time
    function getTime() external view override returns (uint256) {
        return mockTime;
    }

    /// @notice Set the mock time to a specific value
    /// @param _time The new time value
    function setTime(uint256 _time) external onlyAdmin {
        uint256 oldTime = mockTime;
        mockTime = _time;
        emit TimeSet(oldTime, _time);
    }

    /// @notice Advance time by a delta
    /// @param _delta Seconds to advance
    function advanceTime(uint256 _delta) external onlyAdmin {
        uint256 oldTime = mockTime;
        mockTime += _delta;
        emit TimeAdvanced(oldTime, mockTime, _delta);
    }

    /// @notice Convenience: advance by days
    /// @param _days Number of days to advance
    function advanceDays(uint256 _days) external onlyAdmin {
        uint256 oldTime = mockTime;
        uint256 delta = _days * 1 days;
        mockTime += delta;
        emit TimeAdvanced(oldTime, mockTime, delta);
    }

    /// @notice Sync mock time to current block timestamp
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
