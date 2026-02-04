export const config = {
  network: process.env.ROOK_NETWORK || 'base-sepolia',
  rpcUrl: process.env.ROOK_RPC_URL,
  privateKey: process.env.ORACLE_PRIVATE_KEY || process.env.PRIVATE_KEY,
  port: parseInt(process.env.ORACLE_PORT || '3000'),
  
  // Contract addresses
  escrowAddress: process.env.ROOK_ESCROW_ADDRESS,
  oracleAddress: process.env.ROOK_ORACLE_ADDRESS,
  
  // API keys
  moltbookApiKey: process.env.MOLTBOOK_API_KEY,
  moltbookApiUrl: process.env.MOLTBOOK_API_URL || 'https://api.moltbook.com',
  
  // Oracle settings
  updateInterval: parseInt(process.env.ORACLE_UPDATE_INTERVAL || '300000'),
  minConfidence: parseFloat(process.env.ORACLE_MIN_CONFIDENCE || '0.7')
};

if (!config.privateKey) {
  throw new Error('ORACLE_PRIVATE_KEY or PRIVATE_KEY environment variable required');
}
