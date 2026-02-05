import { ethers, Contract } from 'ethers';
import { ERC8004Service } from './erc8004';
import { MoltbookService } from './moltbook';
import { CacheService } from './cache';  // PR#4: Caching layer
import { metrics } from '../monitoring/metrics';  // HIGH-IMPACT FIX: Metrics tracking
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

// PR#3: Configurable weights interface
interface ScoringWeights {
  identity: number;
  reputation: number;
  sybil: number;
  history: number;
  challenge: number;
}

export class ScoringService {
  private erc8004: ERC8004Service;
  private moltbook: MoltbookService;
  private escrowContract: Contract;
  private weights: ScoringWeights;  // PR#3: Configurable weights
  private cache: CacheService;  // PR#4: Caching layer
  private genesisTimestamp: number;  // CRITICAL FIX: Configurable genesis timestamp

  constructor(
    provider: ethers.Provider,
    escrowAddress: string,
    erc8004Identity?: string,
    erc8004Reputation?: string,
    moltbookApiKey?: string,
    customWeights?: Partial<ScoringWeights>,  // PR#3: Optional custom weights
    genesisTimestamp?: number  // CRITICAL FIX: Optional genesis timestamp (defaults to current year)
  ) {
    this.erc8004 = new ERC8004Service(provider, erc8004Identity, erc8004Reputation);
    this.moltbook = new MoltbookService(moltbookApiKey || '');

    // PR#3: Conservative defaults (favor on-chain over social)
    this.weights = {
      identity: 0.30,      // +5% from 0.25
      reputation: 0.30,    // +5% from 0.25
      sybil: 0.20,         // unchanged
      history: 0.15,       // -5% from 0.20
      challenge: 0.05,     // -5% from 0.10
      ...customWeights
    };

    // CRITICAL FIX: Default to January 1st of current year if not specified
    this.genesisTimestamp = genesisTimestamp || Date.UTC(new Date().getUTCFullYear(), 0, 1);

    const escrowAbi = [
      'function getCompletionRate(address agent) view returns (uint256)',
      'function totalEscrows(address agent) view returns (uint256)',
      'function completedEscrows(address agent) view returns (uint256)'
    ];
    this.escrowContract = new Contract(escrowAddress, escrowAbi, provider);

    // PR#4: Initialize cache with 1000 entry limit
    this.cache = new CacheService(1000);
  }

