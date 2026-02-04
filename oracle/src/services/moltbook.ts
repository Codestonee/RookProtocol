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

  constructor(apiKey: string, baseUrl: string = 'https://api.moltbook.com') {
    this.apiKey = apiKey;
    this.baseUrl = baseUrl;
  }

  /**
   * Fetch user data from Moltbook
   */
  async getUser(handle: string): Promise<MoltbookUser | null> {
    try {
      const cleanHandle = handle.startsWith('@') ? handle.slice(1) : handle;
      
      const response = await axios.get(`${this.baseUrl}/users/${cleanHandle}`, {
        headers: {
          'Authorization': `Bearer ${this.apiKey}`
        }
      });

      return response.data;
    } catch (error) {
      logger.error('Error fetching Moltbook user:', error);
      return null;
    }
  }

  /**
   * Calculate karma velocity (karma per day since creation)
   */
  calculateKarmaVelocity(user: MoltbookUser): number {
    const createdAt = new Date(user.createdAt);
    const daysSinceCreation = Math.max(1, (Date.now() - createdAt.getTime()) / (1000 * 60 * 60 * 24));
    return user.karma / daysSinceCreation;
  }

  /**
   * Check for suspicious karma patterns
   */
  isKarmaSuspicious(user: MoltbookUser): boolean {
    const velocity = this.calculateKarmaVelocity(user);
    // More than 100 karma per day is suspicious
    return velocity > 100;
  }

  /**
   * Get social score (0-100)
   */
  async getSocialScore(handle: string): Promise<number> {
    const user = await this.getUser(handle);
    
    if (!user) {
      return 30; // Low score for unknown users
    }

    // Check for suspicious patterns
    if (this.isKarmaSuspicious(user)) {
      logger.warn(`Suspicious karma pattern for ${handle}: ${this.calculateKarmaVelocity(user).toFixed(2)} karma/day`);
      return 20; // Penalty for suspicious activity
    }

    // Base score on karma (capped at 1000 karma = 100 score)
    const karmaScore = Math.min(user.karma / 10, 100);
    
    // Follower ratio bonus/penalty
    const followerRatio = user.followers / Math.max(user.following, 1);
    const ratioScore = Math.min(followerRatio * 20, 30); // Max 30 points

    // Account age bonus
    const accountAge = (Date.now() - new Date(user.createdAt).getTime()) / (1000 * 60 * 60 * 24);
    const ageScore = Math.min(accountAge / 30, 20); // Max 20 points for 30+ days

    return Math.min(karmaScore + ratioScore + ageScore, 100);
  }

  /**
   * Get sybil resistance score based on account age and activity
   */
  async getSybilScore(handle: string): Promise<number> {
    const user = await this.getUser(handle);
    
    if (!user) {
      return 20; // Low score for unknown
    }

    const accountAge = (Date.now() - new Date(user.createdAt).getTime()) / (1000 * 60 * 60 * 24);
    const velocity = this.calculateKarmaVelocity(user);

    // Age factor (0-40 points)
    const ageFactor = Math.min(accountAge / 10, 40);

    // Activity factor based on posts (0-30 points)
    const activityFactor = Math.min(user.posts / 10, 30);

    // Karma velocity factor (penalty for suspicious velocity)
    let velocityFactor = 30;
    if (velocity > 100) velocityFactor = 0;
    else if (velocity > 50) velocityFactor = 15;

    return Math.min(ageFactor + activityFactor + velocityFactor, 100);
  }
}
