import { ethers, Contract } from 'ethers';
import { ERC8004Service } from './erc8004';
import { MoltbookService } from './moltbook';
import { logger } from '../utils/logger';

interface TrustScoreComponents {
  identity: number;      // 0-100
  reputation: number;    // 0-100
  sybil: number;         // 0-100
  history: number;       // 0-100
  challengeBonus: number; // 0-100
}

interface TrustScoreResult extends TrustScoreComponents {
  composite: number;     // 0-100
}

export class ScoringService {
  private erc8004: ERC8004Service;
  private moltbook: MoltbookService;
  private escrowContract: Contract;

  constructor(
    provider: ethers.Provider,
    escrowAddress: string,
    erc8004Identity?: string,
    erc8004Reputation?: string,
    moltbookApiKey?: string
  ) {
    this.erc8004 = new ERC8004Service(provider, erc8004Identity, erc8004Reputation);
    this.moltbook = new MoltbookService(moltbookApiKey || '');
    
    const escrowAbi = [
      'function getCompletionRate(address agent) view returns (uint256)',
      'function totalEscrows(address agent) view returns (uint256)',
      'function completedEscrows(address agent) view returns (uint256)'
    ];
    this.escrowContract = new Contract(escrowAddress, escrowAbi, provider);
  }

  /**
   * Calculate trust score for an agent
   */
  async calculateScore(agent: string, moltbookHandle?: string): Promise<TrustScoreResult> {
    logger.info(`Calculating trust score for ${agent}`);

    const [identityScore, reputationScore, sybilScore, historyScore, challengeBonus] = await Promise.all([
      this.erc8004.getIdentityScore(agent),
      this.calculateReputationScore(agent, moltbookHandle),
      this.calculateSybilScore(agent, moltbookHandle),
      this.getHistoryScore(agent),
      Promise.resolve(0) // Challenge bonus is set externally
    ]);

    // Weighted composite
    const composite = Math.round(
      identityScore * 0.25 +
      reputationScore * 0.25 +
      sybilScore * 0.20 +
      historyScore * 0.20 +
      challengeBonus * 0.10
    );

    return {
      identity: identityScore,
      reputation: reputationScore,
      sybil: sybilScore,
      history: historyScore,
      challengeBonus,
      composite
    };
  }

  /**
   * Calculate reputation score (ERC-8004 + Moltbook weighted)
   */
  private async calculateReputationScore(agent: string, moltbookHandle?: string): Promise<number> {
    const erc8004Score = await this.erc8004.getReputationScore(agent);
    
    let moltbookScore = 50; // Default neutral
    if (moltbookHandle) {
      moltbookScore = await this.moltbook.getSocialScore(moltbookHandle);
    }

    // Weight: 60% ERC-8004, 40% Moltbook (Moltbook weighted lower due to vulnerabilities)
    return Math.round(erc8004Score * 0.6 + moltbookScore * 0.4);
  }

  /**
   * Calculate sybil resistance score
   */
  private async calculateSybilScore(agent: string, moltbookHandle?: string): Promise<number> {
    // Get on-chain metrics
    const provider = this.escrowContract.runner as ethers.Provider;
    const code = await provider.getCode(agent);
    const isContract = code !== '0x';

    let moltbookScore = 50;
    if (moltbookHandle) {
      moltbookScore = await this.moltbook.getSybilScore(moltbookHandle);
    }

    // Contracts get lower sybil score (higher risk)
    const contractPenalty = isContract ? 20 : 0;

    // Get transaction count as proxy for activity
    let txCount = 0;
    try {
      txCount = Number(await provider.getTransactionCount(agent));
    } catch (e) {
      // Ignore errors
    }
    
    const activityScore = Math.min(txCount / 10, 30);

    return Math.round(moltbookScore + activityScore - contractPenalty);
  }

  /**
   * Get escrow completion history score
   */
  private async getHistoryScore(agent: string): Promise<number> {
    try {
      const completionRate = await this.escrowContract.getCompletionRate(agent);
      const totalEscrows = await this.escrowContract.totalEscrows(agent);

      // If no history, return neutral score
      if (totalEscrows === 0n) {
        return 50;
      }

      return Number(completionRate);
    } catch (error) {
      logger.error('Error getting history score:', error);
      return 50;
    }
  }

  /**
   * Verify a challenge response (wallet signature)
   */
  async verifyChallenge(
    escrowId: string,
    signature: string,
    expectedSigner: string
  ): Promise<boolean> {
    try {
      // Create message that was signed
      const message = ethers.keccak256(
        ethers.solidityPacked(['bytes32'], [escrowId])
      );

      // Recover signer
      const recoveredAddress = ethers.verifyMessage(
        ethers.getBytes(message),
        signature
      );

      // Verify it matches expected signer
      const isValid = recoveredAddress.toLowerCase() === expectedSigner.toLowerCase();
      
      logger.info(`Challenge verification: ${isValid ? 'PASSED' : 'FAILED'}`);
      return isValid;
    } catch (error) {
      logger.error('Error verifying challenge:', error);
      return false;
    }
  }
}
