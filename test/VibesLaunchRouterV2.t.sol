// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesLaunchRouterV2} from "../src/VibesLaunchRouterV2.sol";
import {VibesTokenFactory} from "../src/VibesTokenFactory.sol";
import {VibesRegistry} from "../src/VibesRegistry.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesLPLocker} from "../src/VibesLPLocker.sol";
import {VibesVesting} from "../src/VibesVesting.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {MockAerodromeRouter, MockLPToken} from "./mocks/MockAerodromeRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VibesLaunchRouterV2Test is Test {
    VibesLaunchRouterV2 public router;
    VibesTokenFactory public tokenFactory;
    VibesRegistry public registry;
    VibesTranchEscrowFactory public escrowFactory;
    VibesLPLocker public lpLocker;
    MockTimeOracle public timeOracle;
    MockAerodromeRouter public mockAeroRouter;

    address public deployer = makeAddr("deployer");
    address public founder = makeAddr("founder");
    address public backer1 = makeAddr("backer1");
    address public backer2 = makeAddr("backer2");
    address public opsWallet = makeAddr("opsWallet");
    address public stakerRewards = makeAddr("stakerRewards");

    bytes32 public constant CAPSULE_HASH = keccak256("test-capsule");
    bytes32 public constant PROOF_HASH = keccak256("test-transcript");

    uint256 public constant GOAL = 10 ether;
    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;

    function setUp() public {
        vm.startPrank(deployer);

        // Deploy mock Aerodrome router
        address mockWeth = makeAddr("weth");
        address mockFactory = makeAddr("aeroFactory");
        mockAeroRouter = new MockAerodromeRouter(mockWeth, mockFactory);

        // Deploy core contracts
        tokenFactory = new VibesTokenFactory();
        registry = new VibesRegistry();

        // Deploy LP locker with mock aerodrome
        lpLocker = new VibesLPLocker(address(mockAeroRouter), mockFactory);

        // Deploy time oracle
        timeOracle = new MockTimeOracle();

        // Deploy escrow implementation
        VibesTranchEscrow escrowImpl = new VibesTranchEscrow();

        // Deploy router (will be the authorized router)
        router = new VibesLaunchRouterV2(
            address(tokenFactory),
            address(registry),
            address(0), // escrow factory set after
            payable(address(0)) // lp locker set after
        );

        // Deploy escrow factory with router as authorized router
        escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImpl),
            deployer, // admin
            deployer, // platform wallet
            address(timeOracle),
            address(router), // authorized router
            address(lpLocker)
        );

        // Configure router
        router.setEscrowFactory(address(escrowFactory));
        router.setLPLocker(payable(address(lpLocker)));
        router.setOpsWallet(opsWallet);
        router.setStakerRewardsContract(stakerRewards);

        // Authorize router in registry
        registry.authorizeRouter(address(router));

        // Authorize router in LP locker
        lpLocker.setAuthorizedRouter(address(router));

        vm.stopPrank();

        // Fund backers
        vm.deal(founder, 100 ether);
        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);
    }

    // ============ Helpers ============

    function _launchCampaign(
        VibesTranchEscrow.RaiseType raiseType,
        uint256 goal,
        uint256 softCap,
        uint256 founderAllocationBps
    ) internal returns (address token, address escrow, address vesting) {
        vm.prank(founder);
        (token, escrow, vesting) = router.launchWithCampaign{value: 0.05 ether}(
            "Test Token",
            "TEST",
            18,
            TOTAL_SUPPLY,
            CAPSULE_HASH,
            1, // CLAUDE_CODE
            1, // ANTHROPIC
            1, // TRANSCRIPT
            PROOF_HASH,
            raiseType,
            goal,
            softCap,
            block.timestamp + 7 days,
            founderAllocationBps,
            0, // immediate start
            0  // no cliff
        );
    }

    function _fundAndFinalize(address escrow, uint256 amount) internal {
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).contribute{value: amount}();

        vm.prank(deployer);
        timeOracle.advanceDays(8);

        VibesTranchEscrow(payable(escrow)).finalize();
    }

    // ============ Launch Tests ============

    function test_LaunchWithCampaign_FixedGoal() public {
        (address token, address escrow, address vesting) = _launchCampaign(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            500 // 5% founder
        );

        assertTrue(token != address(0));
        assertTrue(escrow != address(0));
        assertTrue(vesting != address(0));

        // Token registered
        assertTrue(registry.isRegistered(token));
        assertEq(registry.founderOf(token), founder);

        // Escrow has correct campaign
        VibesTranchEscrow esc = VibesTranchEscrow(payable(escrow));
        VibesTranchEscrow.Campaign memory campaign = esc.getCampaign();
        assertEq(campaign.founder, founder);
        assertEq(campaign.goal, GOAL);
    }

    function test_LaunchWithCampaign_TokenAllocations() public {
        (address token,, address vesting) = _launchCampaign(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            1000 // 10% founder
        );

        // Founder gets 10% in vesting
        uint256 founderTokens = (TOTAL_SUPPLY * 1000) / 10000;
        assertEq(IERC20(token).balanceOf(vesting), founderTokens);

        // Remaining tokens (90%) stay in router until finalization
        uint256 routerBalance = IERC20(token).balanceOf(address(router));
        assertEq(routerBalance, TOTAL_SUPPLY - founderTokens);
    }

    // ============ Ownable2Step Tests ============

    function test_OwnerIsDeployer() public view {
        assertEq(router.owner(), deployer);
    }

    function test_TransferOwnership_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: Initiate transfer
        vm.prank(deployer);
        router.transferOwnership(newOwner);

        // Owner unchanged until accepted
        assertEq(router.owner(), deployer);
        assertEq(router.pendingOwner(), newOwner);

        // Step 2: Accept ownership
        vm.prank(newOwner);
        router.acceptOwnership();

        assertEq(router.owner(), newOwner);
        assertEq(router.pendingOwner(), address(0));
    }

    function test_TransferOwnership_OnlyOwner() public {
        vm.prank(founder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, founder));
        router.transferOwnership(founder);
    }

    function test_AcceptOwnership_OnlyPendingOwner() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(deployer);
        router.transferOwnership(newOwner);

        // Random address can't accept
        vm.prank(founder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, founder));
        router.acceptOwnership();
    }

    function test_AdminFunctions_RespectOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(deployer);
        router.transferOwnership(newOwner);
        vm.prank(newOwner);
        router.acceptOwnership();

        // Old owner can't call admin functions
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        router.setOpsWallet(makeAddr("x"));

        // New owner can
        vm.prank(newOwner);
        router.setOpsWallet(makeAddr("newOps"));
        assertEq(router.opsWallet(), makeAddr("newOps"));
    }

    // ============ RescueETH Tests ============

    function test_RescueETH() public {
        // Send some ETH to router
        vm.deal(address(router), 1 ether);

        address recipient = makeAddr("recipient");
        uint256 balBefore = recipient.balance;

        vm.prank(deployer);
        router.rescueETH(recipient, 0.5 ether);

        assertEq(recipient.balance - balBefore, 0.5 ether);
    }

    function test_RescueETH_OnlyOwner() public {
        vm.deal(address(router), 1 ether);

        vm.prank(founder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, founder));
        router.rescueETH(founder, 1 ether);
    }

    // ============ Full Flow: FixedGoal ============

    function test_FullFlow_FixedGoal_FundAndClaim() public {
        (address token, address escrow,) = _launchCampaign(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            0 // no founder allocation
        );

        // Backer contributes full goal
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).contribute{value: GOAL}();

        vm.prank(deployer);
        timeOracle.advanceDays(8);

        // Finalize (this calls completeFinalization on router)
        VibesTranchEscrow(payable(escrow)).finalize();

        // Campaign should be funded
        VibesTranchEscrow.Campaign memory campaign = VibesTranchEscrow(payable(escrow)).getCampaign();
        assertEq(uint8(campaign.state), uint8(VibesTranchEscrow.CampaignState.Funded));

        // Backer should have claimable tokens
        uint256 claimable = router.getClaimableTokens(token, backer1);
        assertGt(claimable, 0);

        // Claim tokens
        vm.prank(backer1);
        router.claimTokens(token);

        assertTrue(router.hasClaimedTokens(token, backer1));
        assertEq(IERC20(token).balanceOf(backer1), claimable);
    }

    // ============ Full Flow: ProRata with Excess ============

    function test_FullFlow_ProRata_Oversubscribed() public {
        (address token, address escrow,) = _launchCampaign(
            VibesTranchEscrow.RaiseType.ProRata,
            GOAL, // hard cap
            0,
            0
        );

        // Oversubscribe: 12 ETH + 8 ETH = 20 ETH for 10 ETH cap
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).contribute{value: 12 ether}();
        vm.prank(backer2);
        VibesTranchEscrow(payable(escrow)).contribute{value: 8 ether}();

        vm.prank(deployer);
        timeOracle.advanceDays(8);

        VibesTranchEscrow(payable(escrow)).finalize();

        // Check allocations
        (uint256 alloc1, uint256 excess1) = VibesTranchEscrow(payable(escrow)).getProRataAllocation(backer1);
        assertEq(alloc1, 6 ether); // 12/20 * 10
        assertEq(excess1, 6 ether);

        // Backer1 claims excess
        uint256 b1BalBefore = backer1.balance;
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).claimExcessRefund();
        assertEq(backer1.balance - b1BalBefore, 6 ether);

        // Backer2 claims excess
        uint256 b2BalBefore = backer2.balance;
        vm.prank(backer2);
        VibesTranchEscrow(payable(escrow)).claimExcessRefund();
        assertEq(backer2.balance - b2BalBefore, 4 ether);
    }

    // ============ ProRata Frozen Balance Fix (P1-07) ============

    function test_ProRata_FrozenBalance_ExcludesPendingExcess() public {
        (address token, address escrow,) = _launchCampaign(
            VibesTranchEscrow.RaiseType.ProRata,
            GOAL,
            0,
            0
        );

        // Oversubscribe: 20 ETH for 10 ETH cap
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).contribute{value: 12 ether}();
        vm.prank(backer2);
        VibesTranchEscrow(payable(escrow)).contribute{value: 8 ether}();

        vm.prank(deployer);
        timeOracle.advanceDays(8);

        VibesTranchEscrow(payable(escrow)).finalize();

        // 20 ETH raised, 10 ETH effective, 10 ETH excess for refunds
        // LP takes 20% of effective = 2 ETH, escrow keeps 8 ETH + 10 ETH excess = 18 ETH
        uint256 escrowBalance = address(escrow).balance;

        // Freeze campaign (no excess claimed yet)
        address[] memory excludeAddresses = new address[](0);
        vm.prank(deployer);
        VibesTranchEscrow(payable(escrow)).freezeCampaign("test freeze", excludeAddresses);

        // frozenEthBalance should EXCLUDE the 10 ETH pending excess
        uint256 frozenBal = VibesTranchEscrow(payable(escrow)).frozenEthBalance();
        assertEq(frozenBal, escrowBalance - 10 ether);
    }

    function test_ProRata_FrozenBalance_PartialExcessClaimed() public {
        (address token, address escrow,) = _launchCampaign(
            VibesTranchEscrow.RaiseType.ProRata,
            GOAL,
            0,
            0
        );

        // Oversubscribe
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).contribute{value: 12 ether}();
        vm.prank(backer2);
        VibesTranchEscrow(payable(escrow)).contribute{value: 8 ether}();

        vm.prank(deployer);
        timeOracle.advanceDays(8);

        VibesTranchEscrow(payable(escrow)).finalize();

        // Backer1 claims excess (6 ETH), backer2 does not (4 ETH still pending)
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow)).claimExcessRefund();

        uint256 escrowBalance = address(escrow).balance;

        // Freeze — should subtract only the unclaimed 4 ETH
        address[] memory excludeAddresses = new address[](0);
        vm.prank(deployer);
        VibesTranchEscrow(payable(escrow)).freezeCampaign("test freeze", excludeAddresses);

        uint256 frozenBal = VibesTranchEscrow(payable(escrow)).frozenEthBalance();
        assertEq(frozenBal, escrowBalance - 4 ether);
    }

    function test_FixedGoal_FrozenBalance_NoExcessSubtracted() public {
        (address token, address escrow,) = _launchCampaign(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            0
        );

        _fundAndFinalize(escrow, GOAL);

        uint256 escrowBalance = address(escrow).balance;

        // Freeze — no excess for FixedGoal, so frozenEthBalance = full balance
        address[] memory excludeAddresses = new address[](0);
        vm.prank(deployer);
        VibesTranchEscrow(payable(escrow)).freezeCampaign("test freeze", excludeAddresses);

        assertEq(VibesTranchEscrow(payable(escrow)).frozenEthBalance(), escrowBalance);
    }

    // ============ Batch Claim Tests ============

    function test_BatchClaimTokens() public {
        // Launch first campaign
        (address token1, address escrow1,) = _launchCampaign(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            0
        );

        // Launch second campaign (before time advances)
        (address token2, address escrow2,) = _launchCampaign(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            0
        );

        // Fund both campaigns before advancing time
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow1)).contribute{value: GOAL}();
        vm.prank(backer1);
        VibesTranchEscrow(payable(escrow2)).contribute{value: GOAL}();

        // Advance time past both deadlines
        vm.prank(deployer);
        timeOracle.advanceDays(8);

        // Finalize both
        VibesTranchEscrow(payable(escrow1)).finalize();
        VibesTranchEscrow(payable(escrow2)).finalize();

        // Check claimable
        uint256 claimable1 = router.getClaimableTokens(token1, backer1);
        uint256 claimable2 = router.getClaimableTokens(token2, backer1);
        assertGt(claimable1, 0);
        assertGt(claimable2, 0);

        // Batch claim
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;

        vm.prank(backer1);
        router.batchClaimTokens(tokens);

        assertEq(IERC20(token1).balanceOf(backer1), claimable1);
        assertEq(IERC20(token2).balanceOf(backer1), claimable2);
    }

    // ============ Deposit Tests ============

    function test_DepositAutoRefundOnSuccess() public {
        (, address escrow,) = _launchCampaign(
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            0
        );

        uint256 founderBalBefore = founder.balance;

        // Fund and finalize — deposit should auto-refund
        _fundAndFinalize(escrow, GOAL);

        // Founder got deposit back (0.05 ETH)
        assertEq(founder.balance - founderBalBefore, 0.05 ether);
    }

    // ============ Pause Tests ============

    function test_PauseBlocksLaunches() public {
        vm.prank(deployer);
        router.pause();

        vm.prank(founder);
        vm.expectRevert();
        router.launchWithCampaign{value: 0.05 ether}(
            "Test", "T", 18, TOTAL_SUPPLY, CAPSULE_HASH,
            1, 1, 1, PROOF_HASH,
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL, 0, block.timestamp + 7 days,
            0, 0, 0
        );
    }

    function test_PauseOnlyOwner() public {
        vm.prank(founder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, founder));
        router.pause();
    }
}
