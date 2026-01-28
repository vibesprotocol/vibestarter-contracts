// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAerodromeRouter
/// @notice Interface for Aerodrome Finance Router on Base
/// @dev Based on https://github.com/aerodrome-finance/contracts/blob/main/contracts/interfaces/IRouter.sol
interface IAerodromeRouter {
    /// @notice Add liquidity of a token and WETH (transferred as ETH) to a Pool
    /// @param token Address of the token to pair with ETH
    /// @param stable True for stable pool, false for volatile pool
    /// @param amountTokenDesired Desired amount of token to deposit
    /// @param amountTokenMin Minimum amount of token to deposit
    /// @param amountETHMin Minimum amount of ETH to deposit
    /// @param to Recipient of liquidity tokens
    /// @param deadline Transaction deadline timestamp
    /// @return amountToken Actual amount of token deposited
    /// @return amountETH Actual amount of ETH deposited
    /// @return liquidity Amount of liquidity tokens minted
    function addLiquidityETH(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    /// @notice Get the pool address for a token pair
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @param stable True for stable pool, false for volatile
    /// @return pool Address of the pool
    function poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address pool);

    /// @notice Quote expected amounts when adding liquidity
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @param stable True for stable pool
    /// @param _factory Factory address
    /// @param amountADesired Desired amount of token A
    /// @param amountBDesired Desired amount of token B
    /// @return amountA Expected amount of token A
    /// @return amountB Expected amount of token B
    /// @return liquidity Expected liquidity tokens
    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        address _factory,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external view returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Get the factory address
    function defaultFactory() external view returns (address);

    /// @notice Get the WETH address
    function weth() external view returns (address);
}

/// @title IAerodromePool
/// @notice Interface for Aerodrome liquidity pool
interface IAerodromePool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function stable() external view returns (bool);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}
