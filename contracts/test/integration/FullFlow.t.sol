// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../src/RookEscrow.sol";
import "../../src/RookOracle.sol";
import "../mocks/MockUSDC.sol";

/**
 * @title FullFlowIntegrationTest
 * @notice End-to-end integration tests for complete escrow lifecycle
 * @dev Tests interaction between RookEscrow and RookOracle with all improvements
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
        usdc = new MockUSDC(10_000_000 * 10**6);

        vm.startPrank(owner);
        oracle = new RookOracle(address(0));
        escrow = new RookEscrow(address(usdc), address(oracle));
        oracle.setEscrow(address(escrow));
        oracle.setOperator(operator, true);
        vm.stopPrank();

        usdc.transfer(buyer, 100_000 * 10**6);
        usdc.transfer(challenger, 10_000 * 10**6);
    }

    /**
     * @notice Test complete happy path: create → update scores → release
     */
    function test_FullFlow_HappyPath() public {
        // 1. Buyer creates escrow
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);
        vm.stopPrank();

        // 2. Operator updates seller scores
        vm.prank(operator);
        oracle.updateScores(seller, 95, 90, 85, 0);

        // Verify score freshness
        assertTrue(oracle.isScoreFresh(seller));

        // Score = (95*30 + 90*30 + 85*20 + 0*15 + 0*5) / 100
        // = (2850 + 2700 + 1700 + 0 + 0) / 100 = 72 (history=0, seller has active escrow)
        uint256 trustScore = oracle.computeTrustScore(seller);
        assertEq(trustScore, 72);

        // 3. Operator triggers release (threshold = 70, score = 72, passes)
        vm.prank(operator);
        oracle.triggerRelease(escrowId);

        // Verify seller received funds minus protocol fee (0.5%)
        uint256 expectedFee = (1000 * 10**6 * 50) / 10000;
        assertEq(usdc.balanceOf(seller), 1000 * 10**6 - expectedFee);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));
    }

    /**
     * @notice Test stale score prevention
     */
    function test_FullFlow_StaleScorePrevention() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);
        vm.stopPrank();

        vm.prank(operator);
        oracle.updateScores(seller, 95, 90, 85, 0);

        // Advance time past staleness threshold (1 hour)
        vm.warp(block.timestamp + 1 hours + 1);

        assertFalse(oracle.isScoreFresh(seller));

        // Release fails with StaleScore
        vm.prank(operator);
        vm.expectRevert(RookOracle.StaleScore.selector);
        oracle.triggerRelease(escrowId);

        // Refresh scores
        vm.prank(operator);
        oracle.updateScores(seller, 95, 90, 85, 0);

        // Now release succeeds
        vm.prank(operator);
        oracle.triggerRelease(escrowId);

        uint256 expectedFee = (1000 * 10**6 * 50) / 10000;
        assertEq(usdc.balanceOf(seller), 1000 * 10**6 - expectedFee);
    }

    /**
     * @notice Test challenge flow: initiate → respond → oracle resolves (pass)
     */
    function test_FullFlow_ChallengeAndPass() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);
        vm.stopPrank();

        // Initiate challenge
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Seller responds within window
        vm.prank(seller);
        escrow.respondChallenge(escrowId, keccak256("Valid response"));

        // Oracle resolves challenge (passed)
        vm.prank(operator);
        oracle.resolveChallenge(escrowId, true);

        // Verify escrow is back to Active
        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Active));

        // Verify stake returned to challenger
        assertGt(usdc.balanceOf(challenger), 0);

        // Verify challenge bonus was updated for seller
        assertEq(oracle.challengeBonuses(seller), 100);
    }

    /**
     * @notice Test challenge flow: initiate → oracle resolves (fail)
     */
    function test_FullFlow_ChallengeAndFail() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);
        vm.stopPrank();

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 challengerBefore = usdc.balanceOf(challenger);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Oracle resolves (failed)
        vm.prank(operator);
        oracle.resolveChallenge(escrowId, false);

        // Buyer gets full refund
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 1000 * 10**6);

        // Challenger gets stake back (net zero)
        assertEq(usdc.balanceOf(challenger), challengerBefore);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Refunded));
    }

    /**
     * @notice Test configurable weights
     */
    function test_FullFlow_ConfigurableWeights() public {
        // Update weights to favor identity
        vm.prank(owner);
        oracle.setWeights(40, 25, 20, 10, 5);

        assertEq(oracle.weightIdentity(), 40);
        assertEq(oracle.weightReputation(), 25);

        // Update scores
        vm.prank(operator);
        oracle.updateScores(seller, 90, 50, 50, 0);

        // Score = (90*40 + 50*25 + 50*20 + 40*10 + 0*5) / 100
        // = (3600 + 1250 + 1000 + 400 + 0) / 100 = 62 (history=DEFAULT_HISTORY_SCORE=40, seller has no escrows)
        uint256 score = oracle.computeTrustScore(seller);
        assertEq(score, 62);
        assertGt(score, 50);
    }

    /**
     * @notice Test dispute resolution flow
     */
    function test_FullFlow_DisputeResolution() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);

        escrow.disputeEscrow(escrowId, "Evidence IPFS hash");
        vm.stopPrank();

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Disputed));

        // Owner resolves in favor of seller (no fee on dispute resolution)
        vm.prank(owner);
        escrow.resolveDispute(escrowId, seller, "Valid delivery");

        // Seller gets full amount (dispute resolution has no fee)
        assertEq(usdc.balanceOf(seller), 1000 * 10**6);
    }

    /**
     * @notice Test multiple escrows with different outcomes
     */
    function test_FullFlow_MultipleEscrows() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 3000 * 10**6);

        bytes32 escrowId1 = escrow.createEscrow(seller, 1000 * 10**6, keccak256("Task 1"), 70);
        bytes32 escrowId2 = escrow.createEscrow(seller, 1000 * 10**6, keccak256("Task 2"), 70);
        bytes32 escrowId3 = escrow.createEscrow(seller, 1000 * 10**6, keccak256("Task 3"), 70);
        vm.stopPrank();

        // Update scores (history=0, seller has active escrows)
        vm.prank(operator);
        oracle.updateScores(seller, 95, 90, 85, 0);

        // Escrow 1: Released via oracle
        vm.prank(operator);
        oracle.triggerRelease(escrowId1);

        // Escrow 2: Refunded by buyer
        vm.prank(buyer);
        escrow.refundEscrow(escrowId2, "Not needed");

        // Escrow 3: Challenged
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId3);
        vm.stopPrank();

        // Verify completion rate (basis points): 1/3 = 3333
        uint256 completionRate = escrow.getCompletionRate(seller);
        assertEq(completionRate, 3333);
    }

    /**
     * @notice Test two-party consent release flow
     */
    function test_FullFlow_ConsentRelease() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);
        vm.stopPrank();

        // Fast forward past oracle timeout (1 day)
        vm.warp(block.timestamp + 1 days + 1);

        // Buyer consents first (consent recorded but no release yet)
        vm.prank(buyer);
        escrow.releaseWithConsent(escrowId);

        // Seller consents (both have now consented, succeeds)
        vm.prank(seller);
        escrow.releaseWithConsent(escrowId);

        uint256 expectedFee = (1000 * 10**6 * 50) / 10000;
        assertEq(usdc.balanceOf(seller), 1000 * 10**6 - expectedFee);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));
    }

    /**
     * @notice Test protocol fee collection during release
     */
    function test_FullFlow_ProtocolFeeCollection() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);
        vm.stopPrank();

        vm.prank(operator);
        oracle.updateScores(seller, 95, 90, 85, 0);

        uint256 ownerBefore = usdc.balanceOf(owner);

        vm.prank(operator);
        oracle.triggerRelease(escrowId);

        // Fee = 0.5% of 1000 USDC = 5 USDC
        uint256 expectedFee = (1000 * 10**6 * 50) / 10000;
        assertEq(usdc.balanceOf(owner) - ownerBefore, expectedFee);
        assertEq(escrow.totalFeesCollected(), expectedFee);
    }

    /**
     * @notice Test batch score update followed by release
     */
    function test_FullFlow_BatchScoreUpdate() public {
        address seller2 = address(0x10);
        address seller3 = address(0x11);

        address[] memory agents = new address[](3);
        agents[0] = seller;
        agents[1] = seller2;
        agents[2] = seller3;

        uint256[] memory identities = new uint256[](3);
        identities[0] = 95;
        identities[1] = 70;
        identities[2] = 60;

        uint256[] memory reputations = new uint256[](3);
        reputations[0] = 90;
        reputations[1] = 65;
        reputations[2] = 55;

        uint256[] memory sybils = new uint256[](3);
        sybils[0] = 85;
        sybils[1] = 70;
        sybils[2] = 65;

        uint256[] memory bonuses = new uint256[](3);

        vm.prank(operator);
        oracle.batchUpdateScores(agents, identities, reputations, sybils, bonuses);

        // All agents should have fresh scores
        assertTrue(oracle.isScoreFresh(seller));
        assertTrue(oracle.isScoreFresh(seller2));
        assertTrue(oracle.isScoreFresh(seller3));

        // Create and release escrow using batch-updated scores
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("BatchTask"), 70);
        vm.stopPrank();

        vm.prank(operator);
        oracle.triggerRelease(escrowId);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));
    }

    /**
     * @notice Test challenge timeout flow
     */
    function test_FullFlow_ChallengeTimeout() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 1000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 1000 * 10**6, keccak256("AI Task"), 70);
        vm.stopPrank();

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 challengerBefore = usdc.balanceOf(challenger);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Seller doesn't respond, advance past deadline
        vm.roll(block.number + 51);

        // Challenger claims timeout
        vm.prank(challenger);
        escrow.claimChallengeTimeout(escrowId);

        // Buyer gets refund
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 1000 * 10**6);

        // Challenger gets stake back
        assertEq(usdc.balanceOf(challenger), challengerBefore);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Refunded));
    }
}
