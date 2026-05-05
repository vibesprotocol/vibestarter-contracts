// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/**
 * @title VerifyDeployment
 * @notice Verifies that deployed contracts are correctly configured and contracts.ts matches
 * @dev Run after each deployment: forge script script/VerifyDeployment.s.sol --rpc-url base_sepolia
 *
 * This script:
 * 1. Calls unique methods on each contract to verify it's the correct type
 * 2. Checks cross-references (router -> escrowFactory, router -> lpLocker, etc.)
 * 3. Fails loudly if any mismatch is detected
 */
contract VerifyDeployment is Script {
    // ============ PASTE YOUR ADDRESSES HERE AFTER DEPLOYMENT ============
    // These should match what you put in contracts.ts
    // Updated: 2026-02-10 (security hardening + auto-refund + LP Locker access control)

    address constant ROUTER = 0xc730dC49a40F978F3a48171cDa464a5fFDB1ddAa;
    address constant TOKEN_FACTORY = 0x1424Dd231bf56Beb7338DB0fc7d64a2A2297e715;
    address constant REGISTRY = 0xE648A49adE2Ea7Df83002b4a29283fD85D2adba8;
    address constant ESCROW_FACTORY = 0x009A91c0D608E68F583DfDd65B88F8BA71ea9645;
    address constant ESCROW_IMPL = 0xC5b1443081111444CA92B41F6A8dc54A364FB1ff;
    address constant LP_LOCKER = 0x08885Dd153bb9129976efdEA63608Dd590DBe69f;
    address constant MOCK_AERODROME_ROUTER = 0xB253FbF3220B27Cf0eb5f4142617b520Bf87Fb80;
    address constant TIME_ORACLE = 0x67d0Fe87433347587c6d3Bee6476eE6F3ae55f91;

    // ====================================================================

    function run() external view {
        console.log("========== VERIFYING DEPLOYMENT ==========");
        console.log("");

        uint256 failures = 0;

        // 1. Verify Router (has tokenFactory, registry, escrowFactory, lpLocker methods)
        console.log("1. Verifying VibesLaunchRouterV2...");
        try IRouter(ROUTER).tokenFactory() returns (address tf) {
            if (tf != TOKEN_FACTORY) {
                console.log("   FAIL: router.tokenFactory() =", tf);
                console.log("         Expected:", TOKEN_FACTORY);
                failures++;
            } else {
                console.log("   OK: tokenFactory matches");
            }
        } catch {
            console.log("   FAIL: Cannot call tokenFactory() - wrong contract type?");
            failures++;
        }

        try IRouter(ROUTER).registry() returns (address r) {
            if (r != REGISTRY) {
                console.log("   FAIL: router.registry() =", r);
                console.log("         Expected:", REGISTRY);
                failures++;
            } else {
                console.log("   OK: registry matches");
            }
        } catch {
            console.log("   FAIL: Cannot call registry() - wrong contract type?");
            failures++;
        }

        try IRouter(ROUTER).escrowFactory() returns (address ef) {
            if (ef != ESCROW_FACTORY) {
                console.log("   FAIL: router.escrowFactory() =", ef);
                console.log("         Expected:", ESCROW_FACTORY);
                failures++;
            } else {
                console.log("   OK: escrowFactory matches");
            }
        } catch {
            console.log("   FAIL: Cannot call escrowFactory() - wrong contract type?");
            failures++;
        }

        try IRouter(ROUTER).lpLocker() returns (address lp) {
            if (lp != LP_LOCKER) {
                console.log("   FAIL: router.lpLocker() =", lp);
                console.log("         Expected:", LP_LOCKER);
                failures++;
            } else {
                console.log("   OK: lpLocker matches");
            }
        } catch {
            console.log("   FAIL: Cannot call lpLocker() - wrong contract type?");
            failures++;
        }

        // 2. Verify LP Locker (has DEAD_ADDRESS, aerodromeRouter methods)
        console.log("");
        console.log("2. Verifying VibesLPLocker...");
        try ILPLocker(LP_LOCKER).DEAD_ADDRESS() returns (address dead) {
            if (dead == address(0xdead)) {
                console.log("   OK: DEAD_ADDRESS = 0xdead (correct LP Locker)");
            } else {
                console.log("   WARN: DEAD_ADDRESS =", dead);
            }
        } catch {
            console.log("   FAIL: Cannot call DEAD_ADDRESS() - NOT an LP Locker!");
            failures++;
        }

        try ILPLocker(LP_LOCKER).aerodromeRouter() returns (address ar) {
            if (ar != MOCK_AERODROME_ROUTER) {
                console.log("   WARN: lpLocker.aerodromeRouter() =", ar);
                console.log("         Expected mockAerodromeRouter:", MOCK_AERODROME_ROUTER);
            } else {
                console.log("   OK: aerodromeRouter matches");
            }
        } catch {
            console.log("   FAIL: Cannot call aerodromeRouter() - NOT an LP Locker!");
            failures++;
        }

        // 3. Verify Escrow Factory (has implementation, authorizedRouter methods)
        console.log("");
        console.log("3. Verifying VibesTranchEscrowFactory...");
        try IEscrowFactory(ESCROW_FACTORY).implementation() returns (address impl) {
            if (impl != ESCROW_IMPL) {
                console.log("   FAIL: escrowFactory.implementation() =", impl);
                console.log("         Expected:", ESCROW_IMPL);
                failures++;
            } else {
                console.log("   OK: implementation matches");
            }
        } catch {
            console.log("   FAIL: Cannot call implementation() - NOT an Escrow Factory!");
            failures++;
        }

        try IEscrowFactory(ESCROW_FACTORY).authorizedRouter() returns (address ar) {
            if (ar != ROUTER) {
                console.log("   FAIL: escrowFactory.authorizedRouter() =", ar);
                console.log("         Expected:", ROUTER);
                failures++;
            } else {
                console.log("   OK: authorizedRouter matches");
            }
        } catch {
            console.log("   FAIL: Cannot call authorizedRouter() - NOT an Escrow Factory!");
            failures++;
        }

        // 4. Verify Registry (has authorizedRouters method)
        console.log("");
        console.log("4. Verifying VibesRegistry...");
        try IRegistry(REGISTRY).authorizedRouters(ROUTER) returns (bool authorized) {
            if (!authorized) {
                console.log("   WARN: Router not authorized in registry");
            } else {
                console.log("   OK: Router is authorized in registry");
            }
        } catch {
            console.log("   FAIL: Cannot call authorizedRouters() - NOT a Registry!");
            failures++;
        }

        // 5. Verify Token Factory (by checking code exists)
        console.log("");
        console.log("5. Verifying VibesTokenFactory...");
        if (TOKEN_FACTORY.code.length > 0) {
            console.log("   OK: Contract exists at TOKEN_FACTORY address");
        } else {
            console.log("   FAIL: No contract at TOKEN_FACTORY address!");
            failures++;
        }

        // 6. Verify Escrow Implementation (has KICKSTART_BPS constant)
        console.log("");
        console.log("6. Verifying VibesTranchEscrow (impl)...");
        try IEscrow(ESCROW_IMPL).KICKSTART_BPS() returns (uint256 bps) {
            if (bps == 1000) { // 10%
                console.log("   OK: KICKSTART_BPS = 1000 (correct Escrow impl)");
            } else {
                console.log("   WARN: KICKSTART_BPS =", bps);
            }
        } catch {
            console.log("   FAIL: Cannot call KICKSTART_BPS() - NOT an Escrow impl!");
            failures++;
        }

        // 7. Verify Time Oracle (if set)
        console.log("");
        console.log("7. Verifying MockTimeOracle...");
        if (TIME_ORACLE != address(0)) {
            try ITimeOracle(TIME_ORACLE).getTime() returns (uint256 t) {
                console.log("   OK: getTime() =", t);
            } catch {
                console.log("   FAIL: Cannot call getTime() - NOT a Time Oracle!");
                failures++;
            }
        } else {
            console.log("   SKIP: No time oracle configured");
        }

        // Summary
        console.log("");
        console.log("==========================================");
        if (failures == 0) {
            console.log("SUCCESS: All verifications passed!");
            console.log("contracts.ts addresses are correctly configured.");
        } else {
            console.log("FAILED:", failures, "verification(s) failed!");
            console.log("CHECK YOUR contracts.ts ADDRESSES!");
        }
        console.log("==========================================");
    }
}

// Minimal interfaces for verification
interface IRouter {
    function tokenFactory() external view returns (address);
    function registry() external view returns (address);
    function escrowFactory() external view returns (address);
    function lpLocker() external view returns (address);
}

interface ILPLocker {
    function DEAD_ADDRESS() external view returns (address);
    function aerodromeRouter() external view returns (address);
}

interface IEscrowFactory {
    function implementation() external view returns (address);
    function authorizedRouter() external view returns (address);
}

interface IRegistry {
    function authorizedRouters(address) external view returns (bool);
}

interface IEscrow {
    function KICKSTART_BPS() external view returns (uint256);
}

interface ITimeOracle {
    function getTime() external view returns (uint256);
}
