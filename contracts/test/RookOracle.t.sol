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
        usdc = new MockUSDC(1_000_000 * 10**6);

        vm.startPrank(owner);
        oracle = new RookOracle(address(0));
        escrow = new RookEscrow(address(usdc), address(oracle));
        oracle.setEscrow(address(escrow));
        oracle.setOperator(operator, true);
        vm.stopPrank();
    }

    // =================================================================
    // SCORE MANAGEMENT
    // =================================================================

    function test_UpdateScores() public {
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 50);

        assertEq(oracle.identityScores(agent), 80);
        assertEq(oracle.reputationScores(agent), 70);
        assertEq(oracle.sybilScores(agent), 60);
        assertEq(oracle.challengeBonuses(agent), 50);
        assertGt(oracle.lastUpdated(agent), 0);
    }

    function test_ComputeTrustScore() public {
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 50);

        // Weights: identity=30, reputation=30, sybil=20, history=15, challenge=5
        // History = DEFAULT_HISTORY_SCORE = 40 (new agent, no escrows)
        // = (80*30 + 70*30 + 60*20 + 40*15 + 50*5) / 100
        // = (2400 + 2100 + 1200 + 600 + 250) / 100 = 6550 / 100 = 65
        uint256 score = oracle.computeTrustScore(agent);
        assertEq(score, 65);
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
        assertEq(history, 40); // DEFAULT_HISTORY_SCORE for new agent
        assertEq(challengeBonus, 50);
        assertEq(composite, 65);
    }

    function test_Revert_NotOperator() public {
        vm.prank(address(0x999));
        vm.expectRevert(RookOracle.NotOperator.selector);
        oracle.updateScores(agent, 80, 70, 60, 50);
    }

    function test_Revert_InvalidScore_Identity() public {
        vm.prank(operator);
        vm.expectRevert(RookOracle.InvalidScore.selector);
        oracle.updateScores(agent, 101, 70, 60, 50);
    }

    function test_Revert_InvalidScore_Reputation() public {
        vm.prank(operator);
        vm.expectRevert(RookOracle.InvalidScore.selector);
        oracle.updateScores(agent, 80, 101, 60, 50);
    }

    function test_Revert_InvalidScore_Sybil() public {
        vm.prank(operator);
        vm.expectRevert(RookOracle.InvalidScore.selector);
        oracle.updateScores(agent, 80, 70, 101, 50);
    }

    function test_Revert_InvalidScore_ChallengeBonus() public {
        vm.prank(operator);
        vm.expectRevert(RookOracle.InvalidScore.selector);
        oracle.updateScores(agent, 80, 70, 60, 101);
    }

    function test_Revert_UpdateScores_ZeroAddress() public {
        vm.prank(operator);
        vm.expectRevert(RookOracle.InvalidAddress.selector);
        oracle.updateScores(address(0), 80, 70, 60, 50);
    }

    function test_OwnerCanUpdateScores() public {
        vm.prank(owner);
        oracle.updateScores(agent, 80, 70, 60, 50);
        assertEq(oracle.identityScores(agent), 80);
    }

    function test_SetOperator() public {
        address newOperator = address(0x999);

        vm.prank(owner);
        oracle.setOperator(newOperator, true);

        assertTrue(oracle.operators(newOperator));
    }

    function test_Revert_SetOperator_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RookOracle.InvalidAddress.selector);
        oracle.setOperator(address(0), true);
    }

    // =================================================================
    // STALENESS & SECURITY
    // =================================================================

    function test_ComputeTrustScore_StaleData() public {
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 50);

        uint256 score1 = oracle.computeTrustScore(agent);
        assertGt(score1, 0);

        // Fast forward past staleness threshold (1 hour)
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 score2 = oracle.computeTrustScore(agent);
        assertEq(score2, 0);
    }

    function test_Revert_TriggerRelease_StaleScore() public {
        address testBuyer = address(0x100);
        address testSeller = address(0x200);
        usdc.transfer(testBuyer, 1000 * 10**6);

        vm.startPrank(testBuyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(testSeller, 100 * 10**6, keccak256("job"), 65);
        vm.stopPrank();

        vm.prank(operator);
        oracle.updateScores(testSeller, 80, 80, 80, 0);

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(operator);
        vm.expectRevert(RookOracle.StaleScore.selector);
        oracle.triggerRelease(escrowId);
    }

    function test_ComputeTrustScore_NoDataReturnsZero() public view {
        address newAgent = address(0x999);
        uint256 score = oracle.computeTrustScore(newAgent);
        assertEq(score, 0);
    }

    function test_GetScoreBreakdown_StaleData() public {
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 50);

        vm.warp(block.timestamp + 1 hours + 1);

        (,,,,, uint256 composite) = oracle.getScoreBreakdown(agent);
        assertEq(composite, 0);
    }

    function test_IsScoreFresh() public {
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 50);

        assertTrue(oracle.isScoreFresh(agent));

        vm.warp(block.timestamp + 1 hours + 1);

        assertFalse(oracle.isScoreFresh(agent));
    }

    function test_IsScoreFresh_NeverUpdated() public view {
        assertFalse(oracle.isScoreFresh(address(0x999)));
    }

    // =================================================================
    // CONFIGURABLE WEIGHTS
    // =================================================================

    function test_SetWeights_Valid() public {
        vm.prank(owner);
        oracle.setWeights(25, 25, 25, 20, 5);

        assertEq(oracle.weightIdentity(), 25);
        assertEq(oracle.weightReputation(), 25);
        assertEq(oracle.weightSybil(), 25);
        assertEq(oracle.weightHistory(), 20);
        assertEq(oracle.weightChallenge(), 5);
    }

    function test_Revert_SetWeights_InvalidSum() public {
        vm.prank(owner);
        vm.expectRevert(RookOracle.InvalidWeights.selector);
        oracle.setWeights(30, 30, 30, 20, 5); // Sum = 115
    }

    function test_SetWeights_AllToIdentity() public {
        vm.prank(owner);
        oracle.setWeights(100, 0, 0, 0, 0);

        vm.prank(operator);
        oracle.updateScores(agent, 80, 60, 40, 20);

        uint256 score = oracle.computeTrustScore(agent);
        assertEq(score, 80); // 80 * 100/100 = 80
    }

    function test_SetWeights_OnlyHistory() public {
        vm.prank(owner);
        oracle.setWeights(0, 0, 0, 100, 0);

        vm.prank(operator);
        oracle.updateScores(agent, 80, 60, 40, 20);

        // DEFAULT_HISTORY_SCORE = 40 for new agent
        uint256 score = oracle.computeTrustScore(agent);
        assertEq(score, 40); // 40 * 100/100 = 40
    }

    function test_Revert_SetWeights_NotOwner() public {
        vm.prank(operator);
        vm.expectRevert();
        oracle.setWeights(25, 25, 25, 20, 5);
    }

    // =================================================================
    // BATCH UPDATE SCORES
    // =================================================================

    function test_BatchUpdateScores() public {
        address agent2 = address(0x10);
        address agent3 = address(0x11);

        address[] memory agents = new address[](3);
        agents[0] = agent;
        agents[1] = agent2;
        agents[2] = agent3;

        uint256[] memory identities = new uint256[](3);
        identities[0] = 80;
        identities[1] = 70;
        identities[2] = 60;

        uint256[] memory reputations = new uint256[](3);
        reputations[0] = 75;
        reputations[1] = 65;
        reputations[2] = 55;

        uint256[] memory sybils = new uint256[](3);
        sybils[0] = 90;
        sybils[1] = 85;
        sybils[2] = 80;

        uint256[] memory bonuses = new uint256[](3);
        bonuses[0] = 0;
        bonuses[1] = 50;
        bonuses[2] = 100;

        vm.prank(operator);
        oracle.batchUpdateScores(agents, identities, reputations, sybils, bonuses);

        assertEq(oracle.identityScores(agent), 80);
        assertEq(oracle.identityScores(agent2), 70);
        assertEq(oracle.identityScores(agent3), 60);

        assertEq(oracle.reputationScores(agent2), 65);
        assertEq(oracle.sybilScores(agent3), 80);
        assertEq(oracle.challengeBonuses(agent3), 100);

        // All should be fresh
        assertTrue(oracle.isScoreFresh(agent));
        assertTrue(oracle.isScoreFresh(agent2));
        assertTrue(oracle.isScoreFresh(agent3));
    }

    function test_Revert_BatchUpdateScores_ArrayMismatch() public {
        address[] memory agents = new address[](2);
        agents[0] = agent;
        agents[1] = address(0x10);

        uint256[] memory identities = new uint256[](1); // Wrong length
        identities[0] = 80;

        uint256[] memory reputations = new uint256[](2);
        uint256[] memory sybils = new uint256[](2);
        uint256[] memory bonuses = new uint256[](2);

        vm.prank(operator);
        vm.expectRevert("Array length mismatch");
        oracle.batchUpdateScores(agents, identities, reputations, sybils, bonuses);
    }

    function test_Revert_BatchUpdateScores_ZeroAddress() public {
        address[] memory agents = new address[](1);
        agents[0] = address(0);

        uint256[] memory identities = new uint256[](1);
        uint256[] memory reputations = new uint256[](1);
        uint256[] memory sybils = new uint256[](1);
        uint256[] memory bonuses = new uint256[](1);

        vm.prank(operator);
        vm.expectRevert(RookOracle.InvalidAddress.selector);
        oracle.batchUpdateScores(agents, identities, reputations, sybils, bonuses);
    }

    function test_Revert_BatchUpdateScores_InvalidScore() public {
        address[] memory agents = new address[](1);
        agents[0] = agent;

        uint256[] memory identities = new uint256[](1);
        identities[0] = 101;

        uint256[] memory reputations = new uint256[](1);
        uint256[] memory sybils = new uint256[](1);
        uint256[] memory bonuses = new uint256[](1);

        vm.prank(operator);
        vm.expectRevert(RookOracle.InvalidScore.selector);
        oracle.batchUpdateScores(agents, identities, reputations, sybils, bonuses);
    }

    // =================================================================
    // CHALLENGE BONUS DECAY
    // =================================================================

    function test_ChallengeBonusDecay() public {
        // Set scores with bonus
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 100);

        uint256 bonusTimestamp = oracle.challengeBonusTimestamp(agent);
        assertGt(bonusTimestamp, 0);

        // Score with bonus: (80*30 + 70*30 + 60*20 + 40*15 + 100*5) / 100
        // = (2400 + 2100 + 1200 + 600 + 500) / 100 = 68
        assertEq(oracle.computeTrustScore(agent), 68);

        // Advance past bonus decay (30 days) and refresh scores WITHOUT bonus
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 0); // Refresh without bonus

        // challengeBonuses[agent] = 0, so bonus contributes nothing
        // Score: (80*30 + 70*30 + 60*20 + 40*15 + 0*5) / 100 = 63
        assertEq(oracle.computeTrustScore(agent), 63);
    }

    function test_ChallengeBonusActive() public {
        // Set scores with bonus
        vm.prank(operator);
        oracle.updateScores(agent, 80, 70, 60, 100);

        // Score with active bonus = 68
        assertEq(oracle.computeTrustScore(agent), 68);

        // Score without bonus would be 63
        // Difference = 5 (100 * 5 / 100 = 5 points from challenge weight)
    }

    // =================================================================
    // ADMIN
    // =================================================================

    function test_SetEscrow() public {
        address newEscrow = address(0xBEEF);

        vm.prank(owner);
        oracle.setEscrow(newEscrow);

        assertEq(address(oracle.escrow()), newEscrow);
    }

    function test_Revert_SetEscrow_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RookOracle.InvalidAddress.selector);
        oracle.setEscrow(address(0));
    }

    function test_Revert_SetEscrow_NotOwner() public {
        vm.prank(operator);
        vm.expectRevert();
        oracle.setEscrow(address(0xBEEF));
    }

    function test_SetRegistries() public {
        address identity = address(0x100);
        address reputation = address(0x200);

        vm.prank(owner);
        oracle.setRegistries(identity, reputation);

        assertEq(address(oracle.identityRegistry()), identity);
        assertEq(address(oracle.reputationRegistry()), reputation);
    }

    function test_Revert_SetRegistries_ZeroIdentity() public {
        vm.prank(owner);
        vm.expectRevert(RookOracle.InvalidAddress.selector);
        oracle.setRegistries(address(0), address(0x200));
    }

    function test_Revert_SetRegistries_ZeroReputation() public {
        vm.prank(owner);
        vm.expectRevert(RookOracle.InvalidAddress.selector);
        oracle.setRegistries(address(0x100), address(0));
    }

    // =================================================================
    // ESCROW TRIGGERS
    // =================================================================

    function test_TriggerRelease() public {
        address testBuyer = address(0x100);
        address testSeller = address(0x200);
        usdc.transfer(testBuyer, 1000 * 10**6);

        vm.startPrank(testBuyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(testSeller, 100 * 10**6, keccak256("job"), 65);
        vm.stopPrank();

        // Score = (90*30 + 90*30 + 90*20 + 0*15 + 0*5) / 100 = 72 (history=0, seller has active escrow)
        vm.prank(operator);
        oracle.updateScores(testSeller, 90, 90, 90, 0);

        vm.prank(operator);
        oracle.triggerRelease(escrowId);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));
    }

    function test_ResolveChallenge_Pass_UpdatesBonus() public {
        address testBuyer = address(0x100);
        address testSeller = address(0x200);
        address testChallenger = address(0x300);
        usdc.transfer(testBuyer, 1000 * 10**6);
        usdc.transfer(testChallenger, 100 * 10**6);

        vm.startPrank(testBuyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 escrowId = escrow.createEscrow(testSeller, 100 * 10**6, keccak256("job"), 65);
        vm.stopPrank();

        vm.startPrank(testChallenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.prank(testSeller);
        escrow.respondChallenge(escrowId, keccak256("response"));

        vm.prank(operator);
        oracle.resolveChallenge(escrowId, true);

        // Challenge bonus should be set for seller
        assertEq(oracle.challengeBonuses(testSeller), 100);
        assertGt(oracle.challengeBonusTimestamp(testSeller), 0);

        // Escrow should be back to Active
        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Active));
    }

    // =================================================================
    // FUZZ TESTS
    // =================================================================

    function testFuzz_UpdateScores(
        uint256 identity,
        uint256 reputation,
        uint256 sybil,
        uint256 bonus
    ) public {
        identity = bound(identity, 0, 100);
        reputation = bound(reputation, 0, 100);
        sybil = bound(sybil, 0, 100);
        bonus = bound(bonus, 0, 100);

        vm.prank(operator);
        oracle.updateScores(agent, identity, reputation, sybil, bonus);

        assertEq(oracle.identityScores(agent), identity);
        assertEq(oracle.reputationScores(agent), reputation);
        assertEq(oracle.sybilScores(agent), sybil);
        assertEq(oracle.challengeBonuses(agent), bonus);

        uint256 score = oracle.computeTrustScore(agent);
        assertLe(score, 100);
    }

    function testFuzz_SetWeights(
        uint256 w1,
        uint256 w2,
        uint256 w3,
        uint256 w4
    ) public {
        w1 = bound(w1, 0, 100);
        w2 = bound(w2, 0, 100 - w1);
        w3 = bound(w3, 0, 100 - w1 - w2);
        w4 = bound(w4, 0, 100 - w1 - w2 - w3);
        uint256 w5 = 100 - w1 - w2 - w3 - w4;

        vm.prank(owner);
        oracle.setWeights(w1, w2, w3, w4, w5);

        assertEq(oracle.weightIdentity(), w1);
        assertEq(oracle.weightReputation(), w2);
        assertEq(oracle.weightSybil(), w3);
        assertEq(oracle.weightHistory(), w4);
        assertEq(oracle.weightChallenge(), w5);
    }
}
