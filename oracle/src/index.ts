import dotenv from 'dotenv';
import { createServer, getActiveRequests, setShuttingDown } from './server';
import { logger } from './utils/logger';

dotenv.config();

const PORT = process.env.ORACLE_PORT || 3000;
const SHUTDOWN_TIMEOUT_MS = 10000;
const DRAIN_CHECK_INTERVAL_MS = 100;

async function main() {
  try {
    const app = await createServer();

    const server = app.listen(PORT, () => {
      logger.info(`Rook Oracle running on port ${PORT}`);
    });

    // Graceful shutdown with request draining
    let shutdownInProgress = false;

    const shutdown = async (signal: string) => {
      if (shutdownInProgress) {
        logger.warn('Shutdown already in progress');
        return;
      }

      shutdownInProgress = true;
      setShuttingDown(true);

      const activeRequests = getActiveRequests();
      logger.info(`${signal} received. Shutting down gracefully...`);
      logger.info(`Active requests: ${activeRequests}`);

      // Stop accepting new connections
      server.close(() => {
        logger.info('HTTP server closed (no new connections)');
      });

      // Wait for active requests to complete
      const drainStart = Date.now();
      while (getActiveRequests() > 0 && Date.now() - drainStart < SHUTDOWN_TIMEOUT_MS) {
        const remaining = getActiveRequests();
        logger.info(`Draining ${remaining} active requests...`);
        await new Promise(resolve => setTimeout(resolve, DRAIN_CHECK_INTERVAL_MS));
      }

      const finalCount = getActiveRequests();
      if (finalCount > 0) {
        logger.warn(`Forced shutdown with ${finalCount} requests still active`);
        process.exit(1);
      }

      logger.info('All requests drained. Clean shutdown.');
      process.exit(0);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));

    // Handle uncaught exceptions
    process.on('uncaughtException', (error) => {
      logger.error('Uncaught exception:', error);
      shutdown('UNCAUGHT_EXCEPTION');
    });

    process.on('unhandledRejection', (reason, promise) => {
      logger.error('Unhandled rejection at:', promise, 'reason:', reason);
    });

  } catch (error) {
    logger.error('Failed to start oracle:', error);
    process.exit(1);
  }
}

main();
