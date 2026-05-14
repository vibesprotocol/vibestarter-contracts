// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VibesCommunityRewards} from "../src/VibesCommunityRewards.sol";
import {VibesLaunchRouterV2} from "../src/VibesLaunchRouterV2.sol";
import {VibesRegistry} from "../src/VibesRegistry.sol";
import {VibesRouterExtension} from "../src/VibesRouterExtension.sol";
import {VibesToken} from "../src/VibesToken.sol";
import {VibesTokenFactory} from "../src/VibesTokenFactory.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";

contract SignatureAdminAuditTest is Test {
    VibesLaunchRouterV2 internal router;
    VibesRegistry internal registry;
    VibesTokenFactory internal tokenFactory;

    address internal founder = makeAddr("founder");
    address internal admin = makeAddr("admin");
    address internal platform = makeAddr("platform");
    address internal lpLocker = makeAddr("lpLocker");

    uint256 internal constant SIGNER_PRIVATE_KEY = 0xA11CE;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 internal constant DEPOSIT = 0.01 ether;

    function setUp() public {
        tokenFactory = new VibesTokenFactory();
        registry = new VibesRegistry();

        VibesTranchEscrow escrowImplementation = new VibesTranchEscrow();
        VibesRouterExtension extension = new VibesRouterExtension();

        router = new VibesLaunchRouterV2(
            address(extension),
            address(tokenFactory),
            address(registry),
            address(0),
            payable(address(0))
        );

        VibesTranchEscrowFactory escrowFactory = new VibesTranchEscrowFactory(
            address(escrowImplementation),
            admin,
            platform,
            address(0),
            address(router),
            lpLocker,
            address(0)
        );

        VibesRouterExtension(address(router)).setEscrowFactory(address(escrowFactory));
        registry.authorizeRouter(address(router));
        vm.deal(founder, 10 ether);
    }

    function test_POC_launchAuthorizationDoesNotBindLaunchPayload() public {
        address signer = vm.addr(SIGNER_PRIVATE_KEY);
        VibesRouterExtension(address(router)).setTrustedLaunchSigner(signer);

        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes memory signature = _signLaunch(founder, 0, sigDeadline);

        bytes32 reviewedCapsule = keccak256("reviewed-capsule");
        bytes32 submittedCapsule = keccak256("different-capsule");
        bytes32 submittedProof = keccak256("different-proof");

        vm.prank(founder);
        (address token,,) = router.launchWithCampaign{value: DEPOSIT}(
            "Altered Launch",
            "ALT",
            18,
            TOTAL_SUPPLY,
            submittedCapsule,
            2,
            2,
            3,
            submittedProof,
            VibesTranchEscrow.RaiseType.FixedGoal,
            1 ether,
            0,
            block.timestamp + 7 days,
            750,
            0,
            0,
            0,
            sigDeadline,
            signature
        );

        assertEq(registry.founderOf(token), founder);
        assertEq(registry.capsuleHashOf(token), submittedCapsule);
        assertTrue(registry.capsuleHashOf(token) != reviewedCapsule);
        assertEq(router.launchNonces(founder), 1);
    }

    /// @notice ZXVC VIB-10 (2026-05) regression — admin signature path also respects batch cap.
    /// @dev Same fix as the FundFlow / EconomicMechanics variants; this PoC checked the same
    ///      over-claim attack from the SignatureAdmin-flow angle. After fix, claim reverts.
    function test_VIB10_communityRewardsClaimRespectsDeclaredBatchTotal_signatureAdminPath() public {
        address alice = makeAddr("alice");
        VibesToken token = new VibesToken("Community", "COMM", 18, 1_000 ether, address(this));
        VibesCommunityRewards rewards =
            new VibesCommunityRewards(IERC20(address(token)), block.timestamp, admin);
        token.transfer(address(rewards), 200 ether);

        bytes32 root = _communityLeaf(alice, 150 ether);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(admin);
        rewards.createBatch(root, 100 ether, 30 days, keccak256("metadata"));

        // ZXVC VIB-10 fix: 150 > 100 → revert.
        vm.expectRevert(bytes("Exceeds batch total"));
        rewards.claim(0, alice, 150 ether, emptyProof);

        (, uint256 totalAmount, uint256 claimedAmount,,,,) = rewards.batches(0);
        assertEq(totalAmount, 100 ether);
        assertEq(claimedAmount, 0, "claim accounting not advanced");
        assertEq(token.balanceOf(alice), 0, "no tokens leaked");
    }

    function _signLaunch(address launchFounder, uint256 nonce, uint256 sigDeadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            router.LAUNCH_TYPEHASH(),
            launchFounder,
            nonce,
            sigDeadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", router._launchDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _communityLeaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(abi.encodePacked(account, amount))));
    }
}
