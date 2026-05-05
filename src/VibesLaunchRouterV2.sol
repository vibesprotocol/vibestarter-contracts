// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VibesRouterStorage} from "./VibesRouterStorage.sol";
import {VibesTokenFactory} from "./VibesTokenFactory.sol";
import {VibesRegistry} from "./VibesRegistry.sol";
import {VibesTranchEscrowFactory} from "./VibesTranchEscrowFactory.sol";
import {VibesTranchEscrow} from "./VibesTranchEscrow.sol";
import {VibesLPLocker} from "./VibesLPLocker.sol";
import {VibesVesting} from "./VibesVesting.sol";
import {VibesTreasuryEscrow} from "./VibesTreasuryEscrow.sol";
import {VibesCommunityRewardsFactory} from "./VibesCommunityRewardsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title VibesLaunchRouterV2
 * @notice Main entrypoint for launching VibesCertified tokens with tranche-based escrow and LP locking
 * @dev V2 Features:
 *      - Time-based tranche releases (10% kickstart + 15% x 6 months)
 *      - Three raise types: Fixed Goal, Open-Ended, Pro-Rata
 *      - Automatic LP creation and permanent locking via Aerodrome
 *      - Fixed token allocation: LP 15%, Ecosystem 2.5%, Founder 0-7.5%, Treasury 0-17.5%, Backers remainder
 *      - LP price matches raise price
 *
 *      Admin functions, view helpers, and less-critical operations are in VibesRouterExtension,
 *      accessed via delegatecall fallback to stay under the 24.576 KB contract size limit.
 */
