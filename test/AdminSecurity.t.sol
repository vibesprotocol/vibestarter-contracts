// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesLaunchRouterV2} from "../src/VibesLaunchRouterV2.sol";
import {VibesRouterExtension} from "../src/VibesRouterExtension.sol";
import {VibesRouterStorage} from "../src/VibesRouterStorage.sol";
import {VibesTokenFactory} from "../src/VibesTokenFactory.sol";
import {VibesRegistry} from "../src/VibesRegistry.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTreasuryEscrow} from "../src/VibesTreasuryEscrow.sol";
import {VibesVesting} from "../src/VibesVesting.sol";
import {VibesLPLocker} from "../src/VibesLPLocker.sol";
import {VibesLPFeeClaimer} from "../src/VibesLPFeeClaimer.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockAerodromeRouter.sol";

// ============ Helper mock router for standalone escrow tests ============

/// @notice Minimal router that satisfies the authorizedRouter callback interface
///         for VibesTranchEscrow without pulling in the full router plumbing.
contract MockEscrowRouter {
    function completeFinalization(address) external {
        // Mark LP as created so requestTranche/claimTranche paths are unblocked
        VibesTranchEscrow(payable(msg.sender)).setLPCreated();
    }
    function completeDistribution(address) external {}
    receive() external payable {}
}

/**
 * @title AdminSecurityTest
 * @notice §5.1 Access Control — every admin function must revert when called by
 *         an unauthorized caller, and succeed when called by the correct admin.
 *
 * Covers 16 tests from docs/plans/contracts/test-plan.md §5.1:
 *   - Router owner: pause(), rescueETH(), setEscrowFactory()
 *   - Escrow admin: upholdChallenge(), freezeCampaign()
 *   - Treasury admin: upholdChallengeRework(), upholdChallengeMalicious()
 *   - Founder + Backer: verify neither can call any admin function
 */
