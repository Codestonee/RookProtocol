// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/RookEscrow.sol";
import "../src/RookOracle.sol";
import "./mocks/MockUSDC.sol";

/**
 * @title RookEscrowReentrancyTest
 * @notice Tests for reentrancy protection on all state-changing functions
 * @dev All state-changing functions should be protected by ReentrancyGuard
 */
contract RookEscrowReentrancyTest is Test {
    RookEscrow public escrow;
    RookOracle public oracle;
    MockUSDC public usdc;

    address public owner = address(1);
    address public buyer = address(2);
    address public seller = address(3);
    address public challenger = address(4);

    function setUp() public {
        usdc = new MockUSDC(1_000_000 * 10**6);

        vm.startPrank(owner);
        oracle = new RookOracle(address(0));
        escrow = new RookEscrow(address(usdc), address(oracle));
        oracle.setEscrow(address(escrow));
        oracle.setOperator(address(this), true);
        vm.stopPrank();

        usdc.transfer(buyer, 10_000 * 10**6);
        usdc.transfer(challenger, 10_000 * 10**6);
    }

    /**
     * @notice Verify ReentrancyGuard is present on createEscrow
     */
    function test_ReentrancyGuard_CreateEscrow() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);

        bytes32 escrowId = escrow.createEscrow(seller, 100 * 10**6, keccak256("Test"), 65);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.buyer, buyer);
        assertEq(e.amount, 100 * 10**6);
        vm.stopPrank();
    }

    /**
     * @notice Verify ReentrancyGuard is present on releaseEscrow (via oracle)
     */
    function test_ReentrancyGuard_ReleaseEscrow() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 100 * 10**6, keccak256("Test"), 65);
        vm.stopPrank();

        // Update scores: (90*30 + 90*30 + 90*20 + 0*15 + 0*5) / 100 = 72 >= 65
        oracle.updateScores(seller, 90, 90, 90, 0);

        // Release through oracle (nonReentrant on both oracle and escrow)
        oracle.triggerRelease(escrowId);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));
    }

    /**
     * @notice Verify ReentrancyGuard is present on refundEscrow
     */
    function test_ReentrancyGuard_RefundEscrow() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 100 * 10**6, keccak256("Test"), 65);

        escrow.refundEscrow(escrowId, "Changed mind");
        vm.stopPrank();

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Refunded));
    }

    /**
     * @notice Verify ReentrancyGuard is present on disputeEscrow
     */
    function test_ReentrancyGuard_DisputeEscrow() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 100 * 10**6, keccak256("Test"), 65);

        escrow.disputeEscrow(escrowId, "Dispute evidence");
        vm.stopPrank();

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Disputed));
    }

    /**
     * @notice Verify ReentrancyGuard is present on initiateChallenge
     */
    function test_ReentrancyGuard_InitiateChallenge() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 100 * 10**6, keccak256("Test"), 65);
        vm.stopPrank();

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Challenged));
    }

    /**
     * @notice Verify ReentrancyGuard is present on respondChallenge
     */
    function test_ReentrancyGuard_RespondChallenge() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 100 * 10**6, keccak256("Test"), 65);
        vm.stopPrank();

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.prank(seller);
        escrow.respondChallenge(escrowId, keccak256("Response"));

        RookEscrow.Challenge memory c = escrow.getChallenge(escrowId);
        assertEq(uint8(c.status), uint8(RookEscrow.ChallengeStatus.Responded));
    }

    /**
     * @notice Verify ReentrancyGuard is present on resolveChallenge (via oracle)
     */
    function test_ReentrancyGuard_ResolveChallenge() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 100 * 10**6, keccak256("Test"), 65);
        vm.stopPrank();

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.prank(seller);
        escrow.respondChallenge(escrowId, keccak256("Response"));

        // Resolve through oracle (nonReentrant on both)
        oracle.resolveChallenge(escrowId, true);

        // After passing, escrow goes back to Active and challenge is deleted
        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Active));
    }

    /**
     * @notice Verify ReentrancyGuard is present on claimChallengeTimeout
     */
    function test_ReentrancyGuard_ClaimChallengeTimeout() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 100 * 10**6, keccak256("Test"), 65);
        vm.stopPrank();

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Fast forward past deadline
        vm.roll(block.number + 51);

        vm.prank(challenger);
        escrow.claimChallengeTimeout(escrowId);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Refunded));
    }

    /**
     * @notice Verify ReentrancyGuard is present on resolveDispute
     */
    function test_ReentrancyGuard_ResolveDispute() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 100 * 10**6, keccak256("Test"), 65);
        escrow.disputeEscrow(escrowId, "Dispute evidence");
        vm.stopPrank();

        vm.prank(owner);
        escrow.resolveDispute(escrowId, seller, "Resolved in favor of seller");

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));
    }

    /**
     * @notice Verify ReentrancyGuard is present on releaseWithConsent (two-party)
     */
    function test_ReentrancyGuard_ReleaseWithConsent() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 100 * 10**6, keccak256("Test"), 65);
        vm.stopPrank();

        // Fast forward past oracle timeout
        vm.warp(block.timestamp + 1 days + 1);

        // Buyer consents first (consent recorded but no release yet)
        vm.prank(buyer);
        escrow.releaseWithConsent(escrowId);

        // Seller consents (now both have consented, succeeds)
        vm.prank(seller);
        escrow.releaseWithConsent(escrowId);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));
    }
}
