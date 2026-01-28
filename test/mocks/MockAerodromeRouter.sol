// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockLPToken
/// @notice Simple ERC20 to represent LP tokens in tests
contract MockLPToken is ERC20 {
    constructor() ERC20("Mock LP", "MLP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title MockAerodromeRouter
/// @notice Mock router for testing LP creation without actual Aerodrome
contract MockAerodromeRouter {
    address public immutable weth;
    address public factory;

    // Mapping: token => pool
    mapping(address => address) public tokenPools;

    // Track liquidity additions
    struct LiquidityEvent {
        address token;
        uint256 tokenAmount;
        uint256 ethAmount;
        uint256 lpAmount;
        address recipient;
    }

    LiquidityEvent[] public liquidityEvents;

    // Control behavior for testing
    bool public shouldFail;
    uint256 public lpMultiplier = 1e18; // LP tokens per unit of liquidity

    constructor(address _weth, address _factory) {
        weth = _weth;
        factory = _factory;
    }

    /// @notice Mock addLiquidityETH function
    function addLiquidityETH(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        require(!shouldFail, "Mock: LP creation failed");
        require(block.timestamp <= deadline, "Mock: Expired");
        require(msg.value >= amountETHMin, "Mock: Insufficient ETH");

        // Transfer tokens from caller
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);

        // Create or get pool
        address pool = tokenPools[token];
        if (pool == address(0)) {
            MockLPToken lpToken = new MockLPToken();
            pool = address(lpToken);
            tokenPools[token] = pool;
        }

        // Calculate LP tokens (simplified: sqrt(token * eth) approximation)
        // For testing, use a simple formula: LP = (tokenAmount + ethAmount) / 2
        liquidity = (amountTokenDesired + msg.value) * lpMultiplier / 1e18;

        // Mint LP tokens to recipient
        MockLPToken(pool).mint(to, liquidity);

        // Record event
        liquidityEvents.push(LiquidityEvent({
            token: token,
            tokenAmount: amountTokenDesired,
            ethAmount: msg.value,
            lpAmount: liquidity,
            recipient: to
        }));

        return (amountTokenDesired, msg.value, liquidity);
    }

    /// @notice Get pool address for a token pair
    function poolFor(
        address tokenA,
        address tokenB,
        bool stable,
        address _factory
    ) external view returns (address) {
        // For simplicity, just return the pool for tokenA (assuming tokenB is WETH)
        return tokenPools[tokenA];
    }

    /// @notice Set factory address
    function setFactory(address _factory) external {
        factory = _factory;
    }

    // ============ Test Helpers ============

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function setLpMultiplier(uint256 _multiplier) external {
        lpMultiplier = _multiplier;
    }

    function getLiquidityEventsCount() external view returns (uint256) {
        return liquidityEvents.length;
    }

    function getLastLiquidityEvent() external view returns (LiquidityEvent memory) {
        require(liquidityEvents.length > 0, "No events");
        return liquidityEvents[liquidityEvents.length - 1];
    }

    // Allow receiving ETH
    receive() external payable {}
}
