// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { VibesToken } from "./VibesToken.sol";

/**
 * @title VibesTokenFactory
 * @notice Deploys VibesToken instances with fixed supply.
 * @dev This is a simple factory with no access controls - anyone can deploy.
 *      The VibesLaunchRouter is expected to call this.
 */
contract VibesTokenFactory {
    // ============================================
    // EVENTS
    // ============================================
    
    event TokenDeployed(
        address indexed token,
        address indexed recipient,
        string name,
        string symbol,
        uint8 decimals,
        uint256 totalSupply
    );

    // ============================================
    // FUNCTIONS
    // ============================================
    
    /**
     * @notice Deploy a new VibesToken
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals Token decimals
     * @param totalSupply Total supply to mint
     * @param recipient Address to receive all tokens
     * @return token Address of the deployed token
     */
    function deployToken(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 totalSupply,
        address recipient
    ) external returns (address token) {
        token = address(new VibesToken(name, symbol, decimals, totalSupply, recipient));
        
        emit TokenDeployed(token, recipient, name, symbol, decimals, totalSupply);
    }
}
