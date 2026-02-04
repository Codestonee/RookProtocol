// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IRookEscrow {
    enum EscrowStatus { Active, Released, Refunded, Disputed, Challenged }
    
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
    
    function getEscrow(bytes32 escrowId) external view returns (Escrow memory);
    function releaseEscrow(bytes32 escrowId, uint256 trustScore) external;
    function resolveChallenge(bytes32 escrowId, bool passed) external;
    function getCompletionRate(address agent) external view returns (uint256);
}
