// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VibesCommunityRewards
 * @notice Timelocked, multi-batch merkle distributor for the $VIBES community-rewards slice.
 * @dev Receives the 20% community-rewards allocation at the $VIBES raise finalisation (delivered
 *      via the router's standard merkle claim; this contract's address is one of the merkle leaves).
 *      Enforces a cliff: no tokens can leave before `unlockTime`. Post-cliff, admin creates
 *      distribution batches by committing a merkle root and a total amount; recipients claim via
 *      proof. Admin may rescue unclaimed tokens from a batch after its claim window closes, to
 *      recycle them into future batches.
 *
 *      Distribution criteria and recipient lists are intentionally not published on-chain in
 *      pre-computed form — the merkle root commits to the distribution without revealing
 *      recipients. Leaves are disclosed to individual recipients off-chain at the point of claim.
 *
 *      Designed for flexibility: single-purpose airdrops, hackathon prize drops, grant payouts,
 *      and repeating distributions all use the same batch mechanism.
 */
contract VibesCommunityRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // IMMUTABLES
    // ============================================

    /// @notice The token being distributed ($VIBES)
    IERC20 public immutable token;

    /// @notice Timestamp before which no tokens can be released (cliff)
    uint256 public immutable unlockTime;

    // ============================================
    // STATE
    // ============================================

    /// @notice Admin address (expected: Community Rewards multisig)
    address public admin;

    /// @notice Pending admin for two-step ownership transfer
    address public pendingAdmin;

    /// @notice Emergency pause — halts all claims and new batches when true
    bool public paused;

    /// @notice Distribution batches created by admin post-cliff
    Batch[] public batches;

    /// @notice claimed[batchId][recipient] = true once the recipient has claimed in that batch
    mapping(uint256 => mapping(address => bool)) public claimed;

    // ============================================
    // STRUCTS
    // ============================================

    struct Batch {
        bytes32 merkleRoot;      // commitment to (recipient, amount) leaves
        uint256 totalAmount;     // total tokens earmarked for this batch (admin-declared, for accounting)
        uint256 claimedAmount;   // running tally of tokens released from this batch
        uint256 startTime;       // when the batch was created
        uint256 rescueAfter;     // earliest timestamp admin may rescue unclaimed (0 = never)
        bool    rescued;         // true once admin has rescued remaining
        bytes32 metadataHash;    // optional: hash of off-chain metadata describing the batch
    }

    // ============================================
    // EVENTS
    // ============================================

    event BatchCreated(
        uint256 indexed batchId,
        bytes32 indexed merkleRoot,
        uint256 totalAmount,
        uint256 rescueAfter,
        bytes32 metadataHash
    );
    event Claimed(uint256 indexed batchId, address indexed recipient, uint256 amount);
    event BatchRescued(uint256 indexed batchId, address indexed to, uint256 amount);
    event PausedSet(bool paused);
    event AdminTransferInitiated(address indexed pending);
    event AdminTransferAccepted(address indexed previousAdmin, address indexed newAdmin);

    // ============================================
    // ERRORS
    // ============================================

    error ZeroAddress();
    error OnlyAdmin();
    error OnlyPendingAdmin();
    error BeforeCliff();
    error IsPaused();
    error InvalidProof();
    error AlreadyClaimed();
    error BatchRescuedErr();
    error UnknownBatch();
    error RescueWindowNotOpen();
    error RescueDisabled();
    error NothingToRescue();
    error InsufficientBatchBalance();
    error MetadataHashRequired();

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier afterCliff() {
        if (block.timestamp < unlockTime) revert BeforeCliff();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(IERC20 _token, uint256 _unlockTime, address _admin) {
        if (address(_token) == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        token = _token;
        unlockTime = _unlockTime;
        admin = _admin;
    }

    // ============================================
    // ADMIN: BATCH LIFECYCLE
    // ============================================

    /**
     * @notice Create a new distribution batch.
     * @dev Admin-only. May only be called after `unlockTime`. Contract must hold at least
     *      `totalAmount + (prior batches' unclaimed-and-not-yet-rescued)` at call time; otherwise
     *      reverts. This prevents the admin from committing to a distribution the contract
     *      cannot honour.
     * @param merkleRoot Commitment to the set of (recipient, amount) leaves.
     * @param totalAmount Total tokens this batch may disburse. Used for solvency check + accounting.
     * @param claimWindow Seconds from now during which recipients may claim. 0 = no rescue window
     *        (tokens locked in batch permanently until claimed).
     * @param metadataHash Hash of off-chain batch description (category, distribution policy,
     *        criteria, recipient-checker URL, etc.). **Required.** Emitted in `BatchCreated`
     *        as a permanent public commitment that the admin has produced an off-chain document
     *        describing this batch — the community can verify that the admin publishes content
     *        hashing to this value. If they don't, the event log is evidence of bad faith.
     *        Cannot be `bytes32(0)`.
     * @return batchId Index of the newly created batch.
     */
    function createBatch(
        bytes32 merkleRoot,
        uint256 totalAmount,
        uint256 claimWindow,
        bytes32 metadataHash
    ) external onlyAdmin afterCliff whenNotPaused returns (uint256 batchId) {
        // Metadata commitment is mandatory. Admin cannot distribute silently.
        if (metadataHash == bytes32(0)) revert MetadataHashRequired();

        // Solvency check: contract must hold enough to cover this batch plus any
        // outstanding unclaimed amounts from prior non-rescued batches.
        uint256 required = totalAmount + _outstandingUnclaimed();
        if (token.balanceOf(address(this)) < required) revert InsufficientBatchBalance();

        batchId = batches.length;
        uint256 rescueAt = claimWindow == 0 ? 0 : block.timestamp + claimWindow;

        batches.push(Batch({
            merkleRoot: merkleRoot,
            totalAmount: totalAmount,
            claimedAmount: 0,
            startTime: block.timestamp,
            rescueAfter: rescueAt,
            rescued: false,
            metadataHash: metadataHash
        }));

        emit BatchCreated(batchId, merkleRoot, totalAmount, rescueAt, metadataHash);
    }

    /**
     * @notice Rescue unclaimed tokens from a batch after its claim window closes.
     * @dev Admin-only. Batches created with `claimWindow == 0` cannot be rescued.
     *      Rescued tokens stay in the contract (not transferred out) and become available
     *      for future batches' solvency check — admin may then create a new batch to
     *      redistribute them. To move tokens OUT of this contract entirely, admin creates
     *      a batch whose only leaf is the admin multisig itself.
     * @param batchId Index of the batch to rescue.
     */
    function rescueBatch(uint256 batchId) external onlyAdmin {
        if (batchId >= batches.length) revert UnknownBatch();
        Batch storage b = batches[batchId];
        if (b.rescued) revert BatchRescuedErr();
        if (b.rescueAfter == 0) revert RescueDisabled();
        if (block.timestamp < b.rescueAfter) revert RescueWindowNotOpen();

        uint256 unclaimed = b.totalAmount - b.claimedAmount;
        if (unclaimed == 0) revert NothingToRescue();

        b.rescued = true;
        emit BatchRescued(batchId, address(this), unclaimed);
        // Tokens remain in the contract; the Batch is marked rescued so `_outstandingUnclaimed()`
        // no longer counts them. Admin may now create a new batch to redistribute.
    }

    // ============================================
    // ADMIN: CONTROL
    // ============================================

    /// @notice Emergency pause of all claims and batch creation (e.g., on discovery of a bad root).
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Step 1 of two-step admin transfer.
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferInitiated(newAdmin);
    }

    /// @notice Step 2 of two-step admin transfer — must be called by the pending admin.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert OnlyPendingAdmin();
        address previousAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferAccepted(previousAdmin, admin);
    }

    // ============================================
    // CLAIMS
    // ============================================

    /**
     * @notice Claim tokens from a batch using a merkle proof.
     * @dev Permissionless — anyone with a valid proof for `recipient` can trigger the claim;
     *      tokens always go to `recipient`, not to `msg.sender`. This lets relayers / claim
     *      UIs submit claims on recipients' behalf if desired.
     * @param batchId Index of the batch to claim from.
     * @param recipient Leaf recipient (tokens transfer here).
     * @param amount Leaf amount.
     * @param proof Merkle proof for (recipient, amount) against `batches[batchId].merkleRoot`.
     */
    function claim(
        uint256 batchId,
        address recipient,
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant afterCliff whenNotPaused {
        if (batchId >= batches.length) revert UnknownBatch();
        Batch storage b = batches[batchId];
        if (b.rescued) revert BatchRescuedErr();
        if (claimed[batchId][recipient]) revert AlreadyClaimed();

        // Double-hash leaf, matching the shared packages/shared/src/merkle.ts encoding.
        // abi.encodePacked is safe here because both arguments are fixed-size.
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(recipient, amount))));
        if (!MerkleProof.verify(proof, b.merkleRoot, leaf)) revert InvalidProof();

        // ZXVC VIB-10 (2026-05): hard cap claim-time aggregate to the declared batch total.
        // A malicious / sloppy operator could otherwise commit a merkle root whose leaf-sum
        // exceeds b.totalAmount and drain more than was deposited into the batch. The
        // per-recipient hasClaimed guard prevents double-claim per leaf, but does NOT bound
        // the aggregate; this require does.
        require(b.claimedAmount + amount <= b.totalAmount, "Exceeds batch total");

        claimed[batchId][recipient] = true;
        b.claimedAmount += amount;

        token.safeTransfer(recipient, amount);
        emit Claimed(batchId, recipient, amount);
    }

    // ============================================
    // VIEWS
    // ============================================

    /// @notice Number of batches created (next batch id).
    function batchCount() external view returns (uint256) {
        return batches.length;
    }

    /// @notice Is the cliff over?
    function isUnlocked() external view returns (bool) {
        return block.timestamp >= unlockTime;
    }

    /**
     * @notice Check if a specific (batchId, recipient, amount, proof) would successfully claim.
     * @dev View-only — does not consume the claim. Useful for UI pre-flighting.
     */
    function canClaim(
        uint256 batchId,
        address recipient,
        uint256 amount,
        bytes32[] calldata proof
    ) external view returns (bool) {
        if (paused) return false;
        if (block.timestamp < unlockTime) return false;
        if (batchId >= batches.length) return false;
        Batch storage b = batches[batchId];
        if (b.rescued) return false;
        if (claimed[batchId][recipient]) return false;
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(recipient, amount))));
        return MerkleProof.verify(proof, b.merkleRoot, leaf);
    }

    // ============================================
    // INTERNAL
    // ============================================

    /// @dev Sum of unclaimed-and-not-rescued amounts across all prior batches.
    function _outstandingUnclaimed() internal view returns (uint256 total) {
        uint256 len = batches.length;
        for (uint256 i = 0; i < len; i++) {
            Batch storage b = batches[i];
            if (!b.rescued) {
                total += b.totalAmount - b.claimedAmount;
            }
        }
    }
}
