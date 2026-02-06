// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IRookEscrow {
    enum EscrowStatus { Active, Released, Refunded, Disputed, Challenged }
    enum ChallengeStatus { None, Initiated, Responded }

    struct Escrow {
        address buyer;
        address seller;
        uint256 amount;
        bytes32 jobHash;
        uint256 trustThreshold;
        uint256 createdAt;
        uint256 expiresAt;
        EscrowStatus status;
    }

    struct Challenge {
        address challenger;
        uint256 stake;
        uint256 deadline;
        bytes32 responseHash;
        ChallengeStatus status;
    }

    struct Dispute {
        string evidence;
        uint256 filedAt;
    }

    // Escrow lifecycle
    function createEscrow(address seller, uint256 amount, bytes32 jobHash, uint256 trustThreshold) external returns (bytes32);
    function releaseEscrow(bytes32 escrowId, uint256 trustScore) external;
    function releaseWithConsent(bytes32 escrowId) external;
    function refundEscrow(bytes32 escrowId, string calldata reason) external;
    function claimExpired(bytes32 escrowId) external;

    // Disputes
    function disputeEscrow(bytes32 escrowId, string calldata evidence) external;
    function resolveDispute(bytes32 escrowId, address winner, string calldata reason) external;
    function executeDisputeResolution(bytes32 escrowId) external;
    function cancelDisputeResolution(bytes32 escrowId) external;

    // Challenges
    function initiateChallenge(bytes32 escrowId) external;
    function respondChallenge(bytes32 escrowId, bytes32 responseHash) external;
    function resolveChallenge(bytes32 escrowId, bool passed) external;
    function claimChallengeTimeout(bytes32 escrowId) external;

    // Views
    function getEscrow(bytes32 escrowId) external view returns (Escrow memory);
    function getChallenge(bytes32 escrowId) external view returns (Challenge memory);
    function getDispute(bytes32 escrowId) external view returns (Dispute memory);
    function getBuyerEscrows(address buyer) external view returns (bytes32[] memory);
    function getSellerEscrows(address seller) external view returns (bytes32[] memory);
    function getCompletionRate(address agent) external view returns (uint256);
    function getNextChallengeTime(address challenger) external view returns (uint256);
    function totalEscrows(address agent) external view returns (uint256);
    function completedEscrows(address agent) external view returns (uint256);
    function totalFeesCollected() external view returns (uint256);
}
