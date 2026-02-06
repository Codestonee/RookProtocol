// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IRookEscrow} from "./interfaces/IRookEscrow.sol";
import {IERC8004Identity} from "./interfaces/IERC8004Identity.sol";
import {IERC8004Reputation} from "./interfaces/IERC8004Reputation.sol";

/**
 * @title RookOracle
 * @notice Computes trust scores and triggers escrow operations
 * @dev Added ReentrancyGuard for defense-in-depth on external calls
 */
contract RookOracle is Ownable, ReentrancyGuard {

    // =================================================================
    // STATE
    // =================================================================

    IRookEscrow public escrow;

    // NOTE: These registries are placeholders for future ERC-8004 identity/reputation
    // integration. Currently, scores are updated off-chain via updateScores().
    IERC8004Identity public identityRegistry;
    IERC8004Reputation public reputationRegistry;

    // Configurable weights (scaled to 100)
    uint256 public weightIdentity = 30;
    uint256 public weightReputation = 30;
    uint256 public weightSybil = 20;
    uint256 public weightHistory = 15;
    uint256 public weightChallenge = 5;

    // Score staleness threshold
    uint256 public constant MAX_SCORE_AGE = 1 hours;

    // New agent default history score (aligned with off-chain service)
    uint256 public constant DEFAULT_HISTORY_SCORE = 40;

    // Off-chain oracle operators
    mapping(address => bool) public operators;

    // Cached scores (updated by off-chain oracle)
    mapping(address => uint256) public identityScores;
    mapping(address => uint256) public reputationScores;
    mapping(address => uint256) public sybilScores;
    mapping(address => uint256) public challengeBonuses;
    mapping(address => uint256) public lastUpdated;

    // Challenge bonus decay (bonus resets after this period)
    uint256 public constant CHALLENGE_BONUS_DURATION = 30 days;
    mapping(address => uint256) public challengeBonusTimestamp;

    // =================================================================
    // EVENTS
    // =================================================================

    event ScoreUpdated(
        address indexed agent,
        uint256 identity,
        uint256 reputation,
        uint256 sybil,
        uint256 challengeBonus,
        uint256 composite
    );

    event OperatorUpdated(address indexed operator, bool status);

    event WeightsUpdated(
        uint256 identity,
        uint256 reputation,
        uint256 sybil,
        uint256 history,
        uint256 challenge
    );

    event EscrowUpdated(address indexed oldEscrow, address indexed newEscrow);
    event RegistriesUpdated(address indexed identity, address indexed reputation);

    // =================================================================
    // ERRORS
    // =================================================================

    error NotOperator();
    error InvalidScore();
    error StaleScore();
    error InvalidWeights();
    error InvalidAddress();

    // =================================================================
    // MODIFIERS
    // =================================================================

    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != owner()) revert NotOperator();
        _;
    }

    // =================================================================
    // CONSTRUCTOR
    // =================================================================

    constructor(address _escrow) {
        // Allow address(0) for initial deployment, but setEscrow must be called before use
        if (_escrow != address(0)) {
            escrow = IRookEscrow(_escrow);
        }
    }

    // =================================================================
    // SCORE MANAGEMENT
    // =================================================================

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
        if (agent == address(0)) revert InvalidAddress();
        if (identity > 100 || reputation > 100 || sybil > 100 || challengeBonus > 100) {
            revert InvalidScore();
        }

        identityScores[agent] = identity;
        reputationScores[agent] = reputation;
        sybilScores[agent] = sybil;
        challengeBonuses[agent] = challengeBonus;
        lastUpdated[agent] = block.timestamp;

        if (challengeBonus > 0) {
            challengeBonusTimestamp[agent] = block.timestamp;
        }

        uint256 composite = computeTrustScore(agent);

        emit ScoreUpdated(agent, identity, reputation, sybil, challengeBonus, composite);
    }

    /**
     * @notice Batch update scores for multiple agents
     * @param agents Agent addresses
     * @param identities Identity scores
     * @param reputations Reputation scores
     * @param sybils Sybil resistance scores
     * @param challengeBonusArr Challenge bonuses
     */
    function batchUpdateScores(
        address[] calldata agents,
        uint256[] calldata identities,
        uint256[] calldata reputations,
        uint256[] calldata sybils,
        uint256[] calldata challengeBonusArr
    ) external onlyOperator {
        uint256 len = agents.length;
        require(
            len == identities.length &&
            len == reputations.length &&
            len == sybils.length &&
            len == challengeBonusArr.length,
            "Array length mismatch"
        );

        for (uint256 i = 0; i < len; i++) {
            address agent = agents[i];
            if (agent == address(0)) revert InvalidAddress();
            if (identities[i] > 100 || reputations[i] > 100 || sybils[i] > 100 || challengeBonusArr[i] > 100) {
                revert InvalidScore();
            }

            identityScores[agent] = identities[i];
            reputationScores[agent] = reputations[i];
            sybilScores[agent] = sybils[i];
            challengeBonuses[agent] = challengeBonusArr[i];
            lastUpdated[agent] = block.timestamp;

            if (challengeBonusArr[i] > 0) {
                challengeBonusTimestamp[agent] = block.timestamp;
            }

            uint256 composite = computeTrustScore(agent);
            emit ScoreUpdated(agent, identities[i], reputations[i], sybils[i], challengeBonusArr[i], composite);
        }
    }

    /**
     * @notice Compute composite trust score
     * @param agent Agent address
     * @return Trust score (0-100)
     */
    function computeTrustScore(address agent) public view returns (uint256) {
        // Return conservative 0 for stale/missing data
        if (lastUpdated[agent] == 0 || block.timestamp > lastUpdated[agent] + MAX_SCORE_AGE) {
            return 0;
        }

        uint256 historyScore = getHistoryScore(agent);

        // Apply challenge bonus decay
        uint256 effectiveChallengeBonus = challengeBonuses[agent];
        if (challengeBonusTimestamp[agent] > 0 &&
            block.timestamp > challengeBonusTimestamp[agent] + CHALLENGE_BONUS_DURATION) {
            effectiveChallengeBonus = 0;
        }

        return (
            identityScores[agent] * weightIdentity +
            reputationScores[agent] * weightReputation +
            sybilScores[agent] * weightSybil +
            historyScore * weightHistory +
            effectiveChallengeBonus * weightChallenge
        ) / 100;
    }

    /**
     * @notice Compute trust score with explicit staleness indicator
     * @param agent Agent address
     * @return score Trust score (0-100), returns 0 if stale
     * @return isStale True if score is stale or missing
     * @return lastUpdate Timestamp of last score update (0 if never updated)
     */
    function computeTrustScoreWithStaleness(address agent) public view returns (
        uint256 score,
        bool isStale,
        uint256 lastUpdate
    ) {
        lastUpdate = lastUpdated[agent];
        isStale = lastUpdate == 0 || block.timestamp > lastUpdate + MAX_SCORE_AGE;

        if (isStale) {
            return (0, true, lastUpdate);
        }

        score = computeTrustScore(agent);
        return (score, false, lastUpdate);
    }

    /**
     * @notice Get escrow completion history score
     * @param agent Agent address
     * @return History score (0-100)
     */
    function getHistoryScore(address agent) public view returns (uint256) {
        uint256 total = escrow.totalEscrows(agent);

        // New agents get conservative default score (aligned with off-chain)
        if (total == 0) return DEFAULT_HISTORY_SCORE;

        uint256 completionRate = escrow.getCompletionRate(agent);
        // getCompletionRate now returns basis points (0-10000)
        return completionRate / 100; // Convert to 0-100
    }

    // =================================================================
    // ESCROW TRIGGERS
    // =================================================================

    /**
     * @notice Trigger escrow release after verification
     * @param escrowId Escrow identifier
     */
    function triggerRelease(bytes32 escrowId) external nonReentrant onlyOperator {
        IRookEscrow.Escrow memory e = escrow.getEscrow(escrowId);

        // Single staleness check
        if (lastUpdated[e.seller] == 0 || block.timestamp > lastUpdated[e.seller] + MAX_SCORE_AGE) {
            revert StaleScore();
        }

        // Compute score inline (freshness already verified)
        uint256 historyScore = getHistoryScore(e.seller);

        uint256 effectiveChallengeBonus = challengeBonuses[e.seller];
        if (challengeBonusTimestamp[e.seller] > 0 &&
            block.timestamp > challengeBonusTimestamp[e.seller] + CHALLENGE_BONUS_DURATION) {
            effectiveChallengeBonus = 0;
        }

        uint256 trustScore = (
            identityScores[e.seller] * weightIdentity +
            reputationScores[e.seller] * weightReputation +
            sybilScores[e.seller] * weightSybil +
            historyScore * weightHistory +
            effectiveChallengeBonus * weightChallenge
        ) / 100;

        escrow.releaseEscrow(escrowId, trustScore);
    }

    /**
     * @notice Resolve identity challenge
     * @param escrowId Escrow identifier
     * @param passed Whether challenge was passed
     */
    function resolveChallenge(bytes32 escrowId, bool passed) external nonReentrant onlyOperator {
        escrow.resolveChallenge(escrowId, passed);

        // Update challenge bonus if passed
        if (passed) {
            IRookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
            challengeBonuses[e.seller] = 100;
            challengeBonusTimestamp[e.seller] = block.timestamp;
        }
    }

    // =================================================================
    // VIEW FUNCTIONS
    // =================================================================

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

    /**
     * @notice Check if score data is fresh
     * @param agent Agent address
     * @return True if score was updated within MAX_SCORE_AGE
     */
    function isScoreFresh(address agent) external view returns (bool) {
        return lastUpdated[agent] > 0 && block.timestamp <= lastUpdated[agent] + MAX_SCORE_AGE;
    }

    // =================================================================
    // ADMIN
    // =================================================================

    function setOperator(address operator, bool status) external onlyOwner {
        if (operator == address(0)) revert InvalidAddress();
        operators[operator] = status;
        emit OperatorUpdated(operator, status);
    }

    function setEscrow(address _escrow) external onlyOwner {
        if (_escrow == address(0)) revert InvalidAddress();
        address oldEscrow = address(escrow);
        escrow = IRookEscrow(_escrow);
        emit EscrowUpdated(oldEscrow, _escrow);
    }

    function setRegistries(
        address _identity,
        address _reputation
    ) external onlyOwner {
        if (_identity == address(0) || _reputation == address(0)) revert InvalidAddress();
        identityRegistry = IERC8004Identity(_identity);
        reputationRegistry = IERC8004Reputation(_reputation);
        emit RegistriesUpdated(_identity, _reputation);
    }

    /**
     * @notice Update scoring weights
     */
    function setWeights(
        uint256 _identity,
        uint256 _reputation,
        uint256 _sybil,
        uint256 _history,
        uint256 _challenge
    ) external onlyOwner {
        if (_identity + _reputation + _sybil + _history + _challenge != 100) {
            revert InvalidWeights();
        }

        weightIdentity = _identity;
        weightReputation = _reputation;
        weightSybil = _sybil;
        weightHistory = _history;
        weightChallenge = _challenge;

        emit WeightsUpdated(_identity, _reputation, _sybil, _history, _challenge);
    }
}
