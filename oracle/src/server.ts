import express from 'express';
import rateLimit from 'express-rate-limit';
import { ethers } from 'ethers';
import { createVerifyHandler } from './handlers/verify';
import { createChallengeHandler } from './handlers/challenge';
import { createWebhookHandler } from './handlers/webhook';
import { ScoringService } from './services/scoring';
import { logger } from './utils/logger';
import { config } from './utils/config';
import { metrics } from './monitoring/metrics';

// API key authentication middleware
const apiKeyAuth = (req: express.Request, res: express.Response, next: express.NextFunction) => {
  const apiKey = req.headers['x-api-key'];
  if (!config.apiKey) {
    return next();
  }
  if (!apiKey || apiKey !== config.apiKey) {
    return res.status(401).json({ error: 'Unauthorized: Invalid or missing API key' });
  }
  next();
};

export async function createServer() {
  const app = express();

  // Rate limiting (100 requests per minute)
  const limiter = rateLimit({
    windowMs: 60 * 1000,
    max: 100,
    message: { error: 'Too many requests, please try again later' }
  });

  app.use(limiter);
  app.use(express.json({ limit: '1mb' }));

  // Logging middleware
  app.use((req, res, next) => {
    const start = Date.now();
    res.on('finish', () => {
      const duration = Date.now() - start;
      logger.info(`${req.method} ${req.path} ${res.statusCode} ${duration}ms`);
      metrics.record(`http:${req.method}:${req.path}`, duration, res.statusCode < 400);
    });
    next();
  });

  // Initialize shared provider and scoring service (singleton)
  const provider = new ethers.JsonRpcProvider(
    config.rpcUrl || 'https://sepolia.base.org'
  );

  let scoringService: ScoringService | null = null;
  if (config.escrowAddress) {
    scoringService = new ScoringService(
      provider,
      config.escrowAddress,
      undefined,
      undefined,
      config.moltbookApiKey
    );
  } else {
    logger.warn('ROOK_ESCROW_ADDRESS not configured. Scoring endpoints will return errors.');
  }

  // Health check (public)
  app.get('/health', (req, res) => {
    res.json({
      status: 'ok',
      service: 'rook-oracle',
      uptime: process.uptime(),
      scoring: !!scoringService
    });
  });

  // Metrics endpoint (requires API key)
  app.get('/metrics', apiKeyAuth, (req, res) => {
    res.json({
      stats: metrics.getStats(),
      cacheHitRate: metrics.getCacheHitRate()
    });
  });

  // Verification endpoint (public, read-only)
  app.post('/verify', createVerifyHandler(scoringService));

  // Challenge endpoint (requires API key auth)
  app.post('/challenge', apiKeyAuth, createChallengeHandler(provider, scoringService));

  // Webhook for blockchain events (requires API key auth)
  app.post('/webhook', apiKeyAuth, createWebhookHandler(provider, scoringService));

  // Error handling
  app.use((err: any, req: express.Request, res: express.Response, next: express.NextFunction) => {
    logger.error('Request error:', err);
    res.status(500).json({ error: err.message || 'Internal server error' });
  });

  return app;
}
