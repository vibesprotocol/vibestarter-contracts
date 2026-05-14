// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VibesTokenDistributorV2
 * @notice Merkle-based token distribution with combined ETH refund support for Pro-Rata campaigns
 * @dev V2 Features:
 *      - Combined token + excess ETH claim in single transaction
 *      - Support for Pro-Rata oversubscription refunds
 *      - Efficient batch distribution
 */
contract VibesTokenDistributorV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // EVENTS
    // ============================================

    event DistributionReady(bytes32 indexed merkleRoot, uint256 totalTokens, uint256 totalEthRefunds);
    event TokensClaimed(address indexed backer, uint256 tokenAmount, uint256 ethRefund);
    event TokensRecovered(address indexed recipient, uint256 tokenAmount, uint256 ethAmount);
    event EthDeposited(uint256 amount);

    // ============================================
    // STATE
    // ============================================

    /// @notice The token being distributed
    IERC20 public immutable token;

    /// @notice The founder who controls distribution
    address public immutable founder;

    /// @notice The campaign escrow this distributor is tied to
    address public immutable campaign;

    /// @notice The ops wallet that receives unclaimed funds after sweep period
    address public immutable opsWallet;

    /// @notice The admin who can trigger sweeps
    address public immutable admin;

    /// @notice Timestamp when distribution was set (for sweep timing)
    uint256 public distributionSetTime;

    /// @notice Sweep waiting period (6 months)
    uint256 public constant SWEEP_DELAY = 180 days;

    /// @notice Merkle root for distribution (includes both token amount and ETH refund)
    bytes32 public merkleRoot;

    /// @notice Total tokens allocated for distribution
    uint256 public totalTokens;

    /// @notice Total ETH refunds for Pro-Rata excess
    uint256 public totalEthRefunds;

    /// @notice Whether distribution has been set
    bool public distributionSet;

    /// @notice Mapping of addresses that have claimed
    mapping(address => bool) public hasClaimed;

    /// @notice Total tokens claimed so far
    uint256 public totalTokensClaimed;

    /// @notice Total ETH refunds claimed so far
    uint256 public totalEthClaimed;

    /// @notice ETH owed to recipients from failed transfers during batchDistribute
    mapping(address => uint256) public pendingEthRefunds;

    /// @notice Total outstanding ETH refunds (H8 fix: track to protect from sweep)
    uint256 public totalPendingEthRefunds;

    // ============================================
    // ERRORS
    // ============================================

    error OnlyFounder();
    error OnlyAdmin();
    error ZeroAddress();
    error DistributionNotSet();
    error AlreadySet();
    error AlreadyClaimed();
    error InvalidProof();
    error InvalidAmount();
    error TransferFailed();
    error InsufficientEth();
    error SweepTooEarly();
    error NoPendingEth();

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(
        address _token,
        address _founder,
        address _campaign,
        address _opsWallet,
        address _admin
    ) {
        if (_token == address(0)) revert ZeroAddress();
        if (_founder == address(0)) revert ZeroAddress();
        if (_campaign == address(0)) revert ZeroAddress();
        if (_opsWallet == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        token = IERC20(_token);
        founder = _founder;
        campaign = _campaign;
        opsWallet = _opsWallet;
        admin = _admin;
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyFounder() {
        if (msg.sender != founder) revert OnlyFounder();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // ============================================
    // DISTRIBUTION SETUP
    // ============================================

    /**
     * @notice Set the merkle root for token + ETH distribution
     * @dev Merkle leaves are double-hashed: keccak256(abi.encodePacked(keccak256(abi.encodePacked(address, tokenAmount, ethRefund))))
     * @param _merkleRoot Merkle root of (address, tokenAmount, ethRefund) leaves
     * @param _totalTokens Total tokens to be distributed
     * @param _totalEthRefunds Total ETH refunds (for Pro-Rata excess)
     */
    function setDistributionRoot(
        bytes32 _merkleRoot,
        uint256 _totalTokens,
        uint256 _totalEthRefunds
    ) external onlyFounder {
        if (distributionSet) revert AlreadySet();
        if (_merkleRoot == bytes32(0)) revert ZeroAddress();

        merkleRoot = _merkleRoot;
        totalTokens = _totalTokens;
        totalEthRefunds = _totalEthRefunds;
        distributionSet = true;
        distributionSetTime = block.timestamp;

        emit DistributionReady(_merkleRoot, _totalTokens, _totalEthRefunds);
    }

    /**
     * @notice Deposit ETH for Pro-Rata refunds
     * @dev Anyone can deposit, but typically called by router/escrow
     */
    function depositEthForRefunds() external payable {
        emit EthDeposited(msg.value);
    }

    // ============================================
    // CLAIM FUNCTIONS
    // ============================================

    /**
     * @notice Claim allocated tokens and ETH refund in a single transaction
     * @param tokenAmount Amount of tokens allocated to caller
     * @param ethRefund Amount of ETH refund (0 if no Pro-Rata excess)
     * @param proof Merkle proof for the claim
     */
    function claim(
        uint256 tokenAmount,
        uint256 ethRefund,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (!distributionSet) revert DistributionNotSet();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();
        if (tokenAmount == 0 && ethRefund == 0) revert InvalidAmount();

        // Verify merkle proof (leaf includes both token amount and ETH refund)
        // Double-hash to prevent leaf-node collision with intermediate nodes
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(msg.sender, tokenAmount, ethRefund))));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        hasClaimed[msg.sender] = true;

        // ZXVC Extra-2 (2026-05): aggregate caps mirror VIB-10 for the legacy distributor.
        // The per-recipient hasClaimed guard prevents double-claim per leaf but does NOT
        // bound the aggregate, so a malicious / mis-built merkle root whose leaf-sum exceeds
        // the configured totals could drain more than was deposited. These requires bound
        // claims to the configured budget. This is defense-in-depth on a deprecated path
        // (router migration replaces this distributor for new raises).
        require(totalTokensClaimed + tokenAmount <= totalTokens, "Exceeds totalTokens");
        require(totalEthClaimed + ethRefund <= totalEthRefunds, "Exceeds totalEthRefunds");

        // Transfer tokens if any
        if (tokenAmount > 0) {
            totalTokensClaimed += tokenAmount;
            token.safeTransfer(msg.sender, tokenAmount);
        }

        // Transfer ETH refund if any
        if (ethRefund > 0) {
            if (address(this).balance < ethRefund) revert InsufficientEth();
            totalEthClaimed += ethRefund;
            (bool sent, ) = msg.sender.call{value: ethRefund}("");
            if (!sent) revert TransferFailed();
        }

        emit TokensClaimed(msg.sender, tokenAmount, ethRefund);
    }

    /**
     * @notice Batch distribute tokens + ETH (founder pays gas)
     * @dev Always marks recipient as claimed after tokens are sent. If ETH transfer fails,
     *      the owed ETH is tracked in pendingEthRefunds for the recipient to claim via claimPendingEth().
     * @param recipients Array of recipient addresses
     * @param tokenAmounts Array of token amounts
     * @param ethRefunds Array of ETH refund amounts
     * @param proofs Array of merkle proofs
     */
    function batchDistribute(
        address[] calldata recipients,
        uint256[] calldata tokenAmounts,
        uint256[] calldata ethRefunds,
        bytes32[][] calldata proofs
    ) external onlyFounder nonReentrant {
        if (!distributionSet) revert DistributionNotSet();
        if (recipients.length != tokenAmounts.length) revert InvalidAmount();
        if (recipients.length != ethRefunds.length) revert InvalidAmount();
        if (recipients.length != proofs.length) revert InvalidAmount();
        require(recipients.length <= 100, "Batch too large"); // Audit fix L-01

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 tokenAmount = tokenAmounts[i];
            uint256 ethRefund = ethRefunds[i];

            // Skip if already claimed or nothing to distribute
            if (hasClaimed[recipient]) continue;
            if (tokenAmount == 0 && ethRefund == 0) continue;

            // Verify merkle proof (double-hash)
            bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(recipient, tokenAmount, ethRefund))));
            if (!MerkleProof.verify(proofs[i], merkleRoot, leaf)) continue;

            // Always mark as claimed FIRST to prevent double-claim
            hasClaimed[recipient] = true;

            // Transfer tokens
            if (tokenAmount > 0) {
                totalTokensClaimed += tokenAmount;
                token.safeTransfer(recipient, tokenAmount);
            }

            // Transfer ETH refund
            uint256 actualEth = 0;
            if (ethRefund > 0 && address(this).balance >= ethRefund) {
                (bool sent, ) = recipient.call{value: ethRefund}("");
                if (sent) {
                    actualEth = ethRefund;
                    totalEthClaimed += ethRefund;
                } else {
                    // ETH transfer failed - track for pull-based claim
                    pendingEthRefunds[recipient] = ethRefund;
                    totalPendingEthRefunds += ethRefund;
                }
            } else if (ethRefund > 0) {
                // Insufficient ETH balance - track for pull-based claim
                pendingEthRefunds[recipient] = ethRefund;
                totalPendingEthRefunds += ethRefund;
            }

            emit TokensClaimed(recipient, tokenAmount, actualEth);
        }
    }

    /**
     * @notice Claim pending ETH refund from a failed batch distribution
     * @dev For recipients whose ETH transfer failed during batchDistribute
     */
    function claimPendingEth() external nonReentrant {
        uint256 owed = pendingEthRefunds[msg.sender];
        if (owed == 0) revert NoPendingEth();
        if (address(this).balance < owed) revert InsufficientEth();

        pendingEthRefunds[msg.sender] = 0;
        totalPendingEthRefunds -= owed;
        totalEthClaimed += owed;

        (bool sent, ) = msg.sender.call{value: owed}("");
        if (!sent) revert TransferFailed();

        emit TokensClaimed(msg.sender, 0, owed);
    }

    // ============================================
    // SWEEP FUNCTIONS
    // ============================================

    /**
     * @notice Sweep unclaimed tokens and ETH to ops wallet after 6 months
     * @dev Only admin can call. Requires 6 months after distribution was set.
     *      Unclaimed funds go to ops wallet, not founder.
     */
    function sweepUnclaimed() external onlyAdmin {
        if (!distributionSet) revert DistributionNotSet();
        if (block.timestamp < distributionSetTime + SWEEP_DELAY) revert SweepTooEarly();

        uint256 tokenRemaining = token.balanceOf(address(this));
        uint256 ethRemaining = address(this).balance;

        // H8 fix: protect pending ETH refunds from being swept
        uint256 sweepableEth = ethRemaining > totalPendingEthRefunds
            ? ethRemaining - totalPendingEthRefunds
            : 0;

        if (tokenRemaining > 0) {
            token.safeTransfer(opsWallet, tokenRemaining);
        }

        if (sweepableEth > 0) {
            (bool sent, ) = opsWallet.call{value: sweepableEth}("");
            if (!sent) revert TransferFailed();
        }

        emit TokensRecovered(opsWallet, tokenRemaining, sweepableEth);
    }

    /**
     * @notice Check when sweep becomes available
     * @return canSweep Whether sweep is currently available
     * @return sweepAvailableAt Timestamp when sweep becomes available
     */
    function getSweepStatus() external view returns (bool canSweep, uint256 sweepAvailableAt) {
        if (!distributionSet) {
            return (false, 0);
        }
        sweepAvailableAt = distributionSetTime + SWEEP_DELAY;
        canSweep = block.timestamp >= sweepAvailableAt;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if an address can claim
     * @param account Address to check
     * @param tokenAmount Expected token claim amount
     * @param ethRefund Expected ETH refund amount
     * @param proof Merkle proof
     */
    function canClaim(
        address account,
        uint256 tokenAmount,
        uint256 ethRefund,
        bytes32[] calldata proof
    ) external view returns (bool) {
        if (!distributionSet) return false;
        if (hasClaimed[account]) return false;
        if (tokenAmount == 0 && ethRefund == 0) return false;

        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(account, tokenAmount, ethRefund))));
        return MerkleProof.verify(proof, merkleRoot, leaf);
    }

    /**
     * @notice Get remaining tokens to be claimed
     */
    function remainingTokens() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Get remaining ETH refunds
     */
    function remainingEth() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Get distribution progress
     */
    function claimProgress() external view returns (
        uint256 tokensClaimed,
        uint256 tokensTotal,
        uint256 ethClaimed,
        uint256 ethTotal
    ) {
        return (totalTokensClaimed, totalTokens, totalEthClaimed, totalEthRefunds);
    }

    // ============================================
    // RECEIVE
    // ============================================

    receive() external payable {
        emit EthDeposited(msg.value);
    }
}