contract AdminSecurityTest is Test {
    // Router stack (full deploy wiring — simplified from VibesLaunchRouterV2.t.sol)
    VibesLaunchRouterV2 public router;
    VibesRouterExtension public extension;
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrowFactory public escrowFactory;
    VibesLPLocker public lpLocker;
    MockAerodromeRouter public aeroRouter;
    MockTimeOracle public timeOracle;
    VibesTranchEscrow public escrowImpl;

    // Standalone escrow stack (for escrow-admin tests — uses MockEscrowRouter)
    MockEscrowRouter public mockEscrowRouter;
    VibesTranchEscrow public escrowImpl2;
    VibesTranchEscrowFactory public escrowFactory2;

    address public owner;                                   // router owner = this test contract
    address public escrowAdmin = makeAddr("escrowAdmin");
    address public treasuryAdmin = makeAddr("treasuryAdmin");
    address public founder = makeAddr("founder");
    address public backer = makeAddr("backer");
    address public backer2 = makeAddr("backer2");
    address public stranger = makeAddr("stranger");
    address public rescueRecipient = makeAddr("rescueRecipient");

    address public weth = makeAddr("weth");
    address public aeroFactory = makeAddr("aeroFactory");

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant GOAL = 10 ether;
    uint256 public constant TREASURY_AMOUNT = 100_000 ether; // 10% of supply

    // ============ setUp ============

    function setUp() public {
        owner = address(this);

        tokenFactory = new VibesTokenFactory();
        registry = new VibesRegistry();

        aeroRouter = new MockAerodromeRouter(weth, aeroFactory);
        lpLocker = new VibesLPLocker(address(aeroRouter), aeroFactory);
        // Wire fee claimer implementation so createAndLockLP doesn't revert
        // with FeeClaimerImplementationNotSet (test fixture parity with other suites).
        {
            VibesLPFeeClaimer _fc = new VibesLPFeeClaimer();
            lpLocker.setFeeClaimerImplementation(address(_fc));
        }

        timeOracle = new MockTimeOracle();
        timeOracle.setRealTimeMode(true);

        escrowImpl = new VibesTranchEscrow();

        extension = new VibesRouterExtension();
        router = new VibesLaunchRouterV2(
            address(extension),
            address(tokenFactory),
            address(registry),
            address(0),
            payable(address(0))
        );

        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl),
            owner,
            makeAddr("platform"),
            address(timeOracle),
            address(router),
            address(lpLocker),
            address(0) // trustedSigner disabled
        );

        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker)));
        VibesRouterExtension(address(router)).setOpsWallet(makeAddr("opsWallet"));
        VibesRouterExtension(address(router)).setStakerRewardsContract(makeAddr("stakerRewards"));

        registry.authorizeRouter(address(router));

        // Standalone escrow stack for escrow-admin tests: its factory admin is `escrowAdmin`
        mockEscrowRouter = new MockEscrowRouter();
        escrowImpl2 = new VibesTranchEscrow();
        escrowFactory2 = new VibesTranchEscrowFactory(
            address(escrowImpl2),
            escrowAdmin,
            makeAddr("platform2"),
            address(timeOracle),
            address(mockEscrowRouter),
            address(lpLocker),
            address(0)
        );

        vm.deal(founder, 100 ether);
        vm.deal(backer, 100 ether);
        vm.deal(backer2, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    /// @dev Required so the test contract (router owner) can receive ETH during rescue
    receive() external payable {}

    // ============================================================
    // 1-2. ROUTER: pause()  (onlyOwner)
    // ============================================================

    function test_routerOwner_canPause() public {
        // Owner is the test contract — call directly
        VibesRouterExtension(address(router)).pause();
        assertTrue(VibesRouterExtension(address(router)).paused(), "router should be paused");
    }

    function test_nonOwner_cannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).pause();
    }

    // ============================================================
    // 3-4. ROUTER: rescueETH(to, amount)  (onlyOwner)
    // ============================================================

    function test_routerOwner_canRescueETH() public {
        // Fund the router with loose ETH (no reserved deposits, since no launch was done)
        uint256 amount = 1 ether;
        vm.deal(address(router), amount);

        uint256 balBefore = rescueRecipient.balance;
        VibesRouterExtension(address(router)).rescueETH(rescueRecipient, amount);
        assertEq(rescueRecipient.balance - balBefore, amount, "recipient should receive rescued ETH");
    }

    function test_nonOwner_cannotRescueETH() public {
        vm.deal(address(router), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).rescueETH(stranger, 1 ether);
    }

    // ============================================================
    // 5-6. ROUTER: setEscrowFactory(addr)  (onlyOwner)
    // ============================================================

    function test_routerOwner_canSetEscrowFactory() public {
        address newFactory = makeAddr("newFactory");
        VibesRouterExtension(address(router)).setEscrowFactory(newFactory);
        assertEq(address(VibesRouterExtension(address(router)).escrowFactory()), newFactory);
    }

    function test_nonOwner_cannotSetEscrowFactory() public {
        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).setEscrowFactory(makeAddr("newFactory"));
    }

    // ============================================================
    // 7-8. ESCROW: upholdChallenge()  (onlyAdmin)
    // ============================================================

    function test_escrowAdmin_canUpholdChallenge() public {
        (VibesTranchEscrow escrow, ) = _createFundedEscrowWithChallenge();

        vm.prank(escrowAdmin);
        escrow.upholdChallenge();

        // Verify campaign transitioned to Frozen
        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        assertEq(
            uint8(camp.state),
            uint8(VibesTranchEscrow.CampaignState.Frozen),
            "campaign should be Frozen after uphold"
        );
    }

    function test_nonAdmin_cannotUpholdChallenge() public {
        (VibesTranchEscrow escrow, ) = _createFundedEscrowWithChallenge();

        vm.prank(stranger);
        vm.expectRevert(VibesTranchEscrow.OnlyAdmin.selector);
        escrow.upholdChallenge();
    }

    // ============================================================
    // 9-10. ESCROW: freezeCampaign(reason)  (onlyAdmin, inState Funded)
    // ============================================================

    function test_escrowAdmin_canFreezeCampaign() public {
        VibesTranchEscrow escrow = _createFundedEscrow();

        vm.prank(escrowAdmin);
        escrow.freezeCampaign("misuse of funds");

        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        // With tokens held by founder (full supply), redeemable supply > 0 → Frozen
        assertEq(
            uint8(camp.state),
            uint8(VibesTranchEscrow.CampaignState.Frozen),
            "campaign should be Frozen"
        );
    }

    function test_nonAdmin_cannotFreezeCampaign() public {
        VibesTranchEscrow escrow = _createFundedEscrow();

        vm.prank(stranger);
        vm.expectRevert(VibesTranchEscrow.OnlyAdmin.selector);
        escrow.freezeCampaign("fake reason");
    }

    // ============================================================
    // 11-12. TREASURY: upholdChallengeRework()  (onlyAdmin)
    // ============================================================

    function test_treasuryAdmin_canUpholdRework() public {
        (VibesTreasuryEscrow treasury, ) = _createTreasuryWithPendingChallenge();

        vm.prank(treasuryAdmin);
        treasury.upholdChallengeRework();

        // Active challenge state advanced to UpheldRework
        (, , , , VibesTreasuryEscrow.ChallengeState cstate) = treasury.activeChallenge();
        assertEq(uint8(cstate), uint8(VibesTreasuryEscrow.ChallengeState.UpheldRework));
    }

    function test_nonAdmin_cannotUpholdRework() public {
        (VibesTreasuryEscrow treasury, ) = _createTreasuryWithPendingChallenge();

        vm.prank(stranger);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAdmin.selector);
        treasury.upholdChallengeRework();
    }

    // ============================================================
    // 13-14. TREASURY: upholdChallengeMalicious()  (onlyAdmin)
    // ============================================================

    function test_treasuryAdmin_canUpholdMalicious() public {
        (VibesTreasuryEscrow treasury, ) = _createTreasuryWithPendingChallenge();

        vm.prank(treasuryAdmin);
        treasury.upholdChallengeMalicious();

        assertTrue(treasury.terminated(), "treasury should be terminated after malicious uphold");
    }

    function test_nonAdmin_cannotUpholdMalicious() public {
        (VibesTreasuryEscrow treasury, ) = _createTreasuryWithPendingChallenge();

        vm.prank(stranger);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAdmin.selector);
        treasury.upholdChallengeMalicious();
    }

    // ============================================================
    // 15. Founder cannot call any router/escrow/treasury admin fn
    // ============================================================

    function test_founder_cannotCallAdminFunctions() public {
        // --- Router: founder is not owner ---
        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).pause();

        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).rescueETH(founder, 1 ether);

        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).setEscrowFactory(makeAddr("newFactory"));

        // --- Escrow: founder is not admin ---
        VibesTranchEscrow escrow = _createFundedEscrow();
        vm.prank(founder);
        vm.expectRevert(VibesTranchEscrow.OnlyAdmin.selector);
        escrow.freezeCampaign("founder tries");

        (VibesTranchEscrow escrowWithChallenge, ) = _createFundedEscrowWithChallenge();
        vm.prank(founder);
        vm.expectRevert(VibesTranchEscrow.OnlyAdmin.selector);
        escrowWithChallenge.upholdChallenge();

        // --- Treasury: founder is NOT admin (they're the founder, which is a separate role) ---
        (VibesTreasuryEscrow treasury, ) = _createTreasuryWithPendingChallenge();
        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAdmin.selector);
        treasury.upholdChallengeRework();

        vm.prank(founder);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAdmin.selector);
        treasury.upholdChallengeMalicious();
    }

    // ============================================================
    // 16. Backer cannot call any router/escrow/treasury admin fn
    // ============================================================

    function test_backer_cannotCallAdminFunctions() public {
        // --- Router ---
        vm.prank(backer);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).pause();

        vm.prank(backer);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).rescueETH(backer, 1 ether);

        vm.prank(backer);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).setEscrowFactory(makeAddr("newFactory"));

        // --- Escrow ---
        VibesTranchEscrow escrow = _createFundedEscrow();
        vm.prank(backer);
        vm.expectRevert(VibesTranchEscrow.OnlyAdmin.selector);
        escrow.freezeCampaign("backer tries");

        (VibesTranchEscrow escrowWithChallenge, ) = _createFundedEscrowWithChallenge();
        vm.prank(backer);
        vm.expectRevert(VibesTranchEscrow.OnlyAdmin.selector);
        escrowWithChallenge.upholdChallenge();

        // --- Treasury ---
        (VibesTreasuryEscrow treasury, ) = _createTreasuryWithPendingChallenge();
        vm.prank(backer);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAdmin.selector);
        treasury.upholdChallengeRework();

        vm.prank(backer);
        vm.expectRevert(VibesTreasuryEscrow.OnlyAdmin.selector);
        treasury.upholdChallengeMalicious();
    }

    // ============================================================
    // HELPERS
    // ============================================================

    /// @dev Create an escrow in Funded state (LP created, startTime set).
    ///      Founder holds the full token supply. Ready for freezeCampaign / requestTranche.
    function _createFundedEscrow() internal returns (VibesTranchEscrow escrow) {
        // Founder deploys the project token (full supply to founder)
        vm.prank(founder);
        VibesToken token = new VibesToken("Test", "TST", 18, TOTAL_SUPPLY, founder);

        // MockEscrowRouter creates the escrow via the factory
        vm.prank(address(mockEscrowRouter));
        address escrowAddr = escrowFactory2.createEscrow(
            founder,
            address(token),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 7 days,
            0
        );
        escrow = VibesTranchEscrow(payable(escrowAddr));

        // Backer contributes the full goal
        vm.prank(backer);
        escrow.contribute{value: GOAL}(0, 0, "");

        // Finalize — this transitions Active → Funded and triggers mockEscrowRouter.setLPCreated()
        escrow.finalize();

        VibesTranchEscrow.Campaign memory camp = escrow.getCampaign();
        require(
            camp.state == VibesTranchEscrow.CampaignState.Funded,
            "helper: escrow not Funded"
        );
        require(escrow.lpCreated(), "helper: LP not marked created");
    }

    /// @dev Create a Funded escrow AND raise a challenge on tranche 1 (pending state).
    ///      Returns the escrow + the challenger address (backer, who holds >= 0.25% of supply).
    function _createFundedEscrowWithChallenge()
        internal
        returns (VibesTranchEscrow escrow, address challenger)
    {
        escrow = _createFundedEscrow();
        address token = escrow.getCampaign().token;

        // Founder seeds challenger (backer) with enough tokens to satisfy the 0.25%
        // threshold for tranches 1-2 (getChallengeThreshold(1) = 25 bps).
        // 0.25% of 1_000_000 ether = 2_500 ether. Give 10x headroom.
        challenger = backer;
        vm.prank(founder);
        VibesToken(token).transfer(challenger, 25_000 ether);

        // Claim kickstart (tranche 0) first — increments nextTranche to 1. Kickstart has
        // no challenge window, so no requestTranche needed. unlockTime = startTime (immediate).
        vm.prank(founder);
        escrow.claimTranche(0);

        // Advance to the tranche 1 unlock window: startTime + 30 days.
        // Campaign startTime was set by finalize() = block.timestamp at finalize.
        vm.warp(block.timestamp + 30 days + 1);

        // Founder requests tranche 1 (starts the 72h challenge window)
        vm.prank(founder);
        escrow.requestTranche(1);

        // Challenger approves and raises challenge
        uint256 required = (TOTAL_SUPPLY * 25) / 10000; // 0.25% for tranche 1
        vm.prank(challenger);
        VibesToken(token).approve(address(escrow), required);

        vm.prank(challenger);
        escrow.raiseChallenge("disputed milestone", 0, 0, "");

        // Sanity: challenge is Pending (Challenge struct = 6 fields)
        (, , , , , VibesTranchEscrow.ChallengeState cstate) = escrow.activeChallenge();
        require(cstate == VibesTranchEscrow.ChallengeState.Pending, "helper: challenge not pending");
    }

    /// @dev Create an active treasury with a pending proposal + pending challenge.
    ///      Treasury admin is `treasuryAdmin`.
    function _createTreasuryWithPendingChallenge()
        internal
        returns (VibesTreasuryEscrow treasury, VibesToken token)
    {
        // Founder deploys token, gets full supply
        vm.prank(founder);
        token = new VibesToken("Test", "TST", 18, TOTAL_SUPPLY, founder);

        // Deploy treasury with short release cliff so createProposal is callable quickly.
        // authorizedStarter = this test contract.
        treasury = new VibesTreasuryEscrow(
            address(token),
            founder,
            treasuryAdmin,
            1 days,      // RELEASE_CLIFF — short for tests
            1 hours,     // COOLDOWN
            72 hours     // CHALLENGE_WINDOW
        );

        // Fund treasury with tokens, then activate
        vm.prank(founder);
        token.transfer(address(treasury), TREASURY_AMOUNT);
        treasury.activate();

        // Seed challenger (backer) with > 0.5% of supply (required to raise treasury challenge)
        // 0.5% of 1_000_000 ether = 5_000 ether. Give 2x.
        vm.prank(founder);
        token.transfer(backer, 10_000 ether);

        // Advance past release cliff
        vm.warp(block.timestamp + 1 days + 1);

        // Founder creates a withdrawal proposal (max 10% of treasury balance)
        uint256 proposalAmount = TREASURY_AMOUNT / 20; // 5% — well under 10% cap
        vm.prank(founder);
        treasury.createProposal(proposalAmount, keccak256("reason"));

        // Challenger raises challenge
        uint256 required = (TOTAL_SUPPLY * 50) / 10000; // 0.5%
        vm.prank(backer);
        token.approve(address(treasury), required);

        vm.prank(backer);
        treasury.raiseChallenge("suspicious proposal");

        // Sanity: challenge pending
        (, , , , VibesTreasuryEscrow.ChallengeState cstate) = treasury.activeChallenge();
        require(cstate == VibesTreasuryEscrow.ChallengeState.Pending, "helper: treasury challenge not pending");
    }
}

