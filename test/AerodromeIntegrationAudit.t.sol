// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {VibesLPFeeClaimer} from "../src/VibesLPFeeClaimer.sol";
import {VibesLPLocker} from "../src/VibesLPLocker.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";

contract AerodromeAuditRouter {
    function completeFinalization(address) external {}
    function completeDistribution(address) external {}
    function finalizationPhase(address) external pure returns (uint8) {
        return 0;
    }

    receive() external payable {}
}

contract AuditPoolToken is ERC20 {
    constructor() ERC20("Audit Pool", "aPOOL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract WithdrawableLPHolder {
    address public immutable pool;
    address public immutable campaign;
    address public immutable thief;

    constructor(address _pool, address _campaign, address _thief) {
        pool = _pool;
        campaign = _campaign;
        thief = _thief;
    }

    function drain() external {
        IERC20(pool).transfer(thief, IERC20(pool).balanceOf(address(this)));
    }
}

/// @notice Audit-only PoCs for Aerodrome integration assumptions.
/// @dev These tests intentionally document current risk surfaces; they are not remediations.
contract AerodromeIntegrationAuditTest is Test {
    address public admin = makeAddr("admin");
    address public platformWallet = makeAddr("platform");
    address public founder = makeAddr("founder");
    address public backer = makeAddr("backer");
    address public attacker = makeAddr("attacker");

    uint256 public constant GOAL = 10 ether;
    uint256 public constant TOKEN_SUPPLY = 1_000_000 ether;

    MockTimeOracle public timeOracle;
    AerodromeAuditRouter public auditRouter;
    VibesTranchEscrowFactory public escrowFactory;
    VibesTranchEscrow public escrowImplementation;
    VibesToken public token;

    function setUp() public {
        vm.prank(admin);
        timeOracle = new MockTimeOracle();
        vm.prank(admin);
        timeOracle.setRealTimeMode(true);

        auditRouter = new AerodromeAuditRouter();
        escrowImplementation = new VibesTranchEscrow();

        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImplementation),
            admin,
            platformWallet,
            address(timeOracle),
            address(auditRouter),
            makeAddr("lpLocker"),
            address(0)
        );

        vm.prank(founder);
        token = new VibesToken("Audit Token", "AUD", 18, TOKEN_SUPPLY, founder);
        vm.deal(backer, 100 ether);
    }

    function _createFundedEscrow() internal returns (VibesTranchEscrow esc) {
        vm.prank(address(auditRouter));
        address escrowAddr = escrowFactory.createEscrow(
            founder,
            address(token),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 7 days,
            0
        );
        esc = VibesTranchEscrow(payable(escrowAddr));

        vm.prank(backer);
        esc.contribute{value: GOAL}(0, 0, "");

        skip(8 days);
        esc.finalize();

        uint256 missing = GOAL - address(esc).balance;
        vm.deal(admin, missing);
        vm.prank(admin);
        esc.adminTopUp{value: missing}();
    }

    /// @notice ZXVC VIB-01 (2026-05) regression — canonical Aerodrome pool reserves excluded.
    /// @dev Originally PoC test_freezeDenominatorIncludesAerodromePoolProjectTokenReserves,
    ///      which exercised the buggy behaviour: project-token reserves sitting in the
    ///      Aerodrome pool were silently counted as "redeemable" in frozenTotalSupply,
    ///      diluting per-holder ETH refunds. The option (a) fix excludes the CANONICAL pool
    ///      registered with the LP locker (read lazily via getLockedPosition). To simulate
    ///      the post-LP-lock state without going through the full rescue + manual-lock dance,
    ///      we vm.mockCall the locker's view functions — same effect, smaller test surface.
    ///      NOTE: option (a) is intentionally narrow — only the locker-registered canonical
    ///      pool is excluded. Random ERC-20 holders are still counted. The auditor's option
    ///      (b) (holder-only positive-list snapshot) is the recommended end-state and is
    ///      tracked as a separate follow-up.
    function test_VIB01_canonicalAerodromePoolReservesExcludedFromDenominator() public {
        VibesTranchEscrow esc = _createFundedEscrow();

        address aeroPool = makeAddr("aerodromePool");
        uint256 holderTokens = 250_000 ether;
        uint256 lockedPoolReserve = 150_000 ether;

        vm.startPrank(founder);
        token.transfer(backer, holderTokens);
        token.transfer(aeroPool, lockedPoolReserve);
        token.transfer(address(auditRouter), token.balanceOf(founder));
        vm.stopPrank();

        // ZXVC VIB-01 fix: simulate the locker recognising aeroPool as the canonical
        // Aerodrome pair for this campaign. In production the locker records this during
        // createAndLockLP (or recordManualLPLock after rescue). We mock the lookups here.
        // vm.etch installs stub bytecode so the escrow's code.length guard passes; vm.mockCall
        // intercepts the actual function dispatch and returns canned data.
        address locker = esc.lpLocker();
        vm.etch(locker, hex"60016000fe"); // any non-empty bytecode
        vm.mockCall(
            locker,
            abi.encodeWithSignature("campaignToFeeClaimer(address)", address(esc)),
            abi.encode(address(0))
        );
        VibesLPLocker.LockedLP memory pos;
        pos.pool = aeroPool;
        vm.mockCall(
            locker,
            abi.encodeWithSignature("getLockedPosition(address)", address(esc)),
            abi.encode(pos)
        );

        vm.prank(admin);
        esc.freezeCampaign("audit denominator check");

        // Sanity: auditRouter still holds the residual founder tokens.
        assertEq(token.balanceOf(address(auditRouter)), TOKEN_SUPPLY - holderTokens - lockedPoolReserve);

        // Post-fix: the locker-registered canonical pool's reserves are excluded.
        assertEq(
            esc.frozenTotalSupply(),
            holderTokens,
            "Canonical Aerodrome pool reserves must be excluded from the holder-refund denominator"
        );
    }

    /// @notice ZXVC VIB-09 (2026-05) regression — manual LP lock rejects non-canonical pool.
    /// @dev Originally PoC test_manualLockProofAcceptsWithdrawableHolderAndArbitraryPool, which
    ///      exercised the BUG: recordManualLPLock accepted an arbitrary ERC-20 as the "pool"
    ///      and an arbitrary contract as the "fee claimer". After the fix, the locker
    ///      enforces both (a) _pool == aeroRouter.poolFor(rescue.token, weth, false, factory)
    ///      and (b) _feeClaimer is an EIP-1167 minimal proxy of feeClaimerImplementation.
    ///      The pool check fires first, so the auditor's WithdrawableLPHolder attack is now
    ///      blocked before it reaches the holder validation step.
    function test_VIB09_manualLockRejectsNonCanonicalPool() public {
        MockAerodromeRouter aeroRouter = new MockAerodromeRouter(makeAddr("weth"), makeAddr("factory"));
        VibesLPLocker locker = new VibesLPLocker(address(aeroRouter), makeAddr("factory"));
        locker.setFeeClaimerImplementation(address(new VibesLPFeeClaimer()));
        locker.setAuthorizedRouter(address(this));

        VibesToken lpTokenSource = new VibesToken("LP Source", "LPS", 18, TOKEN_SUPPLY, address(this));
        uint256 tokenAmount = 150_000 ether;
        uint256 ethAmount = 1.5 ether;
        address campaign = makeAddr("rescuedCampaign");

        lpTokenSource.approve(address(locker), tokenAmount);
        aeroRouter.setShouldFail(true);
        locker.createAndLockLP{value: ethAmount}(address(lpTokenSource), tokenAmount, campaign, platformWallet, address(0));
        locker.resolveRescuedFunds(campaign, address(this));

        AuditPoolToken fakePool = new AuditPoolToken();
        uint256 fakeLpAmount = 1 ether;
        WithdrawableLPHolder holder = new WithdrawableLPHolder(address(fakePool), campaign, attacker);
        fakePool.mint(address(holder), fakeLpAmount);

        // ZXVC VIB-09 fix: recordManualLPLock now rejects a non-canonical pool. The mock
        // router's poolFor returns address(0) for tokens that never had liquidity added,
        // so any concrete fakePool != canonical fires InvalidPool before the clone /
        // bytecode checks even run.
        vm.expectRevert(VibesLPLocker.InvalidPool.selector);
        locker.recordManualLPLock(campaign, address(fakePool), address(holder), fakeLpAmount);

        // Sanity: campaign stays in rescue state, never gets the bogus position recorded.
        assertTrue(locker.hasRescuedLP(campaign), "campaign must remain in rescue, not flipped to locked");
        assertFalse(locker.hasLockedLP(campaign), "no locked position recorded");
    }

    receive() external payable {}
}
