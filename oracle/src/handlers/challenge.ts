import { Request, Response } from 'express';
import { ethers, Wallet } from 'ethers';
import { config } from '../utils/config';
import { ScoringService } from '../services/scoring';
import { logger } from '../utils/logger';

// Escrow contract ABI for fetching escrow details
const escrowAbi = [
  'function getEscrow(bytes32 escrowId) view returns (tuple(address buyer, address seller, uint256 amount, bytes32 jobHash, uint256 trustThreshold, uint8 status, uint256 createdAt, uint256 expiresAt))'
];

export async function challengeHandler(req: Request, res: Response) {
  try {
    const { escrowId, signature, action } = req.body;

    // CRITICAL FIX: Don't trust expectedSigner from request body
    if (!escrowId || !signature) {
      return res.status(400).json({ 
        error: 'escrowId and signature required' 
      });
    }

    const provider = new ethers.JsonRpcProvider(
      config.rpcUrl || 'https://sepolia.base.org'
    );

    // CRITICAL FIX: Fetch the seller address from the escrow contract on-chain
    if (!config.escrowAddress) {
      return res.status(500).json({
        error: 'Escrow contract address not configured'
      });
    }

    const escrowContract = new ethers.Contract(
      config.escrowAddress,
      escrowAbi,
      provider
    );

    let expectedSigner: string;
    try {
      const escrow = await escrowContract.getEscrow(escrowId);
      expectedSigner = escrow.seller;
      
      if (expectedSigner === ethers.ZeroAddress) {
        return res.status(404).json({
          error: 'Escrow not found or already resolved'
        });
      }
    } catch (err: any) {
      logger.error('Failed to fetch escrow from contract:', err);
      return res.status(500).json({
        error: 'Failed to fetch escrow from contract'
      });
    }

    const scoring = new ScoringService(
      provider,
      config.escrowAddress,
      undefined,
      undefined,
      config.moltbookApiKey
    );

    // Verify the challenge signature against the on-chain seller
    const isValid = await scoring.verifyChallenge(escrowId, signature, expectedSigner);

    if (!isValid) {
      return res.json({
        escrowId,
        valid: false,
        message: 'Signature verification failed - signer does not match escrow seller'
      });
    }

    // If verification passed and action is 'resolve', submit to contract
    if (action === 'resolve') {
      // CRITICAL FIX: Require private key for write operations
      if (!config.privateKey) {
        return res.status(403).json({
          escrowId,
          valid: true,
          resolved: false,
          error: 'Write operations disabled - no private key configured'
        });
      }

      const signer = new Wallet(config.privateKey, provider);
      
      const oracleAbi = [
        'function resolveChallenge(bytes32 escrowId, bool passed) external'
      ];
      
      const oracle = new ethers.Contract(config.oracleAddress!, oracleAbi, signer);
      
      const tx = await oracle.resolveChallenge(escrowId, true);
      await tx.wait();

      logger.info(`Challenge resolved on-chain: ${escrowId}`);

      return res.json({
        escrowId,
        valid: true,
        resolved: true,
        txHash: tx.hash
      });
    }

    res.json({
      escrowId,
      valid: true,
      resolved: false
    });
  } catch (error: any) {
    logger.error('Challenge handler error:', error);
    res.status(500).json({ error: error.message || 'Internal server error' });
  }
}