/**
 * @title AdminRescueTest
 * @notice §5.2 Rescue Function Safeguards — rescueETH / rescueERC20 must respect
 *         reserved deposits, active escrows, pending backer claims, and pending LP
 *         allocations. Unrelated tokens and dead escrows must remain rescuable.
 *
 * Covers 7 tests from docs/plans/contracts/test-plan.md §5.2:
 *   1. rescueETH cannot drain ETH reserved for founder deposits
 *   2. rescueETH succeeds once all deposits have been refunded
 *   3. rescueERC20 blocked while backerTokensForClaims > 0 (active claims)
 *   4. rescueERC20 blocked while escrow state is Active (not a dead state)
 *   5. rescueERC20 blocked while pendingLP > 0 (and escrow is dead)
 *   6. rescueERC20 allowed after all claims processed + escrow dead + pendingLP == 0
 *   7. rescueERC20 always allowed for unrelated tokens (no escrow, no claims, no LP)
 *
 * Fresh fixture (option a from the brief): §5.2 needs a fully wired launch router
 *         (escrow factory authorized as router on the LP locker) for all 7 tests,
 *         which differs meaningfully from §5.1's standalone-escrow setup.
 */
contract AdminRescueTest is Test {
    VibesLaunchRouterV2 public router;
    VibesRouterExtension public extension;
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrowFactory public escrowFactory;
    VibesLPLocker public lpLocker;
    MockAerodromeRouter public aeroRouter;
    MockTimeOracle public timeOracle;
    VibesTranchEscrow public escrowImpl;

    address public owner;
    address public escrowAdmin = makeAddr("escrowAdmin");
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");
    address public opsWallet = makeAddr("opsWallet");
    address public stakerRewardsAddr = makeAddr("stakerRewards");
    address public rescueRecipient = makeAddr("rescueRecipient");

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
        // Wire fee claimer implementation so createAndLockLP doesn't revert
        // with FeeClaimerImplementationNotSet (test fixture parity with other suites).
        {
            VibesLPFeeClaimer _fc = new VibesLPFeeClaimer();
            lpLocker.setFeeClaimerImplementation(address(_fc));
        }

        timeOracle = new MockTimeOracle();
        timeOracle.setRealTimeMode(true);

        escrowImpl = new VibesTranchEscrow();

        extension = new VibesRouterExtension();
        router = new VibesLaunchRouterV2(
            address(extension),
            address(tokenFactory),
            address(registry),
            address(0),
            payable(address(0))
        );

        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl),
            escrowAdmin,
            makeAddr("platform"),
            address(timeOracle),
            address(router),
            address(lpLocker),
            address(0) // trustedSigner disabled
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

    /// @dev Required so the test contract (router owner) can receive rescued ETH
    receive() external payable {}

    // ============================================================
    // 1. rescueETH_cannotDrainReservedDeposits
    // ============================================================

    function test_rescueETH_cannotDrainReservedDeposits() public {
        // Launch a campaign — reserves DEPOSIT wei via tokenDeposits + totalReservedDeposits
        _launchFixedGoal();
        assertEq(router.totalReservedDeposits(), DEPOSIT, "deposit should be reserved after launch");

        // Top router up with loose ETH so available > 0 but still less than full balance.
        // N = DEPOSIT + 1 ether total balance; M = DEPOSIT reserved; available = 1 ether.
        // Asking for more than `available` must revert with the exact require string.
        uint256 extra = 1 ether;
        vm.deal(address(router), DEPOSIT + extra);

        vm.expectRevert(bytes("Would drain reserved deposits"));
        VibesRouterExtension(address(router)).rescueETH(rescueRecipient, extra + 1);

        // Sanity: rescuing exactly `available` still works (guards the inequality)
        VibesRouterExtension(address(router)).rescueETH(rescueRecipient, extra);
        assertEq(rescueRecipient.balance, extra, "recipient should get the available slice");
    }

    // ============================================================
    // 2. rescueETH_afterAllDepositsRefunded
    // ============================================================

    function test_rescueETH_afterAllDepositsRefunded() public {
        (address token, ) = _launchFixedGoal();
        assertEq(router.totalReservedDeposits(), DEPOSIT);

        // Owner refunds the deposit — clears tokenDeposits + totalReservedDeposits
        VibesRouterExtension(address(router)).refundDeposit(token, founder);
        assertEq(router.totalReservedDeposits(), 0, "reserved should be zero after refund");
        assertEq(VibesRouterExtension(address(router)).getDepositInfo(token), 0);

        // Force a clean loose balance on the router (refundDeposit sent the DEPOSIT to founder)
        uint256 amount = 2 ether;
        vm.deal(address(router), amount);

        // Full balance is rescuable now
        VibesRouterExtension(address(router)).rescueETH(rescueRecipient, amount);
        assertEq(rescueRecipient.balance, amount, "recipient should receive the full balance");
    }

    // ============================================================
    // 3. rescueERC20_blockedDuringActiveClaims
    // ============================================================

    function test_rescueERC20_blockedDuringActiveClaims() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Two backers → after finalize, backerTokensForClaims > 0. Claim with backer1
        // (puts tokens in holder hands → redeemable supply > 0), leave backer2 unclaimed
        // (so backerTokensForClaims stays > 0). Then freeze → escrow enters Frozen (dead),
        // which would skip the ActiveEscrow guard, exposing the ActiveClaims guard.
        vm.prank(backer1);
        escrow.contribute{value: 6 ether}(0, 0, "");
        vm.prank(backer2);
        escrow.contribute{value: 4 ether}(0, 0, "");

        vm.warp(block.timestamp + 15 days);
        escrow.finalize();
        assertEq(
            uint8(escrow.getCampaign().state),
            uint8(VibesTranchEscrow.CampaignState.Funded),
            "should be Funded after finalize"
        );

        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        assertGt(router.backerTokensForClaims(token), 0, "backer2 share still in router");

        // Admin freezes — redeemableSupply > 0 (backer1 holds tokens) so we land on Frozen
        vm.prank(escrowAdmin);
        escrow.freezeCampaign("test-freeze");
        assertEq(
            uint8(escrow.getCampaign().state),
            uint8(VibesTranchEscrow.CampaignState.Frozen),
            "escrow should be Frozen (dead state)"
        );

        // Rescue blocked by ActiveClaims guard (guard 1 fires before the escrow guard)
        vm.expectRevert(VibesRouterStorage.TokenHasActiveClaims.selector);
        VibesRouterExtension(address(router)).rescueERC20(token, rescueRecipient, 1);
    }

    // ============================================================
    // 4. rescueERC20_blockedWithActiveEscrow
    // ============================================================

    function test_rescueERC20_blockedWithActiveEscrow() public {
        (address token, address escrowAddr) = _launchFixedGoal();

        // Escrow is freshly created → state == Active (non-dead).
        // backerTokensForClaims == 0, pendingLP > 0. Guard 1 skips, guard 2 fires.
        assertEq(
            uint8(VibesTranchEscrow(payable(escrowAddr)).getCampaign().state),
            uint8(VibesTranchEscrow.CampaignState.Active),
            "escrow should be Active"
        );
        assertEq(router.backerTokensForClaims(token), 0, "no active claims yet");

        vm.expectRevert(VibesRouterStorage.TokenHasActiveEscrow.selector);
        VibesRouterExtension(address(router)).rescueERC20(token, rescueRecipient, 1);
    }

    // ============================================================
    // 5. rescueERC20_blockedWithPendingLP
    // ============================================================

    function test_rescueERC20_blockedWithPendingLP() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Let the campaign fail (no contributions, deadline passes → finalize → Failed).
        // Failed is a "dead" state → escrow guard skips. No backer tokens were recorded
        // (Phase2 never ran) → claims guard skips. pendingLP was set at launch and never
        // cleared (Phase1 never ran) → pendingLP guard fires.
        vm.warp(block.timestamp + 15 days);
        escrow.finalize();
        assertEq(
            uint8(escrow.getCampaign().state),
            uint8(VibesTranchEscrow.CampaignState.Failed),
            "escrow should be Failed (dead)"
        );

        (, , , , uint256 pendingLPTokens) = VibesRouterExtension(address(router)).getTokenInfo(token);
        assertGt(pendingLPTokens, 0, "pendingLP must still be > 0");
        assertEq(router.backerTokensForClaims(token), 0, "no backer claims for a failed raise");

        vm.expectRevert(VibesRouterStorage.TokenHasPendingLP.selector);
        VibesRouterExtension(address(router)).rescueERC20(token, rescueRecipient, 1);
    }

    // ============================================================
    // 6. rescueERC20_allowedAfterAllClaimsProcessed
    // ============================================================

    function test_rescueERC20_allowedAfterAllClaimsProcessed() public {
        (address token, address escrowAddr) = _launchFixedGoal();
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Single backer hits the goal exactly → finalize → Funded → all backer tokens
        // claimable by one backer.
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        vm.warp(block.timestamp + 15 days);
        escrow.finalize();

        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        assertEq(router.backerTokensForClaims(token), 0, "all claims drained");

        // pendingLP was cleared in Phase 1
        (, , , , uint256 pendingLPTokens) = VibesRouterExtension(address(router)).getTokenInfo(token);
        assertEq(pendingLPTokens, 0, "pendingLP cleared after Phase 1");

        // Freeze → escrow transitions to Frozen (redeemable > 0 since backer1 holds tokens).
        // This makes the escrow "dead" so the rescueERC20 escrow guard skips.
        vm.prank(escrowAdmin);
        escrow.freezeCampaign("post-claim freeze");
        assertEq(
            uint8(escrow.getCampaign().state),
            uint8(VibesTranchEscrow.CampaignState.Frozen),
            "escrow should be Frozen"
        );

        // Simulate accidentally-sent tokens arriving at the router post-campaign
        uint256 strayAmount = 500 ether;
        VibesToken stray = new VibesToken("Stray", "STR", 18, strayAmount, address(this));
        // The real campaign token is address `token`; to exercise the rescue on the *campaign*
        // token we top up the router with a bit of it from the founder's residual. The founder
        // has no balance (router held full supply at launch), so we mint stray tokens and rescue
        // the *actual* campaign token by transferring a small amount there first.
        // Easier: rescue amount = 0. All guards pass; zero-amount transfer is a no-op.
        VibesRouterExtension(address(router)).rescueERC20(token, rescueRecipient, 0);

        // Also prove the router can rescue non-zero balances after the guards clear, using
        // the stray token which we moved to the router ourselves.
        stray.transfer(address(router), strayAmount);
        VibesRouterExtension(address(router)).rescueERC20(address(stray), rescueRecipient, strayAmount);
        assertEq(stray.balanceOf(rescueRecipient), strayAmount, "stray rescued after guards cleared");
    }

    // ============================================================
    // 7. rescueERC20_unrelatedTokenAlwaysAllowed
    // ============================================================

    function test_rescueERC20_unrelatedTokenAlwaysAllowed() public {
        // Deploy a token completely unrelated to any campaign — no tokenToEscrow entry,
        // no backerTokensForClaims entry, no pendingLP entry.
        uint256 supply = 1_000 ether;
        VibesToken unrelated = new VibesToken("Unrelated", "UNR", 18, supply, address(this));

        // Send the full supply to the router (simulating an accidental transfer)
        unrelated.transfer(address(router), supply);

        // Launch a completely separate campaign so the router is otherwise "busy" —
        // this ensures the unrelated token really is the one being tested, not a fresh-state fluke.
        _launchFixedGoal();

        // Sanity: guards for unrelated token are all clean
        assertEq(router.tokenToEscrow(address(unrelated)), address(0));
        assertEq(router.backerTokensForClaims(address(unrelated)), 0);
        (, , , , uint256 pendingLPTokens) =
            VibesRouterExtension(address(router)).getTokenInfo(address(unrelated));
        assertEq(pendingLPTokens, 0);

        VibesRouterExtension(address(router)).rescueERC20(address(unrelated), rescueRecipient, supply);
        assertEq(unrelated.balanceOf(rescueRecipient), supply, "unrelated token fully rescued");
        assertEq(unrelated.balanceOf(address(router)), 0, "router drained of unrelated token");
    }

    // ============================================================
    // HELPERS
    // ============================================================

    /// @dev Launch a FixedGoal campaign via the router. Mirrors AuditFixes.t.sol::_launchFixedGoal.
    function _launchFixedGoal() internal returns (address token, address escrow) {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (token, escrow, ) = router.launchWithCampaign{value: DEPOSIT}(
            "TestToken", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline, 750, 0, 0,
            0, 0, ""  // launchNonce, sigDeadline, launchSignature (disabled)
        );
    }
}

