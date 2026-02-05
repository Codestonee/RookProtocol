import { ethers, Contract } from 'ethers';
import { logger } from '../utils/logger';

const ERC8004_IDENTITY_ABI = [
  'function balanceOf(address owner) view returns (uint256)',
  'function ownerOf(uint256 tokenId) view returns (address)',
  'function getIdentity(address agent) view returns (bytes)',
  'function isRegistered(address agent) view returns (bool)'
];

const ERC8004_REPUTATION_ABI = [
  'function getReputation(address agent) view returns (uint256)',
  'function getFeedbackCount(address agent) view returns (uint256)',
  'function getAverageRating(address agent) view returns (uint256)'
];

export class ERC8004Service {
  private identityContract: Contract | null = null;
  private reputationContract: Contract | null = null;

  constructor(
    provider: ethers.Provider,
    identityAddress?: string,
    reputationAddress?: string
  ) {
    if (identityAddress) {
      this.identityContract = new Contract(identityAddress, ERC8004_IDENTITY_ABI, provider);
    }
    if (reputationAddress) {
      this.reputationContract = new Contract(reputationAddress, ERC8004_REPUTATION_ABI, provider);
    }
  }

  /**
   * Check if agent is registered on ERC-8004
   */
  async isRegistered(agent: string): Promise<boolean> {
    if (!this.identityContract) {
      logger.warn('ERC-8004 identity contract not configured');
      return false;
    }
    
    try {
      return await this.identityContract.isRegistered(agent);
    } catch (error) {
      logger.error('Error checking ERC-8004 registration:', error);
      return false;
    }
  }

  /**
   * Get identity score (0-100)
   * Returns base score of 80 for registered agents, 0 for unregistered
   */
  async getIdentityScore(agent: string): Promise<number> {
    const isRegistered = await this.isRegistered(agent);
    return isRegistered ? 80 : 0;
  }

  /**
   * Get reputation score from ERC-8004
   * PR#3: Updated with conservative defaults and feedback penalty
   */
  async getReputationScore(agent: string): Promise<number> {
    if (!this.reputationContract) {
      logger.warn('ERC-8004 reputation contract not configured');
      return 40; // PR#3: CHANGED from 50 to 40
    }

    try {
      const [reputation, feedbackCount, avgRating] = await Promise.all([
        this.reputationContract.getReputation(agent),
        this.reputationContract.getFeedbackCount(agent),
        this.reputationContract.getAverageRating(agent)
      ]);

      // PR#3: Require minimum feedback count for high scores
      // HIGH-IMPACT FIX: Reduced penalty and capped to not overwhelm high reputation
      const minFeedbackForFullScore = 5;
      const feedbackPenalty = Number(feedbackCount) < minFeedbackForFullScore
        ? Math.min((minFeedbackForFullScore - Number(feedbackCount)) * 3, 12) // -3 per missing feedback, max 12
        : 0;

      // Normalize to 0-100
      const normalizedRating = Number(avgRating) * 20; // Convert 0-5 to 0-100

      // Weight: 70% reputation, 30% rating
      const baseScore = Number(reputation) * 0.7 + normalizedRating * 0.3;

      return Math.max(0, Math.round(baseScore - feedbackPenalty));
    } catch (error) {
      logger.error('Error getting ERC-8004 reputation:', error);
      return 30; // PR#3: CHANGED from 50 to 30 (more conservative on error)
    }
  }

  /**
   * Get full identity info
   */
  async getIdentityInfo(agent: string): Promise<{
    registered: boolean;
    identityScore: number;
    reputationScore: number;
  }> {
    const [registered, identityScore, reputationScore] = await Promise.all([
      this.isRegistered(agent),
      this.getIdentityScore(agent),
      this.getReputationScore(agent)
    ]);

    return {
      registered,
      identityScore,
      reputationScore
    };
  }
}
