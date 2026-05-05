// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {VibesTokenFactory} from "../src/VibesTokenFactory.sol";
import {VibesRegistry} from "../src/VibesRegistry.sol";
import {VibesLaunchRouterV2} from "../src/VibesLaunchRouterV2.sol";
import {VibesRouterExtension} from "../src/VibesRouterExtension.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesLPLocker} from "../src/VibesLPLocker.sol";
import {VibesLPFeeClaimer} from "../src/VibesLPFeeClaimer.sol";
import {VibesCommunityRewardsFactory} from "../src/VibesCommunityRewardsFactory.sol";

/**
 * @title DeployV2
 * @notice Mainnet deployment for Vibes Protocol V2 contracts on Base.
 * @dev Run with: forge script script/DeployV2.s.sol:DeployV2 --rpc-url base --broadcast --verify
 *
 * Required env vars:
 *   PRIVATE_KEY     - Deployer private key
 *   OPS_ADMIN       - Operations admin (challenge resolution, factory admin)
 *   TRUSTED_SIGNER  - EIP-712 signer for launch/contribute gating
 *   GNOSIS_SAFE     - Initiates router ownership transfer
 *
 * Optional:
 *   FEE_RECIPIENT   - Platform fee wallet (defaults to OPS_ADMIN)
 *
 * Note: testnet variants and MockTimeOracle / MockAerodromeRouter are NOT included
 * in this public mirror — testnet program ended 2026-05. The full monorepo retains
 * a parity-tested testnet variant for development; this snapshot is mainnet-only.
 */
contract DeployV2 is Script {
    address constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant AERODROME_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address opsAdmin = vm.envAddress("OPS_ADMIN");
        address trustedSigner = vm.envAddress("TRUSTED_SIGNER");
        address gnosisSafe = vm.envAddress("GNOSIS_SAFE");
        address feeRecipient = vm.envOr("FEE_RECIPIENT", opsAdmin);

        console.log("========== MAINNET DEPLOYMENT ==========");
        console.log("Deployer:", deployer);
        console.log("Ops Admin:", opsAdmin);
        console.log("Trusted Signer:", trustedSigner);
        console.log("Fee Recipient:", feeRecipient);
        console.log("Gnosis Safe:", gnosisSafe);

        vm.startBroadcast(deployerPrivateKey);

        // Core
        VibesTokenFactory tokenFactory = new VibesTokenFactory();
        VibesRegistry registry = new VibesRegistry();

        // Escrow implementation
        VibesTranchEscrow escrowImpl = new VibesTranchEscrow();

        // LP
        VibesLPLocker lpLocker = new VibesLPLocker(AERODROME_ROUTER, AERODROME_FACTORY);

        // LP fee claimer implementation — REQUIRED; createAndLockLP reverts without it.
        VibesLPFeeClaimer feeClaimerImpl = new VibesLPFeeClaimer();
        lpLocker.setFeeClaimerImplementation(address(feeClaimerImpl));

        // Extension (delegatecall target for admin/view functions)
        VibesRouterExtension ext = new VibesRouterExtension();

        // Router (need address for escrow factory)
        VibesLaunchRouterV2 router = new VibesLaunchRouterV2(
            address(ext),
            address(tokenFactory),
            address(registry),
            address(0), // Will set escrow factory after
            payable(address(lpLocker))
        );

        // Escrow factory (needs router address)
        VibesTranchEscrowFactory escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl),
            opsAdmin,           // admin — escrow clones inherit this for challenge resolution
            feeRecipient,       // platformWallet
            address(0),         // No time oracle — uses block.timestamp
            address(router),    // authorizedRouter
            address(lpLocker),  // lpLocker
            trustedSigner       // EIP-712 gating for contribute/challenge
        );

        // Community rewards factory — required for PC-03 pre-authorized community slices.
        VibesCommunityRewardsFactory communityFactory = new VibesCommunityRewardsFactory();

        // Configure router (admin calls go through fallback -> extension)
        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        VibesRouterExtension(address(router)).setOpsWallet(feeRecipient);
        VibesRouterExtension(address(router)).setOperationsAdmin(opsAdmin);
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(trustedSigner);
        VibesRouterExtension(address(router)).setCommunityRewardsFactory(address(communityFactory));

        // Authorize
        registry.authorizeRouter(address(router));
        lpLocker.setAuthorizedRouter(address(router));

        // Ownership transfer to Gnosis Safe (step 1 of 2)
        VibesRouterExtension(address(router)).transferOwnership(gnosisSafe);
        console.log("Router ownership transfer INITIATED to:", gnosisSafe);
        console.log("!! Safe must call acceptOwnership() to complete transfer !!");

        vm.stopBroadcast();

        console.log("");
        console.log("========== DEPLOYMENT SUMMARY ==========");
        console.log("VibesTokenFactory:        ", address(tokenFactory));
        console.log("VibesRegistry:            ", address(registry));
        console.log("VibesTranchEscrow (impl): ", address(escrowImpl));
        console.log("VibesLPLocker:            ", address(lpLocker));
        console.log("VibesLPFeeClaimer (impl): ", address(feeClaimerImpl));
        console.log("VibesLaunchRouterV2:      ", address(router));
        console.log("VibesTranchEscrowFactory: ", address(escrowFactory));
        console.log("=========================================");

        // Output for contracts.ts - COPY THIS BLOCK DIRECTLY
        console.log("");
        console.log("// ===== COPY TO packages/shared/src/contracts.ts (BASE_MAINNET_ADDRESSES) =====");
        console.log("// V2 Core");
        console.log(string.concat("vibesLaunchRouterV2: '", vm.toString(address(router)), "' as `0x${string}`,"));
        console.log(string.concat("vibesTokenFactory: '", vm.toString(address(tokenFactory)), "' as `0x${string}`,"));
        console.log(string.concat("vibesRegistry: '", vm.toString(address(registry)), "' as `0x${string}`,"));
        console.log("");
        console.log("// V2 Escrow System");
        console.log(string.concat("vibesTranchEscrowFactory: '", vm.toString(address(escrowFactory)), "' as `0x${string}`,"));
        console.log(string.concat("vibesTranchEscrowImpl: '", vm.toString(address(escrowImpl)), "' as `0x${string}`,"));
        console.log("");
        console.log("// V2 LP");
        console.log(string.concat("vibesLPLocker: '", vm.toString(address(lpLocker)), "' as `0x${string}`,"));
        console.log("// ===== END COPY =====");
        console.log("");
        console.log("IMPORTANT: After updating contracts.ts, run verification:");
        console.log("  forge script script/VerifyDeployment.s.sol --rpc-url base");
    }
}
