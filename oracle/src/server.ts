import express from 'express';
import rateLimit from 'express-rate-limit';
import { verifyHandler } from './handlers/verify';
import { challengeHandler } from './handlers/challenge';
import { webhookHandler } from './handlers/webhook';
import { logger } from './utils/logger';
import { config } from './utils/config';

// MEDIUM FIX: API key authentication middleware
const apiKeyAuth = (req: express.Request, res: express.Response, next: express.NextFunction) => {
  const apiKey = req.headers['x-api-key'];
  if (!config.apiKey) {
    // No API key configured, allow request (with warning logged at startup)
    return next();
  }
  if (!apiKey || apiKey !== config.apiKey) {
    return res.status(401).json({ error: 'Unauthorized: Invalid or missing API key' });
  }
  next();
};

export async function createServer() {
  const app = express();

  // MEDIUM FIX: Rate limiting (100 requests per minute)
  const limiter = rateLimit({
    windowMs: 60 * 1000,
    max: 100,
    message: { error: 'Too many requests, please try again later' }
  });

  app.use(limiter);
  app.use(express.json({ limit: '1mb' }));

  // Logging middleware
  app.use((req, res, next) => {
    logger.info(`${req.method} ${req.path}`);
    next();
  });

  // Health check (public)
  app.get('/health', (req, res) => {
    res.json({ status: 'ok', service: 'rook-oracle' });
  });

  // Verification endpoint (public, read-only)
  app.post('/verify', verifyHandler);

  // Challenge endpoint (CRITICAL FIX: requires API key auth)
  app.post('/challenge', apiKeyAuth, challengeHandler);

  // Webhook for blockchain events (requires API key auth)
  app.post('/webhook', apiKeyAuth, webhookHandler);

  // Error handling
  app.use((err: any, req: express.Request, res: express.Response, next: express.NextFunction) => {
    logger.error('Request error:', err);
    res.status(500).json({ error: err.message || 'Internal server error' });
  });

  return app;
}
