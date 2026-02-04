import dotenv from 'dotenv';
import { createServer } from './server';
import { logger } from './utils/logger';

dotenv.config();

const PORT = process.env.ORACLE_PORT || 3000;

async function main() {
  try {
    const app = await createServer();
    
    app.listen(PORT, () => {
      logger.info(`🚀 Rook Oracle running on port ${PORT}`);
    });
  } catch (error) {
    logger.error('Failed to start oracle:', error);
    process.exit(1);
  }
}

main();
