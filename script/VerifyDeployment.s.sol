// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/**
 * @title VerifyDeployment
 * @notice Fail-closed verification that the deployed contract suite is wired correctly
 *         and is "production ready" per the ZXVC 2026-05 audit checklist.
 *
 * Run after each deployment:
 *   forge script script/VerifyDeployment.s.sol --rpc-url base_sepolia
 *   forge script script/VerifyDeployment.s.sol --rpc-url base
 *
 * ZXVC VIB-03 (2026-05) — this script previously counted failures and only logged at
 * the end; a deployer could miss the "FAILED" summary and proceed. Every check now
 * `revert`s with a clear message on failure so the deploy pipeline halts immediately.
 *
 * The check list is ported from the auditor's canonical
 * `DeploymentPipeline.t._assertDeploymentReady` so the script and the test stay in lock-step.
 */
contract VerifyDeployment is Script {
    // ============ PASTE YOUR ADDRESSES HERE AFTER DEPLOYMENT ============
    // These should match what you put in contracts.ts
    // Update before each run; do NOT commit production addresses without a fresh review.

    address constant ROUTER = 0xc730dC49a40F978F3a48171cDa464a5fFDB1ddAa;
    address constant TOKEN_FACTORY = 0x1424Dd231bf56Beb7338DB0fc7d64a2A2297e715;
    address constant REGISTRY = 0xE648A49adE2Ea7Df83002b4a29283fD85D2adba8;
    address constant ESCROW_FACTORY = 0x009A91c0D608E68F583DfDd65B88F8BA71ea9645;
    address constant ESCROW_IMPL = 0xC5b1443081111444CA92B41F6A8dc54A364FB1ff;
    address constant LP_LOCKER = 0x08885Dd153bb9129976efdEA63608Dd590DBe69f;
    address constant MOCK_AERODROME_ROUTER = 0xB253FbF3220B27Cf0eb5f4142617b520Bf87Fb80;
    address constant TIME_ORACLE = 0x67d0Fe87433347587c6d3Bee6476eE6F3ae55f91;

    // ZXVC VIB-03 (2026-05) — required for fail-closed deployment gate.
    // Set these to the deployed VibesStaking + VibesStakerRewards addresses, the gnosis
    // safe / multisig that owns the router, and the ops wallet that receives platform
    // fees. Leave address(0) to skip the corresponding gate (e.g., pre-staking deploys).
    address constant STAKING = address(0);
    address constant STAKER_REWARDS = address(0);
    address constant ROUTER_OWNER = address(0); // Expected router.owner() — the multisig.
    address constant OPS_WALLET = address(0);   // Expected router.opsWallet().

    // ====================================================================

    function run() external view {
        console.log("========== VERIFYING DEPLOYMENT (fail-closed) ==========");
        console.log("");

        // -- 1. Router wiring ---------------------------------------------------
        console.log("1. Verifying VibesLaunchRouterV2 wiring...");
        require(IRouter(ROUTER).tokenFactory() == TOKEN_FACTORY, "router.tokenFactory mismatch");
        console.log("   OK: tokenFactory matches");
        require(IRouter(ROUTER).registry() == REGISTRY, "router.registry mismatch");
        console.log("   OK: registry matches");
        require(IRouter(ROUTER).escrowFactory() == ESCROW_FACTORY, "router.escrowFactory mismatch");
        console.log("   OK: escrowFactory matches");
        require(IRouter(ROUTER).lpLocker() == LP_LOCKER, "router.lpLocker mismatch");
        console.log("   OK: lpLocker matches");

        // -- 2. LP Locker -------------------------------------------------------
        console.log("");
        console.log("2. Verifying VibesLPLocker...");
        require(ILPLocker(LP_LOCKER).DEAD_ADDRESS() == address(0xdead), "lpLocker.DEAD_ADDRESS wrong");
        console.log("   OK: DEAD_ADDRESS = 0xdead");
        // aerodromeRouter is allowed to deviate on testnet — log without revert.
        try ILPLocker(LP_LOCKER).aerodromeRouter() returns (address ar) {
            console.log("   INFO: aerodromeRouter =", ar);
        } catch {
            revert("lpLocker.aerodromeRouter() unavailable");
        }
        require(ILPLocker(LP_LOCKER).authorizedRouter() == ROUTER, "lpLocker.authorizedRouter mismatch");
        console.log("   OK: lpLocker.authorizedRouter matches");
        // ZXVC VIB-03 — implementation must be deployed before fee claimer clones can be created.
        address feeImpl = ILPLocker(LP_LOCKER).feeClaimerImplementation();
        require(feeImpl != address(0), "lpLocker.feeClaimerImplementation is zero");
        require(feeImpl.code.length > 0, "lpLocker.feeClaimerImplementation has no code");
        console.log("   OK: feeClaimerImplementation deployed");

        // -- 3. Escrow Factory --------------------------------------------------
        console.log("");
        console.log("3. Verifying VibesTranchEscrowFactory...");
        require(IEscrowFactory(ESCROW_FACTORY).implementation() == ESCROW_IMPL, "escrowFactory.implementation mismatch");
        console.log("   OK: implementation matches");
        require(IEscrowFactory(ESCROW_FACTORY).authorizedRouter() == ROUTER, "escrowFactory.authorizedRouter mismatch");
        console.log("   OK: escrowFactory.authorizedRouter matches");
        require(IEscrowFactory(ESCROW_FACTORY).lpLocker() == LP_LOCKER, "escrowFactory.lpLocker mismatch");
        console.log("   OK: escrowFactory.lpLocker matches");

        // -- 4. Registry --------------------------------------------------------
        console.log("");
        console.log("4. Verifying VibesRegistry authorization...");
        require(IRegistry(REGISTRY).authorizedRouters(ROUTER), "registry: router not authorized");
        console.log("   OK: router authorized in registry");

        // -- 5. Token Factory ---------------------------------------------------
        console.log("");
        console.log("5. Verifying VibesTokenFactory exists...");
        require(TOKEN_FACTORY.code.length > 0, "tokenFactory has no code");
        console.log("   OK: TokenFactory contract present");

        // -- 6. Escrow implementation ------------------------------------------
        console.log("");
        console.log("6. Verifying VibesTranchEscrow implementation...");
        require(IEscrow(ESCROW_IMPL).KICKSTART_BPS() == 1000, "escrow impl: KICKSTART_BPS != 1000");
        console.log("   OK: KICKSTART_BPS = 1000");

        // -- 7. Time oracle (must be zero + locked on mainnet) ------------------
        console.log("");
        console.log("7. Verifying time oracle state...");
        // ZXVC VIB-03 — production must use block.timestamp (timeOracle == 0) and the
        // oracle latch must be engaged so no future admin can re-introduce a fast-forward.
        require(IEscrowFactory(ESCROW_FACTORY).timeOracle() == address(0), "escrowFactory.timeOracle: production must be zero");
        require(IEscrowFactory(ESCROW_FACTORY).timeOracleLocked(), "escrowFactory.timeOracleLocked: must be true");
        console.log("   OK: timeOracle == 0 and timeOracleLocked == true");
        if (TIME_ORACLE != address(0)) {
            console.log("   INFO: TIME_ORACLE constant set to", TIME_ORACLE, "but escrow factory must NOT reference it on mainnet");
        }

        // -- 8. Router ownership (ZXVC VIB-03 + Wave 1 ownership gate) ----------
        console.log("");
        console.log("8. Verifying router ownership state...");
        require(IRouter(ROUTER).pendingOwner() == address(0), "router.pendingOwner: ownership transfer not accepted");
        console.log("   OK: router.pendingOwner == 0 (transfer accepted)");
        if (ROUTER_OWNER != address(0)) {
            require(IRouter(ROUTER).owner() == ROUTER_OWNER, "router.owner mismatch");
            console.log("   OK: router.owner matches ROUTER_OWNER");
        } else {
            console.log("   SKIP: ROUTER_OWNER constant not set");
        }
        if (OPS_WALLET != address(0)) {
            require(IRouter(ROUTER).opsWallet() == OPS_WALLET, "router.opsWallet mismatch");
            console.log("   OK: router.opsWallet matches OPS_WALLET");
        } else {
            console.log("   SKIP: OPS_WALLET constant not set");
        }

        // -- 9. Staker rewards + snapshot authorisation (ZXVC VIB-03) -----------
        console.log("");
        console.log("9. Verifying staker rewards wiring...");
        if (STAKING != address(0) && STAKER_REWARDS != address(0)) {
            require(IStaking(STAKING).snapshotAuthorized(STAKER_REWARDS), "staking.snapshotAuthorized(stakerRewards) is false");
            console.log("   OK: staking.snapshotAuthorized(stakerRewards) == true");
            require(IStakerRewards(STAKER_REWARDS).authorizedRouter() == ROUTER, "stakerRewards.authorizedRouter mismatch");
            console.log("   OK: stakerRewards.authorizedRouter matches");
            require(IStakerRewards(STAKER_REWARDS).stakingContract() == STAKING, "stakerRewards.stakingContract mismatch");
            console.log("   OK: stakerRewards.stakingContract matches");
            require(IRouter(ROUTER).stakerRewardsContract() == STAKER_REWARDS, "router.stakerRewardsContract mismatch");
            console.log("   OK: router.stakerRewardsContract matches");
        } else {
            console.log("   SKIP: STAKING / STAKER_REWARDS constants not set - staking deploy not yet verified");
        }

        console.log("");
        console.log("========================================================");
        console.log("SUCCESS: All fail-closed checks passed");
        console.log("Deployment matches the ZXVC 2026-05 production-ready checklist.");
        console.log("========================================================");
    }
}

// Minimal interfaces for verification
interface IRouter {
    function tokenFactory() external view returns (address);
    function registry() external view returns (address);
    function escrowFactory() external view returns (address);
    function lpLocker() external view returns (address);
    function opsWallet() external view returns (address);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function stakerRewardsContract() external view returns (address);
}

interface ILPLocker {
    function DEAD_ADDRESS() external view returns (address);
    function aerodromeRouter() external view returns (address);
    function authorizedRouter() external view returns (address);
    function feeClaimerImplementation() external view returns (address);
}

interface IEscrowFactory {
    function implementation() external view returns (address);
    function authorizedRouter() external view returns (address);
    function lpLocker() external view returns (address);
    function timeOracle() external view returns (address);
    function timeOracleLocked() external view returns (bool);
}

interface IRegistry {
    function authorizedRouters(address) external view returns (bool);
}

interface IEscrow {
    function KICKSTART_BPS() external view returns (uint256);
}

interface IStaking {
    function snapshotAuthorized(address) external view returns (bool);
}

interface IStakerRewards {
    function authorizedRouter() external view returns (address);
    function stakingContract() external view returns (address);
}
