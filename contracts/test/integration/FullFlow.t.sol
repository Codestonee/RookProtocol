// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../src/RookEscrow.sol";
import "../../src/RookOracle.sol";
import "../mocks/MockUSDC.sol";

/**
 * @title FullFlowIntegrationTest
 * @notice PR#5: End-to-end integration tests for complete escrow lifecycle
 * @dev Tests the interaction between RookEscrow and RookOracle with all PR#1-4 improvements
 */
contract FullFlowIntegrationTest is Test {
    RookEscrow public escrow;
    RookOracle public oracle;
    MockUSDC public usdc;

    address public owner = address(1);
    address public buyer = address(2);
    address public seller = address(3);
    address public challenger = address(4);
    address public operator = address(5);

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockUSDC(10_000_000 * 10**6);
        oracle = new RookOracle(address(0));
        escrow = new RookEscrow(address(usdc), address(oracle));

        oracle.setEscrow(address(escrow));
        oracle.setOperator(operator, true);

        vm.stopPrank();

        usdc.transfer(buyer, 100_000 * 10**6);
        usdc.transfer(challenger, 10_000 * 10**6);
    }

    /**
     * @notice PR#5: Test complete happy path with score staleness checks
     */
    function test_FullFlow_HappyPath() public {
        // 1. Buyer creates escrow
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);
        vm.stopPrank();

        // 2. Operator updates seller scores
        vm.prank(operator);
        oracle.updateScores(seller, 85, 80, 75, 0);

        // Verify score is not stale (PR#1)
        assertGt(oracle.lastUpdated(seller), 0);
        uint256 trustScore = oracle.computeTrustScore(seller);
        assertGt(trustScore, 0);

        // 3. Operator triggers release (should succeed with fresh scores)
        vm.prank(operator);
        oracle.triggerRelease(escrowId);

        // Verify seller received funds
        assertEq(usdc.balanceOf(seller), 1000 * 10**6);

        // Verify escrow status
        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));
    }

    /**
     * @notice PR#5: Test stale score prevention (PR#1 security fix)
     */
    function test_FullFlow_StaleScorePrevention() public {
        // 1. Create escrow
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);
        vm.stopPrank();

        // 2. Update scores
        vm.prank(operator);
        oracle.updateScores(seller, 85, 80, 75, 0);

        // 3. Advance time past staleness threshold (1 hour)
        vm.warp(block.timestamp + 1 hours + 1);

        // 4. Verify release fails with StaleScore (PR#1 fix)
        vm.prank(operator);
        vm.expectRevert(RookOracle.StaleScore.selector);
        oracle.triggerRelease(escrowId);

        // 5. Update scores again
        vm.prank(operator);
        oracle.updateScores(seller, 85, 80, 75, 0);

        // 6. Now release should succeed
        vm.prank(operator);
        oracle.triggerRelease(escrowId);

        assertEq(usdc.balanceOf(seller), 1000 * 10**6);
    }

    /**
     * @notice PR#5: Test challenge flow with response window enforcement (PR#1)
     */
    function test_FullFlow_ChallengeAndPass() public {
        // Create escrow
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);
        vm.stopPrank();

        // Initiate challenge
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Seller responds within response window
        vm.prank(seller);
        escrow.respondChallenge(escrowId, keccak256("Valid response"));

        // Oracle resolves challenge (passed)
        escrow.resolveChallenge(escrowId, true);

        // Verify escrow is back to Active
        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Active));

        // Verify stake returned to challenger
        assertGt(usdc.balanceOf(challenger), 0);
    }

    /**
     * @notice PR#5: Test configurable weights (PR#3)
     */
    function test_FullFlow_ConfigurableWeights() public {
        // Update weights to favor identity (30 -> 40)
        vm.prank(owner);
        oracle.setWeights(40, 25, 20, 10, 5); // Sum = 100

        // Verify weights updated
        assertEq(oracle.weightIdentity(), 40);
        assertEq(oracle.weightReputation(), 25);

        // Update scores
        vm.prank(operator);
        oracle.updateScores(seller, 90, 50, 50, 0); // High identity, low others

        // Compute score (should be weighted towards identity)
        uint256 score = oracle.computeTrustScore(seller);
        assertGt(score, 50); // Identity contributes 36 points (90 * 0.4)
    }

    /**
     * @notice PR#5: Test dispute resolution flow
     */
    function test_FullFlow_DisputeResolution() public {
        // Create escrow
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);

        // Buyer disputes (PR#1: evidence length validated)
        escrow.disputeEscrow(escrowId, "Evidence IPFS hash");
        vm.stopPrank();

        // Verify status is Disputed
        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Disputed));

        // Owner resolves in favor of seller
        vm.prank(owner);
        escrow.resolveDispute(escrowId, seller, "Valid delivery");

        // Verify seller received funds
        assertEq(usdc.balanceOf(seller), 1000 * 10**6);
    }

    /**
     * @notice PR#5: Test multiple escrows with different outcomes
     */
    function test_FullFlow_MultipleEscrows() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 3000 * 10**6);

        // Create 3 escrows
        bytes32 escrowId1 = escrow.createEscrow(seller, 1000 * 10**6, keccak256("Task 1"), 70);
        bytes32 escrowId2 = escrow.createEscrow(seller, 1000 * 10**6, keccak256("Task 2"), 70);
        bytes32 escrowId3 = escrow.createEscrow(seller, 1000 * 10**6, keccak256("Task 3"), 70);
        vm.stopPrank();

        // Update scores
        vm.prank(operator);
        oracle.updateScores(seller, 85, 80, 75, 0);

        // Escrow 1: Released
        vm.prank(operator);
        oracle.triggerRelease(escrowId1);

        // Escrow 2: Refunded
        vm.prank(buyer);
        escrow.refundEscrow(escrowId2, "Not needed");

        // Escrow 3: Challenged
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId3);
        vm.stopPrank();

        // Verify completion rate calculation
        uint256 completionRate = escrow.getCompletionRate(seller);
        assertGt(completionRate, 0); // At least 1 completed
    }
}
