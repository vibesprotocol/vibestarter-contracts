// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesLaunchRouterV2} from "../src/VibesLaunchRouterV2.sol";
import {VibesRouterExtension} from "../src/VibesRouterExtension.sol";

/**
 * @title UpgradeEscrow
 * @notice Targeted upgrade: redeploy escrow implementation + factory only
 * @dev Reuses existing router, registry, LP locker, etc.
 *
 * Run with: forge script script/UpgradeEscrow.s.sol:UpgradeEscrow --rpc-url base_sepolia --broadcast --verify
 *
 * Environment variables required:
 *   PRIVATE_KEY - Deployer private key (must be router owner)
 *   BASE_SEPOLIA_RPC_URL - RPC URL
 *   BASESCAN_API_KEY - For verification
 */
contract UpgradeEscrow is Script {
    // ============ Existing Base Sepolia addresses (unchanged) ============
    address constant ROUTER = 0xc730dC49a40F978F3a48171cDa464a5fFDB1ddAa;
    address constant LP_LOCKER = 0x08885Dd153bb9129976efdEA63608Dd590DBe69f;
    address constant TIME_ORACLE = 0x67d0Fe87433347587c6d3Bee6476eE6F3ae55f91;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========== ESCROW UPGRADE ==========");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("Router:", ROUTER);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new VibesTranchEscrow implementation
        VibesTranchEscrow newImpl = new VibesTranchEscrow();
        console.log("1. New VibesTranchEscrow (impl):", address(newImpl));

        // 2. Deploy new VibesTranchEscrowFactory with the new implementation
        VibesTranchEscrowFactory newFactory = new VibesTranchEscrowFactory(
            address(newImpl),
            deployer,       // admin
            deployer,       // platformWallet
            TIME_ORACLE,    // timeOracle
            ROUTER,         // authorizedRouter
            LP_LOCKER,      // lpLocker
            address(0)      // trustedSigner (set after deploy via setTrustedSigner)
        );
        console.log("2. New VibesTranchEscrowFactory:", address(newFactory));

        // 3. Point the existing router to the new factory (goes through fallback -> extension)
        VibesRouterExtension(ROUTER).setEscrowFactory(address(newFactory));
        console.log("3. Router updated to new escrow factory");

        vm.stopBroadcast();

        // ============ Summary ============
        console.log("");
        console.log("========== UPGRADE COMPLETE ==========");
        console.log("New VibesTranchEscrow (impl): ", address(newImpl));
        console.log("New VibesTranchEscrowFactory: ", address(newFactory));
        console.log("Router (unchanged):           ", ROUTER);
        console.log("=======================================");
        console.log("");
        console.log("// ===== UPDATE in packages/shared/src/contracts.ts =====");
        console.log("// V2 Escrow System");
        console.log(string.concat("vibesTranchEscrowFactory: '", vm.toString(address(newFactory)), "' as `0x${string}`,"));
        console.log(string.concat("vibesTranchEscrowImpl: '", vm.toString(address(newImpl)), "' as `0x${string}`,"));
        console.log("// ===== END =====");
        console.log("");
        console.log("NOTE: Existing raises still use the OLD implementation.");
        console.log("Only NEW raises created after this upgrade will use the updated contract.");
    }
}
