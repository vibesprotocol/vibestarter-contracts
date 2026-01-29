// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./VibesTranchEscrow.sol";

/// @title VibesTranchEscrowFactory
/// @notice Factory for deploying VibesTranchEscrow instances using EIP-1167 minimal proxies
contract VibesTranchEscrowFactory {
    using Clones for address;

    // ============ State ============

    /// @notice Implementation contract for clones
    address public immutable implementation;

    /// @notice Platform admin address
    address public admin;

    /// @notice Platform wallet for fees
    address public platformWallet;

    /// @notice Time oracle (0x0 for production, mock for testnet)
    address public timeOracle;

    /// @notice Authorized router for LP withdrawals
    address public authorizedRouter;

    /// @notice All deployed escrows
    address[] public escrows;

    /// @notice Mapping from founder to their escrows
    mapping(address => address[]) public founderEscrows;

    /// @notice Whether an address is a valid escrow
    mapping(address => bool) public isEscrow;

    // ============ Events ============

    event EscrowCreated(
        address indexed escrow,
        address indexed founder,
        address indexed token,
        VibesTranchEscrow.RaiseType raiseType,
        uint256 goal,
        uint256 deadline
    );

    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event PlatformWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event TimeOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event AuthorizedRouterUpdated(address indexed oldRouter, address indexed newRouter);

    // ============ Errors ============

    error OnlyAdmin();
    error ZeroAddress();

    // ============ Modifiers ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // ============ Constructor ============

    /// @param _implementation Implementation contract address
    /// @param _admin Platform admin
    /// @param _platformWallet Platform fee wallet
    /// @param _timeOracle Time oracle (0x0 for production)
    /// @param _authorizedRouter Router authorized for LP withdrawals
    constructor(
        address _implementation,
        address _admin,
        address _platformWallet,
        address _timeOracle,
        address _authorizedRouter
    ) {
        if (_implementation == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        if (_platformWallet == address(0)) revert ZeroAddress();
        if (_authorizedRouter == address(0)) revert ZeroAddress();

        implementation = _implementation;
        admin = _admin;
        platformWallet = _platformWallet;
        timeOracle = _timeOracle;
        authorizedRouter = _authorizedRouter;
    }

    // ============ Factory Functions ============

    /// @notice Create a new escrow for a campaign
    /// @param _founder Founder address
    /// @param _token Project token address
    /// @param _raiseType Type of raise (FixedGoal, OpenEnded, ProRata)
    /// @param _goal Funding goal (hard cap for ProRata, required for FixedGoal, 0 for OpenEnded)
    /// @param _softCap Soft cap (optional, only for OpenEnded)
    /// @param _deadline Campaign deadline
    /// @return escrow Address of the new escrow
    function createEscrow(
        address _founder,
        address _token,
        VibesTranchEscrow.RaiseType _raiseType,
        uint256 _goal,
        uint256 _softCap,
        uint256 _deadline
    ) external returns (address escrow) {
        // Create deterministic clone
        bytes32 salt = keccak256(abi.encodePacked(_founder, _token, _deadline, escrows.length));
        escrow = implementation.cloneDeterministic(salt);

        // Initialize the clone
        VibesTranchEscrow(payable(escrow)).initialize(
            _founder,
            _token,
            _raiseType,
            _goal,
            _softCap,
            _deadline,
            admin,
            platformWallet,
            timeOracle,
            authorizedRouter
        );

        // Track the escrow
        escrows.push(escrow);
        founderEscrows[_founder].push(escrow);
        isEscrow[escrow] = true;

        emit EscrowCreated(escrow, _founder, _token, _raiseType, _goal, _deadline);
    }

    /// @notice Predict the address of a clone before creation
    function predictEscrowAddress(
        address _founder,
        address _token,
        uint256 _deadline,
        uint256 _index
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_founder, _token, _deadline, _index));
        return implementation.predictDeterministicAddress(salt);
    }

    // ============ Admin Functions ============

    /// @notice Update admin address
    function setAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert ZeroAddress();
        address oldAdmin = admin;
        admin = _newAdmin;
        emit AdminUpdated(oldAdmin, _newAdmin);
    }

    /// @notice Update platform wallet
    function setPlatformWallet(address _newWallet) external onlyAdmin {
        if (_newWallet == address(0)) revert ZeroAddress();
        address oldWallet = platformWallet;
        platformWallet = _newWallet;
        emit PlatformWalletUpdated(oldWallet, _newWallet);
    }

    /// @notice Update time oracle (for testnet deployments)
    function setTimeOracle(address _newOracle) external onlyAdmin {
        address oldOracle = timeOracle;
        timeOracle = _newOracle;
        emit TimeOracleUpdated(oldOracle, _newOracle);
    }

    /// @notice Update authorized router
    function setAuthorizedRouter(address _newRouter) external onlyAdmin {
        if (_newRouter == address(0)) revert ZeroAddress();
        address oldRouter = authorizedRouter;
        authorizedRouter = _newRouter;
        emit AuthorizedRouterUpdated(oldRouter, _newRouter);
    }

    // ============ View Functions ============

    /// @notice Get total number of escrows
    function totalEscrows() external view returns (uint256) {
        return escrows.length;
    }

    /// @notice Get all escrows for a founder
    function getFounderEscrows(address _founder) external view returns (address[] memory) {
        return founderEscrows[_founder];
    }

    /// @notice Get all escrows
    function getAllEscrows() external view returns (address[] memory) {
        return escrows;
    }
}
