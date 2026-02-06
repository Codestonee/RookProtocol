// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IRookOracle {
    // Score management
    function updateScores(
        address agent,
        uint256 identity,
        uint256 reputation,
        uint256 sybil,
        uint256 challengeBonus
    ) external;

    function batchUpdateScores(
        address[] calldata agents,
        uint256[] calldata identities,
        uint256[] calldata reputations,
        uint256[] calldata sybils,
        uint256[] calldata bonuses
    ) external;

    // Score queries
    function computeTrustScore(address agent) external view returns (uint256);
    function getHistoryScore(address agent) external view returns (uint256);
    function isScoreFresh(address agent) external view returns (bool);

    function getScoreBreakdown(address agent) external view returns (
        uint256 identity,
        uint256 reputation,
        uint256 sybil,
        uint256 history,
        uint256 challengeBonus,
        uint256 composite
    );

    // Actions
    function triggerRelease(bytes32 escrowId) external;
    function resolveChallenge(bytes32 escrowId, bool passed) external;

    // Configuration
    function setOperator(address operator, bool status) external;
    function setEscrow(address _escrow) external;
    function setWeights(uint256 _identity, uint256 _reputation, uint256 _sybil, uint256 _history, uint256 _challenge) external;
    function setRegistries(address _identity, address _reputation) external;
}
