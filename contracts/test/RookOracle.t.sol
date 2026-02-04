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
}
