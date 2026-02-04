import { Request, Response } from 'express';
import { ethers } from 'ethers';
import { config } from '../utils/config';
import { ScoringService } from '../services/scoring';
import { logger } from '../utils/logger';

export async function verifyHandler(req: Request, res: Response) {
  try {
    const { agent, moltbookHandle } = req.body;

    if (!agent) {
      return res.status(400).json({ error: 'Agent address required' });
    }

    // Validate address
    if (!ethers.isAddress(agent)) {
      return res.status(400).json({ error: 'Invalid agent address' });
    }

    const provider = new ethers.JsonRpcProvider(
      config.rpcUrl || 'https://sepolia.base.org'
    );

    const scoring = new ScoringService(
      provider,
      config.escrowAddress!,
      undefined, // ERC-8004 identity
      undefined, // ERC-8004 reputation
      config.moltbookApiKey
    );

    const score = await scoring.calculateScore(agent, moltbookHandle);

    res.json({
      agent,
      score,
      timestamp: Date.now()
    });
  } catch (error: any) {
    logger.error('Verify handler error:', error);
    res.status(500).json({ error: error.message || 'Internal server error' });
  }
}
