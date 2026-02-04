// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRookEscrow} from "./interfaces/IRookEscrow.sol";
import {IERC8004Identity} from "./interfaces/IERC8004Identity.sol";
import {IERC8004Reputation} from "./interfaces/IERC8004Reputation.sol";

/**
 * @title RookOracle
 * @notice Computes trust scores and triggers escrow operations
 */
contract RookOracle is Ownable {
    
    // ═══════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════
    
    IRookEscrow public escrow;
    IERC8004Identity public identityRegistry;
    IERC8004Reputation public reputationRegistry;
    
    // Weights (scaled to 100)
    uint256 public constant WEIGHT_IDENTITY = 25;
    uint256 public constant WEIGHT_REPUTATION = 25;
    uint256 public constant WEIGHT_SYBIL = 20;
    uint256 public constant WEIGHT_HISTORY = 20;
    uint256 public constant WEIGHT_CHALLENGE = 10;
    
    // Off-chain oracle operators
    mapping(address => bool) public operators;
    
    // Cached scores (updated by off-chain oracle)
    mapping(address => uint256) public identityScores;
    mapping(address => uint256) public reputationScores;
    mapping(address => uint256) public sybilScores;
    mapping(address => uint256) public challengeBonuses;
    mapping(address => uint256) public lastUpdated;
    
    // ═══════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════
    
    event ScoreUpdated(
        address indexed agent,
        uint256 identity,
        uint256 reputation,
        uint256 sybil,
        uint256 challengeBonus,
        uint256 composite
    );
    
    event OperatorUpdated(address indexed operator, bool status);
    
    // ═══════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════
    
    error NotOperator();
    error InvalidScore();
    
    // ═══════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════
    
    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != owner()) revert NotOperator();
        _;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════
    
    constructor(address _escrow) {
        escrow = IRookEscrow(_escrow);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // SCORE MANAGEMENT
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Update agent scores (off-chain oracle)
     * @param agent Agent address
     * @param identity Identity score (0-100)
     * @param reputation Reputation score (0-100)
     * @param sybil Sybil resistance score (0-100)
     * @param challengeBonus Challenge bonus (0-100)
     */
    function updateScores(
        address agent,
        uint256 identity,
        uint256 reputation,
        uint256 sybil,
        uint256 challengeBonus
    ) external onlyOperator {
        if (identity > 100 || reputation > 100 || sybil > 100 || challengeBonus > 100) {
            revert InvalidScore();
        }
        
        identityScores[agent] = identity;
        reputationScores[agent] = reputation;
        sybilScores[agent] = sybil;
        challengeBonuses[agent] = challengeBonus;
        lastUpdated[agent] = block.timestamp;
        
        uint256 composite = computeTrustScore(agent);
        
        emit ScoreUpdated(agent, identity, reputation, sybil, challengeBonus, composite);
    }
    
    /**
     * @notice Compute composite trust score
     * @param agent Agent address
     * @return Trust score (0-100)
     */
    function computeTrustScore(address agent) public view returns (uint256) {
        uint256 historyScore = getHistoryScore(agent);
        
        return (
            identityScores[agent] * WEIGHT_IDENTITY +
            reputationScores[agent] * WEIGHT_REPUTATION +
            sybilScores[agent] * WEIGHT_SYBIL +
            historyScore * WEIGHT_HISTORY +
            challengeBonuses[agent] * WEIGHT_CHALLENGE
        ) / 100;
    }
    
    /**
     * @notice Get escrow completion history score
     * @param agent Agent address
     * @return History score (0-100)
     */
    function getHistoryScore(address agent) public view returns (uint256) {
        uint256 completionRate = escrow.getCompletionRate(agent);
        
        // New agents get neutral score
        if (completionRate == 0) return 50;
        
        return completionRate;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // ESCROW TRIGGERS
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Trigger escrow release after verification
     * @param escrowId Escrow identifier
     */
    function triggerRelease(bytes32 escrowId) external onlyOperator {
        IRookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        uint256 trustScore = computeTrustScore(e.seller);
        
        escrow.releaseEscrow(escrowId, trustScore);
    }
    
    /**
     * @notice Resolve identity challenge
     * @param escrowId Escrow identifier
     * @param passed Whether challenge was passed
     */
    function resolveChallenge(bytes32 escrowId, bool passed) external onlyOperator {
        escrow.resolveChallenge(escrowId, passed);
        
        // Update challenge bonus if passed
        if (passed) {
            IRookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
            challengeBonuses[e.seller] = 100;  // Max bonus
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════
    
    function getScoreBreakdown(address agent) external view returns (
        uint256 identity,
        uint256 reputation,
        uint256 sybil,
        uint256 history,
        uint256 challengeBonus,
        uint256 composite
    ) {
        identity = identityScores[agent];
        reputation = reputationScores[agent];
        sybil = sybilScores[agent];
        history = getHistoryScore(agent);
        challengeBonus = challengeBonuses[agent];
        composite = computeTrustScore(agent);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════
    
    function setOperator(address operator, bool status) external onlyOwner {
        operators[operator] = status;
        emit OperatorUpdated(operator, status);
    }
    
    function setEscrow(address _escrow) external onlyOwner {
        escrow = IRookEscrow(_escrow);
    }
    
    function setRegistries(
        address _identity,
        address _reputation
    ) external onlyOwner {
        identityRegistry = IERC8004Identity(_identity);
        reputationRegistry = IERC8004Reputation(_reputation);
    }
}