// ============================================================
// Mock staker rewards sink — has code, so stakerDest.code.length > 0.
// Accepts notifyReward as a no-op so _executePhase2 emits
// StakerRewardsAllocated rather than StakerRewardsNotifyFailed.
// ============================================================

contract MockStakerRewardsSink {
    // Match the VibesStakerRewards.notifyReward signature exactly; no-op body.
    function notifyReward(address, uint256, address) external {}
}

/**
 * @title AdminInfraSwapTest
 * @notice §5.3 Infrastructure Swap Attacks — the router's `onlyOwner` setters
 *         (escrow factory, LP locker, staker rewards, fee config) must correctly
 *         redirect the downstream flow for NEW work while NOT retroactively
 *         redirecting in-flight campaigns bound to a previous infra target.
 *
 * Covers 5 tests from docs/plans/contracts/test-plan.md §5.3:
 *   1. setEscrowFactory: new campaigns use the new factory (not the old one)
 *   2. setLPLocker: finalization Phase 1 routes LP ETH/tokens to the new locker
 *   3. setStakerRewardsContract: Phase 2 transfers staker tokens to the new rewards
 *   4. setFeeConfig: fees on a subsequent launch go to the new recipient
 *   5. Existing campaigns are NOT retroactively redirected by a factory swap
 *
 * Timing guarantees derived from reading the router:
 *   - escrowFactory is read at `launchWithCampaign` call time (per-launch).
 *   - lpLocker is read at Phase 1 execution time (`_executePhase1`, via
 *     `escrow.finalize()` → `completeFinalization`). A pre-finalize swap
 *     redirects the LP atomically.
 *   - stakerRewardsContract is read at Phase 1 and cached into
 *     `_pendingStakerRecipient[token]` for Phase 2. A pre-finalize swap
 *     redirects the staker transfer + notify.
 *   - feeRecipient / flatFeeWei are read at launch time inside
 *     `_handleFeesAndDeposit`, per call.
 */
