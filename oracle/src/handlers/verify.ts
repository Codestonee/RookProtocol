import { Request, Response } from 'express';
import { ethers } from 'ethers';
import { ScoringService } from '../services/scoring';
import { logger } from '../utils/logger';

export function createVerifyHandler(scoring: ScoringService | null) {
  return async function verifyHandler(req: Request, res: Response) {
    try {
      const { agent, moltbookHandle } = req.body;

      if (!agent) {
        return res.status(400).json({ error: 'Agent address required' });
      }

      if (!ethers.isAddress(agent)) {
        return res.status(400).json({ error: 'Invalid agent address' });
      }

      if (!scoring) {
        return res.status(503).json({ error: 'Scoring service not configured' });
      }

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
  };
}
