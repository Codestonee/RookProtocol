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

  // Enforce API key in production
  if (!config.apiKey) {
    if (process.env.NODE_ENV === 'production') {
      logger.error('ORACLE_API_KEY not set in production - rejecting request');
      return res.status(500).json({ error: 'Server misconfiguration: API key required' });
    }
    logger.warn('API key not configured - allowing request in development mode');
    return next();
  }

  if (!apiKey || apiKey !== config.apiKey) {
    return res.status(401).json({ error: 'Unauthorized: Invalid or missing API key' });
  }
  next();
};

// Per-endpoint rate limiters
const createRateLimiter = (max: number, windowMs: number = 60 * 1000) => rateLimit({
  windowMs,
  max,
  message: { error: 'Too many requests, please try again later' },
  standardHeaders: true,
  legacyHeaders: false
});

// Different limits for different endpoints
const verifyLimiter = createRateLimiter(200);     // 200/min - read-only, higher limit
const webhookLimiter = createRateLimiter(50);     // 50/min - blockchain events
const challengeLimiter = createRateLimiter(20);   // 20/min - expensive operations
const metricsLimiter = createRateLimiter(30);     // 30/min - monitoring

// Request tracking for graceful shutdown
let activeRequests = 0;
let isShuttingDown = false;

export function getActiveRequests(): number {
  return activeRequests;
}

export function setShuttingDown(value: boolean): void {
  isShuttingDown = value;
}

export function isServerShuttingDown(): boolean {
  return isShuttingDown;
}

export async function createServer() {
  const app = express();

  // Check API key configuration at startup
  if (!config.apiKey && process.env.NODE_ENV === 'production') {
    throw new Error('ORACLE_API_KEY is required in production environment');
  }

  app.use(express.json({ limit: '1mb' }));

  // Request tracking middleware for graceful shutdown
  app.use((req, res, next) => {
    if (isShuttingDown) {
      return res.status(503).json({ error: 'Server is shutting down' });
    }
    activeRequests++;
    res.on('finish', () => {
      activeRequests--;
    });
    res.on('close', () => {
      // Handle aborted requests
      if (!res.writableEnded) {
        activeRequests--;
      }
    });
    next();
  });

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

  // Metrics endpoint (requires API key, rate limited)
  app.get('/metrics', metricsLimiter, apiKeyAuth, (req, res) => {
    res.json({
      stats: metrics.getStats(),
      cacheHitRate: metrics.getCacheHitRate()
    });
  });

  // Verification endpoint (public, read-only, higher rate limit)
  app.post('/verify', verifyLimiter, createVerifyHandler(scoringService));

  // Challenge endpoint (requires API key auth, lower rate limit)
  app.post('/challenge', challengeLimiter, apiKeyAuth, createChallengeHandler(provider, scoringService));

  // Webhook for blockchain events (requires API key auth)
  app.post('/webhook', webhookLimiter, apiKeyAuth, createWebhookHandler(provider, scoringService));

  // Error handling
  app.use((err: any, req: express.Request, res: express.Response, next: express.NextFunction) => {
    logger.error('Request error:', err);
    res.status(500).json({ error: err.message || 'Internal server error' });
  });

  return app;
}
