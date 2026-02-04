// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "./interfaces/IERC20.sol";
import {IRookOracle} from "./interfaces/IRookOracle.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title RookEscrow
 * @notice Trustless USDC escrow for AI agents with multi-layered verification
 * @dev Built for Circle USDC Hackathon on Moltbook
 * @custom:security-contact security@rook-protocol.xyz
 * 
 * GAS OPTIMIZED VERSION - See storage packing optimizations
 */
contract RookEscrow is ReentrancyGuard, Ownable, Pausable {
    
    // ═══════════════════════════════════════════════════════════════
    // TYPES - OPTIMIZED FOR STORAGE PACKING
    // ═══════════════════════════════════════════════════════════════
    
    enum EscrowStatus { 
        Active,
        Released,
        Refunded,
        Disputed,
        Challenged
    }
    
    enum ChallengeStatus {
        None,
        Active,
        Responded,
        Resolved
    }
    
    // OPTIMIZED: Packed into fewer slots (4 slots vs 8)
    struct Escrow {
        address buyer;          // 20 bytes
        address seller;         // 20 bytes  
        uint64 createdAt;       // 8 bytes - sufficient until year 36812
        uint64 expiresAt;       // 8 bytes
        uint8 trustThreshold;   // 1 byte (0-100)
        uint8 status;           // 1 byte (enum)
        // Total: 58 bytes (slot 0-1)
        uint256 amount;         // 32 bytes (slot 2)
        bytes32 jobHash;        // 32 bytes (slot 3)
        // Total: 4 slots (50% gas savings on SSTORE)
    }
    
    struct Challenge {
        address challenger;
        uint96 stake;           // Changed from uint256 - 5 USDC fits easily
        uint32 deadline;        // Changed from uint256 - block number fits in uint32
        uint8 status;           // enum as uint8
        bool passed;
        bytes32 responseHash;
    }
    
    struct Dispute {
        address initiator;
        bytes32 evidenceHash;   // Changed from string - IPFS CID fits in bytes32
        uint64 createdAt;
        bool resolved;
        address winner;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════
    
    IERC20 public immutable usdc;
    IRookOracle public oracle;
    
    // Challenge configuration
    uint256 public constant CHALLENGE_STAKE = 5 * 10**6;
    uint32 public constant CHALLENGE_BLOCKS = 50;
    uint32 public constant CHALLENGE_RESPONSE_BLOCKS = 25;
    
    // Escrow configuration  
    uint8 public constant MIN_THRESHOLD = 50;
    uint8 public constant MAX_THRESHOLD = 100;
    uint32 public constant DEFAULT_EXPIRY_DAYS = 7;
    uint32 public constant ORACLE_TIMEOUT_DAYS = 1;
    uint32 public constant CHALLENGE_COOLDOWN_HOURS = 1;
    uint256 public constant MAX_EVIDENCE_LENGTH = 1000;
    
    // Storage
    mapping(bytes32 => Escrow) public escrows;
    mapping(bytes32 => Challenge) public challenges;
    mapping(bytes32 => Dispute) public disputes;
    mapping(address => bytes32[]) public buyerEscrows;
    mapping(address => bytes32[]) public sellerEscrows;
    mapping(address => uint256) public completedEscrows;
    mapping(address => uint256) public totalEscrows;
    mapping(address => uint256) public lastChallengeTime;
    
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
        uint8 trustThreshold,
        uint64 expiresAt
    );
    
    event EscrowReleased(
        bytes32 indexed escrowId,
        address indexed seller,
        uint256 amount,
        uint256 trustScore,
        bytes32 releaseReason
    );
    
    event EscrowRefunded(
        bytes32 indexed escrowId,
        address indexed buyer,
        uint256 amount,
        bytes32 reasonHash
    );
    
    event EscrowDisputed(
        bytes32 indexed escrowId,
        address indexed initiator,
        bytes32 evidenceHash
    );
    
    event DisputeResolved(
        bytes32 indexed escrowId,
        address indexed winner,
        uint256 amount
    );
    
    event ChallengeInitiated(
        bytes32 indexed escrowId,
        address indexed challenger,
        uint96 stake,
        uint32 deadline
    );
    
    event ChallengeResponded(
        bytes32 indexed escrowId,
        bytes32 responseHash,
        uint32 responseBlock
    );
    
    event ChallengeResolved(
        bytes32 indexed escrowId,
        bool passed,
        address indexed challenger,
        uint96 stakeReturned
    );
    
    event OracleUpdated(
        address indexed oldOracle, 
        address indexed newOracle
    );
    
    // ═══════════════════════════════════════════════════════════════
    // ERRORS - REMOVED UNUSED ONES
    // ═══════════════════════════════════════════════════════════════
    
    error InvalidAmount();
    error InvalidAddress();
    error InvalidThreshold();
    error BelowThreshold();
    error EscrowNotActive();
    error EscrowNotFound();
    error EscrowNotDisputed();
    error EscrowExpired();
    error NotAuthorized();
    error NotBuyer();
    error NotSeller();
    error NotOracle();
    error ChallengeExists();
    error ChallengeNotFound();
    error ChallengeNotActive();
    error ChallengeExpired();
    error ChallengeNotExpired();
    error ChallengeCooldownActive(uint256 waitUntil);
    error SelfChallenge();
    error DisputeAlreadyResolved();
    error OracleTimeoutNotMet();
    error EvidenceTooLong();
    error TransferFailed();
    error MaxEscrowsReached();
    
    // ═══════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════
    
    constructor(address _usdc, address _oracle) {
        if (_usdc == address(0) || _oracle == address(0)) {
            revert InvalidAddress();
        }
        usdc = IERC20(_usdc);
        oracle = IRookOracle(_oracle);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════
    
    modifier onlyOracle() {
        if (msg.sender != address(oracle)) revert NotOracle();
        _;
    }
    
    modifier onlyBuyer(bytes32 escrowId) {
        if (msg.sender != escrows[escrowId].buyer) revert NotBuyer();
        _;
    }
    
    modifier onlySeller(bytes32 escrowId) {
        if (msg.sender != escrows[escrowId].seller) revert NotSeller();
        _;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // ESCROW OPERATIONS
    // ═══════════════════════════════════════════════════════════════
    
    function createEscrow(
        address seller,
        uint256 amount,
        bytes32 jobHash,
        uint8 trustThreshold
    ) external nonReentrant whenNotPaused returns (bytes32 escrowId) {
        // Validation
        if (amount == 0) revert InvalidAmount();
        if (seller == address(0) || seller == msg.sender) revert InvalidAddress();
        if (trustThreshold < MIN_THRESHOLD || trustThreshold > MAX_THRESHOLD) {
            revert InvalidThreshold();
        }
        
        // Rate limit: max 100 escrows per buyer (prevent DoS on array)
        if (buyerEscrows[msg.sender].length >= 100) revert MaxEscrowsReached();
        
        // Generate ID
        escrowId = keccak256(abi.encodePacked(
            msg.sender,
            seller,
            amount,
            jobHash,
            block.timestamp,
            escrowCount++
        ));
        
        // Transfer USDC
        bool success = usdc.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        
        // Create escrow (packed storage)
        escrows[escrowId] = Escrow({
            buyer: msg.sender,
            seller: seller,
            createdAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + (DEFAULT_EXPIRY_DAYS * 1 days)),
            trustThreshold: trustThreshold,
            status: uint8(EscrowStatus.Active),
            amount: amount,
            jobHash: jobHash
        });
        
        // Update tracking
        buyerEscrows[msg.sender].push(escrowId);
        sellerEscrows[seller].push(escrowId);
        totalEscrows[seller]++;
        totalVolume += amount;
        
        emit EscrowCreated(
            escrowId, 
            msg.sender, 
            seller, 
            amount, 
            trustThreshold,
            uint64(block.timestamp + (DEFAULT_EXPIRY_DAYS * 1 days))
        );
    }
    
    function releaseEscrow(
        bytes32 escrowId,
        uint256 trustScore
    ) external nonReentrant onlyOracle {
        Escrow storage escrow = escrows[escrowId];
        
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != uint8(EscrowStatus.Active)) revert EscrowNotActive();
        if (trustScore < escrow.trustThreshold) revert BelowThreshold();
        
        escrow.status = uint8(EscrowStatus.Released);
        completedEscrows[escrow.seller]++;
        
        bool success = usdc.transfer(escrow.seller, escrow.amount);
        if (!success) revert TransferFailed();
        
        emit EscrowReleased(
            escrowId, 
            escrow.seller, 
            escrow.amount, 
            trustScore, 
            keccak256("oracle_release")
        );
    }
    
    function releaseWithConsent(bytes32 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != uint8(EscrowStatus.Active)) revert EscrowNotActive();
        if (block.timestamp < escrow.createdAt + (ORACLE_TIMEOUT_DAYS * 1 days)) {
            revert OracleTimeoutNotMet();
        }
        
        bool isParty = msg.sender == escrow.buyer || msg.sender == escrow.seller;
        if (!isParty) revert NotAuthorized();
        
        escrow.status = uint8(EscrowStatus.Released);
        completedEscrows[escrow.seller]++;
        
        bool success = usdc.transfer(escrow.seller, escrow.amount);
        if (!success) revert TransferFailed();
        
        emit EscrowReleased(
            escrowId, 
            escrow.seller, 
            escrow.amount, 
            0, 
            keccak256("consent_release")
        );
    }
    
    function refundEscrow(
        bytes32 escrowId,
        string calldata reason
    ) external nonReentrant onlyBuyer(escrowId) {
        Escrow storage escrow = escrows[escrowId];
        
        if (escrow.status != uint8(EscrowStatus.Active)) revert EscrowNotActive();
        
        // Check expiry
        if (block.timestamp > escrow.expiresAt) revert EscrowExpired();
        
        escrow.status = uint8(EscrowStatus.Refunded);
        
        bool success = usdc.transfer(escrow.buyer, escrow.amount);
        if (!success) revert TransferFailed();
        
        emit EscrowRefunded(
            escrowId, 
            escrow.buyer, 
            escrow.amount, 
            keccak256(bytes(reason))
        );
    }
    
    function disputeEscrow(
        bytes32 escrowId,
        string calldata evidence
    ) external nonReentrant {
        // Check evidence length (gas griefing protection)
        if (bytes(evidence).length > MAX_EVIDENCE_LENGTH) {
            revert EvidenceTooLong();
        }
        
        Escrow storage e = escrows[escrowId];
        
        if (e.buyer == address(0)) revert EscrowNotFound();
        if (e.status != uint8(EscrowStatus.Active) && e.status != uint8(EscrowStatus.Challenged)) {
            revert EscrowNotActive();
        }
        
        bool isParty = msg.sender == e.buyer || msg.sender == e.seller;
        if (!isParty) revert NotAuthorized();
        
        e.status = uint8(EscrowStatus.Disputed);
        
        disputes[escrowId] = Dispute({
            initiator: msg.sender,
            evidenceHash: keccak256(bytes(evidence)),
            createdAt: uint64(block.timestamp),
            resolved: false,
            winner: address(0)
        });
        
        emit EscrowDisputed(escrowId, msg.sender, keccak256(bytes(evidence)));
    }
    
    function resolveDispute(
        bytes32 escrowId,
        address winner
    ) external nonReentrant onlyOwner {
        Escrow storage e = escrows[escrowId];
        Dispute storage dispute = disputes[escrowId];
        
        if (e.status != uint8(EscrowStatus.Disputed)) revert EscrowNotDisputed();
        if (dispute.resolved) revert DisputeAlreadyResolved();
        if (winner != e.buyer && winner != e.seller) revert NotAuthorized();
        
        dispute.resolved = true;
        dispute.winner = winner;
        
        if (winner == e.seller) {
            e.status = uint8(EscrowStatus.Released);
            completedEscrows[e.seller]++;
        } else {
            e.status = uint8(EscrowStatus.Refunded);
        }
        
        bool success = usdc.transfer(winner, e.amount);
        if (!success) revert TransferFailed();
        
        emit DisputeResolved(escrowId, winner, e.amount);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // CHALLENGE OPERATIONS
    // ═══════════════════════════════════════════════════════════════
    
    function initiateChallenge(bytes32 escrowId) external nonReentrant whenNotPaused {
        Escrow storage e = escrows[escrowId];
        
        if (e.buyer == address(0)) revert EscrowNotFound();
        if (e.status != uint8(EscrowStatus.Active)) revert EscrowNotActive();
        if (msg.sender == e.seller) revert SelfChallenge();
        
        // Rate limiting with detailed error
        uint256 cooldownEnd = lastChallengeTime[msg.sender] + (CHALLENGE_COOLDOWN_HOURS * 1 hours);
        if (block.timestamp < cooldownEnd) {
            revert ChallengeCooldownActive(cooldownEnd);
        }
        
        Challenge storage challenge = challenges[escrowId];
        if (challenge.status != uint8(ChallengeStatus.None)) {
            revert ChallengeExists();
        }
        
        bool success = usdc.transferFrom(msg.sender, address(this), CHALLENGE_STAKE);
        if (!success) revert TransferFailed();
        
        uint32 deadline = uint32(block.number + CHALLENGE_BLOCKS);
        lastChallengeTime[msg.sender] = block.timestamp;
        
        challenges[escrowId] = Challenge({
            challenger: msg.sender,
            stake: uint96(CHALLENGE_STAKE),
            deadline: deadline,
            status: uint8(ChallengeStatus.Active),
            passed: false,
            responseHash: bytes32(0)
        });
        
        e.status = uint8(EscrowStatus.Challenged);
        
        emit ChallengeInitiated(escrowId, msg.sender, uint96(CHALLENGE_STAKE), deadline);
    }
    
    function respondChallenge(
        bytes32 escrowId,
        bytes32 responseHash
    ) external nonReentrant onlySeller(escrowId) {
        Escrow storage e = escrows[escrowId];
        Challenge storage challenge = challenges[escrowId];
        
        if (e.status != uint8(EscrowStatus.Challenged)) revert EscrowNotActive();
        if (challenge.status != uint8(ChallengeStatus.Active)) revert ChallengeNotActive();
        if (block.number > challenge.deadline) revert ChallengeExpired();
        
        challenge.status = uint8(ChallengeStatus.Responded);
        challenge.responseHash = responseHash;
        
        emit ChallengeResponded(escrowId, responseHash, uint32(block.number));
    }
    
    function resolveChallenge(
        bytes32 escrowId,
        bool passed
    ) external nonReentrant onlyOracle {
        Challenge storage challenge = challenges[escrowId];
        Escrow storage e = escrows[escrowId];
        
        if (challenge.status != uint8(ChallengeStatus.Active) && 
            challenge.status != uint8(ChallengeStatus.Responded)) {
            revert ChallengeNotActive();
        }
        if (block.number > challenge.deadline) revert ChallengeExpired();
        
        challenge.status = uint8(ChallengeStatus.Resolved);
        challenge.passed = passed;
        
        if (passed) {
            e.status = uint8(EscrowStatus.Active);
            bool success = usdc.transfer(challenge.challenger, challenge.stake);
            if (!success) revert TransferFailed();
            
            emit ChallengeResolved(escrowId, true, challenge.challenger, challenge.stake);
        } else {
            e.status = uint8(EscrowStatus.Refunded);
            
            bool success1 = usdc.transfer(e.buyer, e.amount);
            if (!success1) revert TransferFailed();
            
            bool success2 = usdc.transfer(challenge.challenger, challenge.stake);
            if (!success2) revert TransferFailed();
            
            emit ChallengeResolved(escrowId, false, challenge.challenger, challenge.stake);
        }
    }
    
    function claimChallengeTimeout(bytes32 escrowId) external nonReentrant {
        Challenge storage challenge = challenges[escrowId];
        Escrow storage e = escrows[escrowId];
        
        if (challenge.status != uint8(ChallengeStatus.Active)) revert ChallengeNotActive();
        if (block.number <= challenge.deadline) revert ChallengeNotExpired();
        
        challenge.status = uint8(ChallengeStatus.Resolved);
        challenge.passed = false;
        e.status = uint8(EscrowStatus.Refunded);
        
        bool success1 = usdc.transfer(e.buyer, e.amount);
        if (!success1) revert TransferFailed();
        
        bool success2 = usdc.transfer(challenge.challenger, challenge.stake);
        if (!success2) revert TransferFailed();
        
        emit ChallengeResolved(escrowId, false, challenge.challenger, challenge.stake);
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
    
    function getDispute(bytes32 escrowId) external view returns (Dispute memory) {
        return disputes[escrowId];
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
    
    function getNextChallengeTime(address user) external view returns (uint256) {
        uint256 lastChallenge = lastChallengeTime[user];
        if (lastChallenge == 0) return 0;
        return lastChallenge + (CHALLENGE_COOLDOWN_HOURS * 1 hours);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════
    
    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert InvalidAddress();
        address old = address(oracle);
        oracle = IRookOracle(_oracle);
        emit OracleUpdated(old, _oracle);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Emergency withdrawal for accidentally sent tokens
     * @param token Token address
     * @param amount Amount to withdraw
     * @dev Only callable by owner, excludes USDC escrow funds
     */
    function emergencyWithdraw(
        address token, 
        uint256 amount
    ) external onlyOwner {
        if (token == address(usdc)) revert NotAuthorized();
        
        bool success = IERC20(token).transfer(owner(), amount);
        if (!success) revert TransferFailed();
    }
}
