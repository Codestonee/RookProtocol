// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/RookOracle.sol";
import "../src/RookEscrow.sol";
import "./mocks/MockUSDC.sol";

contract RookOracleTest is Test {
    RookOracle public oracle;
    RookEscrow public escrow;
    MockUSDC public usdc;
    
    address public owner = address(1);
    address public operator = address(2);
    address public agent = address(3);
    
    function setUp() public {
        vm.startPrank(owner);
        
        usdc = new MockUSDC(1_000_000 * 10**6);
        oracle = new RookOracle(address(0));
        escrow = new RookEscrow(address(usdc), address(oracle));
        oracle.setEscrow(address(escrow));
        oracle.setOperator(operator, true);
        
        vm.stopPrank();
    }
    
    function test_UpdateScores() public {
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 50);
        
        assertEq(oracle.identityScores(agent), 80);
        assertEq(oracle.reputationScores(agent), 70);
        assertEq(oracle.sybilScores(agent), 60);
        assertEq(oracle.challengeBonuses(agent), 50);
    }
    
    function test_ComputeTrustScore() public {
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 50);
        
        // (80 * 25 + 70 * 25 + 60 * 20 + 50 * 20 + 50 * 10) / 100
        // = (2000 + 1750 + 1200 + 1000 + 500) / 100 = 6450 / 100 = 64.5
        // But with default history of 50 for new agent:
        // = (2000 + 1750 + 1200 + 1000 + 500) / 100 = 64.5
        uint256 score = oracle.computeTrustScore(agent);
        assertEq(score, 64);
    }
    
    function test_GetScoreBreakdown() public {
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 50);
        
        (
            uint256 identity,
            uint256 reputation,
            uint256 sybil,
            uint256 history,
            uint256 challengeBonus,
            uint256 composite
        ) = oracle.getScoreBreakdown(agent);
        
        assertEq(identity, 80);
        assertEq(reputation, 70);
        assertEq(sybil, 60);
        assertEq(history, 50); // Default for new agent
        assertEq(challengeBonus, 50);
        assertEq(composite, 64);
    }
    
    function test_Revert_NotOperator() public {
        vm.prank(address(0x999));
        vm.expectRevert(RookOracle.NotOperator.selector);
        oracle.updateScores(agent, 80, 70, 60, 50);
    }
    
    function test_Revert_InvalidScore() public {
        vm.prank(operator);
        vm.expectRevert(RookOracle.InvalidScore.selector);
        oracle.updateScores(agent, 101, 70, 60, 50);
    }
    
    function test_SetOperator() public {
        address newOperator = address(0x999);

        vm.prank(owner);
        oracle.setOperator(newOperator, true);

        assertTrue(oracle.operators(newOperator));
    }

    // ═══════════════════════════════════════════════════════════════
    // PR#2: STALENESS & SECURITY TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_ComputeTrustScore_StaleData() public {
        // Update scores
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 50);

        // Score should be valid initially
        uint256 score1 = oracle.computeTrustScore(agent);
        assertGt(score1, 0);

        // Fast forward past staleness threshold (1 hour)
        vm.warp(block.timestamp + 1 hours + 1);

        // Score should now return 0 (conservative default)
        uint256 score2 = oracle.computeTrustScore(agent);
        assertEq(score2, 0);
    }

    function test_Revert_TriggerRelease_StaleScore() public {
        // Create escrow
        address testBuyer = address(0x100);
        address testSeller = address(0x200);
        usdc.transfer(testBuyer, 1000 * 10**6);

        vm.startPrank(testBuyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(testSeller, 100 * 10**6, keccak256("job"), 65);
        vm.stopPrank();

        // Update scores
        vm.prank(operator);
        oracle.updateScores(testSeller, 80, 80, 80, 0);

        // Fast forward past staleness threshold
        vm.warp(block.timestamp + 1 hours + 1);

        // Try to trigger release with stale score (should fail)
        vm.prank(operator);
        vm.expectRevert(RookOracle.StaleScore.selector);
        oracle.triggerRelease(escrowId);
    }

    function test_ComputeTrustScore_NoDataReturnsZero() public {
        address newAgent = address(0x999);

        // Agent has never had scores updated
        uint256 score = oracle.computeTrustScore(newAgent);

        // Should return conservative 0 score
        assertEq(score, 0);
    }

    function test_GetScoreBreakdown_StaleData() public {
        // Update scores
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 50);

        // Fast forward past staleness threshold
        vm.warp(block.timestamp + 1 hours + 1);

        // Get score breakdown
        (,,,,, uint256 composite) = oracle.getScoreBreakdown(agent);

        // Composite should be 0 due to staleness
        assertEq(composite, 0);
    }

    /**
     * MEDIUM FIX: Test configurable weights - valid update
     */
    function test_SetWeights_Valid() public {
        vm.prank(owner);
        oracle.setWeights(25, 25, 25, 20, 5); // Sum = 100

        assertEq(oracle.weightIdentity(), 25);
        assertEq(oracle.weightReputation(), 25);
        assertEq(oracle.weightSybil(), 25);
        assertEq(oracle.weightHistory(), 20);
        assertEq(oracle.weightChallenge(), 5);
    }

    /**
     * MEDIUM FIX: Test configurable weights - invalid sum
     */
    function test_Revert_SetWeights_InvalidSum() public {
        vm.prank(owner);
        vm.expectRevert(RookOracle.InvalidWeights.selector);
        oracle.setWeights(30, 30, 30, 20, 5); // Sum = 115 (invalid)
    }

    /**
     * MEDIUM FIX: Test configurable weights - all weight to identity
     */
    function test_SetWeights_AllToIdentity() public {
        vm.prank(owner);
        oracle.setWeights(100, 0, 0, 0, 0); // All to identity

        vm.prank(operator);
        oracle.updateScores(agent, 80, 60, 40, 20);

        uint256 score = oracle.computeTrustScore(agent);
        assertEq(score, 80); // 80 * 100/100 = 80
    }

    /**
     * MEDIUM FIX: Test configurable weights - zero weights except history
     */
    function test_SetWeights_OnlyHistory() public {
        vm.prank(owner);
        oracle.setWeights(0, 0, 0, 100, 0); // All to history

        vm.prank(operator);
        oracle.updateScores(agent, 80, 60, 40, 20);

        // History score is calculated from escrow completion rate
        // With zero escrows, historyScore = 50 (neutral)
        uint256 score = oracle.computeTrustScore(agent);
        assertEq(score, 50); // 50 * 100/100 = 50
    }

    /**
     * MEDIUM FIX: Test configurable weights - non-owner cannot set
     */
    function test_Revert_SetWeights_NotOwner() public {
        vm.prank(operator);
        vm.expectRevert();
        oracle.setWeights(25, 25, 25, 20, 5);
    }
}
