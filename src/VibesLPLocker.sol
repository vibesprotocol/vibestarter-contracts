// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IAerodromeRouter.sol";

/// @title VibesLPLocker
/// @notice Creates Aerodrome LP positions and locks them permanently
/// @dev LP tokens are sent to a dead address, making them unrecoverable
contract VibesLPLocker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Dead address where LP tokens are permanently locked
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Aerodrome Router on Base
    /// @dev Mainnet: 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43
    address public immutable aerodromeRouter;

    /// @notice Aerodrome Factory on Base
    /// @dev Mainnet: 0x420DD381b31aEf6683db6B902084cB0FFECe40Da
    address public immutable aerodromeFactory;

    // ============ Structs ============

    struct LockedLP {
        address token;           // Project token
        address pool;            // Aerodrome pool address
        uint256 tokenAmount;     // Tokens added to LP
        uint256 ethAmount;       // ETH added to LP
        uint256 lpAmount;        // LP tokens minted (now locked)
        uint256 timestamp;       // When LP was created
        address campaign;        // Associated campaign escrow
    }

    // ============ State ============

    /// @notice All locked LP positions
    LockedLP[] public lockedPositions;

    /// @notice Mapping from campaign to position index
    mapping(address => uint256) public campaignToPosition;

    /// @notice Whether a campaign has locked LP
    mapping(address => bool) public hasLockedLP;

    /// @notice Contract owner
    address public owner;

    /// @notice Authorized router for LP creation
    address public authorizedRouter;

    // ============ Events ============

    event LPCreatedAndLocked(
        address indexed token,
        address indexed pool,
        address indexed campaign,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 lpAmount
    );

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientTokenBalance();
    error InsufficientETH();
    error LPCreationFailed();
    error AlreadyLocked();
    error OnlyOwner();
    error OnlyRouter();

    // ============ Modifiers ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyRouter() {
        if (msg.sender != authorizedRouter) revert OnlyRouter();
        _;
    }

    // ============ Constructor ============

    /// @param _router Aerodrome Router address
    /// @param _factory Aerodrome Factory address
    constructor(address _router, address _factory) {
        if (_router == address(0)) revert ZeroAddress();
        if (_factory == address(0)) revert ZeroAddress();
        aerodromeRouter = _router;
        aerodromeFactory = _factory;
        owner = msg.sender;
    }

    // ============ Main Functions ============

    /// @notice Create LP position and permanently lock it
    /// @param _token Project token address
    /// @param _tokenAmount Amount of tokens for LP
    /// @param _campaign Associated campaign escrow address
    /// @return pool The Aerodrome pool address
    /// @return lpAmount Amount of LP tokens locked
    function createAndLockLP(
        address _token,
        uint256 _tokenAmount,
        address _campaign
    ) external payable nonReentrant onlyRouter returns (address pool, uint256 lpAmount) {
        if (_token == address(0)) revert ZeroAddress();
        if (_tokenAmount == 0) revert ZeroAmount();
        if (msg.value == 0) revert InsufficientETH();
        if (hasLockedLP[_campaign]) revert AlreadyLocked();

        // Transfer tokens from caller
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _tokenAmount);

        // Approve router to spend tokens
        IERC20(_token).approve(aerodromeRouter, _tokenAmount);

        IAerodromeRouter router = IAerodromeRouter(aerodromeRouter);

        // Add liquidity (volatile pool - not stable)
        // Using 1% slippage tolerance
        uint256 minTokens = (_tokenAmount * 99) / 100;
        uint256 minETH = (msg.value * 99) / 100;

        uint256 actualTokens;
        uint256 actualETH;

        (actualTokens, actualETH, lpAmount) = router.addLiquidityETH{value: msg.value}(
            _token,
            false, // volatile pool
            _tokenAmount,
            minTokens,
            minETH,
            address(this), // LP tokens come to this contract first
            block.timestamp + 300 // 5 min deadline
        );

        if (lpAmount == 0) revert LPCreationFailed();

        // Get pool address
        address weth = router.weth();
        pool = router.poolFor(_token, weth, false, aerodromeFactory);

        // Lock LP tokens by sending to dead address
        IERC20(pool).safeTransfer(DEAD_ADDRESS, lpAmount);

        // Record the locked position
        uint256 positionIndex = lockedPositions.length;
        lockedPositions.push(LockedLP({
            token: _token,
            pool: pool,
            tokenAmount: actualTokens,
            ethAmount: actualETH,
            lpAmount: lpAmount,
            timestamp: block.timestamp,
            campaign: _campaign
        }));

        campaignToPosition[_campaign] = positionIndex;
        hasLockedLP[_campaign] = true;

        // Refund any excess ETH
        if (msg.value > actualETH) {
            (bool success, ) = msg.sender.call{value: msg.value - actualETH}("");
            require(success, "ETH refund failed");
        }

        // Refund any excess tokens
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        if (tokenBalance > 0) {
            IERC20(_token).safeTransfer(msg.sender, tokenBalance);
        }

        emit LPCreatedAndLocked(_token, pool, _campaign, actualTokens, actualETH, lpAmount);
    }

    // ============ Admin Functions ============

    /// @notice Update the authorized router address
    /// @param _router New authorized router address
    function setAuthorizedRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        authorizedRouter = _router;
    }

    // ============ View Functions ============

    /// @notice Get total number of locked positions
    function totalLockedPositions() external view returns (uint256) {
        return lockedPositions.length;
    }

    /// @notice Get locked position details for a campaign
    function getLockedPosition(address _campaign) external view returns (LockedLP memory) {
        require(hasLockedLP[_campaign], "No locked LP for campaign");
        return lockedPositions[campaignToPosition[_campaign]];
    }

    /// @notice Get all locked positions
    function getAllLockedPositions() external view returns (LockedLP[] memory) {
        return lockedPositions;
    }

    /// @notice Verify LP is truly locked (check dead address balance)
    function verifyLPLocked(address _campaign) external view returns (bool, uint256) {
        if (!hasLockedLP[_campaign]) return (false, 0);

        LockedLP memory position = lockedPositions[campaignToPosition[_campaign]];
        uint256 deadBalance = IERC20(position.pool).balanceOf(DEAD_ADDRESS);

        return (deadBalance >= position.lpAmount, deadBalance);
    }

    /// @notice Calculate expected LP price based on locked amounts
    /// @param _campaign Campaign address
    /// @return priceInETH Price of 1 token in ETH (18 decimals)
    function getInitialPrice(address _campaign) external view returns (uint256 priceInETH) {
        require(hasLockedLP[_campaign], "No locked LP");
        LockedLP memory position = lockedPositions[campaignToPosition[_campaign]];

        // Price = ETH / Tokens (both in wei, result in 18 decimals)
        // To avoid precision loss: (ethAmount * 1e18) / tokenAmount
        if (position.tokenAmount > 0) {
            priceInETH = (position.ethAmount * 1e18) / position.tokenAmount;
        }
    }

    // ============ Receive ============

    receive() external payable {}
}
