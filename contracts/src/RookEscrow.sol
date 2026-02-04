// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "./interfaces/IERC20.sol";
import {IRookOracle} from "./interfaces/IRookOracle.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RookEscrow
 * @notice Trustless USDC escrow for AI agents with multi-layered verification
 * @dev Built for Circle USDC Hackathon on Moltbook
 */
contract RookEscrow is ReentrancyGuard, Ownable {
    
    // ═══════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════
    
    enum EscrowStatus { 
        Active,      // Funds locked, awaiting delivery
        Released,    // Funds sent to seller
        Refunded,    // Funds returned to buyer
        Disputed,    // Escalated to arbitration
        Challenged   // Under identity verification
    }
    
    struct Escrow {
        address buyer;
        address seller;
        uint256 amount;
        bytes32 jobHash;
        uint256 trustThreshold;    // 0-100 scale
        uint256 createdAt;
        uint256 expiresAt;
        EscrowStatus status;
    }
    
    struct Challenge {
        address challenger;
        uint256 stake;
        uint256 deadline;          // Block number
        bool resolved;
        bool passed;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════
    
    IERC20 public immutable usdc;
    IRookOracle public oracle;
    
    uint256 public constant MIN_THRESHOLD = 50;
    uint256 public constant MAX_THRESHOLD = 100;
    uint256 public constant CHALLENGE_STAKE = 5 * 10**6;  // 5 USDC
    uint256 public constant CHALLENGE_BLOCKS = 50;         // ~2 min on Base
    uint256 public constant DEFAULT_EXPIRY = 7 days;
    
    mapping(bytes32 => Escrow) public escrows;
    mapping(bytes32 => Challenge) public challenges;
    mapping(address => bytes32[]) public buyerEscrows;
    mapping(address => bytes32[]) public sellerEscrows;
    mapping(address => uint256) public completedEscrows;
    mapping(address => uint256) public totalEscrows;
    
    uint256 public escrowCount;
    uint256 public totalVolume;
    
    // ═══════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════
    
    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        bytes32 jobHash,
        uint256 trustThreshold
    );
    
    event EscrowReleased(
        bytes32 indexed escrowId,
        address indexed seller,
        uint256 amount,
        uint256 trustScore
    );
    
    event EscrowRefunded(
        bytes32 indexed escrowId,
        address indexed buyer,
        uint256 amount,
        string reason
    );
    
    event EscrowDisputed(
        bytes32 indexed escrowId,
        address indexed initiator,
        string evidence
    );
    
    event ChallengeInitiated(
        bytes32 indexed escrowId,
        address indexed challenger,
        uint256 stake,
        uint256 deadline
    );
    
    event ChallengeResolved(
        bytes32 indexed escrowId,
        bool passed,
        address indexed challenger,
        uint256 payout
    );
    
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    
    // ═══════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════
    
    error InvalidAmount();
    error InvalidSeller();
    error InvalidThreshold();
    error EscrowNotActive();
    error EscrowNotFound();
    error NotAuthorized();
    error ChallengeExists();
    error ChallengeNotFound();
    error ChallengeExpired();
    error ChallengeNotExpired();
    error AlreadyResolved();
    error BelowThreshold();
    error TransferFailed();
    
    // ═══════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════
    
    constructor(address _usdc, address _oracle) {
        usdc = IERC20(_usdc);
        oracle = IRookOracle(_oracle);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // ESCROW OPERATIONS
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Create a new escrow
     * @param seller Recipient address
     * @param amount USDC amount (6 decimals)
     * @param jobHash Keccak256 hash of job description
     * @param trustThreshold Minimum trust score for auto-release (0-100)
     */
    function createEscrow(
        address seller,
        uint256 amount,
        bytes32 jobHash,
        uint256 trustThreshold
    ) external nonReentrant returns (bytes32 escrowId) {
        if (amount == 0) revert InvalidAmount();
        if (seller == address(0) || seller == msg.sender) revert InvalidSeller();
        if (trustThreshold < MIN_THRESHOLD || trustThreshold > MAX_THRESHOLD) {
            revert InvalidThreshold();
        }
        
        escrowId = keccak256(abi.encodePacked(
            msg.sender,
            seller,
            amount,
            jobHash,
            block.timestamp,
            escrowCount++
        ));
        
        // Transfer USDC from buyer
        bool success = usdc.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        
        escrows[escrowId] = Escrow({
            buyer: msg.sender,
            seller: seller,
            amount: amount,
            jobHash: jobHash,
            trustThreshold: trustThreshold,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + DEFAULT_EXPIRY,
            status: EscrowStatus.Active
        });
        
        buyerEscrows[msg.sender].push(escrowId);
        sellerEscrows[seller].push(escrowId);
        totalEscrows[seller]++;
        totalVolume += amount;
        
        emit EscrowCreated(escrowId, msg.sender, seller, amount, jobHash, trustThreshold);
    }
    
    /**
     * @notice Release funds to seller (oracle-triggered)
     * @param escrowId Escrow identifier
     * @param trustScore Computed trust score from oracle
     */
    function releaseEscrow(
        bytes32 escrowId,
        uint256 trustScore
    ) external nonReentrant {
        if (msg.sender != address(oracle)) revert NotAuthorized();
        
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Active) revert EscrowNotActive();
        if (trustScore < escrow.trustThreshold) revert BelowThreshold();
        
        escrow.status = EscrowStatus.Released;
        completedEscrows[escrow.seller]++;
        
        bool success = usdc.transfer(escrow.seller, escrow.amount);
        if (!success) revert TransferFailed();
        
        emit EscrowReleased(escrowId, escrow.seller, escrow.amount, trustScore);
    }
    
    /**
     * @notice Refund buyer (manual or timeout)
     * @param escrowId Escrow identifier
     * @param reason Refund reason
     */
    function refundEscrow(
        bytes32 escrowId,
        string calldata reason
    ) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Active) revert EscrowNotActive();
        
        // Only buyer, seller (consent), or timeout can refund
        bool canRefund = msg.sender == escrow.buyer ||
                        msg.sender == escrow.seller ||
                        block.timestamp > escrow.expiresAt;
        if (!canRefund) revert NotAuthorized();
        
        escrow.status = EscrowStatus.Refunded;
        
        bool success = usdc.transfer(escrow.buyer, escrow.amount);
        if (!success) revert TransferFailed();
        
        emit EscrowRefunded(escrowId, escrow.buyer, escrow.amount, reason);
    }
    
    /**
     * @notice Escalate to dispute (Kleros)
     * @param escrowId Escrow identifier
     * @param evidence IPFS hash of evidence
     */
    function disputeEscrow(
        bytes32 escrowId,
        string calldata evidence
    ) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Active) revert EscrowNotActive();
        
        bool isParty = msg.sender == escrow.buyer || msg.sender == escrow.seller;
        if (!isParty) revert NotAuthorized();
        
        escrow.status = EscrowStatus.Disputed;
        
        // TODO: Integrate Kleros arbitration
        emit EscrowDisputed(escrowId, msg.sender, evidence);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // CHALLENGE OPERATIONS (Voight-Kampff)
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Initiate identity challenge
     * @param escrowId Escrow to challenge
     */
    function initiateChallenge(bytes32 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Active) revert EscrowNotActive();
        
        Challenge storage challenge = challenges[escrowId];
        if (challenge.deadline != 0 && !challenge.resolved) {
            revert ChallengeExists();
        }
        
        // Transfer stake
        bool success = usdc.transferFrom(msg.sender, address(this), CHALLENGE_STAKE);
        if (!success) revert TransferFailed();
        
        uint256 deadline = block.number + CHALLENGE_BLOCKS;
        
        challenges[escrowId] = Challenge({
            challenger: msg.sender,
            stake: CHALLENGE_STAKE,
            deadline: deadline,
            resolved: false,
            passed: false
        });
        
        escrow.status = EscrowStatus.Challenged;
        
        emit ChallengeInitiated(escrowId, msg.sender, CHALLENGE_STAKE, deadline);
    }
    
    /**
     * @notice Resolve challenge (oracle-triggered)
     * @param escrowId Escrow identifier
     * @param passed Whether challenge was passed
     */
    function resolveChallenge(
        bytes32 escrowId,
        bool passed
    ) external nonReentrant {
        if (msg.sender != address(oracle)) revert NotAuthorized();
        
        Challenge storage challenge = challenges[escrowId];
        if (challenge.deadline == 0) revert ChallengeNotFound();
        if (challenge.resolved) revert AlreadyResolved();
        
        Escrow storage escrow = escrows[escrowId];
        
        challenge.resolved = true;
        challenge.passed = passed;
        
        if (passed) {
            // Seller passed — return stake to challenger, continue escrow
            escrow.status = EscrowStatus.Active;
            bool success = usdc.transfer(challenge.challenger, challenge.stake);
            if (!success) revert TransferFailed();
            
            emit ChallengeResolved(escrowId, true, challenge.challenger, challenge.stake);
        } else {
            // Seller failed — challenger wins, refund buyer
            escrow.status = EscrowStatus.Refunded;
            
            // Refund buyer
            bool success1 = usdc.transfer(escrow.buyer, escrow.amount);
            if (!success1) revert TransferFailed();
            
            // Reward challenger (stake + bonus from protocol)
            uint256 reward = challenge.stake * 2;
            bool success2 = usdc.transfer(challenge.challenger, reward);
            if (!success2) revert TransferFailed();
            
            emit ChallengeResolved(escrowId, false, challenge.challenger, reward);
        }
    }
    
    /**
     * @notice Claim challenge timeout (seller didn't respond)
     * @param escrowId Escrow identifier
     */
    function claimChallengeTimeout(bytes32 escrowId) external nonReentrant {
        Challenge storage challenge = challenges[escrowId];
        if (challenge.deadline == 0) revert ChallengeNotFound();
        if (challenge.resolved) revert AlreadyResolved();
        if (block.number <= challenge.deadline) revert ChallengeNotExpired();
        
        Escrow storage escrow = escrows[escrowId];
        
        challenge.resolved = true;
        challenge.passed = false;
        escrow.status = EscrowStatus.Refunded;
        
        // Refund buyer
        bool success1 = usdc.transfer(escrow.buyer, escrow.amount);
        if (!success1) revert TransferFailed();
        
        // Reward challenger
        uint256 reward = challenge.stake * 2;
        bool success2 = usdc.transfer(challenge.challenger, reward);
        if (!success2) revert TransferFailed();
        
        emit ChallengeResolved(escrowId, false, challenge.challenger, reward);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════
    
    function getEscrow(bytes32 escrowId) external view returns (Escrow memory) {
        return escrows[escrowId];
    }
    
    function getChallenge(bytes32 escrowId) external view returns (Challenge memory) {
        return challenges[escrowId];
    }
    
    function getBuyerEscrows(address buyer) external view returns (bytes32[] memory) {
        return buyerEscrows[buyer];
    }
    
    function getSellerEscrows(address seller) external view returns (bytes32[] memory) {
        return sellerEscrows[seller];
    }
    
    function getCompletionRate(address agent) external view returns (uint256) {
        if (totalEscrows[agent] == 0) return 0;
        return (completedEscrows[agent] * 100) / totalEscrows[agent];
    }
    
    // ═══════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════
    
    function setOracle(address _oracle) external onlyOwner {
        address old = address(oracle);
        oracle = IRookOracle(_oracle);
        emit OracleUpdated(old, _oracle);
    }
}
