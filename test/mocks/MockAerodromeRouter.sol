// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockLPToken
/// @notice LP token that also implements the minimal IAerodromePool surface
///         (token0/token1/stable/claimFees) so EIP-1167 clones of VibesLPFeeClaimer
///         can initialize against it in unit tests.
contract MockLPToken is ERC20 {
    address public immutable token0;
    address public immutable token1;
    bool public constant stable = false;

    // Fee simulation for claim-path tests: set via setClaimableFees(), paid out (and zeroed)
    // on the next claimFees() call. The pool must be pre-funded with the corresponding
    // token balances by the test setup for the payout transfers to succeed.
    uint256 public claimable0;
    uint256 public claimable1;

    constructor(address _token0, address _token1) ERC20("Mock LP", "MLP") {
        token0 = _token0;
        token1 = _token1;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Test helper — configure the next claimFees() payout.
    function setClaimableFees(uint256 _c0, uint256 _c1) external {
        claimable0 = _c0;
        claimable1 = _c1;
    }

    /// @notice Mock of Aerodrome pool.claimFees() — pays out stored amounts to msg.sender
    ///         and resets. Requires the pool to hold sufficient token0/token1 balances.
    function claimFees() external returns (uint256 claimed0, uint256 claimed1) {
        claimed0 = claimable0;
        claimed1 = claimable1;
        claimable0 = 0;
        claimable1 = 0;

        if (claimed0 > 0) {
            IERC20(token0).transfer(msg.sender, claimed0);
        }
        if (claimed1 > 0) {
            IERC20(token1).transfer(msg.sender, claimed1);
        }
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
            MockLPToken lpToken = new MockLPToken(token, weth);
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
