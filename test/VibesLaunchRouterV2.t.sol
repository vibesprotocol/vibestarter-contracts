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
import {VibesLPLocker} from "../src/VibesLPLocker.sol";
import {VibesLPFeeClaimer} from "../src/VibesLPFeeClaimer.sol";
import {VibesVesting} from "../src/VibesVesting.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import "./mocks/MockAerodromeRouter.sol";

contract VibesLaunchRouterV2Test is Test {
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
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");
    address public opsWallet = makeAddr("opsWallet");
    address public feeRecipient = makeAddr("feeRecipient");
    address public stakerRewardsAddr = makeAddr("stakerRewards");
    address public stranger = makeAddr("stranger");

    address public weth = makeAddr("weth");
    address public aeroFactory = makeAddr("aeroFactory");

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant DEPOSIT = 0.01 ether;

    bytes32 public capsuleHash = keccak256("capsule");
    bytes32 public proofHash = keccak256("proof");

    function setUp() public {
        owner = address(this);

        tokenFactory = new VibesTokenFactory();
        registry = new VibesRegistry();

        // Deploy mock Aerodrome
        aeroRouter = new MockAerodromeRouter(weth, aeroFactory);
        lpLocker = new VibesLPLocker(address(aeroRouter), aeroFactory);

        {
            VibesLPFeeClaimer _fc = new VibesLPFeeClaimer();
            lpLocker.setFeeClaimerImplementation(address(_fc));
        }
        // Deploy time oracle
        timeOracle = new MockTimeOracle();

        // Deploy escrow implementation
        escrowImpl = new VibesTranchEscrow();

        // Deploy extension and router (with zero escrow factory and lp locker initially)
        extension = new VibesRouterExtension();
        router = new VibesLaunchRouterV2(
            address(extension),
            address(tokenFactory),
            address(registry),
            address(0),
            payable(address(0))
        );

        // Deploy escrow factory with router as authorizedRouter
        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl),
            owner,
            makeAddr("platform"),
            address(timeOracle),
            address(router),
            address(lpLocker),
            address(0)          // trustedSigner (disabled for tests)
        );

        // Configure router
        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        VibesRouterExtension(address(router)).setLPLocker(payable(address(lpLocker)));
        VibesRouterExtension(address(router)).setOpsWallet(opsWallet);
        VibesRouterExtension(address(router)).setStakerRewardsContract(stakerRewardsAddr);

        // Authorize router in registry
        registry.authorizeRouter(address(router));

        // Fund founder and backers
        vm.deal(founder, 100 ether);
        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);
    }

    /// @dev Required so the test contract can receive ETH (e.g. forfeitDeposit sends to feeRecipient = address(this))
    receive() external payable {}

    // ============ Constructor Tests ============

    function test_constructor() public view {
        assertEq(address(router.tokenFactory()), address(tokenFactory));
        assertEq(address(router.registry()), address(registry));
        assertEq(router.owner(), owner);
        assertEq(router.feeRecipient(), owner);
        assertEq(router.founderDepositWei(), DEPOSIT);
    }

    function test_constructor_revertsZeroExtension() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        new VibesLaunchRouterV2(address(0), address(tokenFactory), address(registry), address(0), payable(address(0)));
    }

    function test_constructor_revertsZeroTokenFactory() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        new VibesLaunchRouterV2(address(extension), address(0), address(registry), address(0), payable(address(0)));
    }

    function test_constructor_revertsZeroRegistry() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        new VibesLaunchRouterV2(address(extension), address(tokenFactory), address(0), address(0), payable(address(0)));
    }

    // ============ Simple Launch (no campaign) ============

    function test_launch() public {
        vm.prank(founder);
        address token = router.launch(
            "Test", "TST", 18, TOTAL_SUPPLY, founder,
            capsuleHash, 1, 1, 1, proofHash
        );

        assertTrue(token != address(0));
        assertEq(VibesToken(token).balanceOf(founder), TOTAL_SUPPLY);
        assertTrue(registry.isRegistered(token));
        assertEq(registry.founderOf(token), founder);
    }

    function test_launch_withZeroRecipient_goesToSender() public {
        vm.prank(founder);
        address token = router.launch(
            "Test", "TST", 18, TOTAL_SUPPLY, address(0),
            capsuleHash, 1, 1, 1, proofHash
        );
        assertEq(VibesToken(token).balanceOf(founder), TOTAL_SUPPLY);
    }

    function test_launch_revertsZeroCapsuleHash() public {
        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        router.launch("Test", "TST", 18, TOTAL_SUPPLY, founder, bytes32(0), 1, 1, 1, proofHash);
    }

    function test_launch_revertsZeroProofHash() public {
        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        router.launch("Test", "TST", 18, TOTAL_SUPPLY, founder, capsuleHash, 1, 1, 1, bytes32(0));
    }

    // ============ Launch With Campaign ============

    function test_launchWithCampaign_basic() public {
        uint256 deadline = block.timestamp + 14 days;

        vm.prank(founder);
        (address token, address escrow, address vesting) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 750, 0, 0, 0, 0, ""
        );

        assertTrue(token != address(0));
        assertTrue(escrow != address(0));
        assertTrue(vesting != address(0));

        // Token tracked correctly
        assertEq(router.tokenToEscrow(token), escrow);
        assertEq(router.tokenToVesting(token), vesting);
        assertEq(router.tokenDeposits(token), DEPOSIT);
    }

    function test_launchWithCampaign_zeroFounderAllocation() public {
        uint256 deadline = block.timestamp + 14 days;

        vm.prank(founder);
        (address token, address escrow, address vesting) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 0, 0, 0, 0, 0, "" // 0% founder, 0% treasury
        );

        assertTrue(token != address(0));
        assertEq(vesting, address(0)); // No vesting with 0% allocation
    }

    function test_launchWithCampaign_revertsExcessiveFounderAlloc() public {
        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.InvalidAllocation.selector);
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 751, 0, 0, 0, 0, "" // >7.5%
        );
    }

    function test_launchWithCampaign_revertsTreasuryBelowMin() public {
        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.InvalidTreasuryAllocation.selector);
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 500, 0, 0, 0, "" // 5% treasury (below 10% min)
        );
    }

    function test_launchWithCampaign_revertsTreasuryAboveMax() public {
        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.InvalidTreasuryAllocation.selector);
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 1800, 0, 0, 0, "" // 18% treasury (above 17.5% max)
        );
    }

    function test_launchWithCampaign_revertsCombinedExceeds20() public {
        // 750 + 1251 = 2001 > 2000 — should revert the combined founder+treasury cap
        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.InvalidTreasuryAllocation.selector);
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 750, 1251, 0, 0, 0, "" // 7.5% + 12.51% > 20%
        );
    }

    function test_launchWithCampaign_combinedExactly20_succeeds() public {
        // 500 + 1500 = 2000 = 20% — should succeed (matches the $VIBES raise shape)
        vm.prank(founder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 500, 1500, 0, 0, 0, "" // 5% + 15% = 20% OK
        );
        assertTrue(token != address(0));
    }

    function test_launchWithCampaign_treasuryMaxWithZeroFounder() public {
        // 17.5% treasury + 0% founder = valid
        vm.prank(founder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 1750, 0, 0, 0, ""
        );
        assertTrue(token != address(0));
    }

    function test_launchWithCampaign_revertsInsufficientDeposit() public {
        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.InsufficientDeposit.selector);
        router.launchWithCampaign{value: 0.001 ether}( // less than founderDepositWei (0.01 ether)
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 750, 0, 0, 0, 0, ""
        );
    }

    function test_launchWithCampaign_revertsNoEscrowFactory() public {
        VibesLaunchRouterV2 bareRouter = new VibesLaunchRouterV2(
            address(extension), address(tokenFactory), address(registry), address(0), payable(address(0))
        );

        vm.deal(founder, 1 ether);
        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.EscrowFactoryNotSet.selector);
        bareRouter.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0, 0, 0, ""
        );
    }

    function test_launchWithCampaign_revertsWhenPaused() public {
        VibesRouterExtension(address(router)).pause();

        vm.prank(founder);
        vm.expectRevert();
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0, 0, 0, ""
        );
    }

    // ============ Token Allocation Math ============

    function test_tokenAllocation_7_5percentFounder() public {
        uint256 deadline = block.timestamp + 14 days;

        vm.prank(founder);
        (address token, , address vesting) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, deadline, 750, 0, 0, 0, 0, "" // 7.5% founder, 0% treasury
        );

        // Founder tokens = 7.5% = 75_000
        uint256 vestingBalance = VibesToken(token).balanceOf(vesting);
        assertEq(vestingBalance, (TOTAL_SUPPLY * 750) / 10000);

        // Remaining in router = backer + LP + staker tokens
        uint256 routerBalance = VibesToken(token).balanceOf(address(router));
        assertEq(routerBalance + vestingBalance, TOTAL_SUPPLY);
    }

    // ============ Deposit System ============

    function test_deposit_refundExcess() public {
        uint256 excess = 0.1 ether;
        uint256 balBefore = founder.balance;

        vm.prank(founder);
        router.launchWithCampaign{value: DEPOSIT + excess}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0, 0, 0, ""
        );

        // Excess should be refunded
        assertEq(founder.balance, balBefore - DEPOSIT);
    }

    function test_refundDeposit() public {
        vm.prank(founder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0, 0, 0, ""
        );

        uint256 balBefore = founder.balance;
        VibesRouterExtension(address(router)).refundDeposit(token, founder);

        assertEq(founder.balance, balBefore + DEPOSIT);
        assertEq(router.tokenDeposits(token), 0);
    }

    function test_refundDeposit_revertsNoDeposit() public {
        vm.expectRevert(VibesRouterStorage.NoDepositToRefund.selector);
        VibesRouterExtension(address(router)).refundDeposit(makeAddr("noToken"), founder);
    }

    function test_forfeitDeposit() public {
        vm.prank(founder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0, 0, 0, ""
        );

        uint256 recipientBal = router.feeRecipient().balance;
        VibesRouterExtension(address(router)).forfeitDeposit(token, founder);

        assertEq(router.feeRecipient().balance, recipientBal + DEPOSIT);
        assertEq(router.tokenDeposits(token), 0);
    }

    // ============ Fee Configuration ============

    function test_setFeeConfig() public {
        VibesRouterExtension(address(router)).setFeeConfig(true, 0.01 ether, feeRecipient);

        assertTrue(router.feesEnabled());
        assertEq(router.flatFeeWei(), 0.01 ether);
        assertEq(router.feeRecipient(), feeRecipient);
    }

    function test_setFeeConfig_revertsZeroRecipient() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        VibesRouterExtension(address(router)).setFeeConfig(true, 0.01 ether, address(0));
    }

    function test_launchWithFees() public {
        VibesRouterExtension(address(router)).setFeeConfig(true, 0.01 ether, feeRecipient);

        uint256 recipientBal = feeRecipient.balance;
        uint256 total = 0.01 ether + DEPOSIT;

        vm.prank(founder);
        router.launchWithCampaign{value: total}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0, 0, 0, ""
        );

        assertEq(feeRecipient.balance, recipientBal + 0.01 ether);
    }

    // ============ Admin Functions ============

    function test_transferOwnership_setsPendingOwner() public {
        address newOwner = makeAddr("newOwner");
        VibesRouterExtension(address(router)).transferOwnership(newOwner);
        assertEq(router.pendingOwner(), newOwner);
        assertEq(router.owner(), address(this)); // not transferred yet
    }

    function test_transferOwnership_acceptCompletes() public {
        address newOwner = makeAddr("newOwner");
        VibesRouterExtension(address(router)).transferOwnership(newOwner);
        vm.prank(newOwner);
        VibesRouterExtension(address(router)).acceptOwnership();
        assertEq(router.owner(), newOwner);
        assertEq(router.pendingOwner(), address(0));
    }

    function test_transferOwnership_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).transferOwnership(stranger);
    }

    function test_transferOwnership_revertsZero() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        VibesRouterExtension(address(router)).transferOwnership(address(0));
    }

    function test_pauseAndUnpause() public {
        VibesRouterExtension(address(router)).pause();
        assertTrue(router.paused());

        // Audit fix: unpause() via extension fallback is blocked when paused,
        // must use emergencyUnpause() directly on the router
        router.emergencyUnpause();
        assertFalse(router.paused());
    }

    function test_pause_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).pause();
    }

    function test_setEscrowFactory_revertsZero() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        VibesRouterExtension(address(router)).setEscrowFactory(address(0));
    }

    function test_setLPLocker_revertsZero() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        VibesRouterExtension(address(router)).setLPLocker(payable(address(0)));
    }

    function test_setOpsWallet_revertsZero() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        VibesRouterExtension(address(router)).setOpsWallet(address(0));
    }

    function test_setStakerRewardsContract_revertsZero() public {
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        VibesRouterExtension(address(router)).setStakerRewardsContract(address(0));
    }

    function test_setFounderDepositWei() public {
        VibesRouterExtension(address(router)).setFounderDepositWei(0.1 ether);
        assertEq(router.founderDepositWei(), 0.1 ether);
    }

    // ============ View Functions ============

    function test_getTokenInfo() public {
        vm.prank(founder);
        (address token, address escrow, address vesting) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 750, 0, 0, 0, 0, ""
        );

        (address e, address v, address d, address t, uint256 pendingLPTokens) = VibesRouterExtension(address(router)).getTokenInfo(token);
        assertEq(e, escrow);
        assertEq(v, vesting);
        assertEq(d, address(0)); // No distributor yet
        assertEq(t, address(0)); // No treasury (0% treasury allocation)
        assertTrue(pendingLPTokens > 0);
    }

    function test_getDepositInfo() public {
        vm.prank(founder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0, 0, 0, ""
        );

        assertEq(VibesRouterExtension(address(router)).getDepositInfo(token), DEPOSIT);
        assertEq(VibesRouterExtension(address(router)).getDepositRequirement(), DEPOSIT);
    }

    // ============ Rescue ============

    function test_rescueETH() public {
        vm.deal(address(router), 1 ether);

        uint256 balBefore = opsWallet.balance;
        VibesRouterExtension(address(router)).rescueETH(opsWallet, 1 ether);

        assertEq(opsWallet.balance, balBefore + 1 ether);
    }

    function test_rescueETH_revertsZeroAddress() public {
        vm.deal(address(router), 1 ether);
        vm.expectRevert(VibesRouterStorage.ZeroAddress.selector);
        VibesRouterExtension(address(router)).rescueETH(address(0), 1 ether);
    }

    function test_rescueETH_revertsNotOwner() public {
        vm.deal(address(router), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).rescueETH(opsWallet, 1 ether);
    }

    // ============ Receive ============

    function test_receiveETH() public {
        vm.deal(backer1, 1 ether);
        vm.prank(backer1);
        (bool sent, ) = address(router).call{value: 1 ether}("");
        assertTrue(sent);
    }

    // ============ Batch Claim Guard ============

    function test_batchClaimTokens_revertsEmpty() public {
        address[] memory tokens = new address[](0);
        vm.expectRevert(VibesRouterStorage.NothingToClaim.selector);
        VibesRouterExtension(address(router)).batchClaimTokens(tokens);
    }

    function test_batchClaimTokens_revertsTooMany() public {
        address[] memory tokens = new address[](21);
        vm.expectRevert(VibesRouterStorage.TooManyTokens.selector);
        VibesRouterExtension(address(router)).batchClaimTokens(tokens);
    }

    // ============ Launch Signature Gating ============

    function test_setTrustedLaunchSigner() public {
        address signer = makeAddr("signer");
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(signer);
        assertEq(router.trustedLaunchSigner(), signer);
    }

    function test_setTrustedLaunchSigner_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.OnlyOwner.selector);
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(stranger);
    }

    function test_setTrustedLaunchSigner_disableGating() public {
        address signer = makeAddr("signer");
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(signer);
        assertEq(router.trustedLaunchSigner(), signer);

        // Disable gating
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(address(0));
        assertEq(router.trustedLaunchSigner(), address(0));
    }

    function test_launchWithSignature_validSignature() public {
        // Create signer key pair
        uint256 signerPk = 0xA11CE;
        address signer = vm.addr(signerPk);

        // Enable signature gating
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(signer);

        // Create EIP-712 signature
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            router.LAUNCH_TYPEHASH(),
            founder,
            0,
            sigDeadline
        ));
        bytes32 domainSeparator = router._launchDomainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Launch should succeed with valid signature
        vm.prank(founder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0,
            0, sigDeadline, signature
        );
        assertTrue(token != address(0));
    }

    function test_launchWithSignature_revertsInvalidSignature() public {
        // Create signer key pair
        uint256 signerPk = 0xA11CE;
        address signer = vm.addr(signerPk);

        // Enable signature gating
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(signer);

        // Sign with wrong key
        uint256 wrongPk = 0xBAD;
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            router.LAUNCH_TYPEHASH(),
            founder,
            0,
            sigDeadline
        ));
        bytes32 domainSeparator = router._launchDomainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.InvalidSignature.selector);
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0,
            0, sigDeadline, signature
        );
    }

    function test_launchWithSignature_revertsExpiredSignature() public {
        uint256 signerPk = 0xA11CE;
        address signer = vm.addr(signerPk);
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(signer);

        // Create signature with a deadline in the past
        uint256 sigDeadline = block.timestamp - 1;
        bytes32 structHash = keccak256(abi.encode(
            router.LAUNCH_TYPEHASH(),
            founder,
            0,
            sigDeadline
        ));
        bytes32 domainSeparator = router._launchDomainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(founder);
        vm.expectRevert(VibesRouterStorage.SignatureExpired.selector);
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0,
            0, sigDeadline, signature
        );
    }

    function test_launchWithSignature_revertsWrongFounder() public {
        uint256 signerPk = 0xA11CE;
        address signer = vm.addr(signerPk);
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(signer);

        // Sign for founder but call from stranger
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            router.LAUNCH_TYPEHASH(),
            founder,  // signed for founder
            0,
            sigDeadline
        ));
        bytes32 domainSeparator = router._launchDomainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Call from stranger (signature was for founder) - should revert
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(VibesRouterStorage.InvalidSignature.selector);
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0,
            0, sigDeadline, signature
        );
    }

    function test_launchWithoutSignature_worksWhenGatingDisabled() public {
        // trustedLaunchSigner is address(0) by default — gating disabled
        assertEq(router.trustedLaunchSigner(), address(0));

        // Launch should work with empty signature
        vm.prank(founder);
        (address token, , ) = router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0, 0, 0, ""
        );
        assertTrue(token != address(0));
    }

    function test_launchWithSignature_revertsNoSignatureWhenGatingEnabled() public {
        uint256 signerPk = 0xA11CE;
        address signer = vm.addr(signerPk);
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(signer);

        // Try launching with empty signature when gating is enabled
        vm.prank(founder);
        vm.expectRevert(); // ECDSA.recover reverts on empty signature
        router.launchWithCampaign{value: DEPOSIT}(
            "Test", "TST", 18, TOTAL_SUPPLY,
            capsuleHash, 1, 1, 1, proofHash,
            VibesTranchEscrow.RaiseType.FixedGoal,
            10 ether, 0, block.timestamp + 14 days, 0, 0, 0, 0, 0, ""
        );
    }
}
