export interface RookConfig {
  network?: 'base-sepolia' | 'base';
  rpcUrl?: string;
  privateKey?: string;
}

export interface EscrowParams {
  amount: number;
  recipient: string;  // Address, @handle, or ENS
  job: string;
  threshold?: number;
  requireChallenge?: boolean;
}

export interface EscrowResult {
  id: string;
  buyer: string;
  seller: string;
  amount: number;
  job: string;
  threshold: number;
  status: string;
  createdAt?: number;
  expiresAt?: number;
  txHash?: string;
}

export interface TrustScoreBreakdown {
  erc8004_identity: number;
  reputation_signals: number;
  sybil_resistance: number;
  escrow_history: number;
  challenge_bonus: number;
}

export interface VerificationResult {
  agent: string;
  address: string;
  trust_score: number;
  breakdown: TrustScoreBreakdown;
  risk_level: 'LOW' | 'STANDARD' | 'ELEVATED' | 'HIGH';
  recommendation: string;
}

export interface ChallengeParams {
  escrowId: string;
  stake?: number;
  reason?: string;
}

export interface ChallengeResult {
  escrowId: string;
  challenger: string;
  stake: number;
  deadline: number;
  reason?: string;
  txHash: string;
}

export interface DisputeParams {
  escrowId: string;
  evidence: string;  // IPFS hash
  claim: string;
}
