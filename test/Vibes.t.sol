// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { VibesToken } from "../src/VibesToken.sol";
import { VibesTokenFactory } from "../src/VibesTokenFactory.sol";
import { VibesRegistry } from "../src/VibesRegistry.sol";
import { VibesLaunchRouter } from "../src/VibesLaunchRouter.sol";
import { VibesCampaignEscrow } from "../src/VibesCampaignEscrow.sol";
import { VibesCampaignFactory } from "../src/VibesCampaignFactory.sol";
import { VibesVesting } from "../src/VibesVesting.sol";
import { VibesTokenDistributor } from "../src/VibesTokenDistributor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VibesTest is Test {
    VibesTokenFactory public factory;
    VibesRegistry public registry;
    VibesLaunchRouter public router;
    VibesCampaignFactory public campaignFactory;
    VibesCampaignEscrow public escrowImplementation;

    address public deployer = address(1);
    address public founder = address(2);
    address public user = address(3);
    address public backer1 = address(4);
    address public backer2 = address(5);

    bytes32 public constant CAPSULE_HASH = keccak256("test-capsule");
    bytes32 public constant PROOF_HASH = keccak256("test-transcript");
    bytes32 public constant ZERO_HASH = bytes32(0);

    // Event declarations for expectEmit
    event VibesCertified(
        address indexed token,
        address indexed founder,
        bytes32 capsuleHash,
        uint8 agentTool,
        uint8 modelProvider,
        uint8 proofType,
        bytes32 artifactHash
    );

    function setUp() public {
        vm.startPrank(deployer);

        // Deploy contracts
        factory = new VibesTokenFactory();
        registry = new VibesRegistry();
        router = new VibesLaunchRouter(address(factory), address(registry));

        // Deploy escrow implementation and campaign factory
        escrowImplementation = new VibesCampaignEscrow();
        campaignFactory = new VibesCampaignFactory(
            address(registry),
            address(escrowImplementation),
            250, // 2.5% protocol fee
            deployer
        );

        // Configure router with campaign factory
        router.setCampaignFactory(address(campaignFactory));

        // Authorize router in registry
        registry.authorizeRouter(address(router));

        vm.stopPrank();
    }

    // ============================================
    // TOKEN TESTS
    // ============================================

    function test_TokenDeploy() public {
        vm.startPrank(founder);

        address token = factory.deployToken(
            "Test Token",
            "TEST",
            18,
            1_000_000 ether,
            founder
        );

        VibesToken t = VibesToken(token);
        assertEq(t.name(), "Test Token");
        assertEq(t.symbol(), "TEST");
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), 1_000_000 ether);
        assertEq(t.balanceOf(founder), 1_000_000 ether);

        vm.stopPrank();
    }

    function test_TokenTransfer() public {
        vm.startPrank(founder);

        address token = factory.deployToken("Test", "T", 18, 1000 ether, founder);
        VibesToken t = VibesToken(token);

        t.transfer(user, 100 ether);

        assertEq(t.balanceOf(founder), 900 ether);
        assertEq(t.balanceOf(user), 100 ether);

        vm.stopPrank();
    }

    // ============================================
    // REGISTRY TESTS
    // ============================================

    function test_RegistryDirectRegister() public {
        vm.startPrank(founder);

        // First deploy a token
        address token = factory.deployToken("Test", "T", 18, 1000 ether, founder);

        // Register it directly
        VibesRegistry.Attestation memory att = VibesRegistry.Attestation({
            version: 1,
            agentTool: 1, // CLAUDE_CODE
            modelProvider: 1, // ANTHROPIC
            proofType: 1, // TRANSCRIPT
            proofArtifactHash: PROOF_HASH
        });

        registry.register(token, CAPSULE_HASH, att);

        assertTrue(registry.isRegistered(token));
        assertEq(registry.founderOf(token), founder);
        assertEq(registry.capsuleHashOf(token), CAPSULE_HASH);

        VibesRegistry.Attestation memory stored = registry.getAttestation(token);
        assertEq(stored.agentTool, 1);
        assertEq(stored.proofArtifactHash, PROOF_HASH);

        vm.stopPrank();
    }

    function test_RevertWhen_RegistryCannotRegisterTwice() public {
        vm.startPrank(founder);

        address token = factory.deployToken("Test", "T", 18, 1000 ether, founder);

        VibesRegistry.Attestation memory att = VibesRegistry.Attestation({
            version: 1,
            agentTool: 1,
            modelProvider: 1,
            proofType: 1,
            proofArtifactHash: PROOF_HASH
        });

        registry.register(token, CAPSULE_HASH, att);

        vm.expectRevert("Already registered");
        registry.register(token, CAPSULE_HASH, att); // Should fail

        vm.stopPrank();
    }

    function test_RevertWhen_RegistryZeroCapsuleHash() public {
        vm.startPrank(founder);

        address token = factory.deployToken("Test", "T", 18, 1000 ether, founder);

        VibesRegistry.Attestation memory att = VibesRegistry.Attestation({
            version: 1,
            agentTool: 1,
            modelProvider: 1,
            proofType: 1,
            proofArtifactHash: PROOF_HASH
        });

        vm.expectRevert("Capsule hash required");
        registry.register(token, ZERO_HASH, att); // Should fail

        vm.stopPrank();
    }

    function test_RevertWhen_RegistryZeroProofHash() public {
        vm.startPrank(founder);

        address token = factory.deployToken("Test", "T", 18, 1000 ether, founder);

        VibesRegistry.Attestation memory att = VibesRegistry.Attestation({
            version: 1,
            agentTool: 1,
            modelProvider: 1,
            proofType: 1,
            proofArtifactHash: ZERO_HASH
        });

        vm.expectRevert("Proof hash required");
        registry.register(token, CAPSULE_HASH, att); // Should fail

        vm.stopPrank();
    }

    function test_RevertWhen_RegistryUnauthorizedRouter() public {
        vm.startPrank(user); // Not an authorized router

        address token = factory.deployToken("Test", "T", 18, 1000 ether, user);

        VibesRegistry.Attestation memory att = VibesRegistry.Attestation({
            version: 1,
            agentTool: 1,
            modelProvider: 1,
            proofType: 1,
            proofArtifactHash: PROOF_HASH
        });

        vm.expectRevert("Not authorized router");
        registry.registerFromRouter(token, founder, CAPSULE_HASH, att); // Should fail

        vm.stopPrank();
    }

    // ============================================
    // ROUTER TESTS
    // ============================================

    function test_RouterLaunch() public {
        vm.startPrank(founder);

        address token = router.launch(
            "Vibes Token",
            "VIBES",
            18,
            1_000_000 ether,
            address(0), // Use msg.sender
            CAPSULE_HASH,
            1, // CLAUDE_CODE
            1, // ANTHROPIC
            1, // TRANSCRIPT
            PROOF_HASH
        );

        // Check token was created correctly
        VibesToken t = VibesToken(token);
        assertEq(t.name(), "Vibes Token");
        assertEq(t.symbol(), "VIBES");
        assertEq(t.totalSupply(), 1_000_000 ether);
        assertEq(t.balanceOf(founder), 1_000_000 ether);

        // Check registry was updated
        assertTrue(registry.isRegistered(token));
        assertEq(registry.founderOf(token), founder);
        assertEq(registry.capsuleHashOf(token), CAPSULE_HASH);

        vm.stopPrank();
    }

    function test_RouterLaunchWithCustomRecipient() public {
        vm.startPrank(founder);

        address token = router.launch(
            "Vibes Token",
            "VIBES",
            18,
            1_000_000 ether,
            user, // Custom recipient
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH
        );

        VibesToken t = VibesToken(token);
        assertEq(t.balanceOf(user), 1_000_000 ether);
        assertEq(t.balanceOf(founder), 0);

        // Founder should still be recorded as founder
        assertEq(registry.founderOf(token), founder);

        vm.stopPrank();
    }

    function test_RouterLaunchEmitsEvent() public {
        vm.startPrank(founder);

        // Only check indexed parameters (token, founder) but not the token value since it's unknown
        // checkTopic1 = false (skip token address), checkTopic2 = true (check founder), checkTopic3 = false, checkData = true
        vm.expectEmit(false, true, false, true);
        emit VibesCertified(
            address(0), // Token address unknown before call - will be skipped
            founder,
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH
        );

        router.launch(
            "Vibes Token",
            "VIBES",
            18,
            1_000_000 ether,
            address(0),
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH
        );

        vm.stopPrank();
    }

    function test_RevertWhen_RouterLaunchZeroCapsuleHash() public {
        vm.startPrank(founder);

        vm.expectRevert("Capsule hash required");
        router.launch(
            "Test",
            "T",
            18,
            1000 ether,
            address(0),
            ZERO_HASH, // Should fail
            1,
            1,
            1,
            PROOF_HASH
        );

        vm.stopPrank();
    }

    function test_RevertWhen_RouterLaunchZeroProofHash() public {
        vm.startPrank(founder);

        vm.expectRevert("Proof hash required");
        router.launch(
            "Test",
            "T",
            18,
            1000 ether,
            address(0),
            CAPSULE_HASH,
            1,
            1,
            1,
            ZERO_HASH // Should fail
        );

        vm.stopPrank();
    }

    // ============================================
    // FEE TESTS
    // ============================================

    function test_RouterFeesDisabledByDefault() public view {
        assertFalse(router.feesEnabled());
        assertEq(router.flatFeeWei(), 0);
    }

    function test_RouterFeeConfig() public {
        vm.startPrank(deployer);

        router.setFeeConfig(true, 0.01 ether, deployer);

        assertTrue(router.feesEnabled());
        assertEq(router.flatFeeWei(), 0.01 ether);
        assertEq(router.feeRecipient(), deployer);

        vm.stopPrank();
    }

    function test_RouterLaunchWithFee() public {
        // Enable fees
        vm.prank(deployer);
        router.setFeeConfig(true, 0.01 ether, deployer);

        // Launch with fee
        vm.deal(founder, 1 ether);
        vm.startPrank(founder);

        uint256 deployerBalanceBefore = deployer.balance;

        router.launch{ value: 0.01 ether }(
            "Test",
            "T",
            18,
            1000 ether,
            address(0),
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH
        );

        assertEq(deployer.balance, deployerBalanceBefore + 0.01 ether);

        vm.stopPrank();
    }

    function test_RevertWhen_RouterLaunchInsufficientFee() public {
        // Enable fees
        vm.prank(deployer);
        router.setFeeConfig(true, 0.01 ether, deployer);

        // Launch without enough fee
        vm.deal(founder, 1 ether);
        vm.startPrank(founder);

        vm.expectRevert("Insufficient fee");
        router.launch{ value: 0.005 ether }( // Not enough
            "Test",
            "T",
            18,
            1000 ether,
            address(0),
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH
        );

        vm.stopPrank();
    }

    // ============================================
    // CAMPAIGN + TOKEN ALLOCATION TESTS
    // ============================================

    function test_LaunchWithCampaignDefaultAllocations() public {
        vm.startPrank(founder);

        string[] memory milestoneTitles = new string[](2);
        milestoneTitles[0] = "MVP Launch";
        milestoneTitles[1] = "Full Release";

        uint256[] memory milestonePercents = new uint256[](2);
        milestonePercents[0] = 5000; // 50%
        milestonePercents[1] = 5000; // 50%

        uint256 totalSupply = 1_000_000 ether;

        (address token, address escrow, address vesting) = router.launchWithCampaign(
            "Campaign Token",
            "CAMP",
            18,
            totalSupply,
            CAPSULE_HASH,
            1, // CLAUDE_CODE
            1, // ANTHROPIC
            1, // TRANSCRIPT
            PROOF_HASH,
            0, // FIXED_GOAL
            10 ether, // goal
            block.timestamp + 30 days, // deadline
            milestoneTitles,
            milestonePercents,
            0, // Use defaults
            0,
            0
        );

        // Verify token allocations with defaults (50/30/20)
        IERC20 tokenContract = IERC20(token);

        // 50% (500,000) should be in escrow for backers
        assertEq(tokenContract.balanceOf(escrow), 500_000 ether);

        // 30% (300,000) should be in vesting for founder
        assertEq(tokenContract.balanceOf(vesting), 300_000 ether);

        // 20% (200,000) should be in router for liquidity
        assertEq(tokenContract.balanceOf(address(router)), 200_000 ether);
        assertEq(router.liquidityTokens(token), 200_000 ether);

        // Verify escrow has correct backer allocation stored
        VibesCampaignEscrow escrowContract = VibesCampaignEscrow(payable(escrow));
        assertEq(escrowContract.backerTokenAllocation(), 500_000 ether);

        // Verify vesting is for founder
        VibesVesting vestingContract = VibesVesting(vesting);
        assertEq(vestingContract.beneficiary(), founder);
        assertEq(vestingContract.totalAmount(), 300_000 ether);

        vm.stopPrank();
    }

    function test_LaunchWithCampaignCustomAllocations() public {
        vm.startPrank(founder);

        string[] memory milestoneTitles = new string[](1);
        milestoneTitles[0] = "Complete Project";

        uint256[] memory milestonePercents = new uint256[](1);
        milestonePercents[0] = 10000; // 100%

        uint256 totalSupply = 1_000_000 ether;

        // Custom allocation: 70% backers, 20% founder, 10% liquidity
        (address token, address escrow, address vesting) = router.launchWithCampaign(
            "Custom Token",
            "CUST",
            18,
            totalSupply,
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH,
            0, // FIXED_GOAL
            5 ether,
            block.timestamp + 7 days,
            milestoneTitles,
            milestonePercents,
            7000, // 70% backers
            2000, // 20% founder
            1000  // 10% liquidity
        );

        IERC20 tokenContract = IERC20(token);

        // Verify custom allocations
        assertEq(tokenContract.balanceOf(escrow), 700_000 ether);
        assertEq(tokenContract.balanceOf(vesting), 200_000 ether);
        assertEq(tokenContract.balanceOf(address(router)), 100_000 ether);

        vm.stopPrank();
    }

    function test_RevertWhen_AllocationsNotSum100() public {
        vm.startPrank(founder);

        string[] memory milestoneTitles = new string[](1);
        milestoneTitles[0] = "Test";

        uint256[] memory milestonePercents = new uint256[](1);
        milestonePercents[0] = 10000;

        vm.expectRevert("Allocations must sum to 100%");
        router.launchWithCampaign(
            "Test",
            "T",
            18,
            1000 ether,
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH,
            0,
            1 ether,
            block.timestamp + 1 days,
            milestoneTitles,
            milestonePercents,
            5000, // 50%
            3000, // 30%
            1000  // 10% - doesn't sum to 100%!
        );

        vm.stopPrank();
    }

    // ============================================
    // VESTING TESTS
    // ============================================

    function test_VestingLinearRelease() public {
        vm.startPrank(founder);

        string[] memory milestoneTitles = new string[](1);
        milestoneTitles[0] = "Done";

        uint256[] memory milestonePercents = new uint256[](1);
        milestonePercents[0] = 10000;

        (, , address vesting) = router.launchWithCampaign(
            "Vest Token",
            "VEST",
            18,
            1_000_000 ether,
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH,
            0,
            1 ether,
            block.timestamp + 30 days,
            milestoneTitles,
            milestonePercents,
            0, 0, 0 // defaults
        );

        VibesVesting vestingContract = VibesVesting(vesting);
        IERC20 tokenContract = IERC20(vestingContract.token());

        uint256 founderTokens = 300_000 ether; // 30% of 1M

        // At start, nothing releasable
        assertEq(vestingContract.releasable(), 0);

        // Fast forward 6 months (half of vesting period)
        vm.warp(block.timestamp + 182.5 days);

        // Should have ~50% vested
        uint256 halfVested = vestingContract.vestedAmount();
        assertApproxEqRel(halfVested, founderTokens / 2, 0.01e18); // 1% tolerance

        // Release vested tokens
        uint256 founderBalanceBefore = tokenContract.balanceOf(founder);
        vestingContract.release();
        uint256 founderBalanceAfter = tokenContract.balanceOf(founder);

        assertApproxEqRel(founderBalanceAfter - founderBalanceBefore, founderTokens / 2, 0.01e18);

        // Fast forward to end of vesting
        vm.warp(block.timestamp + 183 days);

        // Should have remaining tokens releasable
        assertApproxEqRel(vestingContract.releasable(), founderTokens / 2, 0.01e18);

        // Release remaining
        vestingContract.release();

        // Vesting should be empty
        assertEq(tokenContract.balanceOf(vesting), 0);
        assertEq(tokenContract.balanceOf(founder), founderTokens);

        vm.stopPrank();
    }

    // ============================================
    // CAMPAIGN CONTRIBUTION TESTS
    // ============================================

    function test_CampaignContribution() public {
        // Setup: Launch campaign
        vm.startPrank(founder);

        string[] memory milestoneTitles = new string[](1);
        milestoneTitles[0] = "Finish";

        uint256[] memory milestonePercents = new uint256[](1);
        milestonePercents[0] = 10000;

        (, address escrow, ) = router.launchWithCampaign(
            "Fund Token",
            "FUND",
            18,
            1_000_000 ether,
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH,
            0, // FIXED_GOAL
            10 ether,
            block.timestamp + 30 days,
            milestoneTitles,
            milestonePercents,
            0, 0, 0
        );
        vm.stopPrank();

        VibesCampaignEscrow escrowContract = VibesCampaignEscrow(payable(escrow));

        // Backer contributes
        vm.deal(backer1, 5 ether);
        vm.prank(backer1);
        escrowContract.contribute{ value: 5 ether }();

        assertEq(escrowContract.totalRaised(), 5 ether);
        assertEq(escrowContract.contributions(backer1), 5 ether);
        assertEq(address(escrowContract).balance, 5 ether);
    }

    function test_MilestoneVerificationAndFundRelease() public {
        // Setup: Launch campaign
        vm.startPrank(founder);

        string[] memory milestoneTitles = new string[](1);
        milestoneTitles[0] = "Complete";

        uint256[] memory milestonePercents = new uint256[](1);
        milestonePercents[0] = 10000;

        (, address escrow, ) = router.launchWithCampaign(
            "Release Token",
            "REL",
            18,
            1_000_000 ether,
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH,
            0, // FIXED_GOAL
            10 ether,
            block.timestamp + 30 days,
            milestoneTitles,
            milestonePercents,
            0, 0, 0
        );
        vm.stopPrank();

        VibesCampaignEscrow escrowContract = VibesCampaignEscrow(payable(escrow));

        // Backer contributes enough to reach goal
        vm.deal(backer1, 10 ether);
        vm.prank(backer1);
        escrowContract.contribute{ value: 10 ether }();

        // Campaign should now be FUNDED
        assertEq(uint256(escrowContract.status()), uint256(VibesCampaignEscrow.CampaignStatus.FUNDED));

        // Founder submits milestone proof and releases funds
        uint256 founderBalanceBefore = founder.balance;
        uint256 deployerBalanceBefore = deployer.balance; // Protocol fee recipient

        vm.prank(founder);
        escrowContract.submitMilestoneProof(0, CAPSULE_HASH);

        // Calculate expected amounts (2.5% fee)
        uint256 grossRelease = 10 ether;
        uint256 protocolFee = (grossRelease * 250) / 10000; // 0.25 ETH
        uint256 founderReceived = grossRelease - protocolFee; // 9.75 ETH

        assertEq(founder.balance - founderBalanceBefore, founderReceived);
        assertEq(deployer.balance - deployerBalanceBefore, protocolFee);

        // Campaign should now be COMPLETED
        assertEq(uint256(escrowContract.status()), uint256(VibesCampaignEscrow.CampaignStatus.COMPLETED));
    }

    // ============================================
    // TOKEN DISTRIBUTION TESTS
    // ============================================

    function test_TransferToDistributor() public {
        // Setup: Launch and complete campaign
        vm.startPrank(founder);

        string[] memory milestoneTitles = new string[](1);
        milestoneTitles[0] = "Done";

        uint256[] memory milestonePercents = new uint256[](1);
        milestonePercents[0] = 10000;

        (address token, address escrow, ) = router.launchWithCampaign(
            "Dist Token",
            "DIST",
            18,
            1_000_000 ether,
            CAPSULE_HASH,
            1,
            1,
            1,
            PROOF_HASH,
            0,
            5 ether,
            block.timestamp + 30 days,
            milestoneTitles,
            milestonePercents,
            0, 0, 0
        );
        vm.stopPrank();

        VibesCampaignEscrow escrowContract = VibesCampaignEscrow(payable(escrow));

        // Backer contributes
        vm.deal(backer1, 5 ether);
        vm.prank(backer1);
        escrowContract.contribute{ value: 5 ether }();

        // Founder completes milestone
        vm.prank(founder);
        escrowContract.submitMilestoneProof(0, CAPSULE_HASH);

        // Founder creates distributor via router
        vm.prank(founder);
        address distributor = router.createDistributor(token, escrow);

        // Verify tokens transferred to distributor
        IERC20 tokenContract = IERC20(token);
        assertEq(tokenContract.balanceOf(distributor), 500_000 ether); // 50% backer allocation
        assertEq(tokenContract.balanceOf(escrow), 0);

        // Verify escrow marked as distributed
        assertTrue(escrowContract.tokensDistributed());
    }
}
