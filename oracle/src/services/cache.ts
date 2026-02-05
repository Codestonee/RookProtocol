import { logger } from '../utils/logger';
import { metrics } from '../monitoring/metrics';

/**
 * PR#4: In-memory caching service for trust scores
 * Provides TTL-based caching with automatic eviction
 * HIGH-IMPACT FIX: Integrated with metrics tracking
 */

interface CacheEntry<T> {
  data: T;
  timestamp: number;
  ttl: number; // Time to live in milliseconds
}

export class CacheService {
  private cache: Map<string, CacheEntry<any>>;
  private maxSize: number;
  private evicting: boolean = false;

  constructor(maxSize: number = 1000) {
    this.cache = new Map();
    this.maxSize = maxSize;
  }

  /**
   * Get cached value
   * @param key Cache key
   * @returns Cached value or null if expired/missing
   * HIGH-IMPACT FIX: Tracks cache hits and misses
   */
  get<T>(key: string): T | null {
    const entry = this.cache.get(key);

    if (!entry) {
      logger.debug(`Cache miss: ${key}`);
      metrics.record('cache_miss', 0);
      return null;
    }

    // Check if expired
    if (Date.now() > entry.timestamp + entry.ttl) {
      this.cache.delete(key);
      logger.debug(`Cache expired: ${key}`);
      metrics.record('cache_miss', 0);
      return null;
    }

    logger.debug(`Cache hit: ${key}`);
    metrics.record('cache_hit', 0);
    return entry.data as T;
  }

  /**
   * Set cached value with TTL
   * @param key Cache key
   * @param data Data to cache
   * @param ttl Time to live in milliseconds
   */
  set<T>(key: string, data: T, ttl: number): void {
    // CONCURRENCY FIX: Set first, then evict if needed
    this.cache.set(key, {
      data,
      timestamp: Date.now(),
      ttl
    });

    logger.debug(`Cache set: ${key} (TTL: ${ttl}ms)`);

    // Evict oldest entries if cache exceeds maxSize (LRU-like)
    // Use flag to prevent concurrent evictions
    if (this.cache.size > this.maxSize && !this.evicting) {
      this.evicting = true;
      try {
        const entriesToRemove = this.cache.size - this.maxSize;
        const iterator = this.cache.keys();
        for (let i = 0; i < entriesToRemove; i++) {
          const oldestKey = iterator.next().value;
          if (oldestKey && oldestKey !== key) { // Don't evict what we just set
            this.cache.delete(oldestKey);
            logger.debug(`Cache evicted: ${oldestKey}`);
          }
        }
      } finally {
        this.evicting = false;
      }
    }
  }

  /**
   * Clear entire cache
   */
  clear(): void {
    this.cache.clear();
    logger.info('Cache cleared');
  }

  /**
   * Delete specific key
   * @param key Cache key to delete
   */
  delete(key: string): boolean {
    const deleted = this.cache.delete(key);
    if (deleted) {
      logger.debug(`Cache deleted: ${key}`);
    }
    return deleted;
  }

  /**
   * Get cache statistics
   */
  getStats() {
    return {
      size: this.cache.size,
      maxSize: this.maxSize,
      keys: Array.from(this.cache.keys())
    };
  }

  /**
   * Clean expired entries
   */
  cleanExpired(): number {
    let cleaned = 0;
    const now = Date.now();

    for (const [key, entry] of this.cache.entries()) {
      if (now > entry.timestamp + entry.ttl) {
        this.cache.delete(key);
        cleaned++;
      }
    }

    if (cleaned > 0) {
      logger.info(`Cleaned ${cleaned} expired cache entries`);
    }

    return cleaned;
  }
}
