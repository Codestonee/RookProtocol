// Contract addresses by network
export const CONTRACTS: Record<string, { escrow: string; oracle: string; usdc: string }> = {
  'base-sepolia': {
    escrow: process.env.ROOK_ESCROW_ADDRESS || '0x0000000000000000000000000000000000000000',
    oracle: process.env.ROOK_ORACLE_ADDRESS || '0x0000000000000000000000000000000000000000',
    usdc: '0x036CbD53842c5426634e7929541eC2318f3dCF7e' // Base Sepolia USDC
  },
  'base': {
    escrow: process.env.ROOK_ESCROW_ADDRESS || '0x0000000000000000000000000000000000000000',
    oracle: process.env.ROOK_ORACLE_ADDRESS || '0x0000000000000000000000000000000000000000',
    usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' // Base Mainnet USDC
  }
};

// Default trust threshold (0-100)
export const DEFAULT_THRESHOLD = 65;

// Challenge stake in USDC
export const CHALLENGE_STAKE = 5;

// Challenge timeout in blocks (~2 minutes on Base)
export const CHALLENGE_BLOCKS = 50;

// Default escrow expiry (7 days in seconds)
export const DEFAULT_EXPIRY = 7 * 24 * 60 * 60;

// Score weights (must sum to 100, matches RookOracle contract)
export const SCORE_WEIGHTS = {
  identity: 30,
  reputation: 30,
  sybil: 20,
  history: 15,
  challenge: 5
};

// Risk levels
export const RISK_LEVELS = {
  LOW: { min: 0.80, action: 'Auto-release enabled' },
  STANDARD: { min: 0.65, action: 'Auto-release with monitoring' },
  ELEVATED: { min: 0.50, action: 'Manual review recommended' },
  HIGH: { min: 0, action: 'Challenge required' }
};
