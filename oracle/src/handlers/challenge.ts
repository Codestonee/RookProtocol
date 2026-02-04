import { Request, Response } from 'express';
import { ethers, Wallet } from 'ethers';
import { config } from '../utils/config';
import { ScoringService } from '../services/scoring';
import { logger } from '../utils/logger';

export async function challengeHandler(req: Request, res: Response) {
  try {
    const { escrowId, signature, expectedSigner, action } = req.body;

    if (!escrowId || !signature || !expectedSigner) {
      return res.status(400).json({ 
        error: 'escrowId, signature, and expectedSigner required' 
      });
    }

    const provider = new ethers.JsonRpcProvider(
      config.rpcUrl || 'https://sepolia.base.org'
    );

    const scoring = new ScoringService(
      provider,
      config.escrowAddress!,
      undefined,
      undefined,
      config.moltbookApiKey
    );

    // Verify the challenge signature
    const isValid = await scoring.verifyChallenge(escrowId, signature, expectedSigner);

    if (!isValid) {
      return res.json({
        escrowId,
        valid: false,
        message: 'Signature verification failed'
      });
    }

    // If verification passed and action is 'resolve', submit to contract
    if (action === 'resolve' && config.privateKey) {
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
