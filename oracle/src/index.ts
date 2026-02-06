import dotenv from 'dotenv';
import { createServer } from './server';
import { logger } from './utils/logger';

dotenv.config();

const PORT = process.env.ORACLE_PORT || 3000;

async function main() {
  try {
    const app = await createServer();

    const server = app.listen(PORT, () => {
      logger.info(`Rook Oracle running on port ${PORT}`);
    });

    // Graceful shutdown
    const shutdown = (signal: string) => {
      logger.info(`${signal} received. Shutting down gracefully...`);
      server.close(() => {
        logger.info('HTTP server closed');
        process.exit(0);
      });

      // Force shutdown after 10 seconds
      setTimeout(() => {
        logger.error('Forced shutdown after timeout');
        process.exit(1);
      }, 10000);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
  } catch (error) {
    logger.error('Failed to start oracle:', error);
    process.exit(1);
  }
}

main();
