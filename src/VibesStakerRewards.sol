// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VibesStakerRewards
 * @notice Manages reward distributions for $VIBES stakers from platform raises
 * @dev For each raise that finalizes successfully, 2% of the vibetoken is allocated to stakers.
 *      A Merkle root is set per raise (off-chain snapshot at finalization time).
 *      Stakers can claim their proportional share using Merkle proofs.
 *      No expiry - rewards remain claimable forever.
 *
 *      Merkle leaf structure: keccak256(abi.encodePacked(staker, tokenAmount))
 */
contract VibesStakerRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a rewards root is set for a raise
    /// @param escrow The escrow contract address (unique identifier for the raise)
    /// @param token The vibetoken being distributed
    /// @param merkleRoot Root of the Merkle tree
    /// @param totalTokens Total tokens allocated to stakers (2% of supply)
    event RewardsRootSet(
        address indexed escrow,
        address indexed token,
        bytes32 merkleRoot,
        uint256 totalTokens
    );

    /// @notice Emitted when a staker claims rewards for a raise
    /// @param staker Address of the claimant
    /// @param escrow The escrow contract address
    /// @param token The vibetoken claimed
    /// @param amount Amount of tokens claimed
    event RewardClaimed(
        address indexed staker,
        address indexed escrow,
        address indexed token,
        uint256 amount
    );

    // ============================================
    // STRUCTS
    // ============================================

    /// @notice Reward data for a single raise
    struct RaiseRewards {
        address token;          // The vibetoken address
        bytes32 merkleRoot;     // Merkle root for claims
        uint256 totalTokens;    // Total tokens allocated (2%)
        uint256 claimedTokens;  // Tokens claimed so far
        bool rootSet;           // Whether the root has been set
    }

    /// @notice Data for batch claiming
    struct ClaimData {
        address escrow;         // Escrow address identifying the raise
        uint256 amount;         // Token amount to claim
        bytes32[] proof;        // Merkle proof
    }

    // ============================================
    // STATE
    // ============================================

    /// @notice Admin address (can set merkle roots)
    address public admin;

    /// @notice Pending admin for two-step transfer
    address public pendingAdmin;

    /// @notice Rewards data per raise (escrow address => rewards)
    mapping(address => RaiseRewards) public raiseRewards;

    /// @notice Track claimed status per raise per staker (escrow => staker => claimed)
    mapping(address => mapping(address => bool)) public hasClaimed;

    /// @notice List of all escrows with rewards (for enumeration)
    address[] public rewardedEscrows;

    // ============================================
    // ERRORS
    // ============================================

    error OnlyAdmin();
    error ZeroAddress();
    error RootAlreadySet();
    error RootNotSet();
    error AlreadyClaimed();
    error InvalidProof();
    error InvalidAmount();
    error NoRewardsToClaim();

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Initialize the rewards contract
    /// @param _admin Admin address that can set merkle roots
    constructor(address _admin) {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Set the Merkle root for a raise's staker rewards
     * @dev Called by backend after raise finalization and snapshot generation.
     *      Tokens must be transferred to this contract before or after this call.
     * @param escrow Escrow contract address (unique identifier for the raise)
     * @param token Vibetoken address
     * @param merkleRoot Merkle root of (staker, amount) leaves
     * @param totalTokens Total tokens allocated to stakers
     */
    function setRewardsRoot(
        address escrow,
        address token,
        bytes32 merkleRoot,
        uint256 totalTokens
    ) external onlyAdmin {
        if (escrow == address(0)) revert ZeroAddress();
        if (token == address(0)) revert ZeroAddress();
        if (merkleRoot == bytes32(0)) revert ZeroAddress();
        if (raiseRewards[escrow].rootSet) revert RootAlreadySet();

        raiseRewards[escrow] = RaiseRewards({
            token: token,
            merkleRoot: merkleRoot,
            totalTokens: totalTokens,
            claimedTokens: 0,
            rootSet: true
        });

        rewardedEscrows.push(escrow);

        emit RewardsRootSet(escrow, token, merkleRoot, totalTokens);
    }

    /**
     * @notice Transfer admin role (two-step process)
     * @param newAdmin New admin address
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin;
    }

    /**
     * @notice Accept admin role
     */
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert OnlyAdmin();
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    // ============================================
    // CLAIM FUNCTIONS
    // ============================================

    /**
     * @notice Claim staker rewards for a single raise
     * @param escrow Escrow address identifying the raise
     * @param amount Amount of tokens allocated to caller
     * @param proof Merkle proof
     */
    function claim(
        address escrow,
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant {
        _claim(escrow, amount, proof);
    }

    /**
     * @notice Batch claim rewards across multiple raises
     * @param claims Array of claim data
     */
    function claimMultiple(ClaimData[] calldata claims) external nonReentrant {
        if (claims.length == 0) revert NoRewardsToClaim();

        for (uint256 i = 0; i < claims.length; i++) {
            // Skip if already claimed (don't revert, just continue)
            if (hasClaimed[claims[i].escrow][msg.sender]) continue;

            _claimInternal(claims[i].escrow, claims[i].amount, claims[i].proof);
        }
    }

    /**
     * @notice Internal claim logic
     */
    function _claim(
        address escrow,
        uint256 amount,
        bytes32[] calldata proof
    ) internal {
        if (hasClaimed[escrow][msg.sender]) revert AlreadyClaimed();
        _claimInternal(escrow, amount, proof);
    }

    /**
     * @notice Internal claim implementation (shared by single and batch)
     */
    function _claimInternal(
        address escrow,
        uint256 amount,
        bytes32[] calldata proof
    ) internal {
        RaiseRewards storage rewards = raiseRewards[escrow];

        if (!rewards.rootSet) revert RootNotSet();
        if (amount == 0) revert InvalidAmount();

        // Verify Merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        if (!MerkleProof.verify(proof, rewards.merkleRoot, leaf)) {
            revert InvalidProof();
        }

        // Mark as claimed
        hasClaimed[escrow][msg.sender] = true;
        rewards.claimedTokens += amount;

        // Transfer tokens
        IERC20(rewards.token).safeTransfer(msg.sender, amount);

        emit RewardClaimed(msg.sender, escrow, rewards.token, amount);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if a staker can claim for a specific raise
     * @param escrow Escrow address
     * @param staker Staker address
     * @param amount Expected amount
     * @param proof Merkle proof
     * @return canClaim True if claim would succeed
     */
    function canClaim(
        address escrow,
        address staker,
        uint256 amount,
        bytes32[] calldata proof
    ) external view returns (bool canClaim) {
        RaiseRewards storage rewards = raiseRewards[escrow];

        if (!rewards.rootSet) return false;
        if (hasClaimed[escrow][staker]) return false;
        if (amount == 0) return false;

        bytes32 leaf = keccak256(abi.encodePacked(staker, amount));
        return MerkleProof.verify(proof, rewards.merkleRoot, leaf);
    }

    /**
     * @notice Get rewards info for a raise
     * @param escrow Escrow address
     * @return token Vibetoken address
     * @return merkleRoot Merkle root
     * @return totalTokens Total allocated
     * @return claimedTokens Total claimed
     * @return rootSet Whether root is set
     */
    function getRewardsInfo(address escrow) external view returns (
        address token,
        bytes32 merkleRoot,
        uint256 totalTokens,
        uint256 claimedTokens,
        bool rootSet
    ) {
        RaiseRewards storage rewards = raiseRewards[escrow];
        return (
            rewards.token,
            rewards.merkleRoot,
            rewards.totalTokens,
            rewards.claimedTokens,
            rewards.rootSet
        );
    }

    /**
     * @notice Get number of raises with rewards
     * @return Count of rewarded raises
     */
    function getRewardedRaisesCount() external view returns (uint256) {
        return rewardedEscrows.length;
    }

    /**
     * @notice Get all escrows with rewards (paginated)
     * @param offset Start index
     * @param limit Max items to return
     * @return escrows Array of escrow addresses
     */
    function getRewardedEscrows(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory escrows) {
        uint256 total = rewardedEscrows.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        escrows = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            escrows[i - offset] = rewardedEscrows[i];
        }
    }

    /**
     * @notice Check claim status for multiple raises
     * @param staker Staker address
     * @param escrows Array of escrow addresses to check
     * @return claimed Array of claim statuses
     */
    function getClaimStatuses(
        address staker,
        address[] calldata escrows
    ) external view returns (bool[] memory claimed) {
        claimed = new bool[](escrows.length);
        for (uint256 i = 0; i < escrows.length; i++) {
            claimed[i] = hasClaimed[escrows[i]][staker];
        }
    }
}
