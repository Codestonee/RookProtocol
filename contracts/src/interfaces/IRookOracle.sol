// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IRookOracle {
    function computeTrustScore(address agent) external view returns (uint256);
    function updateScores(
        address agent,
        uint256 identity,
        uint256 reputation,
        uint256 sybil,
        uint256 challengeBonus
    ) external;
}
