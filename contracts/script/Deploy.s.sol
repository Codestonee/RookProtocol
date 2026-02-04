// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/RookEscrow.sol";
import "../src/RookOracle.sol";
import "../test/mocks/MockUSDC.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Mock USDC (for testnet)
        MockUSDC usdc = new MockUSDC(1_000_000_000 * 10**6); // 1B USDC
        console.log("MockUSDC deployed at:", address(usdc));
        
        // Deploy Oracle first
        RookOracle oracle = new RookOracle(address(0));
        console.log("RookOracle deployed at:", address(oracle));
        
        // Deploy Escrow
        RookEscrow escrow = new RookEscrow(address(usdc), address(oracle));
        console.log("RookEscrow deployed at:", address(escrow));
        
        // Set escrow in oracle
        oracle.setEscrow(address(escrow));
        console.log("Oracle escrow set to:", address(escrow));
        
        // Mint some USDC to test accounts
        address testAccount1 = vm.envAddress("TEST_ACCOUNT_1");
        address testAccount2 = vm.envAddress("TEST_ACCOUNT_2");
        
        usdc.mint(testAccount1, 100_000 * 10**6);
        usdc.mint(testAccount2, 100_000 * 10**6);
        
        console.log("Test accounts funded");
        
        vm.stopBroadcast();
    }
}
