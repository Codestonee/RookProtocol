import { ethers } from 'ethers';

/**
 * Format USDC amount for display
 */
export function formatUSDC(amount: number | string | bigint): string {
  const num = typeof amount === 'bigint' 
    ? Number(ethers.formatUnits(amount, 6))
    : typeof amount === 'string' 
      ? Number(amount) 
      : amount;
  return `$${num.toFixed(2)} USDC`;
}

/**
 * Format trust score for display
 */
export function formatScore(score: number): string {
  return `${(score * 100).toFixed(0)}%`;
}

/**
 * Truncate address for display
 */
export function truncateAddress(address: string, chars = 4): string {
  if (!address) return '';
  return `${address.slice(0, chars + 2)}...${address.slice(-chars)}`;
}

/**
 * Format timestamp to relative time
 */
export function formatRelativeTime(timestamp: number): string {
  const now = Date.now();
  const diff = now - timestamp * 1000;
  
  const minutes = Math.floor(diff / 60000);
  const hours = Math.floor(diff / 3600000);
  const days = Math.floor(diff / 86400000);
  
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  if (hours < 24) return `${hours}h ago`;
  return `${days}d ago`;
}

/**
 * Format escrow status with emoji
 */
export function formatStatus(status: string): string {
  const statusMap: Record<string, string> = {
    'Active': '🟢 Active',
    'Released': '✅ Released',
    'Refunded': '↩️ Refunded',
    'Disputed': '⚖️ Disputed',
    'Challenged': '🎯 Challenged'
  };
  return statusMap[status] || status;
}

/**
 * Compute composite trust score from components
 */
export function computeCompositeScore(
  identity: number,
  reputation: number,
  sybil: number,
  history: number,
  challenge: number
): number {
  return (
    identity * 0.25 +
    reputation * 0.25 +
    sybil * 0.20 +
    history * 0.20 +
    challenge * 0.10
  );
}

/**
 * Get risk level from trust score
 */
export function getRiskLevel(score: number): 'LOW' | 'STANDARD' | 'ELEVATED' | 'HIGH' {
  if (score >= 0.80) return 'LOW';
  if (score >= 0.65) return 'STANDARD';
  if (score >= 0.50) return 'ELEVATED';
  return 'HIGH';
}

/**
 * Get recommendation based on risk level
 */
export function getRecommendation(riskLevel: string): string {
  const recommendations: Record<string, string> = {
    'LOW': 'Auto-release enabled',
    'STANDARD': 'Auto-release with monitoring',
    'ELEVATED': 'Manual review recommended',
    'HIGH': 'Challenge required before release'
  };
  return recommendations[riskLevel] || 'Unknown';
}

/**
 * Validate job description
 */
export function validateJob(job: string): boolean {
  return job.length > 0 && job.length <= 1000;
}

/**
 * Generate job hash
 */
export function generateJobHash(job: string): string {
  return ethers.keccak256(ethers.toUtf8Bytes(job));
}

/**
 * Parse escrow ID from transaction receipt
 */
export function parseEscrowIdFromReceipt(receipt: any): string | null {
  const event = receipt.logs?.find(
    (log: any) => log.fragment?.name === 'EscrowCreated'
  );
  return event?.args?.escrowId || null;
}