  /**
   * Calculate trust score for an agent
   * PR#3: Added time decay and configurable weights
   * PR#4: Added caching
   * HIGH-IMPACT FIX: Added metrics tracking
   */
  async calculateScore(agent: string, moltbookHandle?: string): Promise<TrustScoreResult> {
    const startTime = Date.now();

    // PR#4: Check cache first (5 minute TTL)
    const cacheKey = `score:${agent}:${moltbookHandle || 'none'}`;
    const cached = this.cache.get<TrustScoreResult>(cacheKey);
    if (cached) {
      logger.info(`Using cached score for ${agent}`);
      metrics.record('calculateScore', Date.now() - startTime, true);
      return cached;
    }

    logger.info(`Calculating trust score for ${agent}`);

    const [identityScore, reputationScore, sybilScore, historyScore, challengeBonus] = await Promise.all([
      this.erc8004.getIdentityScore(agent),
      this.calculateReputationScore(agent, moltbookHandle),
      this.calculateSybilScore(agent, moltbookHandle),
      this.getHistoryScore(agent),
      Promise.resolve(0) // Challenge bonus is set externally
    ]);

    // PR#3: Apply time decay to all scores
    const decayedIdentity = this.applyTimeDecay(identityScore, agent);
    const decayedReputation = this.applyTimeDecay(reputationScore, agent);
    const decayedSybil = this.applyTimeDecay(sybilScore, agent);
    const decayedHistory = this.applyTimeDecay(historyScore, agent);

    // PR#3: Use configurable weights
    const composite = Math.round(
      decayedIdentity * this.weights.identity +
      decayedReputation * this.weights.reputation +
      decayedSybil * this.weights.sybil +
      decayedHistory * this.weights.history +
      challengeBonus * this.weights.challenge
    );

    const result = {
      identity: decayedIdentity,
      reputation: decayedReputation,
      sybil: decayedSybil,
      history: decayedHistory,
      challengeBonus,
      composite: Math.max(0, Math.min(100, composite)) // Clamp to 0-100
    };

    // PR#4: Cache result (5 minutes = 300000 ms)
    this.cache.set(cacheKey, result, 5 * 60 * 1000);

    // HIGH-IMPACT FIX: Track score calculation duration
    metrics.record('calculateScore', Date.now() - startTime, true);

    return result;
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
   * PR#4: Parallelized RPC calls for better performance
   */
  private async calculateSybilScore(agent: string, moltbookHandle?: string): Promise<number> {
    const provider = this.escrowContract.runner as ethers.Provider;

    // PR#4: Parallel RPC calls for code, txCount, and Moltbook score
    const [code, txCount, moltbookScore] = await Promise.all([
      provider.getCode(agent).catch(() => '0x'),
      provider.getTransactionCount(agent).then(Number).catch(() => 0),
      moltbookHandle ? this.moltbook.getSybilScore(moltbookHandle) : Promise.resolve(50)
    ]);

    const isContract = code !== '0x';

    // Contracts get lower sybil score (higher risk)
    const contractPenalty = isContract ? 20 : 0;

    // Transaction count as proxy for activity
    const activityScore = Math.min(txCount / 10, 30);

    return Math.round(moltbookScore + activityScore - contractPenalty);
  }

  /**
   * Get escrow completion history score
   * PR#3: Added failure penalties and conservative defaults
   */
  private async getHistoryScore(agent: string): Promise<number> {
    try {
      const [completionRate, totalEscrows, completedEscrows] = await Promise.all([
        this.escrowContract.getCompletionRate(agent),
        this.escrowContract.totalEscrows(agent),
        this.escrowContract.completedEscrows(agent)
      ]);

      const total = Number(totalEscrows);
      const completed = Number(completedEscrows);

      // PR#3: More conservative default for new agents
      if (total === 0) {
        return 40; // CHANGED from 50 to 40
      }

      // PR#3: Calculate failure penalty
      const failed = total - completed;
      const failureRate = failed / total;
      const baseScore = Number(completionRate);

      // Failure penalty (max 30 points)
      const failurePenalty = Math.min(failureRate * 30, 30);

      // Recency bonus for active agents
      const recencyBonus = (total >= 5 && completed >= 3) ? 10 : 0;

      return Math.max(0, Math.min(100, baseScore - failurePenalty + recencyBonus));
    } catch (error) {
      logger.error('Error getting history score:', error);
      return 30; // PR#3: More conservative from 50
    }
  }

  /**
   * PR#3: Apply time-based decay to score
   * Scores decay 5% per week of inactivity
   * CRITICAL FIX: Uses configurable genesis timestamp
   */
  private applyTimeDecay(score: number, agent: string, lastActivity?: number): number {
    if (!lastActivity) {
      // If no activity timestamp, assume neutral decay from genesis
      // (In production, this should be fetched from on-chain or database)
      const weeksSinceGenesis = (Date.now() - this.genesisTimestamp) / (1000 * 60 * 60 * 24 * 7);
      const decayRate = 0.05; // 5% per week
      const decayFactor = Math.pow(1 - decayRate, Math.min(weeksSinceGenesis, 52)); // Cap at 1 year
      return Math.round(score * decayFactor);
    }

    const weeksSinceActivity = (Date.now() - lastActivity) / (1000 * 60 * 60 * 24 * 7);
    const decayRate = 0.05;
    const decayFactor = Math.pow(1 - decayRate, weeksSinceActivity);
    return Math.round(score * decayFactor);
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
