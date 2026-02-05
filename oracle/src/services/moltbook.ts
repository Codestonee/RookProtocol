import axios from 'axios';
import { logger } from '../utils/logger';

interface MoltbookUser {
  id: string;
  handle: string;
  karma: number;
  followers: number;
  following: number;
  createdAt: string;
  posts: number;
}

export class MoltbookService {
  private apiKey: string;
  private baseUrl: string;
  private timeout: number;

  constructor(apiKey: string, baseUrl: string = 'https://api.moltbook.com', timeout: number = 5000) {
    this.apiKey = apiKey;
    this.baseUrl = baseUrl;
    this.timeout = timeout; // HIGH-IMPACT FIX: Default 5 second timeout
  }

  /**
   * HIGH-IMPACT FIX: Wrap promise with timeout
   * @param promise The promise to execute
   * @param timeoutMs Timeout in milliseconds
   * @returns Promise that rejects on timeout
   */
  private withTimeout<T>(promise: Promise<T>, timeoutMs: number = this.timeout): Promise<T> {
    return Promise.race([
      promise,
      new Promise<T>((_, reject) =>
        setTimeout(() => reject(new Error('Moltbook API timeout')), timeoutMs)
      )
    ]);
  }

  /**
   * Fetch user data from Moltbook
   * HIGH-IMPACT FIX: Includes timeout protection
   */
  async getUser(handle: string): Promise<MoltbookUser | null> {
    try {
      const cleanHandle = handle.startsWith('@') ? handle.slice(1) : handle;

      const response = await this.withTimeout(
        axios.get(`${this.baseUrl}/users/${cleanHandle}`, {
          headers: {
            'Authorization': `Bearer ${this.apiKey}`
          }
        })
      );

      return response.data;
    } catch (error) {
      logger.error('Error fetching Moltbook user:', error);
      return null;
    }
  }

  /**
   * Calculate karma velocity (karma per day since creation)
   * MEDIUM FIX: Handles sub-day ages by using minimum of 1 day
   */
  calculateKarmaVelocity(user: MoltbookUser): number {
    const createdAt = new Date(user.createdAt);
    // MEDIUM FIX: Math.max(1, ...) ensures accounts < 1 day old are treated as 1 day
    // This prevents division by very small numbers and inflated velocity scores
    const daysSinceCreation = Math.max(1, (Date.now() - createdAt.getTime()) / (1000 * 60 * 60 * 24));
    return user.karma / daysSinceCreation;
  }

  /**
   * Check for suspicious karma patterns
   * PR#3: Age-based thresholds
   */
  isKarmaSuspicious(user: MoltbookUser): boolean {
    const velocity = this.calculateKarmaVelocity(user);
    const accountAgeDays = (Date.now() - new Date(user.createdAt).getTime()) / (1000 * 60 * 60 * 24);

    // PR#3: Different thresholds based on account age
    if (accountAgeDays < 7) {
      // New accounts: max 50 karma/day
      return velocity > 50;
    } else if (accountAgeDays < 30) {
      // Young accounts: max 75 karma/day
      return velocity > 75;
    } else {
      // Mature accounts: max 100 karma/day
      return velocity > 100;
    }
  }

  /**
   * Get social score (0-100)
   * PR#3: Harsher penalties and lower karma cap
   */
  async getSocialScore(handle: string): Promise<number> {
    const user = await this.getUser(handle);

    if (!user) {
      return 20; // PR#3: CHANGED from 30 to 20
    }

    // Check for suspicious patterns
    if (this.isKarmaSuspicious(user)) {
      logger.warn(`Suspicious karma pattern for ${handle}: ${this.calculateKarmaVelocity(user).toFixed(2)} karma/day`);
      return 10; // PR#3: CHANGED from 20 to 10 (harsher penalty)
    }

    // PR#3: Lower karma cap
    const karmaScore = Math.min(user.karma / 10, 60); // CHANGED cap from 100 to 60

    // Follower ratio bonus/penalty
    const followerRatio = user.followers / Math.max(user.following, 1);
    let ratioScore = 0;
    if (followerRatio > 2) {
      ratioScore = Math.min((followerRatio - 2) * 10, 20); // Bonus for high ratio
    } else if (followerRatio < 0.5) {
      ratioScore = -10; // Penalty for low ratio
    }

    // Account age bonus (more conservative)
    const accountAge = (Date.now() - new Date(user.createdAt).getTime()) / (1000 * 60 * 60 * 24);
    const ageScore = Math.min(accountAge / 60, 20); // CHANGED from 30 days to 60 days for max

    // PR#3: Activity consistency check
    const avgPostsPerDay = user.posts / Math.max(accountAge, 1);
    let consistencyBonus = 0;
    if (avgPostsPerDay >= 0.5 && avgPostsPerDay <= 5) {
      consistencyBonus = 10; // Bonus for consistent activity
    } else if (avgPostsPerDay > 10) {
      consistencyBonus = -10; // Penalty for spam-like activity
    }

    const finalScore = karmaScore + ratioScore + ageScore + consistencyBonus;
    return Math.max(0, Math.min(100, Math.round(finalScore)));
  }

  /**
   * Get sybil resistance score based on account age and activity
   * PR#3: More conservative thresholds and engagement quality check
   */
  async getSybilScore(handle: string): Promise<number> {
    const user = await this.getUser(handle);

    if (!user) {
      return 10; // PR#3: CHANGED from 20 to 10 (more conservative)
    }

    const accountAge = (Date.now() - new Date(user.createdAt).getTime()) / (1000 * 60 * 60 * 24);
    const velocity = this.calculateKarmaVelocity(user);

    // PR#3: More conservative age factor
    const ageFactor = Math.min(accountAge / 30, 40); // CHANGED from /10 to /30

    // Activity factor based on posts (more conservative)
    const activityFactor = Math.min(user.posts / 20, 30); // CHANGED from /10 to /20

    // Karma velocity factor (stricter penalties)
    let velocityFactor = 30;
    if (velocity > 100) {
      velocityFactor = 0; // Harsh penalty
    } else if (velocity > 75) {
      velocityFactor = 10; // CHANGED from 15
    } else if (velocity > 50) {
      velocityFactor = 20; // NEW tier
    }

    // PR#3: Engagement quality (followers/karma ratio)
    const engagementRatio = user.followers / Math.max(user.karma, 1);
    let engagementBonus = 0;
    if (engagementRatio > 0.1) {
      engagementBonus = Math.min(engagementRatio * 50, 10); // Max 10 points
    }

    const finalScore = ageFactor + activityFactor + velocityFactor + engagementBonus;
    return Math.max(0, Math.min(100, Math.round(finalScore)));
  }
}
