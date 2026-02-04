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

export type EscrowStatus = 'Active' | 'Released' | 'Refunded' | 'Disputed' | 'Challenged' | 'Unknown';

export type RiskLevel = 'LOW' | 'STANDARD' | 'ELEVATED' | 'HIGH';

export interface EscrowResult {
  id: string;
  buyer: string;
  seller: string;
  amount: number;
  job: string;
  threshold: number;
  status: EscrowStatus;
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
  risk_level: RiskLevel;
  recommendation: string;
}

export interface ChallengeParams {
  escrowId: string;
  stake?: number;  // Ignored - contract uses fixed 5 USDC
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
  evidence: string;  // IPFS hash or text
  claim: string;
}

export interface DisputeResult {
  escrowId: string;
  winner: string;
  amount: number;
  reason: string;
  txHash: string;
}

// Event types for listeners
export interface EscrowCreatedEvent {
  escrowId: string;
  buyer: string;
  seller: string;
  amount: bigint;
  trustThreshold: number;
  expiresAt: number;
}

export interface EscrowReleasedEvent {
  escrowId: string;
  seller: string;
  amount: bigint;
  trustScore: number;
}

export interface ChallengeInitiatedEvent {
  escrowId: string;
  challenger: string;
  stake: bigint;
  deadline: number;
}
