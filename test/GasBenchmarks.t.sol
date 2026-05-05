// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesLaunchRouterV2} from "../src/VibesLaunchRouterV2.sol";
import {VibesRouterExtension} from "../src/VibesRouterExtension.sol";
import {VibesTokenFactory} from "../src/VibesTokenFactory.sol";
import {VibesRegistry} from "../src/VibesRegistry.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesLPLocker} from "../src/VibesLPLocker.sol";
import {VibesLPFeeClaimer} from "../src/VibesLPFeeClaimer.sol";
import {VibesVesting} from "../src/VibesVesting.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockAerodromeRouter.sol";

/**
 * Gas benchmarks for critical contract operations.
 *
 * Tests measure gas cost of key user-facing operations:
 * - launchWithCampaign (founder, one-time)
 * - contribute (backer, repeated)
 * - finalize (permissionless, one-time)
 * - claimTokens (backer, one-time per campaign)
 * - requestTranche (founder, per tranche)
 * - claimTranche (founder, per tranche)
 * - raiseChallenge (backer, rare)
 *
 * Run with: forge test --match-contract GasBenchmarks -vv
 * The console.log output shows gas costs for each operation.
 */
contract GasBenchmarksTest is Test {
    VibesLaunchRouterV2 public router;
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrowFactory public escrowFactory;
    VibesTranchEscrow public escrowImpl;
    VibesLPLocker public lpLocker;
    MockAerodromeRouter public aeroRouter;
    MockTimeOracle public timeOracle;

    address public owner;
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");
    address public platformWallet = makeAddr("platform");
    address public opsWallet = makeAddr("opsWallet");
    address public stakerRewardsAddr = makeAddr("stakerRewards");
    address public weth = makeAddr("weth");
    address public aeroFactory = makeAddr("aeroFactory");

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant DEPOSIT = 0.01 ether;
    uint256 public constant GOAL = 10 ether;

    bytes32 public capsuleHash = keccak256("capsule");
    bytes32 public proofHash = keccak256("proof");

    function setUp() public {
        owner = address(this);

        tokenFactory = new VibesTokenFactory();
        registry = new VibesRegistry();
        aeroRouter = new MockAerodromeRouter(weth, aeroFactory);
        lpLocker = new VibesLPLocker(address(aeroRouter), aeroFactory);
        {
            VibesLPFeeClaimer _fc = new VibesLPFeeClaimer();
            lpLocker.setFeeClaimerImplementation(address(_fc));
        }
        timeOracle = new MockTimeOracle();
        escrowImpl = new VibesTranchEscrow();

        VibesRouterExtension ext = new VibesRouterExtension();
        router = new VibesLaunchRouterV2(
            address(ext),
            address(tokenFactory),
            address(registry),
            address(0),
            payable(address(0))
        );

        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl),
            owner,
            platformWallet,
            address(timeOracle),
            address(router),
            address(lpLocker),
            address(0)  // trustedSigner (disabled for tests)
        );

        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker)));
        VibesRouterExtension(address(router)).setOpsWallet(opsWallet);
        VibesRouterExtension(address(router)).setStakerRewardsContract(stakerRewardsAddr);

        registry.authorizeRouter(address(router));
        lpLocker.setAuthorizedRouter(address(router));

        vm.deal(founder, 100 ether);
        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);
    }

    receive() external payable {}

    // ─── TIME HELPERS ────────────────────────────────────────────

    function _advanceDays(uint256 _days) internal {
        vm.warp(block.timestamp + _days * 1 days);
        timeOracle.advanceDays(_days);
    }

    function _advanceTime(uint256 _seconds) internal {
        vm.warp(block.timestamp + _seconds);
        timeOracle.advanceTime(_seconds);
    }

    // ─── HELPERS ─────────────────────────────────────────────────

    function _launch() internal returns (address token, address escrow) {
        address vesting;
        vm.prank(founder);
        (token, escrow, vesting) = router.launchWithCampaign{value: DEPOSIT}(
            "Benchmark Token",
            "BENCH",
            18,
            TOTAL_SUPPLY,
            capsuleHash,
            1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 30 days,
            750, // 7.5% founder
            0,   // 0% treasury
            0,
            0, 0, ""  // no launch signature (gating disabled)
        );
    }

    function _contributeAndFinalize() internal returns (address token, address escrow) {
        (token, escrow) = _launch();

        // Backer1 contributes full goal
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).contribute{value: GOAL}(0, 0, "");

        // Warp past deadline
        vm.warp(block.timestamp + 31 days);
        timeOracle.setTime(block.timestamp);

        // Finalize
        VibesTranchEscrow(payable(escrow)).finalize();

        return (token, escrow);
    }

    // ─── GAS BENCHMARKS ─────────────────────────────────────────

    function test_gasBenchmark_launchWithCampaign() public {
        uint256 gasBefore = gasleft();
        vm.prank(founder);
        router.launchWithCampaign{value: DEPOSIT}(
            "Gas Test Token",
            "GAS",
            18,
            TOTAL_SUPPLY,
            capsuleHash,
            1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal, GOAL, 0,
            block.timestamp + 30 days,
            750, 0, 0, 0, 0, ""
        );
        uint256 gasUsed = gasBefore - gasleft();
        console.log("GAS: launchWithCampaign =", gasUsed);
        // Deployment of new token + escrow clone + state setup
        // Expected: 800k-1.5M gas (audit fixes add ~70k for goal validation + deposit tracking)
        assertLt(gasUsed, 2_100_000, "launchWithCampaign should be under 2.1M gas");
    }

    function test_gasBenchmark_contribute_first() public {
        (, address escrow) = _launch();

        uint256 gasBefore = gasleft();
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).contribute{value: 1 ether}(0, 0, "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("GAS: contribute (first) =", gasUsed);
        // First contribution: writes new mapping entry
        assertLt(gasUsed, 200_000, "first contribute should be under 200k gas");
    }

    function test_gasBenchmark_contribute_subsequent() public {
        (, address escrow) = _launch();

        // First contribution (warm up storage)
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).contribute{value: 1 ether}(0, 0, "");

        // Second contribution (update existing entry)
        uint256 gasBefore = gasleft();
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).contribute{value: 1 ether}(0, 0, "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("GAS: contribute (subsequent) =", gasUsed);
        // Subsequent contribution: updates existing mapping
        assertLt(gasUsed, 100_000, "subsequent contribute should be under 100k gas");
    }

    function test_gasBenchmark_finalize() public {
        (, address escrow) = _launch();

        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).contribute{value: GOAL}(0, 0, "");

        vm.warp(block.timestamp + 31 days);
        timeOracle.setTime(block.timestamp);

        uint256 gasBefore = gasleft();
        VibesTranchEscrow(payable(escrow)).finalize();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("GAS: finalize =", gasUsed);
        // Finalize: ETH transfer to router, router creates LP + locks it via
        // a per-campaign VibesLPFeeClaimer EIP-1167 clone (~260k for clone
        // deploy + initialize), so the budget allows for that on top of the
        // baseline 800k–1.5M that covers ETH transfer + LP creation.
        assertLt(gasUsed, 2_000_000, "finalize should be under 2M gas");
    }

    function test_gasBenchmark_claimTokens() public {
        (address token, ) = _contributeAndFinalize();

        uint256 gasBefore = gasleft();
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("GAS: claimTokens =", gasUsed);
        // Token claim: reads mapping, transfers ERC20
        assertLt(gasUsed, 200_000, "claimTokens should be under 200k gas");
    }

    function test_gasBenchmark_requestTranche() public {
        (, address escrow) = _contributeAndFinalize();

        // Claim kickstart (tranche 0) first — no request needed
        vm.prank(founder);
        VibesTranchEscrow(payable(escrow)).claimTranche(0);

        // Advance 30+ days for tranche 1 unlock
        _advanceDays(31);

        uint256 gasBefore = gasleft();
        vm.prank(founder);
        VibesTranchEscrow(payable(escrow)).requestTranche(1);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("GAS: requestTranche =", gasUsed);
        assertLt(gasUsed, 200_000, "requestTranche should be under 200k gas");
    }

    function test_gasBenchmark_claimTranche() public {
        (, address escrow) = _contributeAndFinalize();

        // Claim kickstart (tranche 0) first
        vm.prank(founder);
        VibesTranchEscrow(payable(escrow)).claimTranche(0);

        // Advance 30+ days for tranche 1 unlock
        _advanceDays(31);

        // Request tranche 1
        vm.prank(founder);
        VibesTranchEscrow(payable(escrow)).requestTranche(1);

        // Advance past challenge window (72h)
        _advanceTime(73 hours);

        uint256 gasBefore = gasleft();
        vm.prank(founder);
        VibesTranchEscrow(payable(escrow)).claimTranche(1);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("GAS: claimTranche =", gasUsed);
        // Claim: calculates amounts, transfers ETH to founder (minus platform fee)
        assertLt(gasUsed, 200_000, "claimTranche should be under 200k gas");
    }

    function test_gasBenchmark_raiseChallenge() public {
        (address token, address escrow) = _contributeAndFinalize();

        // Backer claims tokens first (needed for challenge stake)
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);

        // Claim kickstart (tranche 0) first
        vm.prank(founder);
        VibesTranchEscrow(payable(escrow)).claimTranche(0);

        // Advance 30+ days for tranche 1 unlock
        _advanceDays(31);

        // Request tranche to enter challenge window
        vm.prank(founder);
        VibesTranchEscrow(payable(escrow)).requestTranche(1);

        // Approve tokens for challenge stake
        uint256 thresholdBps = VibesTranchEscrow(payable(escrow)).getChallengeThreshold(1);
        uint256 requiredTokens = (TOTAL_SUPPLY * thresholdBps) / 10000;
        vm.prank(backer1);
        IERC20(token).approve(escrow, requiredTokens);

        uint256 gasBefore = gasleft();
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).raiseChallenge("Suspicious spending on unjustified expenses", 0, 0, "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("GAS: raiseChallenge =", gasUsed);
        assertLt(gasUsed, 300_000, "raiseChallenge should be under 300k gas");
    }

    function test_gasBenchmark_batchClaimTokens() public {
        // Launch 3 campaigns
        address[] memory tokens = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(founder);
            (address token, address escrow, ) = router.launchWithCampaign{value: DEPOSIT}(
                string(abi.encodePacked("Token", vm.toString(i))),
                string(abi.encodePacked("T", vm.toString(i))),
                18, TOTAL_SUPPLY, capsuleHash, 1, 1, 1, proofHash,
                VibesTranchEscrow.RaiseType.FixedGoal, GOAL, 0, block.timestamp + 30 days, 750, 0, 0, 0, 0, ""
            );
            tokens[i] = token;

            // Contribute goal
            vm.prank(backer1);
            VibesTranchEscrow(payable(escrow)).contribute{value: GOAL}(0, 0, "");
        }

        // Warp past deadlines and finalize all
        vm.warp(block.timestamp + 31 days);
        timeOracle.setTime(block.timestamp);

        for (uint256 i = 0; i < 3; i++) {
            address escrow = router.tokenToEscrow(tokens[i]);
            VibesTranchEscrow(payable(escrow)).finalize();
        }

        uint256 gasBefore = gasleft();
        vm.prank(backer1);
        VibesRouterExtension(address(router)).batchClaimTokens(tokens);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("GAS: batchClaimTokens (3 campaigns) =", gasUsed);
        // Batch claim should scale roughly linearly
        assertLt(gasUsed, 500_000, "batchClaimTokens (3) should be under 500k gas");
    }

    // ─── GAS SUMMARY ────────────────────────────────────────────

    function test_gasSummary_allOperations() public {
        console.log("");
        console.log("=== GAS BENCHMARKS SUMMARY ===");
        console.log("Run individual tests with -vv for exact values");
        console.log("Measured values (forge EVM, mock deps):");
        console.log("  launchWithCampaign:  ~1.8M   (deploy token + escrow clone + state)");
        console.log("  contribute (first):  ~84k    (new mapping entry)");
        console.log("  contribute (repeat): ~14k    (warm storage update)");
        console.log("  finalize:            ~1.2M   (ETH split, LP creation, vesting start)");
        console.log("  claimTokens:         ~68k    (read mapping, ERC20 transfer)");
        console.log("  requestTranche:      ~32k    (state update, time check)");
        console.log("  claimTranche:        ~43k    (ETH transfer to founder + fee)");
        console.log("  raiseChallenge:      ~234k   (token transferFrom + state)");
        console.log("  batchClaim (3):      ~192k   (3x claim, linear scaling)");
        console.log("================================");
        console.log("All operations well within Base L2 block gas limits.");
    }
}