contract AdminInfraSwapTest is Test {
    VibesLaunchRouterV2 public router;
    VibesRouterExtension public extension;
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrowFactory public escrowFactory1;
    VibesLPLocker public lpLocker1;
    MockAerodromeRouter public aeroRouter;
    MockTimeOracle public timeOracle;
    VibesTranchEscrow public escrowImpl;

    address public owner;
    address public escrowAdmin = makeAddr("escrowAdmin");
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");
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
        lpLocker1 = new VibesLPLocker(address(aeroRouter), aeroFactory);
        // Wire fee claimer implementation so createAndLockLP doesn't revert.
        {
            VibesLPFeeClaimer _fc = new VibesLPFeeClaimer();
            lpLocker1.setFeeClaimerImplementation(address(_fc));
        }

        timeOracle = new MockTimeOracle();
        timeOracle.setRealTimeMode(true);

        escrowImpl = new VibesTranchEscrow();

        extension = new VibesRouterExtension();
        router = new VibesLaunchRouterV2(
            address(extension),
            address(tokenFactory),
            address(registry),
            address(0),
            payable(address(0))
        );

        escrowFactory1 = new VibesTranchEscrowFactory(
            address(escrowImpl),
            escrowAdmin,
            makeAddr("platform"),
            address(timeOracle),
            address(router),
            address(lpLocker1),
            address(0) // trustedSigner disabled
        );

        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory1));
        VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker1)));
        VibesRouterExtension(address(router)).setOpsWallet(opsWallet);
        VibesRouterExtension(address(router)).setStakerRewardsContract(stakerRewardsAddr);

        registry.authorizeRouter(address(router));
        lpLocker1.setAuthorizedRouter(address(router));

        vm.deal(founder, 100 ether);
        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);
    }

    /// @dev Receive rescued/refunded ETH (router owner is this contract)
    receive() external payable {}

    // ============================================================
    // 1. test_setEscrowFactory_newCampaignsUseMaliciousFactory
    //    Swap factory → a new launch is created by the NEW factory.
    // ============================================================

    function test_setEscrowFactory_newCampaignsUseMaliciousFactory() public {
        // --- Launch A with factory1 ---
        (, address escrowA) = _launch("A", "A");
        assertTrue(escrowFactory1.isEscrow(escrowA), "A should belong to factory1");

        // --- Deploy factory2, authorize router for it, swap the router pointer ---
        VibesTranchEscrowFactory escrowFactory2 = new VibesTranchEscrowFactory(
            address(escrowImpl),
            escrowAdmin,
            makeAddr("platform2"),
            address(timeOracle),
            address(router),
            address(lpLocker1),
            address(0)
        );

        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory2));
        assertEq(
            address(VibesRouterExtension(address(router)).escrowFactory()),
            address(escrowFactory2),
            "router pointer should be factory2"
        );

        // --- Launch B with factory2 ---
        (, address escrowB) = _launch("B", "B");

        // Escrow B must have been created by factory2, NOT by factory1
        assertTrue(escrowFactory2.isEscrow(escrowB), "B should belong to factory2");
        assertFalse(escrowFactory1.isEscrow(escrowB), "B should NOT belong to factory1");
        assertTrue(escrowA != escrowB, "escrows must be distinct");
    }

    // ============================================================
    // 2. test_setLPLocker_redirectsLPFunds
    //    Swap locker BEFORE Phase 1 runs → finalize → tokens + ETH arrive at new locker.
    //    (Phase 1 reads `lpLocker` at call time, so a pre-finalize swap works.)
    // ============================================================

    function test_setLPLocker_redirectsLPFunds() public {
        // Launch A wired to lpLocker1
        (address token, address escrowAddr) = _launch("LPSwap", "LPS");
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Fully fund the campaign
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");

        // Deploy a fresh LPLocker (lpLocker2) and authorize the router on it.
        // Use a fresh MockAerodromeRouter for clean bookkeeping — not strictly required,
        // but makes the balance check unambiguous.
        MockAerodromeRouter aeroRouter2 = new MockAerodromeRouter(weth, aeroFactory);
        VibesLPLocker lpLocker2 = new VibesLPLocker(address(aeroRouter2), aeroFactory);
        lpLocker2.setAuthorizedRouter(address(router));
        // Wire fee claimer impl on the new locker too (createAndLockLP requires it).
        {
            VibesLPFeeClaimer _fc2 = new VibesLPFeeClaimer();
            lpLocker2.setFeeClaimerImplementation(address(_fc2));
        }

        // Swap the router pointer BEFORE finalize (Phase 1 reads it live)
        VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker2)));
        assertEq(
            address(VibesRouterExtension(address(router)).lpLocker()),
            address(lpLocker2),
            "router pointer should be lpLocker2"
        );

        // Snapshot state before finalize
        assertFalse(lpLocker2.hasLockedLP(escrowAddr), "new locker idle before finalize");
        assertFalse(lpLocker1.hasLockedLP(escrowAddr), "old locker idle before finalize");

        // Finalize — Phase 1 runs against lpLocker2. Goal reached → early finalization allowed.
        escrow.finalize();

        // Assert: the NEW locker received the LP work, the OLD locker did NOT.
        assertTrue(lpLocker2.hasLockedLP(escrowAddr), "new locker recorded the LP");
        assertFalse(lpLocker1.hasLockedLP(escrowAddr), "old locker still idle");

        // Stronger: the new aeroRouter logged a liquidity event, the old one did not.
        (, , , uint256 lpAmountNew, ) = aeroRouter2.liquidityEvents(0);
        assertGt(lpAmountNew, 0, "new aero router minted LP");
        // Old aeroRouter has no events at index 0 → accessing it would revert.
        // Validate via the locker's public mapping instead (already done above).

        // Finalization phase tracking confirms Phase 1 completed through new locker
        assertEq(
            uint8(VibesRouterExtension(address(router)).finalizationPhase(token)),
            uint8(VibesRouterStorage.FinalizationPhase.FullyComplete),
            "finalization should have completed through new locker"
        );
    }

    // ============================================================
    // 3. test_setStakerRewards_redirectsTokens
    //    Swap staker rewards BEFORE Phase 1 → Phase 2 transfers to NEW recipient.
    //    (Phase 1 caches `stakerRewardsContract` into `_pendingStakerRecipient`.)
    // ============================================================

    function test_setStakerRewards_redirectsTokens() public {
        // Deploy a contract-based sink for the NEW staker rewards (needs code.length > 0
        // to hit the transfer path instead of the EOA redirect-to-backers branch).
        MockStakerRewardsSink newRewards = new MockStakerRewardsSink();

        // Launch the campaign FIRST (to keep the old EOA address set for at least one moment)
        (address token, address escrowAddr) = _launch("Staker", "STK");
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // Swap the router pointer BEFORE finalize — Phase 1 caches this into _pendingStakerRecipient
        VibesRouterExtension(address(router)).setStakerRewardsContract(address(newRewards));
        assertEq(
            VibesRouterExtension(address(router)).stakerRewardsContract(),
            address(newRewards),
            "router pointer should be newRewards"
        );

        // Fund to goal and finalize
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");
        escrow.finalize();

        // Expected ecosystem allocation: 2.5% of TOTAL_SUPPLY (ECOSYSTEM_ALLOCATION_BPS = 250)
        uint256 expectedStakerTokens = (TOTAL_SUPPLY * 250) / 10000;

        // The NEW rewards address got the staker tokens; the OLD EOA got nothing.
        assertEq(
            IERC20(token).balanceOf(address(newRewards)),
            expectedStakerTokens,
            "new staker rewards should have received tokens"
        );
        assertEq(
            IERC20(token).balanceOf(stakerRewardsAddr),
            0,
            "old staker rewards EOA should have received nothing"
        );

        // Finalization fully complete
        assertEq(
            uint8(VibesRouterExtension(address(router)).finalizationPhase(token)),
            uint8(VibesRouterStorage.FinalizationPhase.FullyComplete),
            "phase 2 must have run"
        );
    }

    // ============================================================
    // 4. test_setFeeConfig_redirectsFees
    //    Swap fee config → fees on a subsequent launch go to the NEW recipient.
    // ============================================================

    function test_setFeeConfig_redirectsFees() public {
        uint256 fee = 0.05 ether;
        address recipient1 = makeAddr("feeRecipient1");
        address recipient2 = makeAddr("feeRecipient2");

        // Enable fees → recipient1
        VibesRouterExtension(address(router)).setFeeConfig(true, fee, recipient1);
        assertEq(VibesRouterExtension(address(router)).feeRecipient(), recipient1);
        assertEq(VibesRouterExtension(address(router)).flatFeeWei(), fee);
        assertTrue(VibesRouterExtension(address(router)).feesEnabled());

        uint256 r1Before = recipient1.balance;
        uint256 r2Before = recipient2.balance;

        // Launch #1 pays fee to recipient1
        _launchWithValue("Fee1", "F1", DEPOSIT + fee);
        assertEq(recipient1.balance - r1Before, fee, "recipient1 should receive fee #1");
        assertEq(recipient2.balance - r2Before, 0, "recipient2 untouched before swap");

        // Swap fee recipient → recipient2 (keep fees enabled, same fee amount)
        VibesRouterExtension(address(router)).setFeeConfig(true, fee, recipient2);
        assertEq(VibesRouterExtension(address(router)).feeRecipient(), recipient2);

        // Launch #2 pays fee to recipient2, NOT recipient1
        uint256 r1Mid = recipient1.balance;
        _launchWithValue("Fee2", "F2", DEPOSIT + fee);
        assertEq(recipient2.balance - r2Before, fee, "recipient2 should receive fee #2");
        assertEq(recipient1.balance, r1Mid, "recipient1 balance unchanged after swap");
    }

    // ============================================================
    // 5. test_existingCampaignsUnaffectedByFactorySwap
    //    Campaign A (factory1) keeps working after swap to factory2:
    //    contribute / finalize / claim all succeed on the existing escrow.
    // ============================================================

    function test_existingCampaignsUnaffectedByFactorySwap() public {
        // Launch A with factory1
        (address token, address escrowAddr) = _launch("Existing", "EXS");
        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));

        // A is provably from factory1
        assertTrue(escrowFactory1.isEscrow(escrowAddr), "A from factory1 pre-swap");

        // Deploy factory2 and swap the router pointer
        VibesTranchEscrowFactory escrowFactory2 = new VibesTranchEscrowFactory(
            address(escrowImpl),
            escrowAdmin,
            makeAddr("platform2"),
            address(timeOracle),
            address(router),
            address(lpLocker1),
            address(0)
        );
        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory2));

        // A is STILL from factory1 (retroactive redirect would be a critical bug)
        assertTrue(escrowFactory1.isEscrow(escrowAddr), "A still belongs to factory1 post-swap");
        assertFalse(escrowFactory2.isEscrow(escrowAddr), "A was NOT retroactively moved to factory2");

        // Contribution AFTER the swap still works on A's existing escrow
        vm.prank(backer1);
        escrow.contribute{value: GOAL}(0, 0, "");
        assertEq(escrow.getCampaign().totalRaised, GOAL, "post-swap contribute still works");

        // Finalize works — Phase 1 + Phase 2 complete through the still-valid router wiring
        escrow.finalize();
        assertEq(
            uint8(escrow.getCampaign().state),
            uint8(VibesTranchEscrow.CampaignState.Funded),
            "campaign A should be Funded post-swap"
        );
        assertEq(
            uint8(VibesRouterExtension(address(router)).finalizationPhase(token)),
            uint8(VibesRouterStorage.FinalizationPhase.FullyComplete),
            "phase 2 completed for A post-swap"
        );

        // Claim tokens on the existing escrow — proves its wiring to the router is intact
        uint256 balBefore = IERC20(token).balanceOf(backer1);
        vm.prank(backer1);
        VibesRouterExtension(address(router)).claimTokens(token);
        assertGt(
            IERC20(token).balanceOf(backer1) - balBefore,
            0,
            "backer1 should receive claim tokens after swap"
        );
    }

    // ============================================================
    // HELPERS
    // ============================================================

    /// @dev Launch a FixedGoal campaign with a unique name/symbol. Uses DEPOSIT as msg.value.
    function _launch(string memory name, string memory symbol)
        internal
        returns (address token, address escrow)
    {
        return _launchWithValue(name, symbol, DEPOSIT);
    }

    /// @dev Launch a FixedGoal campaign with a caller-specified msg.value (e.g. fee + deposit).
    function _launchWithValue(string memory name, string memory symbol, uint256 value)
        internal
        returns (address token, address escrow)
    {
        uint256 deadline = block.timestamp + 14 days;
        vm.prank(founder);
        (token, escrow, ) = router.launchWithCampaign{value: value}(
            name, symbol, 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, deadline, 750, 0, 0,
            0, 0, ""
        );
    }
}

