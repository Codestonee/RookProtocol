import { logger } from '../utils/logger';

/**
 * PR#5: Performance monitoring and metrics tracking
 * Tracks operation latency, success rates, and provides statistics
 */

interface PerformanceMetric {
  operation: string;
  duration: number;
  timestamp: number;
  success: boolean;
}

export class MetricsService {
  private metrics: PerformanceMetric[] = [];
  private maxMetrics: number;

  constructor(maxMetrics: number = 10000) {
    this.maxMetrics = maxMetrics;
  }

  /**
   * Record a metric
   * @param operation Operation name
   * @param duration Duration in milliseconds
   * @param success Whether operation succeeded
   */
  record(operation: string, duration: number, success: boolean = true): void {
    // Evict old metrics if needed
    if (this.metrics.length >= this.maxMetrics) {
      this.metrics.shift();
    }

    this.metrics.push({
      operation,
      duration,
      timestamp: Date.now(),
      success
    });

    logger.debug(`Metric: ${operation} took ${duration}ms (${success ? 'success' : 'failed'})`);
  }

  /**
   * Get average duration for operation
   * @param operation Operation name
   * @returns Average duration in milliseconds
   */
  getAverage(operation: string): number {
    const filtered = this.metrics.filter(m => m.operation === operation && m.success);
    if (filtered.length === 0) return 0;

    const sum = filtered.reduce((acc, m) => acc + m.duration, 0);
    return Math.round(sum / filtered.length);
  }

  /**
   * Get p50 (median) duration for operation
   */
  getP50(operation: string): number {
    return this.getPercentile(operation, 0.50);
  }

  /**
   * Get p95 duration for operation
   */
  getP95(operation: string): number {
    return this.getPercentile(operation, 0.95);
  }

  /**
   * Get p99 duration for operation
   */
  getP99(operation: string): number {
    return this.getPercentile(operation, 0.99);
  }

  /**
   * Get percentile duration for operation
   */
  private getPercentile(operation: string, percentile: number): number {
    const filtered = this.metrics
      .filter(m => m.operation === operation && m.success)
      .map(m => m.duration)
      .sort((a, b) => a - b);

    if (filtered.length === 0) return 0;

    const index = Math.floor(filtered.length * percentile);
    return filtered[index] || 0;
  }

  /**
   * Get success rate for operation
   * @param operation Operation name
   * @returns Success rate as percentage
   */
  getSuccessRate(operation: string): number {
    const filtered = this.metrics.filter(m => m.operation === operation);
    if (filtered.length === 0) return 0;

    const successful = filtered.filter(m => m.success).length;
    return (successful / filtered.length) * 100;
  }

  /**
   * Get all statistics
   */
  getStats() {
    const operations = [...new Set(this.metrics.map(m => m.operation))];

    return operations.map(op => ({
      operation: op,
      count: this.metrics.filter(m => m.operation === op).length,
      average: this.getAverage(op),
      p50: this.getP50(op),
      p95: this.getP95(op),
      p99: this.getP99(op),
      successRate: this.getSuccessRate(op).toFixed(2) + '%'
    }));
  }

  /**
   * Get cache hit rate (if caching is enabled)
   */
  getCacheHitRate(): number {
    const cacheHits = this.metrics.filter(m => m.operation === 'cache_hit').length;
    const cacheMisses = this.metrics.filter(m => m.operation === 'cache_miss').length;
    const total = cacheHits + cacheMisses;

    if (total === 0) return 0;
    return (cacheHits / total) * 100;
  }

  /**
   * Clear all metrics
   */
  clear(): void {
    this.metrics = [];
    logger.info('Metrics cleared');
  }

  /**
   * Get metrics for time window
   * @param windowMs Time window in milliseconds
   */
  getRecentMetrics(windowMs: number): PerformanceMetric[] {
    const cutoff = Date.now() - windowMs;
    return this.metrics.filter(m => m.timestamp > cutoff);
  }
}

// Global metrics instance
export const metrics = new MetricsService();
