import { Request, Response } from 'express';
import { logger } from '../utils/logger';

/**
 * Handle webhooks from blockchain indexers (Alchemy, etc.)
 */
export async function webhookHandler(req: Request, res: Response) {
  try {
    const { event, data } = req.body;

    logger.info(`Received webhook: ${event}`, { data });

    switch (event) {
      case 'escrow.created':
        await handleEscrowCreated(data);
        break;
      case 'escrow.challenged':
        await handleEscrowChallenged(data);
        break;
      case 'escrow.disputed':
        await handleEscrowDisputed(data);
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
}

async function handleEscrowCreated(data: any) {
  logger.info(`New escrow created: ${data.escrowId}`);
  // Trigger initial verification
  // Could queue a job to compute trust score
}

async function handleEscrowChallenged(data: any) {
  logger.info(`Escrow challenged: ${data.escrowId}`);
  // Could send notification to seller
  // Start monitoring for response
}

async function handleEscrowDisputed(data: any) {
  logger.info(`Escrow disputed: ${data.escrowId}`);
  // Could initiate Kleros integration
  // Alert both parties
}
