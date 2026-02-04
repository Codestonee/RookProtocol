import express from 'express';
import { verifyHandler } from './handlers/verify';
import { challengeHandler } from './handlers/challenge';
import { webhookHandler } from './handlers/webhook';
import { logger } from './utils/logger';

export async function createServer() {
  const app = express();

  app.use(express.json());

  // Logging middleware
  app.use((req, res, next) => {
    logger.info(`${req.method} ${req.path}`);
    next();
  });

  // Health check
  app.get('/health', (req, res) => {
    res.json({ status: 'ok', service: 'rook-oracle' });
  });

  // Verification endpoint
  app.post('/verify', verifyHandler);

  // Challenge endpoint
  app.post('/challenge', challengeHandler);

  // Webhook for blockchain events
  app.post('/webhook', webhookHandler);

  // Error handling
  app.use((err: any, req: express.Request, res: express.Response, next: express.NextFunction) => {
    logger.error('Request error:', err);
    res.status(500).json({ error: err.message || 'Internal server error' });
  });

  return app;
}
