// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VibesRouterStorage} from "./VibesRouterStorage.sol";
import {VibesTranchEscrow} from "./VibesTranchEscrow.sol";
import {VibesLPLocker} from "./VibesLPLocker.sol";
import {VibesTranchEscrowFactory} from "./VibesTranchEscrowFactory.sol";
import {VibesTokenDistributorV2} from "./VibesTokenDistributorV2.sol";
import {VibesVesting} from "./VibesVesting.sol";
import {VibesTreasuryEscrow} from "./VibesTreasuryEscrow.sol";
import {VibesStakerRewards} from "./VibesStakerRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title VibesRouterExtension
 * @notice Extension contract for VibesLaunchRouterV2, accessed via delegatecall fallback.
 * @dev Contains admin functions, view functions, and less-frequently-used operations
 *      to reduce the main router's bytecode size below the 24.576 KB limit.
 *      This contract is NOT called directly — it is only invoked via delegatecall from
 *      the main router's fallback function.
 */
contract VibesRouterExtension is VibesRouterStorage {
    using SafeERC20 for IERC20;

    // ============================================
    // EVENTS (extension-only)
    // ============================================

    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    // ============================================
    // CONSTRUCTOR (no-op, only used via delegatecall)
    // ============================================

    constructor() VibesRouterStorage(address(1), address(1)) {}

    // ============================================
    // FINALIZE — PHASE 1: LP Creation (~800K gas)
    // Called by escrow callback via router fallback
    // ============================================

    /**
     * @notice Phase 1: Create and lock LP after escrow transitions to Funded state
     * @dev Called by escrow via IVibesLaunchRouter(router).completeFinalization(token).
     *      Reaches this contract via the router's fallback -> delegatecall pattern.
     *      This is the gas-heavy phase (LP pool deployment). Phase 2 (distribution)
     *      is a separate call to reduce per-tx gas and prevent OOG failures.
     * @param token Token address
     */
    function completeFinalization(address token) external whenNotPaused {
        // No-op if already past Phase 1
        if (finalizationPhase[token] == FinalizationPhase.LPComplete ||
            finalizationPhase[token] == FinalizationPhase.FullyComplete) {
            return;
        }

        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) revert ZeroAddress();

        // Only the escrow can call this
        if (msg.sender != escrowAddr) revert OnlyEscrow();

        _executePhase1(token, escrowAddr);
    }

    /**
     * @dev Internal Phase 1 execution: LP creation, staker allocation caching
     */
    function _executePhase1(address token, address escrowAddr) internal {
        if (address(lpLocker) == address(0)) revert LPLockerNotSet();

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();

        if (campaign.state != VibesTranchEscrow.CampaignState.Funded) {
            revert CampaignNotFunded();
        }

        PendingLP memory lpData = pendingLP[token];
        if (lpData.tokenAmount == 0) revert NoPendingLP();
        if (opsWallet == address(0)) revert OpsWalletNotSet();

        // Cache staker allocation + destination BEFORE deleting pendingLP
        // Snapshot destination prevents config drift between phases
        _pendingStakerAllocation[token] = lpData.stakerAllocation;
        _pendingStakerRecipient[token] = stakerRewardsContract;

        // === Create and lock LP ===
        uint256 ethForLP = escrow.getLPEthSent();
        IERC20(token).approve(address(lpLocker), lpData.tokenAmount);

        // Locker deploys a per-campaign VibesLPFeeClaimer, routes LP there (soulbound),
        // and wires fee destinations: WETH → feeRecipient, project token → treasury if
        // configured (else burned inside the claimer).
        (address pool, uint256 lpAmount) = lpLocker.createAndLockLP{value: ethForLP}(
            token,
            lpData.tokenAmount,
            escrowAddr,
            feeRecipient,
            tokenToTreasury[token]
        );

        // Audit fix F1: Accept LP rescue instead of reverting
        if (pool == address(0) || lpAmount == 0) {
            lpStatus[token] = LPStatus.Rescued;
            emit LPCreationRescued(token, escrowAddr);
        } else {
            lpStatus[token] = LPStatus.Created;
            escrow.setLPCreated();
            emit LPCreated(token, pool, lpData.tokenAmount, ethForLP, lpAmount);
        }

        // Clear pending LP (data now cached in _pendingStaker* mappings)
        delete pendingLP[token];

        finalizationPhase[token] = FinalizationPhase.LPComplete;
        emit FinalizationPhase1Complete(token);
    }

    // ============================================
    // FINALIZE — PHASE 2: Distribution (~400K gas)
    // Called by escrow, admin, or auto-triggered by claimTokens
    // ============================================

    /**
     * @notice Phase 2: Distribute tokens (vesting, treasury, staker rewards, backer pool)
     * @dev Can be called by the escrow (normal flow) or by owner (admin retry).
     *      Requires Phase 1 (LP creation) to have completed first.
     *      No-op if already fully complete (safe for retry).
     * @param token Token address
     */
    // Audit fix M-1: nonReentrant added for defense-in-depth against future project tokens
    // that add transfer hooks (ERC777-style) or a malicious staker-rewards recipient.
    function completeDistribution(address token) external whenNotPaused nonReentrant {
        // No-op if already fully complete
        if (finalizationPhase[token] == FinalizationPhase.FullyComplete) return;

        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) revert ZeroAddress();

        // Access: escrow OR owner (enables admin retry)
        if (msg.sender != escrowAddr && msg.sender != owner) revert OnlyEscrow();

        _executePhase2(token, escrowAddr);
    }

    /**
     * @dev Internal Phase 2 execution: vesting, treasury, staker rewards, backer pool, deposit refund
     */
    function _executePhase2(address token, address escrowAddr) internal {
        if (finalizationPhase[token] != FinalizationPhase.LPComplete) revert Phase1NotComplete();

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();

        if (campaign.state != VibesTranchEscrow.CampaignState.Funded) {
            revert CampaignNotFunded();
        }

        // === Start founder vesting (no try-catch — must succeed or Phase 2 retries) ===
        address vestingAddr = tokenToVesting[token];
        if (vestingAddr != address(0)) {
            VibesVesting(vestingAddr).startVesting();
        }

        // === Activate treasury (no try-catch — must succeed or Phase 2 retries) ===
        address treasuryAddr = tokenToTreasury[token];
        if (treasuryAddr != address(0)) {
            VibesTreasuryEscrow(treasuryAddr).activate();
        }

        // === Staker rewards: transfer + notify (decoupled for retry safety) ===
        uint256 stakerTokens = _pendingStakerAllocation[token];
        address stakerDest = _pendingStakerRecipient[token];

        if (stakerTokens > 0 && stakerDest != address(0) && stakerDest.code.length > 0) {
            // ZXVC VIB-03 (2026-05): notify BEFORE transfer, no try/catch.
            //
            // The previous order (transfer → try/catch notify) allowed a deployment with
            // staking.snapshotAuthorized(stakerRewards) == false to reach FullyComplete
            // while leaving tokens permanently stranded in stakerRewards with
            // reward.active == false (no claim path opens, no rescuePath exists). With
            // notify-first, takeSnapshot's authorisation check reverts up through
            // _executePhase2 → state fully rolls back → tokens are NOT transferred.
            // Invariant: tokens never sit in stakerRewards while reward.active == false.
            VibesStakerRewards(stakerDest).notifyReward(token, stakerTokens, escrowAddr);
            emit StakerRewardsAllocated(token, stakerDest, stakerTokens);

            // Transfer after notify succeeded. The _stakerTokensTransferred checkpoint
            // is kept as a belt-and-braces double-transfer guard, but with notify-first
            // it's not needed for retry safety — Phase 2 is atomic within a tx, so a
            // notify-then-revert path rolls back both state changes together; if notify
            // already succeeded in a prior tx, that tx must have completed Phase 2 and
            // there is no retry from this path.
            if (!_stakerTokensTransferred[token]) {
                IERC20(token).safeTransfer(stakerDest, stakerTokens);
                _stakerTokensTransferred[token] = true;
            }
        } else if (stakerTokens > 0) {
            emit StakerTokensRedirectedToBackers(token, stakerTokens);
        }

        // === Wire locked addresses for correct refund denominator ===
        escrow.setLockedAddresses(vestingAddr, stakerDest);
        // Audit fix F-2 (2026-04): exclude treasury balance from redeemable supply on freeze.
        // Only wire when a treasury is configured for this token.
        if (treasuryAddr != address(0)) {
            escrow.setTreasuryContract(treasuryAddr);
        }
        // ZXVC VIB-02 (2026-05): latch custody addresses so admin cannot manipulate the
        // refund denominator post-Phase-2 to extract frozenEthBalance.
        escrow.finalizeLockedAddresses();

        // === Record backer tokens available for claims ===
        uint256 routerBalance = IERC20(token).balanceOf(address(this));
        backerTokensForClaims[token] = routerBalance;
        initialBackerTokens[token] = routerBalance;

        // === Cleanup phase tracking (CEI: state updates BEFORE external call) ===
        delete _pendingStakerAllocation[token];
        delete _pendingStakerRecipient[token];
        delete _stakerTokensTransferred[token];

        finalizationPhase[token] = FinalizationPhase.FullyComplete;
        emit FinalizationPhase2Complete(token);

        // Post-completion invariant
        assert(_pendingStakerAllocation[token] == 0);

        // === Auto-refund founder deposit (non-blocking, AFTER state finalization) ===
        // CEI fix: moved after finalizationPhase update so a malicious founder contract
        // receiving ETH cannot re-enter and read stale intermediate state.
        uint256 depositAmount = tokenDeposits[token];
        if (depositAmount > 0) {
            delete tokenDeposits[token];
            totalReservedDeposits -= depositAmount;
            (bool sent, ) = campaign.founder.call{value: depositAmount}("");
            if (sent) {
                emit DepositRefunded(campaign.founder, token, depositAmount);
            } else {
                // Revert bookkeeping if transfer fails — deposit stays reserved
                tokenDeposits[token] = depositAmount;
                totalReservedDeposits += depositAmount;
            }
        }
    }

    // ============================================
    // ADMIN: RETRY FINALIZATION
    // ============================================

    /**
     * @notice Admin retry for failed/deferred finalization
     * @dev Runs whichever phases haven't completed yet.
     *      Detects pre-migration raises (completed before phase tracker existed) and skips them.
     * @param token Token address
     */
    function adminRetryFinalization(address token) external onlyOwner nonReentrant whenNotPaused {
        if (finalizationPhase[token] == FinalizationPhase.FullyComplete) {
            revert FinalizationAlreadyComplete();
        }

        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) revert ZeroAddress();

        // Detect pre-migration completed raises:
        // initialBackerTokens is a non-depleting snapshot set once during finalization.
        // If it's > 0 and pendingLP is gone, the raise was finalized under old code.
        if (finalizationPhase[token] == FinalizationPhase.None &&
            pendingLP[token].tokenAmount == 0 &&
            initialBackerTokens[token] > 0) {
            revert FinalizationAlreadyComplete();
        }

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();
        if (campaign.state != VibesTranchEscrow.CampaignState.Funded) {
            revert CampaignNotFunded();
        }

        uint8 startPhase = uint8(finalizationPhase[token]);

        if (finalizationPhase[token] == FinalizationPhase.None) {
            _executePhase1(token, escrowAddr);
        }

        _executePhase2(token, escrowAddr);

        emit FinalizationRetried(token, startPhase, msg.sender);
    }

    // ============================================
    // TOKEN CLAIMS (moved from router to reduce bytecode)
    // ============================================

    /**
     * @notice Claim tokens for a funded campaign (auto-finalizes if needed)
     * @param token Token address of the campaign
     */
    function claimTokens(address token) external nonReentrant whenNotPaused {
        _claimTokensInternal(token);
    }

    /**
     * @notice Batch claim tokens from multiple funded campaigns
     * @param tokens Array of token addresses to claim from
     */
    function batchClaimTokens(address[] calldata tokens) external nonReentrant whenNotPaused {
        if (tokens.length == 0) revert NothingToClaim();
        if (tokens.length > 20) revert TooManyTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            _claimTokensInternal(tokens[i]);
        }
    }

    /**
     * @dev Internal claim logic shared by claimTokens and batchClaimTokens
     */
    function _claimTokensInternal(address token) internal {
        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) revert ZeroAddress();

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();

        // Auto-finalize if campaign has ended but hasn't been finalized yet
        if (campaign.state == VibesTranchEscrow.CampaignState.Active ||
            campaign.state == VibesTranchEscrow.CampaignState.Paused) {
            uint256 escrowTime = escrow.currentTime();
            if (escrowTime < campaign.deadline) revert CampaignNotReady();
            escrow.finalize();
            campaign = escrow.getCampaign();
        }

        // Must be in Funded, Completed, Frozen, or Refunding state to claim
        if (campaign.state != VibesTranchEscrow.CampaignState.Funded &&
            campaign.state != VibesTranchEscrow.CampaignState.Completed &&
            campaign.state != VibesTranchEscrow.CampaignState.Frozen &&
            campaign.state != VibesTranchEscrow.CampaignState.Refunding) {
            revert CampaignNotFunded();
        }

        // Audit fix H-3: Block claims before any finalization progress. Phase-0 (None) would
        // otherwise silently succeed the side-effect way (via backerTokensForClaims defaulting
        // to zero → NothingToClaim revert), but relying on that is fragile: any refactor that
        // populates backerTokensForClaims earlier would open the H-3 double-dip path. Explicitly
        // require the router to have progressed finalization for this token before any transfer.
        if (finalizationPhase[token] == FinalizationPhase.None) revert Phase1NotComplete();

        // Auto-trigger Phase 2 if LP is done but distribution hasn't run
        // Safety net: first claimer pays ~400K extra gas but raise self-heals
        if (finalizationPhase[token] == FinalizationPhase.LPComplete) {
            _executePhase2(token, escrowAddr);
        }

        // Audit fix H-3: After self-heal, finalization MUST be fully complete before we
        // transfer tokens. If _executePhase2 reverted inside try/catch or the campaign was
        // forced through an intermediate state, we fail closed rather than allow a partial claim.
        if (finalizationPhase[token] != FinalizationPhase.FullyComplete) revert Phase1NotComplete();

        if (hasClaimedTokens[token][msg.sender]) revert AlreadyClaimed();

        VibesTranchEscrow.Contribution memory contrib = escrow.getContribution(msg.sender);
        if (contrib.amount == 0) revert NotABacker();

        // Calculate effective contribution (handles pro-rata)
        uint256 effectiveContribution = contrib.amount;
        if (campaign.raiseType == VibesTranchEscrow.RaiseType.ProRata) {
            uint256 totalCommitted = campaign.totalCommitted;
            if (totalCommitted > campaign.goal) {
                effectiveContribution = (contrib.amount * campaign.goal) / totalCommitted;
            }
        }

        // Calculate token allocation using initial snapshot (audit fix: order-independent claims)
        uint256 effectiveRaised = escrow.effectiveRaised();
        uint256 totalBackerTokens = initialBackerTokens[token];
        if (totalBackerTokens == 0) totalBackerTokens = backerTokensForClaims[token];

        if (effectiveRaised == 0 || totalBackerTokens == 0) revert NothingToClaim();

        uint256 tokenAmount = (effectiveContribution * totalBackerTokens) / effectiveRaised;

        // Cap to remaining balance to handle rounding
        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (tokenAmount > remaining) {
            tokenAmount = remaining;
        }
        if (tokenAmount == 0) revert NothingToClaim();

        // Mark as claimed, decrement pool, and transfer
        hasClaimedTokens[token][msg.sender] = true;
        backerTokensForClaims[token] -= tokenAmount;
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit TokensClaimed(token, msg.sender, tokenAmount);
    }

    // ============================================
    // DISTRIBUTOR CREATION
    // ============================================

    /**
     * @notice DEPRECATED — distributor path disabled (audit fix F5)
     * @dev This function was permissionless and could grief backer claims by moving
     *      router-held tokens into an unconfigured distributor. Direct router claims
     *      via claimTokens() are the canonical production path.
     */
    function createDistributor(address /* token */) external pure returns (address) {
        revert DistributorDisabled();
    }

    // ============================================
    // LP RESOLUTION (audit fix F1)
    // ============================================

    /**
     * @notice Mark a rescued LP as manually resolved
     * @dev Called by owner after resolving rescued funds in LP locker via resolveRescuedFunds()
     *      and manually creating LP through alternative means.
     *      Audit fix F7b: Requires onchain proof that LP was actually created and locked to
     *      0xdead before unblocking tranche claims. Without this, a compromised owner could
     *      unblock tranches without LP ever being locked, breaking a core user trust guarantee.
     * @param token Token address whose LP was rescued during finalization
     */
    function completeLP(address token) external onlyOwner nonReentrant {
        if (lpStatus[token] != LPStatus.Rescued) revert NotInRescuedState();

        // Audit fix F7b: Verify LP was actually created and locked onchain
        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr != address(0)) {
            // LP locker must have a real locked position (not just rescued) for this campaign
            require(
                lpLocker.hasLockedLP(escrowAddr) && !lpLocker.hasRescuedLP(escrowAddr),
                "LP not actually locked onchain"
            );
            (bool locked, ) = lpLocker.verifyLPLocked(escrowAddr);
            require(locked, "LP tokens not verified at dead address");

            lpStatus[token] = LPStatus.Created;
            VibesTranchEscrow(payable(escrowAddr)).setLPCreated();
        }

        emit LPManuallyResolved(token);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get claimable amounts for multiple tokens at once
     * @param tokens Array of token addresses
     * @param backer Backer address
     * @return amounts Array of claimable token amounts (0 for non-claimable)
     */
    function getBatchClaimableTokens(address[] calldata tokens, address backer) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = this.getClaimableTokens(tokens[i], backer);
        }
    }

    /**
     * @notice Get the token amount a backer can claim
     * @param token Token address
     * @param backer Backer address
     * @return tokenAmount Amount of tokens claimable (0 if already claimed or not eligible)
     */
    function getClaimableTokens(address token, address backer) external view returns (uint256 tokenAmount) {
        address escrowAddr = tokenToEscrow[token];
        if (escrowAddr == address(0)) return 0;

        if (hasClaimedTokens[token][backer]) return 0;

        VibesTranchEscrow escrow = VibesTranchEscrow(payable(escrowAddr));
        VibesTranchEscrow.Campaign memory campaign = escrow.getCampaign();

        // Only calculate if funded (or will be funded when finalized)
        if (campaign.state != VibesTranchEscrow.CampaignState.Funded &&
            campaign.state != VibesTranchEscrow.CampaignState.Active &&
            campaign.state != VibesTranchEscrow.CampaignState.Paused) {
            return 0;
        }

        VibesTranchEscrow.Contribution memory contrib = escrow.getContribution(backer);
        if (contrib.amount == 0) return 0;

        uint256 effectiveContribution = contrib.amount;
        if (campaign.raiseType == VibesTranchEscrow.RaiseType.ProRata) {
            uint256 totalCommitted = campaign.totalCommitted;
            if (totalCommitted > campaign.goal) {
                effectiveContribution = (contrib.amount * campaign.goal) / totalCommitted;
            }
        }

        uint256 effectiveRaised = escrow.effectiveRaised();
        // Use initial snapshot for consistent view (audit fix: order-independent claims)
        uint256 totalBackerTokens = initialBackerTokens[token];
        if (totalBackerTokens == 0) totalBackerTokens = backerTokensForClaims[token];

        // If not finalized yet, estimate based on pending LP data
        if (totalBackerTokens == 0) {
            PendingLP memory lpData = pendingLP[token];
            uint256 routerBalance = IERC20(token).balanceOf(address(this));
            if (routerBalance < lpData.tokenAmount) return 0;
            totalBackerTokens = routerBalance - lpData.tokenAmount;
        }

        if (effectiveRaised == 0) {
            // Use totalRaised as estimate for effectiveRaised if not set yet
            effectiveRaised = campaign.totalRaised;
        }

        if (effectiveRaised == 0 || totalBackerTokens == 0) return 0;

        tokenAmount = (effectiveContribution * totalBackerTokens) / effectiveRaised;
    }

    function getTokenInfo(address token) external view returns (
        address escrow,
        address vesting,
        address distributor,
        address treasury,
        uint256 pendingLPTokens
    ) {
        escrow = tokenToEscrow[token];
        vesting = tokenToVesting[token];
        distributor = tokenToDistributor[token];
        treasury = tokenToTreasury[token];
        pendingLPTokens = pendingLP[token].tokenAmount;
    }

    /**
     * @notice Get deposit info for a token
     * @param token Token address
     * @return depositAmount Amount of deposit held (0 if refunded/forfeited)
     */
    function getDepositInfo(address token) external view returns (uint256 depositAmount) {
        depositAmount = tokenDeposits[token];
    }

    /**
     * @notice Get current deposit requirement
     * @return Current founder deposit amount in wei
     */
    function getDepositRequirement() external view returns (uint256) {
        return founderDepositWei;
    }

    /**
     * @notice Get current $VIBES burn requirement for launching
     * @return token Address of $VIBES token (address(0) if burn disabled)
     * @return amount Amount of $VIBES burned per launch (0 if burn disabled)
     */
    function getLaunchBurnRequirement() external view returns (address token, uint256 amount) {
        token = address(vibesToken);
        amount = launchBurnAmount;
    }

    // ============================================
    // ADMIN: OWNERSHIP
    // ============================================

    /// @notice L6 fix: two-step ownership transfer (step 1: propose)
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
    }

    /// @notice L6 fix: two-step ownership transfer (step 2: accept)
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ============================================
    // ADMIN: PAUSE
    // ============================================

    /// @notice Emergency pause - stops launches, claims, and finalization
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause after emergency is resolved
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================
    // ADMIN: SETTERS
    // ============================================

    function setFeeConfig(
        bool _enabled,
        uint256 _flatFeeWei,
        address _recipient
    ) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        feesEnabled = _enabled;
        flatFeeWei = _flatFeeWei;
        feeRecipient = _recipient;
    }

    function setEscrowFactory(address _escrowFactory) external onlyOwner {
        if (_escrowFactory == address(0)) revert ZeroAddress();
        escrowFactory = VibesTranchEscrowFactory(_escrowFactory);
    }

    function setLPLocker(address payable _lpLocker) external onlyOwner {
        if (_lpLocker == address(0)) revert ZeroAddress();
        lpLocker = VibesLPLocker(_lpLocker);
    }

    function setCommunityRewardsFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert ZeroAddress();
        communityRewardsFactory = _factory;
    }

    function setOpsWallet(address _opsWallet) external onlyOwner {
        if (_opsWallet == address(0)) revert ZeroAddress();
        opsWallet = _opsWallet;
    }

    /**
     * @notice Set the staker rewards contract for $VIBES staker distributions
     * @param _stakerRewardsContract Address of VibesStakerRewards contract
     */
    function setStakerRewardsContract(address _stakerRewardsContract) external onlyOwner {
        if (_stakerRewardsContract == address(0)) revert ZeroAddress();
        stakerRewardsContract = _stakerRewardsContract;
    }

    /**
     * @notice PC-01: Toggle the global staker-allocation-disabled flag.
     * @dev When true, every subsequent `launchWithCampaign` skips the 2.5% ecosystem slice
     *      and absorbs it into the backer slice. Intended to be flipped `true` at mainnet
     *      deployment and remain true until the Luxembourg operating entity is formed, at
     *      which point admin flips `false` and staker rewards begin accruing forward-only.
     * @param _disabled New value for the flag.
     */
    function setStakerAllocationDisabled(bool _disabled) external onlyOwner {
        stakerAllocationDisabled = _disabled;
        emit StakerAllocationDisabledSet(_disabled);
    }

    /**
     * @notice PC-03: Pre-authorize a specific launcher wallet to launch a raise with a
     *         Community Rewards allocation. On the launcher's next `launchWithCampaign` call,
     *         the router will atomically deploy a fresh `VibesCommunityRewards` contract bound
     *         to the new token, transfer the slice to it, and clear the authorization
     *         (one-shot). No pre-existing recipient contract is needed.
     * @dev Admin-only. Community allocation is capped at MAX_COMMUNITY_ALLOCATION_BPS (20%).
     *      The combined allocation math at launch time enforces the MIN_BACKER_ALLOCATION_BPS
     *      (50%) floor — if `founder + treasury + ecosystem + LP + community` would leave
     *      backers below 50%, the launch reverts. This guarantees community rewards come out
     *      of founder/treasury/ecosystem headroom, never out of the backer slice.
     *
     *      Pass `bps = 0` (and any values for `cliffDuration` / `communityAdmin`) to revoke a
     *      prior authorization without a launch consuming it.
     * @param launcher Launcher wallet authorized to consume this config.
     * @param bps Community allocation in BPS (0 to MAX_COMMUNITY_ALLOCATION_BPS).
     * @param cliffDuration Seconds from the launch timestamp until the Community Rewards
     *        contract's tokens become available for batch distribution. Ignored when `bps = 0`.
     * @param communityAdmin Admin of the newly-deployed `VibesCommunityRewards` contract.
     *        This address controls batch creation post-cliff. Typically a multisig. Ignored
     *        when `bps = 0`.
     */
    function setCommunityAllocationForLaunch(
        address launcher,
        uint256 bps,
        uint256 cliffDuration,
        address communityAdmin
    ) external onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        if (bps > MAX_COMMUNITY_ALLOCATION_BPS) revert InvalidAllocation();
        if (bps > 0) {
            if (communityAdmin == address(0)) revert ZeroAddress();
            if (cliffDuration == 0) revert InvalidAllocation();
        }

        communityConfigForLaunch[launcher] = LaunchCommunityConfig({
            bps: bps,
            cliffDuration: cliffDuration,
            communityAdmin: communityAdmin
        });
        emit CommunityAllocationSet(launcher, bps, cliffDuration, communityAdmin);
    }

    /**
     * @notice Set the founder deposit amount
     * @param _amount New deposit amount in wei
     */
    function setFounderDepositWei(uint256 _amount) external onlyOwner {
        founderDepositWei = _amount;
    }

    /**
     * @notice Enable/disable testnet-accelerated timings for vesting and treasury contracts
     * @param _useTestnet true for testnet (accelerated), false for mainnet (production)
     * @dev Guarded against Base mainnet (chain ID 8453) — nuclear risk if toggled on production.
     */
    function setUseTestnetContracts(bool _useTestnet) external onlyOwner {
        require(block.chainid != 8453, "Cannot change on Base mainnet");
        useTestnetContracts = _useTestnet;
    }

    /**
     * @notice Set or revoke the operations admin (day-to-day challenge resolution)
     * @param _admin New operations admin address (address(0) disables — falls back to owner)
     * @dev Operations admin is passed to new escrows and treasuries at creation time.
     *      They handle challenge resolution, campaign freezes, and merkle roots.
     *      They CANNOT call any owner function (rescue, pause, infrastructure changes).
     *      Owner can revoke at any time by calling setOperationsAdmin(newAddress).
     */
    function setOperationsAdmin(address _admin) external onlyOwner {
        address old = operationsAdmin;
        operationsAdmin = _admin;
        emit OperationsAdminUpdated(old, _admin);
    }

    /**
     * @notice Set the trusted signer for launch authorization
     * @param _newSigner New signer address (address(0) disables gating)
     */
    function setTrustedLaunchSigner(address _newSigner) external onlyOwner {
        address oldSigner = trustedLaunchSigner;
        trustedLaunchSigner = _newSigner;
        emit TrustedLaunchSignerUpdated(oldSigner, _newSigner);
    }

    /**
     * @notice Set the $VIBES token address for burn-to-launch
     * @param _vibesToken Address of the $VIBES token (address(0) disables burn)
     */
    function setVibesToken(address _vibesToken) external onlyOwner {
        address oldToken = address(vibesToken);
        vibesToken = IERC20(_vibesToken);
        emit VibesTokenUpdated(oldToken, _vibesToken);
    }

    /**
     * @notice Set the amount of $VIBES burned per launch
     * @param _amount Amount to burn (0 disables burn even if vibesToken is set)
     */
    function setLaunchBurnAmount(uint256 _amount) external onlyOwner {
        uint256 oldAmount = launchBurnAmount;
        launchBurnAmount = _amount;
        emit LaunchBurnAmountUpdated(oldAmount, _amount);
    }

    // ============================================
    // ADMIN: DEPOSITS
    // ============================================

    /**
     * @notice Refund deposit to founder (success or cancelled raise)
     * @param token Token address to identify the deposit
     * @param founder Address to receive the refund
     */
    function refundDeposit(address token, address founder) external onlyOwner {
        uint256 depositAmount = tokenDeposits[token];
        if (depositAmount == 0) revert NoDepositToRefund();

        // Clear the deposit record and update reserved tracking
        delete tokenDeposits[token];
        totalReservedDeposits -= depositAmount;

        // Transfer deposit back to founder
        (bool sent, ) = founder.call{value: depositAmount}("");
        if (!sent) revert RefundFailed();

        emit DepositRefunded(founder, token, depositAmount);
    }

    /**
     * @notice Forfeit deposit (spam/fraud removal)
     * @param token Token address to identify the deposit
     * @param founder Original founder address (for event)
     */
    function forfeitDeposit(address token, address founder) external onlyOwner {
        uint256 depositAmount = tokenDeposits[token];
        if (depositAmount == 0) revert NoDepositToRefund();

        // Clear the deposit record and update reserved tracking
        delete tokenDeposits[token];
        totalReservedDeposits -= depositAmount;

        // Transfer forfeited deposit to fee recipient (platform)
        (bool sent, ) = feeRecipient.call{value: depositAmount}("");
        if (!sent) revert RefundFailed();

        emit DepositForfeited(founder, token, depositAmount);
    }

    // ============================================
    // RESCUE
    // ============================================

    /// @notice Rescue accidentally sent ETH from the router
    /// @dev Audit fix: prevents draining ETH reserved for founder deposits
    /// @param to Recipient address
    /// @param amount Amount of ETH to rescue
    function rescueETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        // Only allow rescuing ETH not reserved for founder deposits
        uint256 totalBalance = address(this).balance;
        uint256 available = totalBalance > totalReservedDeposits ? totalBalance - totalReservedDeposits : 0;
        require(amount <= available, "Would drain reserved deposits");

        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
        emit ETHRescued(to, amount);
    }

    /// @notice Rescue accidentally sent ERC20 tokens (L9 fix + audit fix F2)
    /// @dev Only rescues tokens not associated with active campaigns.
    ///      Blocks rescue for any token with: pending backer claims, an active escrow,
    ///      or pending LP allocation — preventing accidental drain of campaign reserves.
    ///      Exception: tokens whose escrow is Failed, Frozen, or Refunding are considered
    ///      dead — those tokens will never be distributed, so rescue is safe.
    /// @param tokenAddr ERC20 token address
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (tokenAddr == address(0)) revert ZeroAddress();
        // Prevent rescuing tokens that have pending claims
        if (backerTokensForClaims[tokenAddr] > 0) revert TokenHasActiveClaims();
        // Prevent rescuing tokens tied to an active campaign escrow (audit fix F2)
        // Exception: allow rescue for dead escrows (Failed/Frozen/Refunding)
        address escrowAddr = tokenToEscrow[tokenAddr];
        if (escrowAddr != address(0)) {
            VibesTranchEscrow.CampaignState state = VibesTranchEscrow(payable(escrowAddr)).getCampaign().state;
            if (state != VibesTranchEscrow.CampaignState.Failed &&
                state != VibesTranchEscrow.CampaignState.Frozen &&
                state != VibesTranchEscrow.CampaignState.Refunding) {
                revert TokenHasActiveEscrow();
            }
        }
        // Prevent rescuing tokens with pending LP allocation (audit fix F2)
        // Audit fix F8: Removed escrowAddr==0 condition — tokens with dead escrows AND pending LP
        // should also be blocked to prevent rescuing LP-designated tokens
        if (pendingLP[tokenAddr].tokenAmount > 0) revert TokenHasPendingLP();
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit ERC20Rescued(tokenAddr, to, amount);
    }
}
