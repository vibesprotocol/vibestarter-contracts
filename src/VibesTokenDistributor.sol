// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VibesTokenDistributor
 * @notice Merkle-based token distribution for campaign backers.
 * @dev After a campaign completes, founder sets the merkle root and backers claim tokens.
 */
contract VibesTokenDistributor is ReentrancyGuard {
    // ============================================
    // EVENTS
    // ============================================

    event DistributionReady(bytes32 indexed merkleRoot, uint256 totalTokens);
    event TokensClaimed(address indexed backer, uint256 amount);
    event TokensRecovered(address indexed recipient, uint256 amount);

    // ============================================
    // STATE
    // ============================================

    /// @notice The token being distributed
    IERC20 public immutable token;

    /// @notice The founder who controls distribution
    address public immutable founder;

    /// @notice The campaign escrow this distributor is tied to
    address public immutable campaign;

    /// @notice Merkle root for distribution
    bytes32 public merkleRoot;

    /// @notice Total tokens allocated for distribution
    uint256 public totalTokens;

    /// @notice Whether distribution has been set
    bool public distributionSet;

    /// @notice Mapping of addresses that have claimed
    mapping(address => bool) public hasClaimed;

    /// @notice Total tokens claimed so far
    uint256 public totalClaimed;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @param _token Token to distribute
     * @param _founder Founder address
     * @param _campaign Campaign escrow address
     */
    constructor(
        address _token,
        address _founder,
        address _campaign
    ) {
        require(_token != address(0), "Invalid token");
        require(_founder != address(0), "Invalid founder");
        require(_campaign != address(0), "Invalid campaign");

        token = IERC20(_token);
        founder = _founder;
        campaign = _campaign;
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyFounder() {
        require(msg.sender == founder, "Not founder");
        _;
    }

    // ============================================
    // DISTRIBUTION SETUP
    // ============================================

    /**
     * @notice Set the merkle root for token distribution
     * @dev Founder must transfer tokens to this contract before or after calling this
     * @param _merkleRoot Merkle root of (address, amount) leaves
     * @param _totalTokens Total tokens to be distributed
     */
    function setDistributionRoot(
        bytes32 _merkleRoot,
        uint256 _totalTokens
    ) external onlyFounder {
        require(!distributionSet, "Already set");
        require(_merkleRoot != bytes32(0), "Invalid root");
        require(_totalTokens > 0, "Invalid amount");

        merkleRoot = _merkleRoot;
        totalTokens = _totalTokens;
        distributionSet = true;

        emit DistributionReady(_merkleRoot, _totalTokens);
    }

    // ============================================
    // CLAIM FUNCTIONS
    // ============================================

    /**
     * @notice Claim allocated tokens using merkle proof
     * @param amount Amount of tokens allocated to caller
     * @param proof Merkle proof for the claim
     */
    function claim(
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant {
        require(distributionSet, "Distribution not set");
        require(!hasClaimed[msg.sender], "Already claimed");
        require(amount > 0, "Invalid amount");

        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "Invalid proof");

        hasClaimed[msg.sender] = true;
        totalClaimed += amount;

        // Transfer tokens
        require(token.transfer(msg.sender, amount), "Transfer failed");

        emit TokensClaimed(msg.sender, amount);
    }

    /**
     * @notice Batch distribute tokens (founder pays gas)
     * @dev Useful for airdropping to backers who haven't claimed
     * @param recipients Array of recipient addresses
     * @param amounts Array of token amounts
     * @param proofs Array of merkle proofs
     */
    function batchDistribute(
        address[] calldata recipients,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external onlyFounder nonReentrant {
        require(distributionSet, "Distribution not set");
        require(recipients.length == amounts.length, "Length mismatch");
        require(recipients.length == proofs.length, "Proof length mismatch");

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];

            // Skip if already claimed
            if (hasClaimed[recipient]) continue;
            if (amount == 0) continue;

            // Verify merkle proof
            bytes32 leaf = keccak256(abi.encodePacked(recipient, amount));
            if (!MerkleProof.verify(proofs[i], merkleRoot, leaf)) continue;

            hasClaimed[recipient] = true;
            totalClaimed += amount;

            // Transfer tokens
            require(token.transfer(recipient, amount), "Transfer failed");

            emit TokensClaimed(recipient, amount);
        }
    }

    // ============================================
    // RECOVERY FUNCTIONS
    // ============================================

    /**
     * @notice Recover unclaimed tokens after distribution period
     * @dev Only founder can call, intended for cleanup after sufficient claim period
     * @param recipient Address to receive unclaimed tokens
     */
    function recoverUnclaimedTokens(address recipient) external onlyFounder {
        require(distributionSet, "Distribution not set");
        require(recipient != address(0), "Invalid recipient");

        uint256 remaining = token.balanceOf(address(this));
        require(remaining > 0, "No tokens to recover");

        require(token.transfer(recipient, remaining), "Transfer failed");

        emit TokensRecovered(recipient, remaining);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if an address can claim
     * @param account Address to check
     * @param amount Expected claim amount
     * @param proof Merkle proof
     */
    function canClaim(
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) external view returns (bool) {
        if (!distributionSet) return false;
        if (hasClaimed[account]) return false;
        if (amount == 0) return false;

        bytes32 leaf = keccak256(abi.encodePacked(account, amount));
        return MerkleProof.verify(proof, merkleRoot, leaf);
    }

    /**
     * @notice Get remaining tokens to be claimed
     */
    function remainingTokens() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Get distribution progress
     */
    function claimProgress() external view returns (uint256 claimed, uint256 total) {
        return (totalClaimed, totalTokens);
    }
}