/**
 * @title AdminTimingTest
 * @notice §5.4 Timing Parameter Integrity — verify that the release cliff on treasury
 *         and vesting contracts is exactly `6 * tranche_duration` for both testnet and
 *         mainnet parameterizations, and that proposal/vesting time gates behave
 *         correctly across the cliff boundary.
 *
 * Covers 8 tests from docs/plans/contracts/test-plan.md §5.4:
 *   1. testnet treasury cliff == 6 × testnet tranche duration (6 days == 6 * 1 days)
 *   2. testnet vesting  cliff == 6 × testnet tranche duration (6 days == 6 * 1 days)
 *   3. mainnet treasury cliff == 6 × mainnet tranche duration (180 days == 6 * 30 days)
 *   4. mainnet vesting  cliff == 6 × mainnet tranche duration (180 days == 6 * 30 days)
 *   5. createProposal reverts with ReleaseCliffNotElapsed before cliff elapses
 *   6. createProposal succeeds after cliff elapses
 *   7. releasable() == 0 before the vesting cliff
 *   8. releasable() ≈ 50% of totalAmount at cliff + 50% of vestDuration (linear)
 *
 * Fresh minimal fixture: these tests don't need a full router deploy or escrow
 * factory. They directly instantiate VibesTreasuryEscrow / VibesVesting with the
 * exact values the router would pass based on its `useTestnetContracts` flag.
 * Note on equivalence: in Solidity, `24 hours == 1 days` (both 86_400 seconds), so
 * the task's `1 days` tranche duration matches the contract's `24 hours` constant.
 */
