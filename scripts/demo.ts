#!/usr/bin/env tsx

/**
 * Rook Protocol Demo Script
 * 
 * This script demonstrates a complete escrow flow:
 * 1. Create escrow
 * 2. Verify seller
 * 3. Challenge (optional)
 * 4. Release funds
 */

import { RookProtocol } from '../sdk/src/client';

async function sleep(ms: number) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function main() {
  console.log('♜ Rook Protocol Demo\n');
  
  // Configuration
  const config = {
    network: 'base-sepolia' as const,
    privateKey: process.env.PRIVATE_KEY!,
    rpcUrl: process.env.BASE_SEPOLIA_RPC
  };
  
  if (!config.privateKey) {
    console.error('Error: PRIVATE_KEY environment variable required');
    process.exit(1);
  }
  
  // Initialize
  console.log('Initializing Rook Protocol...');
  const rook = new RookProtocol(config);
  
  const sellerAddress = '0x1234567890123456789012345678901234567890';
  const buyerAddress = await rook['signer']!.getAddress();
  
  console.log(`Buyer: ${buyerAddress}`);
  console.log(`Seller: ${sellerAddress}\n`);
  
  // Step 1: Check buyer balance
  console.log('Step 1: Checking balance...');
  const balance = await rook.getBalance();
  console.log(`Balance: ${balance} USDC\n`);
  
  if (balance < 50) {
    console.error('Error: Insufficient balance (need at least 50 USDC)');
    process.exit(1);
  }
  
  // Step 2: Verify seller
  console.log('Step 2: Verifying seller...');
  try {
    const verification = await rook.verify(sellerAddress);
    console.log('Trust Score:', verification.trust_score);
    console.log('Risk Level:', verification.risk_level);
    console.log('Recommendation:', verification.recommendation);
    console.log('');
  } catch (e) {
    console.log('Note: Verification service not fully configured\n');
  }
  
  // Step 3: Create escrow
  console.log('Step 3: Creating escrow...');
  const escrow = await rook.createEscrow({
    amount: 50,
    recipient: sellerAddress,
    job: 'Demo: Market data analysis for ETH/BTC',
    threshold: 65
  });
  
  console.log('Escrow created!');
  console.log('  ID:', escrow.id);
  console.log('  Amount:', escrow.amount, 'USDC');
  console.log('  Threshold:', escrow.threshold);
  console.log('  TX Hash:', escrow.txHash);
  console.log('');
  
  // Step 4: Check escrow status
  console.log('Step 4: Checking escrow status...');
  const status = await rook.getEscrow(escrow.id);
  console.log('  Status:', status.status);
  console.log('  Buyer:', status.buyer);
  console.log('  Seller:', status.seller);
  console.log('');
  
  // Step 5: (Optional) Challenge
  console.log('Step 5: Challenge demonstration...');
  console.log('Skipping challenge for demo\n');
  
  // Step 6: Release (normally done by oracle)
  console.log('Step 6: Release would be triggered by oracle...');
  console.log('  - Oracle computes trust score');
  console.log('  - If score >= 65, funds auto-release to seller');
  console.log('  - If score < 65, manual review required\n');
  
  console.log('✅ Demo complete!');
  console.log('\nNext steps:');
  console.log('  - Check escrow on Base Sepolia explorer');
  console.log('  - Visit https://rook-protocol.xyz for more');
}

main().catch((error) => {
  console.error('Error:', error);
  process.exit(1);
});
