// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IAerodromeRouter.sol";
import "./VibesLPFeeClaimer.sol";

/// @title VibesLPLocker
/// @notice Creates Aerodrome LP positions and routes them to a per-campaign
///         VibesLPFeeClaimer that holds the LP soulbound while streaming trading
///         fees to the platform (WETH side) and treasury-or-burn (project-token side).
/// @dev LP tokens are non-recoverable by design: the claimer has no transfer or
///      withdraw surface. From a lock-guarantee perspective this is equivalent to
///      the prior 0xdead sink, but it captures Aerodrome trading fees that would
///      otherwise accrue to dead unclaimably.
contract VibesLPLocker is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Clones for address;

    // ============ Constants ============

    /// @notice Dead address — retained for manual-lock fallback semantics only.
    /// @dev New locks are routed to a cloned VibesLPFeeClaimer, not here.
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Aerodrome Router on Base
    /// @dev Mainnet: 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43
    address public immutable aerodromeRouter;

    /// @notice Aerodrome Factory on Base
    /// @dev Mainnet: 0x420DD381b31aEf6683db6B902084cB0FFECe40Da
    address public immutable aerodromeFactory;

    // ============ Structs ============

    struct LockedLP {
        address token;           // Project token
        address pool;            // Aerodrome pool address
        uint256 tokenAmount;     // Tokens added to LP
        uint256 ethAmount;       // ETH added to LP
        uint256 lpAmount;        // LP tokens minted (now locked)
        uint256 timestamp;       // When LP was created
        address campaign;        // Associated campaign escrow
    }

    // ============ Structs (Rescue) ============

    struct RescueFunds {
        address token;           // Project token held in rescue
        uint256 tokenAmount;     // Tokens held for manual LP resolution
        uint256 ethAmount;       // ETH held for manual LP resolution
        address campaign;        // Associated campaign escrow
        bool resolved;           // Whether admin has resolved this
    }

    // ============ State ============

    /// @notice Contract owner (deployer)
    address public owner;

    /// @notice Pending owner for two-step transfer (L4 fix)
    address public pendingOwner;

    /// @notice Authorized launch router that can call createAndLockLP
    address public authorizedRouter;

    /// @notice All locked LP positions
    LockedLP[] public lockedPositions;

    /// @notice Mapping from campaign to position index
    mapping(address => uint256) public campaignToPosition;

    /// @notice Whether a campaign has locked LP (true locked position exists in lockedPositions)
    mapping(address => bool) public hasLockedLP;

    /// @notice Rescue funds for campaigns where LP creation failed
    mapping(address => RescueFunds) public rescuedFunds;

    /// @notice Whether a campaign has rescued (failed LP) funds pending admin resolution
    mapping(address => bool) public hasRescuedFunds;

    /// @notice Audit fix F7: Whether LP was rescued (not truly locked) — separate from hasLockedLP
    /// @dev In rescue scenarios, hasLockedLP was incorrectly set true without a real position.
    ///      This flag distinguishes rescued campaigns from truly locked ones for view functions.
    mapping(address => bool) public hasRescuedLP;

    /// @notice VibesLPFeeClaimer implementation used for EIP-1167 cloning.
    /// @dev Set by owner after deployment via setFeeClaimerImplementation.
    address public feeClaimerImplementation;

    /// @notice Per-campaign fee claimer address (the permanent LP holder).
    /// @dev Set on successful auto-lock and on recordManualLPLock.
    mapping(address => address) public campaignToFeeClaimer;

    // ============ Events ============

    event LPCreatedAndLocked(
        address indexed token,
        address indexed pool,
        address indexed campaign,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 lpAmount
    );

    event LPCreationRescued(
        address indexed token,
        address indexed campaign,
        uint256 tokenAmount,
        uint256 ethAmount
    );

    event RescuedFundsResolved(
        address indexed campaign,
        address indexed resolvedBy
    );

    /// @notice Audit fix H-4: onchain record of a manually-created LP lock after rescue
    ///         resolution. Verifiable via the `pool` balance at the claimer (or DEAD_ADDRESS
    ///         for legacy burn-path locks).
    event ManualLPLockRecorded(
        address indexed campaign,
        address indexed pool,
        uint256 lpAmount,
        address indexed recordedBy
    );

    event FeeClaimerImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    event FeeClaimerDeployed(
        address indexed campaign,
        address indexed claimer,
        address indexed pool
    );

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientTokenBalance();
    error InsufficientETH();
    error LPCreationFailed();
    error AlreadyLocked();
    error OnlyOwner();
    error OnlyRouter();
    error NoRescuedFunds();
    error AlreadyResolved();
    // Audit fix H-4
    error RescueNotResolved();
    error InvalidPool();
    error InvalidLPAmount();
    error InvalidLPProof();
    error FeeClaimerImplementationNotSet();
    error InvalidFeeClaimer();

    // ============ Modifiers ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyRouter() {
        if (msg.sender != authorizedRouter) revert OnlyRouter();
        _;
    }

    // ============ Constructor ============

    /// @param _router Aerodrome Router address
    /// @param _factory Aerodrome Factory address
    constructor(address _router, address _factory) {
        if (_router == address(0)) revert ZeroAddress();
        if (_factory == address(0)) revert ZeroAddress();
        aerodromeRouter = _router;
        aerodromeFactory = _factory;
        owner = msg.sender;
    }

    // ============ Main Functions ============

    /// @notice Create LP position and route it to a per-campaign fee claimer (soulbound).
    /// @dev If LP creation fails (e.g., MEV front-running skewed the pool), funds are rescued
    ///      rather than reverting, so finalize() can still complete. The successful path
    ///      deploys a VibesLPFeeClaimer clone, transfers LP to it, and the claimer streams
    ///      Aerodrome trading fees to the platform / treasury-or-burn thereafter.
    /// @param _token Project token address
    /// @param _tokenAmount Amount of tokens for LP
    /// @param _campaign Associated campaign escrow address
    /// @param _platformFeeRecipient WETH-side fee destination (immutable on the claimer)
    /// @param _treasuryEscrow Project-token-side fee destination; address(0) = burn
    /// @return pool The Aerodrome pool address (address(0) if rescued)
    /// @return lpAmount Amount of LP tokens locked (0 if rescued)
    function createAndLockLP(
        address _token,
        uint256 _tokenAmount,
        address _campaign,
        address _platformFeeRecipient,
        address _treasuryEscrow
    ) external payable nonReentrant onlyRouter returns (address pool, uint256 lpAmount) {
        if (_token == address(0)) revert ZeroAddress();
        if (_tokenAmount == 0) revert ZeroAmount();
        if (msg.value == 0) revert InsufficientETH();
        if (_platformFeeRecipient == address(0)) revert ZeroAddress();
        if (feeClaimerImplementation == address(0)) revert FeeClaimerImplementationNotSet();
        if (hasLockedLP[_campaign]) revert AlreadyLocked();
        if (hasRescuedLP[_campaign]) revert AlreadyLocked(); // Audit fix F7: prevent double rescue

        // Transfer tokens from caller
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _tokenAmount);

        // Approve router to spend tokens (Audit fix L-4: use SafeERC20 forceApprove
        // so non-compliant ERC20s that require approve-to-zero are tolerated.)
        IERC20(_token).forceApprove(aerodromeRouter, _tokenAmount);

        IAerodromeRouter router = IAerodromeRouter(aerodromeRouter);

        // Add liquidity (volatile pool - not stable)
        // Using 0.5% slippage tolerance (audit fix M-04: tightened from 1%)
        uint256 minTokens = (_tokenAmount * 995) / 1000;
        uint256 minETH = (msg.value * 995) / 1000;

        uint256 actualTokens;
        uint256 actualETH;

        // Wrap in try/catch: if LP creation fails (e.g., pool was front-run with skewed ratio),
        // rescue the funds instead of reverting the entire finalize() flow.
        try router.addLiquidityETH{value: msg.value}(
            _token,
            false, // volatile pool
            _tokenAmount,
            minTokens,
            minETH,
            address(this), // LP tokens come to this contract first
            block.timestamp + 300 // 5 min deadline
        ) returns (uint256 _actualTokens, uint256 _actualETH, uint256 _lpAmount) {
            actualTokens = _actualTokens;
            actualETH = _actualETH;
            lpAmount = _lpAmount;
        } catch {
            // LP creation failed — rescue funds for admin to resolve manually.
            // Revoke router approval since we're keeping the tokens (L-4: forceApprove).
            IERC20(_token).forceApprove(aerodromeRouter, 0);

            rescuedFunds[_campaign] = RescueFunds({
                token: _token,
                tokenAmount: _tokenAmount,
                ethAmount: msg.value,
                campaign: _campaign,
                resolved: false
            });
            hasRescuedFunds[_campaign] = true;

            // Audit fix F7: Mark as rescued (NOT locked) so view functions don't return wrong data.
            // hasLockedLP stays false for rescued campaigns — only set true for real LP locks.
            hasRescuedLP[_campaign] = true;

            emit LPCreationRescued(_token, _campaign, _tokenAmount, msg.value);
            return (address(0), 0);
        }

        if (lpAmount == 0) {
            // Zero LP from a non-reverting call — also rescue (L-4: forceApprove)
            IERC20(_token).forceApprove(aerodromeRouter, 0);

            rescuedFunds[_campaign] = RescueFunds({
                token: _token,
                tokenAmount: _tokenAmount,
                ethAmount: msg.value,
                campaign: _campaign,
                resolved: false
            });
            hasRescuedFunds[_campaign] = true;
            // Audit fix F7: Mark as rescued, not locked
            hasRescuedLP[_campaign] = true;

            emit LPCreationRescued(_token, _campaign, _tokenAmount, msg.value);
            return (address(0), 0);
        }

        // Get pool address
        address weth = router.weth();
        pool = router.poolFor(_token, weth, false, aerodromeFactory);

        // Deploy per-campaign fee claimer (EIP-1167 clone) and soulbind LP to it.
        // From here on, the claimer captures Aerodrome trading fees permissionlessly;
        // it has no transfer/withdraw surface, so the LP is as locked as DEAD_ADDRESS.
        address claimer = feeClaimerImplementation.clone();
        VibesLPFeeClaimer(claimer).initialize(
            pool,
            _campaign,
            _token,
            _platformFeeRecipient,
            _treasuryEscrow
        );
        campaignToFeeClaimer[_campaign] = claimer;
        emit FeeClaimerDeployed(_campaign, claimer, pool);

        IERC20(pool).safeTransfer(claimer, lpAmount);

        // Record the locked position
        uint256 positionIndex = lockedPositions.length;
        lockedPositions.push(LockedLP({
            token: _token,
            pool: pool,
            tokenAmount: actualTokens,
            ethAmount: actualETH,
            lpAmount: lpAmount,
            timestamp: block.timestamp,
            campaign: _campaign
        }));

        campaignToPosition[_campaign] = positionIndex;
        hasLockedLP[_campaign] = true;

        // Refund any excess ETH
        if (msg.value > actualETH) {
            (bool success, ) = msg.sender.call{value: msg.value - actualETH}("");
            require(success, "ETH refund failed");
        }

        // Refund any excess tokens
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        if (tokenBalance > 0) {
            IERC20(_token).safeTransfer(msg.sender, tokenBalance);
        }

        emit LPCreatedAndLocked(_token, pool, _campaign, actualTokens, actualETH, lpAmount);
    }

    // ============ Admin Functions ============

    /// @notice Resolve rescued funds after a failed LP creation
    /// @dev Admin can withdraw rescued ETH + tokens to a specified address for manual LP creation
    /// @param _campaign Campaign with rescued funds
    /// @param _to Address to send the rescued funds to (e.g., admin multisig for manual LP)
    function resolveRescuedFunds(address _campaign, address _to) external onlyOwner nonReentrant {
        if (!hasRescuedFunds[_campaign]) revert NoRescuedFunds();
        RescueFunds storage rescue = rescuedFunds[_campaign];
        if (rescue.resolved) revert AlreadyResolved();
        if (_to == address(0)) revert ZeroAddress();

        rescue.resolved = true;

        // Transfer rescued tokens
        if (rescue.tokenAmount > 0) {
            IERC20(rescue.token).safeTransfer(_to, rescue.tokenAmount);
        }

        // Transfer rescued ETH
        if (rescue.ethAmount > 0) {
            (bool success, ) = _to.call{value: rescue.ethAmount}("");
            require(success, "ETH transfer failed");
        }

        emit RescuedFundsResolved(_campaign, msg.sender);
    }

    /// @notice Audit fix H-4: Record a manually-created LP lock for a rescued campaign.
    /// @dev After `resolveRescuedFunds()` pays rescued ETH + tokens to the owner, the owner
    ///      creates LP off-chain and either (a) burns it to DEAD_ADDRESS or (b) sends it to
    ///      a pre-deployed VibesLPFeeClaimer so fees are captured. They then call this
    ///      function to record the lock on-chain — the ONLY path to transition a campaign
    ///      out of the rescued-LP state so that `verifyLPLocked()` and
    ///      `VibesRouterExtension.completeLP()` can unblock tranche claims.
    ///
    ///      Security model:
    ///      - Only the owner can call (operational control).
    ///      - Campaign must have previously been rescued (`hasRescuedLP == true`) AND the rescue
    ///        must be resolved (funds paid out) — guarantees we're not front-running a pending
    ///        rescue payout.
    ///      - `_pool` must be a real deployed contract (code.length > 0).
    ///      - `_lpAmount` must be non-zero.
    ///      - If `_feeClaimer` is non-zero, it must be a contract whose `pool()` matches _pool
    ///        and whose `campaign()` matches _campaign — prevents pointing at an unrelated claimer.
    ///      - HARD onchain proof: the pool's balanceOf(holder) must be >= _lpAmount at call
    ///        time, where holder = _feeClaimer if provided, else DEAD_ADDRESS. An owner who
    ///        did NOT actually park LP at the claimed holder cannot satisfy this.
    /// @param _campaign Campaign escrow address whose rescue is being finalized.
    /// @param _pool The AMM pool contract address where LP tokens were minted.
    /// @param _feeClaimer Pre-deployed claimer holding the LP, or address(0) to register a burn.
    /// @param _lpAmount The LP token amount the admin claims to have parked at the holder.
    function recordManualLPLock(
        address _campaign,
        address _pool,
        address _feeClaimer,
        uint256 _lpAmount
    ) external onlyOwner nonReentrant {
        if (_campaign == address(0)) revert ZeroAddress();
        if (!hasRescuedLP[_campaign]) revert NoRescuedFunds();
        if (hasLockedLP[_campaign]) revert AlreadyLocked();

        RescueFunds storage rescue = rescuedFunds[_campaign];
        if (!rescue.resolved) revert RescueNotResolved();

        if (_pool == address(0) || _pool.code.length == 0) revert InvalidPool();
        if (_lpAmount == 0) revert InvalidLPAmount();

        // Resolve the holder whose balance we'll prove. A claimer must be wired correctly
        // for this campaign+pool; otherwise reject rather than let fees leak to the wrong place.
        address holder;
        if (_feeClaimer == address(0)) {
            holder = DEAD_ADDRESS;
        } else {
            if (_feeClaimer.code.length == 0) revert InvalidFeeClaimer();
            if (VibesLPFeeClaimer(_feeClaimer).pool() != _pool) revert InvalidFeeClaimer();
            if (VibesLPFeeClaimer(_feeClaimer).campaign() != _campaign) revert InvalidFeeClaimer();
            holder = _feeClaimer;
            campaignToFeeClaimer[_campaign] = _feeClaimer;
        }

        // HARD onchain proof: LP tokens must actually be held at the claimed holder.
        uint256 heldBalance = IERC20(_pool).balanceOf(holder);
        if (heldBalance < _lpAmount) revert InvalidLPProof();

        // Flip state: out of rescued, into locked. `completeLP()` on the router can now pass.
        hasRescuedLP[_campaign] = false;
        hasLockedLP[_campaign] = true;

        uint256 positionIndex = lockedPositions.length;
        lockedPositions.push(LockedLP({
            token: rescue.token,
            pool: _pool,
            tokenAmount: rescue.tokenAmount,
            ethAmount: rescue.ethAmount,
            lpAmount: _lpAmount,
            timestamp: block.timestamp,
            campaign: _campaign
        }));
        campaignToPosition[_campaign] = positionIndex;

        emit ManualLPLockRecorded(_campaign, _pool, _lpAmount, msg.sender);
    }

    /// @notice Set or rotate the VibesLPFeeClaimer implementation used for cloning.
    /// @dev Only affects FUTURE locks. Existing claimers are immutable once deployed.
    function setFeeClaimerImplementation(address _impl) external onlyOwner {
        if (_impl == address(0)) revert ZeroAddress();
        if (_impl.code.length == 0) revert InvalidFeeClaimer();
        address old = feeClaimerImplementation;
        feeClaimerImplementation = _impl;
        emit FeeClaimerImplementationUpdated(old, _impl);
    }

    /// @notice Update the authorized router address
    /// @param _router New authorized router address
    function setAuthorizedRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        authorizedRouter = _router;
    }

    /// @notice L4 fix: two-step ownership transfer (step 1: propose)
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
    }

    /// @notice L4 fix: two-step ownership transfer (step 2: accept)
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ============ View Functions ============

    /// @notice Get total number of locked positions
    function totalLockedPositions() external view returns (uint256) {
        return lockedPositions.length;
    }

    /// @notice Get locked position details for a campaign
    /// @notice Audit fix F7: Guard against rescued campaigns returning wrong position data
    function getLockedPosition(address _campaign) external view returns (LockedLP memory) {
        require(hasLockedLP[_campaign] && !hasRescuedLP[_campaign], "No locked LP for campaign");
        return lockedPositions[campaignToPosition[_campaign]];
    }

    /// @notice Get all locked positions
    function getAllLockedPositions() external view returns (LockedLP[] memory) {
        return lockedPositions;
    }

    /// @notice Verify LP is truly locked by checking the soulbound holder's balance.
    /// @dev Audit fix F7: Returns false for rescued campaigns instead of reading wrong position.
    ///      Checks the per-campaign fee claimer first (new path). If no claimer is set
    ///      (manual-lock recorded against DEAD_ADDRESS), falls back to reading dead's balance.
    function verifyLPLocked(address _campaign) external view returns (bool, uint256) {
        if (!hasLockedLP[_campaign] || hasRescuedLP[_campaign]) return (false, 0);

        LockedLP memory position = lockedPositions[campaignToPosition[_campaign]];
        address holder = campaignToFeeClaimer[_campaign];
        if (holder == address(0)) holder = DEAD_ADDRESS;
        uint256 heldBalance = IERC20(position.pool).balanceOf(holder);

        return (heldBalance >= position.lpAmount, heldBalance);
    }

    /// @notice Calculate expected LP price based on locked amounts
    /// @param _campaign Campaign address
    /// @return priceInETH Price of 1 token in ETH (18 decimals)
    function getInitialPrice(address _campaign) external view returns (uint256 priceInETH) {
        require(hasLockedLP[_campaign] && !hasRescuedLP[_campaign], "No locked LP");
        LockedLP memory position = lockedPositions[campaignToPosition[_campaign]];

        // Price = ETH / Tokens (both in wei, result in 18 decimals)
        // To avoid precision loss: (ethAmount * 1e18) / tokenAmount
        if (position.tokenAmount > 0) {
            priceInETH = (position.ethAmount * 1e18) / position.tokenAmount;
        }
    }

    /// @notice Get rescued funds details for a campaign
    function getRescuedFunds(address _campaign) external view returns (RescueFunds memory) {
        require(hasRescuedFunds[_campaign], "No rescued funds for campaign");
        return rescuedFunds[_campaign];
    }

    // ============ Receive ============

    receive() external payable {}
}