contract VibesLaunchRouterV2 is VibesRouterStorage {
    using SafeERC20 for IERC20;

    /// @notice Extension contract for delegatecall (immutable, does not use storage slot)
    address public immutable extension;

    /// @notice EIP-712 typehash for launch authorization
    bytes32 public constant LAUNCH_TYPEHASH = keccak256("LaunchAuthorization(address founder,uint256 nonce,uint256 deadline)");

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(
        address _extension,
        address _tokenFactory,
        address _registry,
        address _escrowFactory,
        address payable _lpLocker
    ) VibesRouterStorage(_tokenFactory, _registry) {
        if (_extension == address(0)) revert ZeroAddress();
        extension = _extension;

        if (_escrowFactory != address(0)) {
            escrowFactory = VibesTranchEscrowFactory(_escrowFactory);
        }
        if (_lpLocker != address(0)) {
            lpLocker = VibesLPLocker(_lpLocker);
        }

        owner = msg.sender;
        feeRecipient = msg.sender;

        // Compute EIP-712 domain separator for launch signature verification
        _launchDomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("VibesLaunchRouter"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ============================================
    // LAUNCH FUNCTIONS
    // ============================================

    /**
     * @notice Launch a VibesCertified token (simple, no campaign)
     */
    function launch(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 totalSupply,
        address recipient,
        bytes32 capsuleHash,
        uint8 agentTool,
        uint8 modelProvider,
        uint8 proofType,
        bytes32 proofArtifactHash
    ) external payable whenNotPaused returns (address token) {
        _handleFees();

        if (capsuleHash == bytes32(0)) revert ZeroAddress();
        if (proofArtifactHash == bytes32(0)) revert ZeroAddress();

        address tokenRecipient = recipient == address(0) ? msg.sender : recipient;

        token = tokenFactory.deployToken(name, symbol, decimals, totalSupply, tokenRecipient);

        _registerProvenance(token, capsuleHash, agentTool, modelProvider, proofType, proofArtifactHash);
    }

    /**
     * @notice Launch a VibesCertified token with a tranche-based campaign
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals Token decimals
     * @param totalSupply Total supply to mint
     * @param capsuleHash Hash of the off-chain capsule JSON
     * @param agentTool AI tool enum value
     * @param modelProvider AI provider enum value
     * @param proofType Proof type enum value
     * @param proofArtifactHash Hash of the proof artifact
     * @param raiseType Raise type (0=FixedGoal, 1=OpenEnded, 2=ProRata)
     * @param goal Goal amount (required for FixedGoal, hard cap for ProRata)
     * @param softCap Soft cap (optional, only for OpenEnded)
     * @param deadline Campaign deadline timestamp
     * @param founderAllocationBps Founder allocation 0-750 (0-7.5%)
     * @param treasuryAllocationBps Treasury allocation: 0 (disabled) or 1000-1750 (10-17.5%). founder+treasury <= 1750
     * @param raiseStart When contributions begin (0 = immediate)
     * @return token Address of the deployed token
     * @return escrow Address of the campaign escrow
     * @return vesting Address of the founder vesting contract
     */
    function launchWithCampaign(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 totalSupply,
        bytes32 capsuleHash,
        uint8 agentTool,
        uint8 modelProvider,
        uint8 proofType,
        bytes32 proofArtifactHash,
        VibesTranchEscrow.RaiseType raiseType,
        uint256 goal,
        uint256 softCap,
        uint256 deadline,
        uint256 founderAllocationBps,
        uint256 treasuryAllocationBps,
        uint256 raiseStart,
        uint256 launchNonce,
        uint256 sigDeadline,
        bytes calldata launchSignature
    ) external payable nonReentrant whenNotPaused returns (address token, address escrow, address vesting) {
        // Verify launch authorization signature (if trustedLaunchSigner is set)
        _verifyLaunchSignature(msg.sender, launchNonce, sigDeadline, launchSignature);

        if (address(escrowFactory) == address(0)) revert EscrowFactoryNotSet();
        if (founderAllocationBps > MAX_FOUNDER_ALLOCATION_BPS) revert InvalidAllocation();
        // Treasury: must be 0 (disabled) or between MIN (10%) and MAX (17.5%)
        if (treasuryAllocationBps > 0) {
            if (treasuryAllocationBps < MIN_TREASURY_ALLOCATION_BPS) revert InvalidTreasuryAllocation();
            if (treasuryAllocationBps > MAX_TREASURY_ALLOCATION_BPS) revert InvalidTreasuryAllocation();
        }
        // Combined founder + treasury capped independently of each individual max
        // (see MAX_FOUNDER_PLUS_TREASURY_BPS). Backer protection is enforced below
        // by the 50% backer floor, not by squeezing this cap.
        if (founderAllocationBps + treasuryAllocationBps > MAX_FOUNDER_PLUS_TREASURY_BPS) revert InvalidTreasuryAllocation();

        // Audit fix: validate goal for raise types that require it
        if (raiseType == VibesTranchEscrow.RaiseType.FixedGoal) {
            require(goal > 0, "FixedGoal requires goal > 0");
        }
        if (raiseType == VibesTranchEscrow.RaiseType.ProRata) {
            require(goal > 0, "ProRata requires goal > 0");
        }

        // Collect deposit + fees
        _handleFeesAndDeposit();

        if (capsuleHash == bytes32(0)) revert ZeroAddress();
        if (proofArtifactHash == bytes32(0)) revert ZeroAddress();

        // PC-01: admin-toggleable staker-allocation disable. When `stakerAllocationDisabled`
        // is set (admin-only via setStakerAllocationDisabled in the extension), the 2.5%
        // ecosystem slice is skipped entirely and absorbed into the backer slice. Used for the
        // $VIBES TGE (no stakers at TGE finalisation) and all pre-Luxembourg-entity raises.
        // Admin flips the flag off once the operating entity is formed.
        bool stakerDisabled = stakerAllocationDisabled;

        // PC-02: admin-pre-authorized per-launcher Community Rewards slice. When the caller
        // has a non-zero `communityConfigForLaunch`, the router transfers `(totalSupply *
        // bps / 10000)` to the configured recipient at launch time. The config is deleted
        // immediately after consumption (one-shot). Default (no entry): no community slice —
        // same as any unauthorized founder.
        LaunchCommunityConfig memory communityConfig = communityConfigForLaunch[msg.sender];
        uint256 communityBps = communityConfig.bps;

        // Calculate token allocations (fixed model)
        // LP: 15% fixed, Ecosystem: 2.5% fixed (unless stakerAllocationDisabled absorbs it)
        // Treasury: 0% or 10-17.5% (at 17.5%, founder must be 0%)
        // Community: 0 by default; 0-20% when admin pre-authorized this launcher (PC-02)
        // Backers: everything else; must be >= MIN_BACKER_ALLOCATION_BPS (50%) or revert
        uint256 ecosystemBps = stakerDisabled ? 0 : ECOSYSTEM_ALLOCATION_BPS;
        uint256 backerAllocationBps = BPS_DENOMINATOR - founderAllocationBps - treasuryAllocationBps - LP_ALLOCATION_BPS - ecosystemBps - communityBps;

        // PC-02: enforce the 50% backer floor. Protects backers from any combination of
        // slices that would leave them below the minimum. In practice this only matters when
        // a community slice is authorized — founder/treasury/LP/ecosystem alone cannot push
        // backers below ~57.5% given their current caps.
        if (backerAllocationBps < MIN_BACKER_ALLOCATION_BPS) revert BackerAllocationTooLow();

        uint256 founderTokens = (totalSupply * founderAllocationBps) / BPS_DENOMINATOR;
        uint256 treasuryTokens = (totalSupply * treasuryAllocationBps) / BPS_DENOMINATOR;
        uint256 stakerTokens = (totalSupply * ecosystemBps) / BPS_DENOMINATOR;
        uint256 lpTokens = (totalSupply * LP_ALLOCATION_BPS) / BPS_DENOMINATOR;
        uint256 communityTokens = (totalSupply * communityBps) / BPS_DENOMINATOR;
        uint256 backerTokens = totalSupply - founderTokens - treasuryTokens - stakerTokens - lpTokens - communityTokens;

        // Deploy token - all tokens go to this router initially
        token = tokenFactory.deployToken(name, symbol, decimals, totalSupply, address(this));

        // Track deposit for this token
        if (founderDepositWei > 0) {
            tokenDeposits[token] = founderDepositWei;
            totalReservedDeposits += founderDepositWei;
            emit DepositCollected(msg.sender, token, founderDepositWei);
        }

        // Register provenance
        _registerProvenance(token, capsuleHash, agentTool, modelProvider, proofType, proofArtifactHash);

        // Create escrow
        escrow = escrowFactory.createEscrow(
            msg.sender,
            token,
            raiseType,
            goal,
            softCap,
            deadline,
            raiseStart
        );

        tokenToEscrow[token] = escrow;

        // Store pending LP info (LP created after campaign succeeds).
        // When stakerAllocationDisabled is true, stakerTokens is 0 — the Phase 2 staker
        // branch in VibesRouterExtension._executePhase2 short-circuits when stakerTokens == 0,
        // so no transfer or notifyReward is attempted against VibesStakerRewards.
        pendingLP[token] = PendingLP({
            tokenAmount: lpTokens,
            backerAllocation: backerTokens,
            stakerAllocation: stakerTokens
        });

        if (stakerDisabled) {
            emit StakerAllocationDisabledForLaunch(token, escrow);
        }

        // PC-03: atomically deploy a fresh VibesCommunityRewards bound to the new token,
        // transfer the slice to it, and consume the authorization. Mirrors the pattern used
        // for VibesVesting and VibesTreasuryEscrow above — except the actual `new` is
        // delegated to VibesCommunityRewardsFactory so the router's own bytecode stays
        // under the EIP-170 24,576-byte runtime limit. The factory call still happens in
        // the same transaction, preserving atomicity.
        if (communityBps > 0) {
            if (communityRewardsFactory == address(0)) revert CommunityRewardsFactoryNotSet();
            delete communityConfigForLaunch[msg.sender];
            address crAddr = VibesCommunityRewardsFactory(communityRewardsFactory).create(
                IERC20(token),
                block.timestamp + communityConfig.cliffDuration,
                communityConfig.communityAdmin
            );
            tokenToCommunityRewards[token] = crAddr;
            IERC20(token).safeTransfer(crAddr, communityTokens);
            emit CommunityAllocationConsumed(token, msg.sender, crAddr, communityTokens);
        }

        // Create vesting for founder if allocation > 0
        if (founderTokens > 0) {
            VibesVesting newVesting = new VibesVesting(
                token,
                msg.sender,
                useTestnetContracts ? 6 days : 180 days,
                useTestnetContracts ? 12 days : 365 days
            );
            vesting = address(newVesting);
            tokenToVesting[token] = vesting;

            IERC20(token).safeTransfer(vesting, founderTokens);
            newVesting.initializeAmount();

            emit VestingCreated(token, vesting, msg.sender, founderTokens);
        }

        // Create treasury escrow if allocation > 0
        if (treasuryTokens > 0) {
            // Use operations admin for day-to-day challenge resolution.
            // Falls back to owner if operationsAdmin not yet set.
            address treasuryAdmin = operationsAdmin != address(0) ? operationsAdmin : owner;
            VibesTreasuryEscrow newTreasury = new VibesTreasuryEscrow(
                token,
                msg.sender,
                treasuryAdmin,  // Operations admin resolves treasury challenges
                useTestnetContracts ? 6 days : 180 days,
                useTestnetContracts ? 2 hours : 14 days,
                useTestnetContracts ? 2 hours : 72 hours
            );
            address treasuryAddr = address(newTreasury);
            tokenToTreasury[token] = treasuryAddr;

            IERC20(token).safeTransfer(treasuryAddr, treasuryTokens);

            // Link vesting to treasury so malicious upheld can freeze vesting
            if (vesting != address(0)) {
                newTreasury.setVestingContract(vesting);
                VibesVesting(vesting).setAuthorizedFreezer(treasuryAddr);
            }

            emit TreasuryCreated(token, treasuryAddr, msg.sender, treasuryTokens);
        }

        // Note: Backer tokens and LP tokens stay in router until campaign succeeds
        // They are distributed/locked via finalizeSuccessfulCampaign()

        emit CampaignLaunched(token, escrow, msg.sender, raiseType, goal, deadline);
    }

    /**
     * @notice Complete finalization of a successful campaign - creates LP and distributor atomically
     * @dev Called by escrow during finalize(). Creates LP, locks it, and sets up token distribution.
     *      This allows the entire finalization to happen in one transaction when the raise ends.
     * @param token Token address
     *
     *      NOTE: Intentionally omits nonReentrant - called by trusted escrow during
     *      finalize(). Adding nonReentrant causes revert when triggered via claimTokens().
     */
    // NOTE: completeFinalization, claimTokens, batchClaimTokens, and _claimTokensInternal
    // have been moved to VibesRouterExtension.sol to reduce bytecode size.
    // They are accessed transparently via the router's fallback -> delegatecall pattern.

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /// @notice Verify that the backend trusted signer authorized this launch
    /// @dev If trustedLaunchSigner is address(0), gating is disabled (backwards compatible)
    /// @dev Nonce must match current value for founder; incremented after successful verification
    function _verifyLaunchSignature(address founder, uint256 nonce, uint256 sigDeadline, bytes calldata signature) internal {
        if (trustedLaunchSigner == address(0)) return; // Gating disabled

        if (nonce != launchNonces[founder]) revert InvalidNonce();
        if (block.timestamp > sigDeadline) revert SignatureExpired();

        bytes32 structHash = keccak256(abi.encode(LAUNCH_TYPEHASH, founder, nonce, sigDeadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _launchDomainSeparator, structHash));

        address recovered = ECDSA.recover(digest, signature);
        if (recovered != trustedLaunchSigner) revert InvalidSignature();

        launchNonces[founder]++;
    }

    function _handleFees() internal {
        if (feesEnabled) {
            require(msg.value >= flatFeeWei, "Insufficient fee");
            if (flatFeeWei > 0) {
                (bool sent, ) = feeRecipient.call{value: flatFeeWei}("");
                require(sent, "Fee transfer failed");
            }
            if (msg.value > flatFeeWei) {
                (bool refunded, ) = msg.sender.call{value: msg.value - flatFeeWei}("");
                require(refunded, "Refund failed");
            }
        }
    }

    function _handleFeesAndDeposit() internal {
        uint256 requiredAmount = flatFeeWei + founderDepositWei;
        if (feesEnabled) {
            if (msg.value < requiredAmount) revert InsufficientDeposit();

            // Transfer fee to recipient
            if (flatFeeWei > 0) {
                (bool sent, ) = feeRecipient.call{value: flatFeeWei}("");
                require(sent, "Fee transfer failed");
            }

            // Deposit stays in contract (tracked via tokenDeposits mapping)

            // Refund any excess
            uint256 excess = msg.value - requiredAmount;
            if (excess > 0) {
                (bool refunded, ) = msg.sender.call{value: excess}("");
                require(refunded, "Refund failed");
            }
        } else {
            // No fees but still require deposit
            if (msg.value < founderDepositWei) revert InsufficientDeposit();

            // Refund excess
            uint256 excess = msg.value - founderDepositWei;
            if (excess > 0) {
                (bool refunded, ) = msg.sender.call{value: excess}("");
                require(refunded, "Refund failed");
            }
        }

        // Burn $VIBES if configured (feature-flagged: both vibesToken and launchBurnAmount must be set)
        if (address(vibesToken) != address(0) && launchBurnAmount > 0) {
            // Transfer $VIBES from founder to dead address (permanent burn)
            // Founder must have called vibesToken.approve(router, amount) beforehand
            IERC20(address(vibesToken)).safeTransferFrom(msg.sender, address(0xdead), launchBurnAmount);
            emit VibesBurned(msg.sender, launchBurnAmount);
        }
    }

    function _registerProvenance(
        address token,
        bytes32 capsuleHash,
        uint8 agentTool,
        uint8 modelProvider,
        uint8 proofType,
        bytes32 proofArtifactHash
    ) internal {
        VibesRegistry.Attestation memory attestation = VibesRegistry.Attestation({
            version: 1,
            agentTool: agentTool,
            modelProvider: modelProvider,
            proofType: proofType,
            proofArtifactHash: proofArtifactHash
        });

        registry.registerFromRouter(token, msg.sender, capsuleHash, attestation);

        emit VibesCertified(
            token,
            msg.sender,
            capsuleHash,
            agentTool,
            modelProvider,
            proofType,
            proofArtifactHash
        );
    }

    // ============================================
    // EMERGENCY UNPAUSE (audit fix: accessible while paused)
    // ============================================

    /// @notice Emergency unpause — callable even when contract is paused
    /// @dev Lives directly on the router (not behind fallback) so it remains
    ///      reachable when the pause-guarded fallback blocks extension calls.
    function emergencyUnpause() external {
        if (msg.sender != owner) revert OnlyOwner();
        _unpause();
    }

    // ============================================
    // DELEGATECALL FALLBACK
    // ============================================

    /// @notice Forwards unmatched calls to the extension contract via delegatecall
    /// @dev Audit fix: pause-guarded to enforce emergency stop on all extension mutations.
    ///      Use emergencyUnpause() on the router directly to recover from paused state.
    fallback() external payable whenNotPaused {
        address ext = extension;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), ext, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ============================================
    // RECEIVE
    // ============================================

    event ETHReceived(address indexed sender, uint256 amount); // Audit fix U-02

    receive() external payable {
        emit ETHReceived(msg.sender, msg.value); // Audit fix U-02: log arbitrary ETH
    }
}
