// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/RookEscrow.sol";
import "../src/RookOracle.sol";
import "../test/mocks/MockUSDC.sol";

/**
 * @notice Demo script showing a full escrow flow
 * @dev Run with: forge script script/Demo.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast
 */
contract DemoScript is Script {
    function run() external {
        uint256 buyerKey = vm.envUint("PRIVATE_KEY");
        address escrowAddress = vm.envAddress("ROOK_ESCROW_ADDRESS");
        address oracleAddress = vm.envAddress("ROOK_ORACLE_ADDRESS");
        
        RookEscrow escrow = RookEscrow(escrowAddress);
        RookOracle oracle = RookOracle(oracleAddress);
        
        address seller = vm.envAddress("TEST_ACCOUNT_1");
        address challenger = vm.envAddress("TEST_ACCOUNT_2");
        
        console.log("=== Rook Protocol Demo ===");
        console.log("Buyer:", vm.addr(buyerKey));
        console.log("Seller:", seller);
        console.log("Challenger:", challenger);
        
        // Step 1: Create escrow
        vm.startBroadcast(buyerKey);
        
        uint256 amount = 50 * 10**6; // 50 USDC
        bytes32 jobHash = keccak256("Market data analysis");
        uint256 threshold = 65;
        
        console.log("\n1. Creating escrow...");
        console.log("   Amount:", amount / 10**6, "USDC");
        console.log("   Threshold:", threshold);
        
        // Note: Buyer must approve USDC before calling this
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, threshold);
        console.log("   Escrow ID:", vm.toString(escrowId));
        
        vm.stopBroadcast();
        
        // Step 2: Update seller scores (oracle operator)
        uint256 operatorKey = vm.envUint("OPERATOR_KEY");
        vm.startBroadcast(operatorKey);
        
        console.log("\n2. Updating seller trust scores...");
        oracle.updateScores(seller, 85, 75, 80, 0);
        
        uint256 trustScore = oracle.computeTrustScore(seller);
        console.log("   Computed trust score:", trustScore);
        
        vm.stopBroadcast();
        
        // Step 3: Release escrow (oracle-triggered)
        vm.startBroadcast(operatorKey);
        
        console.log("\n3. Releasing escrow...");
        console.log("   Trust score (70) >= Threshold (65):", trustScore >= threshold);
        
        escrow.releaseEscrow(escrowId, uint256(70));
        console.log("   Escrow released to seller!");
        
        vm.stopBroadcast();
        
        console.log("\n=== Demo Complete ===");
        console.log("Funds released based on trust verification!");
    }
}
