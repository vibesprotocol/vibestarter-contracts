// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {VibesIdentityRegistry} from "../src/VibesIdentityRegistry.sol";

/**
 * @title DeployIdentityRegistry
 * @notice Deployment script for ERC-8004 Identity Registry on Base
 * @dev Run with: forge script script/DeployIdentityRegistry.s.sol:DeployIdentityRegistry --rpc-url base --broadcast --verify
 *
 * Environment variables required:
 *   PRIVATE_KEY - Deployer private key
 *   BASESCAN_API_KEY - API key for contract verification
 */
contract DeployIdentityRegistry is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========== ERC-8004 IDENTITY REGISTRY DEPLOYMENT ==========");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy VibesIdentityRegistry
        VibesIdentityRegistry registry = new VibesIdentityRegistry();
        console.log("VibesIdentityRegistry:", address(registry));

        vm.stopBroadcast();

        // ============ Summary ============
        console.log("");
        console.log("========== DEPLOYMENT SUMMARY ==========");
        console.log("VibesIdentityRegistry:", address(registry));
        console.log("Owner:", deployer);
        console.log("");
        console.log("Registry ID (for agentURI files):");
        console.log(string.concat("eip155:", vm.toString(block.chainid), ":", vm.toString(address(registry))));
        console.log("");
        console.log("=========================================");

        // Output for code updates
        console.log("");
        console.log("# Update in packages/shared/src/erc8004.ts:");
        console.log(string.concat("export const ERC8004_REGISTRY_ADDRESS = '", vm.toString(address(registry)), "' as const;"));
    }
}

/**
 * @title RegisterAgentsBatch
 * @notice Register all 34 proxy agents in a single batch transaction
 * @dev Run with: forge script script/DeployIdentityRegistry.s.sol:RegisterAgentsBatch --rpc-url base --broadcast
 *
 * Environment variables required:
 *   PRIVATE_KEY - Registry owner private key
 *   IDENTITY_REGISTRY - Deployed registry address
 *   IPFS_BASE_URI - Base IPFS URI for registration files (e.g., "ipfs://Qm.../")
 */
contract RegisterAgentsBatch is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("IDENTITY_REGISTRY");
        string memory ipfsBaseUri = vm.envString("IPFS_BASE_URI");

        console.log("========== BATCH AGENT REGISTRATION ==========");
        console.log("Registry:", registryAddress);
        console.log("IPFS Base URI:", ipfsBaseUri);
        console.log("");

        VibesIdentityRegistry registry = VibesIdentityRegistry(registryAddress);

        // Build the array of URIs for all 34 agents
        string[] memory uris = new string[](34);

        // Core coding assistants (1-15)
        uris[0] = string.concat(ipfsBaseUri, "01-claude-code.json");
        uris[1] = string.concat(ipfsBaseUri, "02-cursor.json");
        uris[2] = string.concat(ipfsBaseUri, "03-windsurf.json");
        uris[3] = string.concat(ipfsBaseUri, "04-v0.json");
        uris[4] = string.concat(ipfsBaseUri, "05-bolt.json");
        uris[5] = string.concat(ipfsBaseUri, "06-lovable.json");
        uris[6] = string.concat(ipfsBaseUri, "07-replit.json");
        uris[7] = string.concat(ipfsBaseUri, "08-copilot.json");
        uris[8] = string.concat(ipfsBaseUri, "09-aider.json");
        uris[9] = string.concat(ipfsBaseUri, "10-cline.json");
        uris[10] = string.concat(ipfsBaseUri, "11-devin.json");
        uris[11] = string.concat(ipfsBaseUri, "12-amazon-q.json");
        uris[12] = string.concat(ipfsBaseUri, "13-tabnine.json");
        uris[13] = string.concat(ipfsBaseUri, "14-codeium.json");
        uris[14] = string.concat(ipfsBaseUri, "15-continue.json");

        // More coding tools (16-25)
        uris[15] = string.concat(ipfsBaseUri, "16-codestral.json");
        uris[16] = string.concat(ipfsBaseUri, "17-deepseek.json");
        uris[17] = string.concat(ipfsBaseUri, "18-cody.json");
        uris[18] = string.concat(ipfsBaseUri, "19-pieces.json");
        uris[19] = string.concat(ipfsBaseUri, "20-supermaven.json");
        uris[20] = string.concat(ipfsBaseUri, "21-zed.json");
        uris[21] = string.concat(ipfsBaseUri, "22-phind.json");
        uris[22] = string.concat(ipfsBaseUri, "23-blackbox.json");
        uris[23] = string.concat(ipfsBaseUri, "24-codiumai.json");
        uris[24] = string.concat(ipfsBaseUri, "25-qodo.json");

        // General AI assistants (26-33)
        uris[25] = string.concat(ipfsBaseUri, "26-claude.json");
        uris[26] = string.concat(ipfsBaseUri, "27-chatgpt.json");
        uris[27] = string.concat(ipfsBaseUri, "28-gemini.json");
        uris[28] = string.concat(ipfsBaseUri, "29-perplexity.json");
        uris[29] = string.concat(ipfsBaseUri, "30-poe.json");
        uris[30] = string.concat(ipfsBaseUri, "31-llama.json");
        uris[31] = string.concat(ipfsBaseUri, "32-grok.json");
        uris[32] = string.concat(ipfsBaseUri, "33-openrouter.json");

        // MCP / Custom (34)
        uris[33] = string.concat(ipfsBaseUri, "34-mcp-custom.json");

        vm.startBroadcast(deployerPrivateKey);

        // Register all agents in one transaction
        uint256 startId = registry.registerBatch(uris);

        vm.stopBroadcast();

        console.log("");
        console.log("========== REGISTRATION COMPLETE ==========");
        console.log("Registered 34 agents starting at ID:", startId);
        console.log("Agent IDs: 1-34");
        console.log("");
        console.log("Verify on Basescan:");
        console.log(string.concat("https://basescan.org/address/", vm.toString(registryAddress)));
        console.log("============================================");
    }
}
