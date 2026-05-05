// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockAerodromePool
/// @notice Mock AMM pool for testing swap/trade simulation against locked LP
/// @dev Implements constant-product (x*y=k) pricing for realistic trade simulation
contract MockAerodromePool is ERC20 {
    address public token0;
    address public token1;

    uint256 public reserve0;
    uint256 public reserve1;

    uint256 private constant FEE_BPS = 30; // 0.3% swap fee (Aerodrome volatile)

    constructor(address _token0, address _token1) ERC20("Mock AMM LP", "MLP") {
        token0 = _token0;
        token1 = _token1;
    }

    /// @notice Add liquidity — mints LP tokens proportional to sqrt(dx*dy)
    function addLiquidity(uint256 amount0, uint256 amount1, address to) external returns (uint256 lpMinted) {
        IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1);

        if (totalSupply() == 0) {
            lpMinted = _sqrt(amount0 * amount1);
        } else {
            uint256 lp0 = (amount0 * totalSupply()) / reserve0;
            uint256 lp1 = (amount1 * totalSupply()) / reserve1;
            lpMinted = lp0 < lp1 ? lp0 : lp1;
        }

        reserve0 += amount0;
        reserve1 += amount1;
        _mint(to, lpMinted);
    }

    /// @notice Swap token0 for token1 (constant product with fee)
    function swap0For1(uint256 amountIn, address to) external returns (uint256 amountOut) {
        require(amountIn > 0, "Zero input");
        require(reserve0 > 0 && reserve1 > 0, "No liquidity");

        IERC20(token0).transferFrom(msg.sender, address(this), amountIn);

        uint256 amountInAfterFee = amountIn * (10000 - FEE_BPS) / 10000;
        // x * y = k → amountOut = reserve1 - k / (reserve0 + amountIn)
        amountOut = (reserve1 * amountInAfterFee) / (reserve0 + amountInAfterFee);

        require(amountOut > 0 && amountOut < reserve1, "Insufficient output");

        reserve0 += amountIn;
        reserve1 -= amountOut;

        IERC20(token1).transfer(to, amountOut);
    }

    /// @notice Swap token1 for token0 (constant product with fee)
    function swap1For0(uint256 amountIn, address to) external returns (uint256 amountOut) {
        require(amountIn > 0, "Zero input");
        require(reserve0 > 0 && reserve1 > 0, "No liquidity");

        IERC20(token1).transferFrom(msg.sender, address(this), amountIn);

        uint256 amountInAfterFee = amountIn * (10000 - FEE_BPS) / 10000;
        amountOut = (reserve0 * amountInAfterFee) / (reserve1 + amountInAfterFee);

        require(amountOut > 0 && amountOut < reserve0, "Insufficient output");

        reserve1 += amountIn;
        reserve0 -= amountOut;

        IERC20(token0).transfer(to, amountOut);
    }

    /// @notice Get current price of token0 in terms of token1 (18-decimal fixed point)
    function getPrice0In1() external view returns (uint256) {
        if (reserve0 == 0) return 0;
        return (reserve1 * 1e18) / reserve0;
    }

    /// @notice Get current price of token1 in terms of token0 (18-decimal fixed point)
    function getPrice1In0() external view returns (uint256) {
        if (reserve1 == 0) return 0;
        return (reserve0 * 1e18) / reserve1;
    }

    /// @notice Get the constant product k
    function getK() external view returns (uint256) {
        return reserve0 * reserve1;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    // Integer square root (Babylonian method)
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
