// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VibesTranchEscrow} from "../src/VibesTranchEscrow.sol";
import {VibesTranchEscrowFactory} from "../src/VibesTranchEscrowFactory.sol";
import {VibesStaking} from "../src/VibesStaking.sol";
import {MockTimeOracle} from "../src/MockTimeOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal ERC20 for staking tests
contract MockVibesToken is IERC20 {
    string public name = "Vibes";
    string public symbol = "VIBES";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract TermsSignatureVerificationTest is Test {
    VibesTranchEscrow public escrow;
    VibesTranchEscrowFactory public factory;
    VibesTranchEscrow public implementation;
    MockTimeOracle public timeOracle;
    VibesStaking public staking;
    MockVibesToken public vibesToken;

    // Signer key pair
    uint256 constant SIGNER_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address signerAddress;

    // Different signer for rotation tests
    uint256 constant ALT_SIGNER_PRIVATE_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address altSignerAddress;

    address public admin = makeAddr("admin");
    address public platformWallet = makeAddr("platform");
    address public router = makeAddr("router");
    address public founder = makeAddr("founder");
    address public backer1;
    address public backer2;

    uint256 constant GOAL = 10 ether;

    bytes32 constant TERMS_TYPEHASH = keccak256("TermsAcceptance(address user,uint256 nonce,uint256 deadline)");

    function setUp() public {
        signerAddress = vm.addr(SIGNER_PRIVATE_KEY);
        altSignerAddress = vm.addr(ALT_SIGNER_PRIVATE_KEY);
        backer1 = makeAddr("backer1");
        backer2 = makeAddr("backer2");

        timeOracle = new MockTimeOracle();
        implementation = new VibesTranchEscrow();

        // Factory with trustedSigner enabled
        factory = new VibesTranchEscrowFactory(
            address(implementation),
            admin,
            platformWallet,
            address(timeOracle),
            router,
            makeAddr("lpLocker"),
            signerAddress // trustedSigner enabled
        );

        // Create escrow via factory
        vm.prank(router);
        address escrowAddr = factory.createEscrow(
            founder,
            makeAddr("token"),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 14 days,
            0
        );
        escrow = VibesTranchEscrow(payable(escrowAddr));

        // Deploy staking with signer
        vibesToken = new MockVibesToken();
        staking = new VibesStaking(address(vibesToken), signerAddress);

        // Fund backers
        vm.deal(backer1, 100 ether);
        vm.deal(backer2, 100 ether);

        // Mint and approve vibes tokens for staking
        vibesToken.mint(backer1, 1000 ether);
        vm.prank(backer1);
        vibesToken.approve(address(staking), type(uint256).max);
    }

    // ============ Helpers ============

    function _signTerms(
        uint256 privateKey,
        address user,
        uint256 nonce,
        uint256 deadline,
        address verifyingContract,
        string memory contractName
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(contractName)),
                keccak256("1"),
                block.chainid,
                verifyingContract
            )
        );

        bytes32 structHash = keccak256(abi.encode(TERMS_TYPEHASH, user, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signEscrowTerms(
        uint256 privateKey,
        address user,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signTerms(privateKey, user, nonce, deadline, address(escrow), "VibesTranchEscrow");
    }

    function _signStakingTerms(
        uint256 privateKey,
        address user,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signTerms(privateKey, user, nonce, deadline, address(staking), "VibesStaking");
    }

    // ============ Escrow: Valid Signature ============

    function test_contribute_validSignature() public {
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signEscrowTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        escrow.contribute{value: 1 ether}(0, deadline, sig);

        (uint256 amount,,) = escrow.contributions(backer1);
        assertGt(amount, 0);
    }

    // NOTE: raiseChallenge signature verification is tested in FullLifecycleIntegration.t.sol
    // which has a proper router + token setup. This file's escrow uses mock addresses that
    // cannot support finalization or token staking required for challenge flow.

    // ============ Escrow: Expired Deadline ============

    function test_contribute_expiredDeadline_reverts() public {
        uint256 deadline = block.timestamp - 1; // Already expired
        bytes memory sig = _signEscrowTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.SignatureExpired.selector);
        escrow.contribute{value: 1 ether}(0, deadline, sig);
    }

    // ============ Escrow: Wrong Signer Key ============

    function test_contribute_wrongSignerKey_reverts() public {
        uint256 deadline = block.timestamp + 300;
        // Sign with alt key, but escrow expects SIGNER_PRIVATE_KEY
        bytes memory sig = _signEscrowTerms(ALT_SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.InvalidSignature.selector);
        escrow.contribute{value: 1 ether}(0, deadline, sig);
    }

    // ============ Escrow: Signature for Wrong User ============

    function test_contribute_signatureForWrongUser_reverts() public {
        uint256 deadline = block.timestamp + 300;
        // Sign for backer2, but backer1 calls
        bytes memory sig = _signEscrowTerms(SIGNER_PRIVATE_KEY, backer2, 0, deadline);

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.InvalidSignature.selector);
        escrow.contribute{value: 1 ether}(0, deadline, sig);
    }

    // ============ Escrow: Zero Signer (Gating Disabled) ============

    function test_contribute_zeroSigner_noSignatureNeeded() public {
        // Create escrow with no signer
        VibesTranchEscrowFactory noSignerFactory = new VibesTranchEscrowFactory(
            address(implementation),
            admin,
            platformWallet,
            address(timeOracle),
            router,
            makeAddr("lpLocker"),
            address(0) // No signer
        );

        vm.prank(router);
        address escrowAddr = noSignerFactory.createEscrow(
            founder,
            makeAddr("token2"),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 14 days,
            0
        );

        VibesTranchEscrow noSignerEscrow = VibesTranchEscrow(payable(escrowAddr));

        // Should succeed with empty signature
        vm.prank(backer1);
        noSignerEscrow.contribute{value: 1 ether}(0, 0, "");

        (uint256 contribAmount,,) = noSignerEscrow.contributions(backer1);
        assertGt(contribAmount, 0);
    }

    // ============ Escrow: Signer Rotation ============

    function test_signerRotation_oldSignatureRejected() public {
        // Generate signature with original signer
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signEscrowTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        // Rotate signer on escrow
        vm.prank(admin);
        escrow.setTrustedSigner(altSignerAddress);

        // Old signature should now fail
        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.InvalidSignature.selector);
        escrow.contribute{value: 1 ether}(0, deadline, sig);

        // New signer's signature should work
        bytes memory newSig = _signEscrowTerms(ALT_SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        escrow.contribute{value: 1 ether}(0, deadline, newSig);
    }

    // ============ Cross-Escrow Replay ============

    function test_crossEscrowReplay_reverts() public {
        // Create second escrow
        vm.prank(router);
        address escrow2Addr = factory.createEscrow(
            founder,
            makeAddr("token3"),
            VibesTranchEscrow.RaiseType.FixedGoal,
            GOAL,
            0,
            block.timestamp + 14 days,
            0
        );
        VibesTranchEscrow escrow2 = VibesTranchEscrow(payable(escrow2Addr));

        // Sign for escrow1
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signEscrowTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        // Should work on escrow1
        vm.prank(backer1);
        escrow.contribute{value: 1 ether}(0, deadline, sig);

        // Should fail on escrow2 (different domain separator)
        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.InvalidSignature.selector);
        escrow2.contribute{value: 1 ether}(0, deadline, sig);
    }

    // ============ receive() Reverts ============

    function test_receive_reverts_UseContributeFunction() public {
        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.UseContributeFunction.selector);
        (bool success,) = address(escrow).call{value: 1 ether}("");
        // The call itself returns false because of revert, but expectRevert handles it
    }

    // ============ Staking: Valid Signature ============

    function test_stake_validSignature() public {
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signStakingTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        staking.stake(100 ether, 0, deadline, sig);

        assertEq(staking.stakedBalance(backer1), 100 ether);
    }

    // ============ Staking: Expired Deadline ============

    function test_stake_expiredDeadline_reverts() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signStakingTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        vm.expectRevert(VibesStaking.SignatureExpired.selector);
        staking.stake(100 ether, 0, deadline, sig);
    }

    // ============ Staking: Wrong Signer ============

    function test_stake_wrongSigner_reverts() public {
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signStakingTerms(ALT_SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        vm.expectRevert(VibesStaking.InvalidSignature.selector);
        staking.stake(100 ether, 0, deadline, sig);
    }

    // ============ Staking: Zero Signer ============

    function test_stake_zeroSigner_noSignatureNeeded() public {
        VibesStaking noSignerStaking = new VibesStaking(address(vibesToken), address(0));

        vibesToken.mint(backer2, 1000 ether);
        vm.prank(backer2);
        vibesToken.approve(address(noSignerStaking), type(uint256).max);

        vm.prank(backer2);
        noSignerStaking.stake(100 ether, 0, 0, "");

        assertEq(noSignerStaking.stakedBalance(backer2), 100 ether);
    }

    // ============ Staking: Signer Rotation ============

    function test_stake_signerRotation() public {
        // Rotate signer
        staking.setTrustedSigner(altSignerAddress);

        // Old signer should fail
        uint256 deadline = block.timestamp + 300;
        bytes memory oldSig = _signStakingTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        vm.expectRevert(VibesStaking.InvalidSignature.selector);
        staking.stake(100 ether, 0, deadline, oldSig);

        // New signer should work
        bytes memory newSig = _signStakingTerms(ALT_SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        staking.stake(100 ether, 0, deadline, newSig);
    }

    // ============ Cross-Contract Replay (Staking sig on Escrow) ============

    function test_crossContractReplay_stakingSigOnEscrow_reverts() public {
        uint256 deadline = block.timestamp + 300;
        // Sign for staking contract
        bytes memory sig = _signStakingTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        // Try to use on escrow — different domain separator
        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.InvalidSignature.selector);
        escrow.contribute{value: 1 ether}(0, deadline, sig);
    }

    // ============ Nonce Validation Tests ============

    function test_contribute_wrongNonce_reverts() public {
        uint256 deadline = block.timestamp + 300;
        // Sign with nonce=1 but onchain nonce is 0
        bytes memory sig = _signEscrowTerms(SIGNER_PRIVATE_KEY, backer1, 1, deadline);

        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.InvalidNonce.selector);
        escrow.contribute{value: 1 ether}(1, deadline, sig);
    }

    function test_contribute_nonceIncrementsAfterUse() public {
        // First contribution with nonce=0
        uint256 deadline = block.timestamp + 300;
        bytes memory sig0 = _signEscrowTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        escrow.contribute{value: 1 ether}(0, deadline, sig0);

        // Onchain nonce should now be 1
        assertEq(escrow.nonces(backer1), 1);

        // Second contribution with nonce=1
        bytes memory sig1 = _signEscrowTerms(SIGNER_PRIVATE_KEY, backer1, 1, deadline);

        vm.prank(backer1);
        escrow.contribute{value: 1 ether}(1, deadline, sig1);

        // Onchain nonce should now be 2
        assertEq(escrow.nonces(backer1), 2);
    }

    function test_contribute_replayedSignature_reverts() public {
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signEscrowTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        // First use succeeds
        vm.prank(backer1);
        escrow.contribute{value: 1 ether}(0, deadline, sig);

        // Replay with same nonce=0 should fail (nonce is now 1)
        vm.prank(backer1);
        vm.expectRevert(VibesTranchEscrow.InvalidNonce.selector);
        escrow.contribute{value: 1 ether}(0, deadline, sig);
    }

    function test_stake_nonceIncrementsAfterUse() public {
        uint256 deadline = block.timestamp + 300;
        bytes memory sig0 = _signStakingTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        vm.prank(backer1);
        staking.stake(100 ether, 0, deadline, sig0);

        assertEq(staking.nonces(backer1), 1);

        // Second stake with nonce=1
        bytes memory sig1 = _signStakingTerms(SIGNER_PRIVATE_KEY, backer1, 1, deadline);

        vm.prank(backer1);
        staking.stake(100 ether, 1, deadline, sig1);

        assertEq(staking.nonces(backer1), 2);
    }

    function test_stake_replayedSignature_reverts() public {
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signStakingTerms(SIGNER_PRIVATE_KEY, backer1, 0, deadline);

        // First use succeeds
        vm.prank(backer1);
        staking.stake(100 ether, 0, deadline, sig);

        // Replay should fail
        vm.prank(backer1);
        vm.expectRevert(VibesStaking.InvalidNonce.selector);
        staking.stake(100 ether, 0, deadline, sig);
    }
}
