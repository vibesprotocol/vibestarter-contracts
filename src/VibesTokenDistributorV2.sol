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

    // ============================================
    // ERRORS
    // ============================================

    error OnlyFounder();
    error ZeroAddress();
    error DistributionNotSet();
    error AlreadySet();
    error AlreadyClaimed();
    error InvalidProof();
    error InvalidAmount();
    error TransferFailed();
    error InsufficientEth();

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(
        address _token,
        address _founder,
        address _campaign
    ) {
        if (_token == address(0)) revert ZeroAddress();
        if (_founder == address(0)) revert ZeroAddress();
        if (_campaign == address(0)) revert ZeroAddress();

        token = IERC20(_token);
        founder = _founder;
        campaign = _campaign;
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyFounder() {
        if (msg.sender != founder) revert OnlyFounder();
        _;
    }

    // ============================================
    // DISTRIBUTION SETUP
    // ============================================

    /**
     * @notice Set the merkle root for token + ETH distribution
     * @dev Merkle leaves are: keccak256(abi.encodePacked(address, tokenAmount, ethRefund))
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
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, tokenAmount, ethRefund));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        hasClaimed[msg.sender] = true;

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

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 tokenAmount = tokenAmounts[i];
            uint256 ethRefund = ethRefunds[i];

            // Skip if already claimed or nothing to distribute
            if (hasClaimed[recipient]) continue;
            if (tokenAmount == 0 && ethRefund == 0) continue;

            // Verify merkle proof
            bytes32 leaf = keccak256(abi.encodePacked(recipient, tokenAmount, ethRefund));
            if (!MerkleProof.verify(proofs[i], merkleRoot, leaf)) continue;

            hasClaimed[recipient] = true;

            // Transfer tokens
            if (tokenAmount > 0) {
                totalTokensClaimed += tokenAmount;
                token.safeTransfer(recipient, tokenAmount);
            }

            // Transfer ETH refund
            if (ethRefund > 0 && address(this).balance >= ethRefund) {
                totalEthClaimed += ethRefund;
                (bool sent, ) = recipient.call{value: ethRefund}("");
                // Don't revert on individual failure in batch
                if (sent) {
                    emit TokensClaimed(recipient, tokenAmount, ethRefund);
                } else {
                    // Emit with 0 ETH if transfer failed
                    emit TokensClaimed(recipient, tokenAmount, 0);
                }
            } else {
                emit TokensClaimed(recipient, tokenAmount, 0);
            }
        }
    }

    // ============================================
    // RECOVERY FUNCTIONS
    // ============================================

    /**
     * @notice Recover unclaimed tokens and ETH after distribution period
     * @param recipient Address to receive unclaimed assets
     */
    function recoverUnclaimed(address recipient) external onlyFounder {
        if (!distributionSet) revert DistributionNotSet();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 tokenRemaining = token.balanceOf(address(this));
        uint256 ethRemaining = address(this).balance;

        if (tokenRemaining > 0) {
            token.safeTransfer(recipient, tokenRemaining);
        }

        if (ethRemaining > 0) {
            (bool sent, ) = recipient.call{value: ethRemaining}("");
            if (!sent) revert TransferFailed();
        }

        emit TokensRecovered(recipient, tokenRemaining, ethRemaining);
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

        bytes32 leaf = keccak256(abi.encodePacked(account, tokenAmount, ethRefund));
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
