import { Request, Response } from 'express';
import { ethers } from 'ethers';
import { ScoringService } from '../services/scoring';
import { config } from '../utils/config';
import { logger } from '../utils/logger';
import { metrics } from '../monitoring/metrics';

const oracleAbi = [
  'function updateScores(address agent, uint256 identity, uint256 reputation, uint256 sybil, uint256 challengeBonus) external',
  'function triggerRelease(bytes32 escrowId) external'
];

const escrowAbi = [
  'function getEscrow(bytes32 escrowId) view returns (tuple(address buyer, address seller, uint256 amount, bytes32 jobHash, uint256 trustThreshold, uint8 status, uint256 createdAt, uint256 expiresAt))'
];

export function createWebhookHandler(provider: ethers.Provider, scoring: ScoringService | null) {
  return async function webhookHandler(req: Request, res: Response) {
    try {
      const { event, data } = req.body;

      if (!event || !data) {
        return res.status(400).json({ error: 'event and data required' });
      }

      logger.info(`Received webhook: ${event}`, { data });
      metrics.record(`webhook:${event}`, 0, true);

      switch (event) {
        case 'escrow.created':
          await handleEscrowCreated(provider, scoring, data);
          break;
        case 'escrow.challenged':
          await handleEscrowChallenged(data);
          break;
        case 'escrow.disputed':
          await handleEscrowDisputed(data);
          break;
        case 'escrow.release_requested':
          await handleReleaseRequested(provider, scoring, data);
          break;
        default:
          logger.warn(`Unknown webhook event: ${event}`);
      }

      res.json({ received: true });
    } catch (error: any) {
      logger.error('Webhook handler error:', error);
      // Always return 200 to prevent retries
      res.json({ received: true, error: error.message });
    }
  };
}

/**
 * When a new escrow is created, pre-compute the seller's trust score
 * so it's cached and ready for release checks.
 */
async function handleEscrowCreated(
  provider: ethers.Provider,
  scoring: ScoringService | null,
  data: { escrowId: string; seller?: string; moltbookHandle?: string }
) {
  logger.info(`New escrow created: ${data.escrowId}`);

  if (!scoring || !data.seller) return;

  try {
    const score = await scoring.calculateScore(data.seller, data.moltbookHandle);
    logger.info(`Pre-computed trust score for ${data.seller}: ${score.composite}`);
  } catch (error) {
    logger.error(`Failed to pre-compute score for ${data.seller}:`, error);
  }
}

/**
 * When an escrow is challenged, log the event for monitoring.
 * The challenge flow is handled through the /challenge endpoint.
 */
async function handleEscrowChallenged(data: { escrowId: string; challenger?: string }) {
  logger.info(`Escrow challenged: ${data.escrowId} by ${data.challenger || 'unknown'}`);
}

/**
 * When an escrow is disputed, log for admin review.
 */
async function handleEscrowDisputed(data: { escrowId: string; evidence?: string }) {
  logger.info(`Escrow disputed: ${data.escrowId}`);
  if (data.evidence) {
    logger.info(`Dispute evidence: ${data.evidence}`);
  }
}

/**
 * When a release is requested, compute fresh score and submit on-chain
 * if it meets the threshold.
 */
async function handleReleaseRequested(
  provider: ethers.Provider,
  scoring: ScoringService | null,
  data: { escrowId: string; moltbookHandle?: string }
) {
  logger.info(`Release requested for escrow: ${data.escrowId}`);

  if (!scoring || !config.escrowAddress || !config.oracleAddress || !config.privateKey) {
    logger.warn('Cannot process release: missing configuration');
    return;
  }

  try {
    // Fetch escrow details
    const escrowContract = new ethers.Contract(config.escrowAddress, escrowAbi, provider);
    const escrow = await escrowContract.getEscrow(data.escrowId);

    if (escrow.seller === ethers.ZeroAddress) {
      logger.warn(`Escrow ${data.escrowId} not found`);
      return;
    }

    // Compute fresh score
    const score = await scoring.calculateScore(escrow.seller, data.moltbookHandle);
    logger.info(`Score for ${escrow.seller}: ${score.composite} (threshold: ${Number(escrow.trustThreshold)})`);

    // Update scores on-chain
    const signer = new ethers.Wallet(config.privateKey, provider);
    const oracle = new ethers.Contract(config.oracleAddress, oracleAbi, signer);

    const updateTx = await oracle.updateScores(
      escrow.seller,
      score.identity,
      score.reputation,
      score.sybil,
      score.challengeBonus
    );
    await updateTx.wait();
    logger.info(`Scores updated on-chain for ${escrow.seller}`);

    // Trigger release if score meets threshold
    if (score.composite >= Number(escrow.trustThreshold)) {
      const releaseTx = await oracle.triggerRelease(data.escrowId);
      await releaseTx.wait();
      logger.info(`Escrow ${data.escrowId} released. Score: ${score.composite}`);
    } else {
      logger.info(`Score ${score.composite} below threshold ${Number(escrow.trustThreshold)}. Release not triggered.`);
    }
  } catch (error) {
    logger.error(`Failed to process release for ${data.escrowId}:`, error);
  }
}