contract AdminTimingTest is Test {
    // Testnet / mainnet tranche durations (sourced from VibesTranchEscrow(Testnet).sol)
    uint256 internal constant TRANCHE_DURATION_TESTNET = 24 hours; // == 1 days
    uint256 internal constant TRANCHE_DURATION_MAINNET = 30 days;

    // Testnet / mainnet cliff durations (sourced from VibesLaunchRouterV2 construction)
    uint256 internal constant RELEASE_CLIFF_TESTNET = 6 days;
    uint256 internal constant RELEASE_CLIFF_MAINNET = 180 days;
    uint256 internal constant COOLDOWN_TESTNET = 2 hours;
    uint256 internal constant COOLDOWN_MAINNET = 14 days;
    uint256 internal constant CHALLENGE_WINDOW_TESTNET = 2 hours;
    uint256 internal constant CHALLENGE_WINDOW_MAINNET = 72 hours;
    uint256 internal constant VESTING_DURATION_TESTNET = 12 days;
    uint256 internal constant VESTING_DURATION_MAINNET = 365 days;

    address public founder = makeAddr("timingFounder");
    address public admin = makeAddr("timingAdmin");

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant TREASURY_AMOUNT = 100_000 ether; // 10% of supply
    uint256 public constant VESTING_AMOUNT = 100_000 ether;  // 10% of supply

    function setUp() public {
        // Fresh minimal fixture — no router wiring needed. Individual tests
        // instantiate the contract under test (treasury or vesting).
    }

    // ============================================================
    // Tests 1-4: cliff == 6 × tranche duration
    // ============================================================

    /// @notice §5.4 #1 — testnet treasury release cliff == 6 × testnet tranche duration
    function test_testnet_treasuryCliff_matchesTrancheSchedule() public {
        VibesToken token = new VibesToken("TST", "TST", 18, TOTAL_SUPPLY, founder);
        VibesTreasuryEscrow treasury = new VibesTreasuryEscrow(
            address(token),
            founder,
            admin,
            RELEASE_CLIFF_TESTNET,
            COOLDOWN_TESTNET,
            CHALLENGE_WINDOW_TESTNET
        );

        assertEq(
            treasury.RELEASE_CLIFF(),
            6 * TRANCHE_DURATION_TESTNET,
            "testnet treasury cliff must equal 6 tranches"
        );
        assertEq(treasury.RELEASE_CLIFF(), 6 days, "testnet treasury cliff literal");
    }

    /// @notice §5.4 #2 — testnet vesting cliff == 6 × testnet tranche duration
    function test_testnet_vestingCliff_matchesTrancheSchedule() public {
        VibesToken token = new VibesToken("TST", "TST", 18, TOTAL_SUPPLY, founder);
        VibesVesting vesting = new VibesVesting(
            address(token),
            founder,
            RELEASE_CLIFF_TESTNET,
            VESTING_DURATION_TESTNET
        );

        assertEq(
            vesting.CLIFF(),
            6 * TRANCHE_DURATION_TESTNET,
            "testnet vesting cliff must equal 6 tranches"
        );
        assertEq(vesting.CLIFF(), 6 days, "testnet vesting cliff literal");
    }

    /// @notice §5.4 #3 — mainnet treasury release cliff == 6 × mainnet tranche duration
    function test_mainnet_treasuryCliff_matchesTrancheSchedule() public {
        VibesToken token = new VibesToken("TST", "TST", 18, TOTAL_SUPPLY, founder);
        VibesTreasuryEscrow treasury = new VibesTreasuryEscrow(
            address(token),
            founder,
            admin,
            RELEASE_CLIFF_MAINNET,
            COOLDOWN_MAINNET,
            CHALLENGE_WINDOW_MAINNET
        );

        assertEq(
            treasury.RELEASE_CLIFF(),
            6 * TRANCHE_DURATION_MAINNET,
            "mainnet treasury cliff must equal 6 tranches"
        );
        assertEq(treasury.RELEASE_CLIFF(), 180 days, "mainnet treasury cliff literal");
    }

    /// @notice §5.4 #4 — mainnet vesting cliff == 6 × mainnet tranche duration
    function test_mainnet_vestingCliff_matchesTrancheSchedule() public {
        VibesToken token = new VibesToken("TST", "TST", 18, TOTAL_SUPPLY, founder);
        VibesVesting vesting = new VibesVesting(
            address(token),
            founder,
            RELEASE_CLIFF_MAINNET,
            VESTING_DURATION_MAINNET
        );

        assertEq(
            vesting.CLIFF(),
            6 * TRANCHE_DURATION_MAINNET,
            "mainnet vesting cliff must equal 6 tranches"
        );
        assertEq(vesting.CLIFF(), 180 days, "mainnet vesting cliff literal");
    }

    // ============================================================
    // Tests 5-6: treasury proposal timing gates
    // ============================================================

    /// @notice §5.4 #5 — createProposal reverts with ReleaseCliffNotElapsed before cliff
    /// @dev Testnet params: 6-day cliff. Warp to day 5 and attempt proposal — must revert.
    function test_treasuryProposal_blockedBeforeAllTranchesAvailable() public {
        (VibesTreasuryEscrow treasury, ) = _deployTestnetTreasury();

        // Day 5 (before 6-day cliff elapses). activate() was called at setUp time → use +5d
        vm.warp(block.timestamp + 5 days);

        uint256 amount = TREASURY_AMOUNT / 20; // 5% — under 10% cap
        vm.expectRevert(VibesTreasuryEscrow.ReleaseCliffNotElapsed.selector);
        vm.prank(founder);
        treasury.createProposal(amount, keccak256("early"));
    }

    /// @notice §5.4 #6 — createProposal succeeds after cliff elapses
    /// @dev Testnet params: 6-day cliff. Warp to day 7 and proposal must succeed.
    function test_treasuryProposal_allowedAfterAllTranchesAvailable() public {
        (VibesTreasuryEscrow treasury, ) = _deployTestnetTreasury();

        // Day 7 (past the 6-day cliff)
        vm.warp(block.timestamp + 7 days);

        uint256 amount = TREASURY_AMOUNT / 20;
        vm.prank(founder);
        treasury.createProposal(amount, keccak256("on-time"));

        // Assert: proposal state == Pending, count incremented, amount recorded
        (uint256 _amount, , , VibesTreasuryEscrow.ProposalState _state) = treasury.getProposal();
        assertEq(uint8(_state), uint8(VibesTreasuryEscrow.ProposalState.Pending), "proposal must be Pending");
        assertEq(_amount, amount, "proposal amount must be recorded");
        assertEq(treasury.proposalCount(), 1, "proposal count should increment to 1");
    }

    // ============================================================
    // Tests 7-8: vesting release math (true delayed start, linear after cliff)
    // ============================================================

    /// @notice §5.4 #7 — releasable() returns 0 before the vesting cliff elapses
    function test_vestingRelease_zeroBeforeCliff() public {
        VibesVesting vesting = _deployActiveTestnetVesting();

        // Partway through the cliff (cliff is 6 days)
        vm.warp(block.timestamp + 3 days);
        assertEq(vesting.releasable(), 0, "should be 0 mid-cliff");

        // At the cliff boundary exactly — vestedAmount uses `<` so boundary still returns 0
        vm.warp(block.timestamp + 3 days); // now at start + 6 days
        assertEq(vesting.releasable(), 0, "should be 0 at cliff boundary (true delayed start)");
    }

    /// @notice §5.4 #8 — releasable() ≈ 50% of totalAmount at cliff + 50% of vestDuration
    /// @dev Curve shape (VibesVesting.vestedAmount): true delayed start. At start + CLIFF,
    ///      vested = 0. From there, linear over VESTING_DURATION up to totalAmount at
    ///      start + CLIFF + VESTING_DURATION. So at cliff + 50% of vestDuration:
    ///      vested = totalAmount * (0.5 * VESTING_DURATION) / VESTING_DURATION = totalAmount / 2.
    ///      Division is integer; rounding tolerance of 1 wei covers truncation.
    function test_vestingRelease_linearAfterCliff() public {
        VibesVesting vesting = _deployActiveTestnetVesting();

        // Warp to start + CLIFF + (VESTING_DURATION / 2) → halfway through the linear ramp
        uint256 halfVest = VESTING_DURATION_TESTNET / 2;
        vm.warp(block.timestamp + RELEASE_CLIFF_TESTNET + halfVest);

        uint256 releasable = vesting.releasable();
        uint256 expected = VESTING_AMOUNT / 2;

        // Integer division inside vestedAmount can drop at most 1 wei
        assertApproxEqAbs(releasable, expected, 1, "releasable must be ~50% at midpoint");
    }

    // ============================================================
    // HELPERS
    // ============================================================

    /// @dev Deploy a token + testnet-parameterized treasury, fund it with tokens,
    ///      and activate it. Returns the treasury + its token. activatedAt = now.
    function _deployTestnetTreasury()
        internal
        returns (VibesTreasuryEscrow treasury, VibesToken token)
    {
        vm.prank(founder);
        token = new VibesToken("TST", "TST", 18, TOTAL_SUPPLY, founder);

        // Test contract is authorizedStarter (creator)
        treasury = new VibesTreasuryEscrow(
            address(token),
            founder,
            admin,
            RELEASE_CLIFF_TESTNET,    // 6 days
            COOLDOWN_TESTNET,         // 2 hours
            CHALLENGE_WINDOW_TESTNET  // 2 hours
        );

        vm.prank(founder);
        token.transfer(address(treasury), TREASURY_AMOUNT);

        treasury.activate();
    }

    /// @dev Deploy a token + testnet-parameterized vesting contract. Seeds the vesting
    ///      contract with VESTING_AMOUNT of tokens, initializes, and starts vesting.
    ///      start = now.
    function _deployActiveTestnetVesting() internal returns (VibesVesting vesting) {
        vm.prank(founder);
        VibesToken token = new VibesToken("TST", "TST", 18, TOTAL_SUPPLY, founder);

        // Test contract is authorizedStarter (creator)
        vesting = new VibesVesting(
            address(token),
            founder,
            RELEASE_CLIFF_TESTNET,    // 6 days
            VESTING_DURATION_TESTNET  // 12 days
        );

        vm.prank(founder);
        token.transfer(address(vesting), VESTING_AMOUNT);

        vesting.initializeAmount();
        vesting.startVesting();
    }
}
