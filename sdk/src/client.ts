import { ethers, Contract, Wallet, Provider, TransactionReceipt } from 'ethers';
import {
  EscrowParams,
  EscrowResult,
  VerificationResult,
  ChallengeParams,
  ChallengeResult,
  TrustScoreBreakdown,
  RookConfig,
  EscrowStatus,
  RiskLevel,
  AmountInput
} from './types';
import { CONTRACTS, DEFAULT_THRESHOLD, CHALLENGE_STAKE } from './utils/constants';
import { RookError, ErrorCodes } from './utils/errors';
import RookEscrowABI from './abi/RookEscrow.json';
import RookOracleABI from './abi/RookOracle.json';
import ERC20ABI from './abi/ERC20.json';

/**
 * Configuration options for RookProtocol SDK
 */
export interface RookProtocolOptions {
  /** Gas limit multiplier (default: 1.2) */
  gasLimitMultiplier?: number;
  /** Maximum confirmation blocks (default: 2) */
  confirmations?: number;
  /** Request timeout in ms (default: 30000) */
  timeout?: number;
  /** Enable debug logging */
  debug?: boolean;
}

/**
 * Rook Protocol SDK
 *
 * Trustless USDC escrow for AI agents with multi-layered verification.
 *
 * @example
 * ```typescript
 * const rook = new RookProtocol({
 *   network: 'base-sepolia',
 *   privateKey: process.env.PRIVATE_KEY
 * }, {
 *   gasLimitMultiplier: 1.5,
 *   confirmations: 3
 * });
 * ```
 */
export class RookProtocol {
  private provider: Provider;
  private signer: Wallet | null;
  private escrowContract: Contract;
  private oracleContract: Contract;
  private usdcContract: Contract;
  private network: string;
  private options: Required<RookProtocolOptions>;

  constructor(
    config: RookConfig,
    options: RookProtocolOptions = {}
  ) {
    this.network = config.network || 'base-sepolia';

    // Validate network
    if (!CONTRACTS[this.network]) {
      throw new RookError(ErrorCodes.INVALID_NETWORK,
        `Unsupported network: ${this.network}. Use 'base-sepolia' or 'base'`);
    }

    // Merge options with defaults
    this.options = {
      gasLimitMultiplier: options.gasLimitMultiplier ?? 1.2,
      confirmations: options.confirmations ?? 2,
      timeout: options.timeout ?? 30000,
      debug: options.debug ?? false
    };

    // Setup provider with timeout
    const rpcUrl = config.rpcUrl || this.getDefaultRpc(this.network);
    this.provider = new ethers.JsonRpcProvider(rpcUrl, undefined, {
      staticNetwork: true
    });

    // Setup signer
    if (config.privateKey) {
      if (this.options.debug) {
        console.warn('[RookProtocol] Using private key in constructor. Consider using a signer interface for better security.');
      }
      this.signer = new Wallet(config.privateKey, this.provider);
    } else {
      this.signer = null;
    }

    // Setup contracts
    const addresses = CONTRACTS[this.network];

    this.escrowContract = new Contract(
      addresses.escrow,
      RookEscrowABI,
      this.signer || this.provider
    );

    this.oracleContract = new Contract(
      addresses.oracle,
      RookOracleABI,
      this.signer || this.provider
    );

    this.usdcContract = new Contract(
      addresses.usdc,
      ERC20ABI,
      this.signer || this.provider
    );
  }

  // =================================================================
  // VALIDATION HELPERS
  // =================================================================

  // Cache for oracle timeout (read from chain)
  private oracleTimeoutCache: { value: number; timestamp: number } | null = null;
  private readonly TIMEOUT_CACHE_TTL = 60 * 60 * 1000; // 1 hour

  /**
   * Normalize amount input to bigint (USDC units with 6 decimals)
   */
  private normalizeAmount(amount: AmountInput): bigint {
    if (typeof amount === 'bigint') {
      return amount;
    }
    if (typeof amount === 'string') {
      // Parse decimal string like "100.50"
      return ethers.parseUnits(amount, 6);
    }
    if (typeof amount === 'number') {
      if (isNaN(amount)) {
        throw new RookError(ErrorCodes.INVALID_AMOUNT, 'Amount is NaN');
      }
      return ethers.parseUnits(amount.toString(), 6);
    }
    throw new RookError(ErrorCodes.INVALID_AMOUNT, 'Amount must be number, string, or bigint');
  }

  /**
   * Get oracle timeout from chain (cached)
   */
  async getOracleTimeout(): Promise<number> {
    // Return cached value if valid
    if (this.oracleTimeoutCache && Date.now() - this.oracleTimeoutCache.timestamp < this.TIMEOUT_CACHE_TTL) {
      return this.oracleTimeoutCache.value;
    }

    try {
      const timeout = await this.escrowContract.ORACLE_TIMEOUT();
      const value = Number(timeout);
      this.oracleTimeoutCache = { value, timestamp: Date.now() };
      return value;
    } catch (error) {
      // Fallback to 1 day if contract call fails
      return 24 * 60 * 60;
    }
  }

  /**
   * Validate escrow parameters before creation
   */
  private validateEscrowParams(params: EscrowParams): bigint {
    // Normalize and validate amount
    let amountBigInt: bigint;
    try {
      amountBigInt = this.normalizeAmount(params.amount);
    } catch (error) {
      throw new RookError(ErrorCodes.INVALID_AMOUNT, 'Invalid amount format');
    }

    if (amountBigInt <= 0n) {
      throw new RookError(ErrorCodes.INVALID_AMOUNT, 'Amount must be greater than 0');
    }

    const maxAmount = ethers.parseUnits('1000000', 6); // 1M USDC
    if (amountBigInt > maxAmount) {
      throw new RookError(ErrorCodes.INVALID_AMOUNT, 'Amount exceeds maximum (1M USDC)');
    }

    if (!params.recipient || typeof params.recipient !== 'string') {
      throw new RookError(ErrorCodes.INVALID_AGENT, 'Recipient is required');
    }

    if (!params.job || params.job.length === 0) {
      throw new RookError(ErrorCodes.INVALID_AGENT, 'Job description is required');
    }
    if (params.job.length > 1000) {
      throw new RookError(ErrorCodes.INVALID_AGENT, 'Job description too long (max 1000 chars)');
    }

    const threshold = params.threshold ?? DEFAULT_THRESHOLD;
    if (threshold < 50 || threshold > 100) {
      throw new RookError(ErrorCodes.INVALID_THRESHOLD, 'Threshold must be between 50 and 100');
    }

    return amountBigInt;
  }

  /**
   * Wait for transaction with timeout and confirmation checks
   */
  private async waitForTransaction(
    txPromise: Promise<any>,
    operation: string
  ): Promise<TransactionReceipt> {
    const timeoutPromise = new Promise<never>((_, reject) => {
      setTimeout(() => {
        reject(new RookError(ErrorCodes.NETWORK_ERROR,
          `${operation} timed out after ${this.options.timeout}ms`));
      }, this.options.timeout);
    });

    try {
      const tx = await Promise.race([txPromise, timeoutPromise]);
      const receipt = await tx.wait(this.options.confirmations);

      if (receipt.status !== 1) {
        throw new RookError(ErrorCodes.TRANSFER_FAILED,
          `${operation} failed - transaction reverted`);
      }

      return receipt;
    } catch (error: any) {
      if (error instanceof RookError) throw error;

      if (error.code === 'CALL_EXCEPTION') {
        throw new RookError(ErrorCodes.TRANSFER_FAILED,
          `${operation} failed: ${error.reason || 'Contract call reverted'}`);
      }

      throw new RookError(ErrorCodes.NETWORK_ERROR,
        `${operation} failed: ${error.message}`);
    }
  }

  // =================================================================
  // ESCROW OPERATIONS
  // =================================================================

  /**
   * Create a new escrow with full validation
   *
   * @param params - Escrow parameters
   * @returns Escrow result with ID and transaction details
   *
   * @example
   * ```typescript
   * const escrow = await rook.createEscrow({
   *   amount: 50,
   *   recipient: '0x...',
   *   job: 'Market analysis',
   *   threshold: 65
   * });
   * ```
   */
  async createEscrow(params: EscrowParams): Promise<EscrowResult> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);

    // Validate and normalize amount
    const amount = this.validateEscrowParams(params);
    const jobHash = ethers.keccak256(ethers.toUtf8Bytes(params.job));
    const threshold = params.threshold || DEFAULT_THRESHOLD;

    const seller = await this.resolveAddress(params.recipient);

    // Check buyer balance
    const buyerAddress = await this.signer.getAddress();
    const balance = await this.usdcContract.balanceOf(buyerAddress);
    if (balance < amount) {
      throw new RookError(ErrorCodes.INSUFFICIENT_BALANCE,
        `Insufficient USDC balance. Have: ${ethers.formatUnits(balance, 6)}, Need: ${params.amount}`);
    }

    // Check allowance
    const escrowAddress = await this.escrowContract.getAddress();
    const allowance = await this.usdcContract.allowance(buyerAddress, escrowAddress);
    if (allowance < amount) {
      const approveTx = await this.usdcContract.approve(escrowAddress, amount);
      await this.waitForTransaction(Promise.resolve(approveTx), 'USDC approval');
    }

    // Create escrow with gas estimation
    const txPromise = this.escrowContract.createEscrow(
      seller,
      amount,
      jobHash,
      threshold,
      {
        gasLimit: await this.estimateGas('createEscrow', [seller, amount, jobHash, threshold])
      }
    );

    const receipt = await this.waitForTransaction(txPromise, 'Escrow creation');

    // Parse escrow ID from event (filter by contract address to prevent hijacking)
    const iface = this.escrowContract.interface;
    const escrowCreatedEvent = receipt.logs
      .filter((log: any) => log.address.toLowerCase() === escrowAddress.toLowerCase())
      .map((log: any) => {
        try {
          return iface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((parsed: any) => parsed && parsed.name === 'EscrowCreated');

    const escrowId = escrowCreatedEvent?.args?.escrowId;

    if (!escrowId) {
      throw new RookError(ErrorCodes.UNKNOWN, 'Failed to parse escrow ID from transaction');
    }

    return {
      id: escrowId,
      buyer: buyerAddress,
      seller,
      amount: Number(ethers.formatUnits(amount, 6)),
      job: params.job,
      threshold,
      status: 'Active' as EscrowStatus,
      createdAt: Math.floor(Date.now() / 1000),
      txHash: receipt.hash
    };
  }

  /**
   * Estimate gas for a contract method
   */
  private async estimateGas(method: string, args: any[]): Promise<bigint> {
    try {
      const estimated = await this.escrowContract[method].estimateGas(...args);
      return BigInt(Math.floor(Number(estimated) * this.options.gasLimitMultiplier));
    } catch {
      return BigInt(300000);
    }
  }

  /**
   * Release escrow (requires oracle authorization)
   *
   * @param escrowId - Escrow identifier
   * @returns Transaction hash
   */
  async release(escrowId: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);

    const isOp = await this.isOperator();
    if (!isOp) {
      throw new RookError(ErrorCodes.UNAUTHORIZED,
        'Only oracle operators can release escrows. Use releaseWithConsent() after timeout.');
    }

    const txPromise = this.oracleContract.triggerRelease(escrowId);
    const receipt = await this.waitForTransaction(txPromise, 'Escrow release');

    return receipt.hash;
  }

  /**
   * Release escrow with mutual consent (after oracle timeout)
   *
   * @param escrowId - Escrow identifier
   * @returns Transaction hash
   */
  async releaseWithConsent(escrowId: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);

    const escrow = await this.getEscrow(escrowId);
    if (escrow.status !== 'Active') {
      throw new RookError(ErrorCodes.ESCROW_NOT_ACTIVE,
        `Escrow is ${escrow.status.toLowerCase()}, not active`);
    }

    // Get oracle timeout from chain (cached)
    const oracleTimeout = await this.getOracleTimeout();
    if (escrow.createdAt && (Date.now() / 1000 - escrow.createdAt < oracleTimeout)) {
      const hoursRemaining = Math.ceil((oracleTimeout - (Date.now() / 1000 - escrow.createdAt)) / 3600);
      throw new RookError(ErrorCodes.UNAUTHORIZED,
        `Oracle timeout not met. Wait ${hoursRemaining} more hours.`);
    }

    const txPromise = this.escrowContract.releaseWithConsent(escrowId);
    const receipt = await this.waitForTransaction(txPromise, 'Consent release');

    return receipt.hash;
  }

  /**
   * Request refund (buyer only)
   *
   * @param escrowId - Escrow identifier
   * @param reason - Refund reason
   * @returns Transaction hash
   */
  async refund(escrowId: string, reason: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);

    if (!reason || reason.length === 0) {
      throw new RookError(ErrorCodes.INVALID_AGENT, 'Refund reason is required');
    }
    if (reason.length > 1000) {
      throw new RookError(ErrorCodes.INVALID_AGENT, 'Reason too long (max 1000 chars)');
    }

    const txPromise = this.escrowContract.refundEscrow(escrowId, reason);
    const receipt = await this.waitForTransaction(txPromise, 'Refund');

    return receipt.hash;
  }

  /**
   * Escalate to dispute
   *
   * @param escrowId - Escrow identifier
   * @param evidence - IPFS hash or URL of evidence
   * @returns Transaction hash
   */
  async dispute(escrowId: string, evidence: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);

    if (!evidence || evidence.length === 0) {
      throw new RookError(ErrorCodes.INVALID_AGENT, 'Evidence is required');
    }
    if (evidence.length > 1000) {
      throw new RookError(ErrorCodes.INVALID_AGENT, 'Evidence too long (max 1000 chars)');
    }

    const txPromise = this.escrowContract.disputeEscrow(escrowId, evidence);
    const receipt = await this.waitForTransaction(txPromise, 'Dispute filing');

    return receipt.hash;
  }

  /**
   * Resolve dispute (owner only)
   *
   * @param escrowId - Escrow identifier
   * @param winner - Address of winner (buyer or seller)
   * @param reason - Resolution reason
   * @returns Transaction hash
   */
  async resolveDispute(escrowId: string, winner: string, reason: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);

    if (!ethers.isAddress(winner)) {
      throw new RookError(ErrorCodes.INVALID_AGENT, 'Invalid winner address');
    }

    const txPromise = this.escrowContract.resolveDispute(escrowId, winner, reason);
    const receipt = await this.waitForTransaction(txPromise, 'Dispute resolution');

    return receipt.hash;
  }

  /**
   * Get escrow details
   *
   * @param escrowId - Escrow identifier
   * @returns Escrow details
   */
  async getEscrow(escrowId: string): Promise<EscrowResult> {
    const escrow = await this.escrowContract.getEscrow(escrowId);

    const statusMap: EscrowStatus[] = ['Active', 'Released', 'Refunded', 'Disputed', 'Challenged'];

    return {
      id: escrowId,
      buyer: escrow.buyer,
      seller: escrow.seller,
      amount: Number(ethers.formatUnits(escrow.amount, 6)),
      job: '', // Job hash only stored on-chain
      threshold: Number(escrow.trustThreshold),
      status: statusMap[escrow.status] || 'Unknown',
      createdAt: Number(escrow.createdAt),
      expiresAt: Number(escrow.expiresAt)
    };
  }

  // =================================================================
  // VERIFICATION
  // =================================================================

  /**
   * Verify an agent's trust score
   *
   * @param agent - Agent address or handle
   * @returns Verification result with trust score breakdown
   */
  async verify(agent: string): Promise<VerificationResult> {
    const address = await this.resolveAddress(agent);

    const [
      identity,
      reputation,
      sybil,
      history,
      challengeBonus,
      composite
    ] = await this.oracleContract.getScoreBreakdown(address);

    const trustScore = Number(composite) / 100;

    const breakdown: TrustScoreBreakdown = {
      erc8004_identity: Number(identity) / 100,
      reputation_signals: Number(reputation) / 100,
      sybil_resistance: Number(sybil) / 100,
      escrow_history: Number(history) / 100,
      challenge_bonus: Number(challengeBonus) / 100
    };

    let riskLevel: RiskLevel;
    if (trustScore >= 0.80) riskLevel = 'LOW';
    else if (trustScore >= 0.65) riskLevel = 'STANDARD';
    else if (trustScore >= 0.50) riskLevel = 'ELEVATED';
    else riskLevel = 'HIGH';

    let recommendation: string;
    if (trustScore >= 0.80) recommendation = 'Auto-release enabled';
    else if (trustScore >= 0.65) recommendation = 'Auto-release with monitoring';
    else if (trustScore >= 0.50) recommendation = 'Manual review recommended';
    else recommendation = 'Challenge required before release';

    return {
      agent,
      address,
      trust_score: trustScore,
      breakdown,
      risk_level: riskLevel,
      recommendation
    };
  }

  // =================================================================
  // CHALLENGES (Voight-Kampff)
  // =================================================================

  /**
   * Initiate identity challenge (stake is fixed at 5 USDC)
   *
   * @param params - Challenge parameters
   * @returns Challenge result
   */
  async challenge(params: ChallengeParams): Promise<ChallengeResult> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);

    // Check cooldown
    const challengerAddress = await this.signer.getAddress();
    const nextChallengeTime = await this.escrowContract.getNextChallengeTime(challengerAddress);
    if (Number(nextChallengeTime) > Date.now() / 1000) {
      const minutesRemaining = Math.ceil((Number(nextChallengeTime) - Date.now() / 1000) / 60);
      throw new RookError(ErrorCodes.UNAUTHORIZED,
        `Challenge cooldown active. Wait ${minutesRemaining} more minutes.`);
    }

    // Use fixed stake amount
    const stakeAmount = ethers.parseUnits(CHALLENGE_STAKE.toString(), 6);
    const escrowAddress = await this.escrowContract.getAddress();

    // Approve USDC for stake
    const allowance = await this.usdcContract.allowance(challengerAddress, escrowAddress);
    if (allowance < stakeAmount) {
      const approveTx = await this.usdcContract.approve(escrowAddress, stakeAmount);
      await this.waitForTransaction(Promise.resolve(approveTx), 'Stake approval');
    }

    // Initiate challenge
    const txPromise = this.escrowContract.initiateChallenge(params.escrowId);
    const receipt = await this.waitForTransaction(txPromise, 'Challenge initiation');

    // Get challenge details
    const challenge = await this.escrowContract.getChallenge(params.escrowId);

    return {
      escrowId: params.escrowId,
      challenger: challengerAddress,
      stake: CHALLENGE_STAKE,
      deadline: Number(challenge.deadline),
      reason: params.reason,
      txHash: receipt.hash
    };
  }

  /**
   * Respond to challenge (seller only)
   *
   * @param escrowId - Escrow identifier
   * @param responseData - Response data (will be hashed)
   * @returns Transaction hash
   */
  async respondChallenge(escrowId: string, responseData: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);

    if (!responseData || responseData.length === 0) {
      throw new RookError(ErrorCodes.INVALID_AGENT, 'Response data is required');
    }

    const responseHash = ethers.keccak256(ethers.toUtf8Bytes(responseData));

    const txPromise = this.escrowContract.respondChallenge(escrowId, responseHash);
    const receipt = await this.waitForTransaction(txPromise, 'Challenge response');

    return receipt.hash;
  }

  /**
   * Resolve challenge (oracle only)
   *
   * @param escrowId - Escrow identifier
   * @param passed - Whether challenge was passed
   * @returns Transaction hash
   */
  async resolveChallenge(escrowId: string, passed: boolean): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);

    const isOp = await this.isOperator();
    if (!isOp) {
      throw new RookError(ErrorCodes.UNAUTHORIZED, 'Only oracle operators can resolve challenges');
    }

    const txPromise = this.oracleContract.resolveChallenge(escrowId, passed);
    const receipt = await this.waitForTransaction(txPromise, 'Challenge resolution');

    return receipt.hash;
  }

  /**
   * Claim challenge timeout (challenger wins if seller didn't respond)
   *
   * @param escrowId - Escrow identifier
   * @returns Transaction hash
   */
  async claimTimeout(escrowId: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);

    // Check if deadline has passed
    const challenge = await this.escrowContract.getChallenge(escrowId);
    const currentBlock = await this.getBlockNumber();

    if (currentBlock <= Number(challenge.deadline)) {
      const blocksRemaining = Number(challenge.deadline) - currentBlock;
      throw new RookError(ErrorCodes.CHALLENGE_NOT_EXPIRED,
        `Challenge deadline not reached. ${blocksRemaining} blocks remaining.`);
    }

    const txPromise = this.escrowContract.claimChallengeTimeout(escrowId);
    const receipt = await this.waitForTransaction(txPromise, 'Timeout claim');

    return receipt.hash;
  }

  // =================================================================
  // UTILITIES
  // =================================================================

  /**
   * Resolve agent handle to address
   */
  private async resolveAddress(agent: string): Promise<string> {
    if (ethers.isAddress(agent)) {
      return agent;
    }

    if (agent.startsWith('@')) {
      // TODO: Implement Moltbook API lookup
      throw new RookError(ErrorCodes.NOT_IMPLEMENTED, 'Moltbook resolution coming soon');
    }

    if (agent.endsWith('.eth')) {
      const address = await this.provider.resolveName(agent);
      if (!address) {
        throw new RookError(ErrorCodes.INVALID_AGENT, `Could not resolve ENS: ${agent}`);
      }
      return address;
    }

    throw new RookError(ErrorCodes.INVALID_AGENT, `Invalid agent identifier: ${agent}`);
  }

  private getDefaultRpc(network: string): string {
    switch (network) {
      case 'base-sepolia':
        return 'https://sepolia.base.org';
      case 'base':
        return 'https://mainnet.base.org';
      default:
        throw new RookError(ErrorCodes.INVALID_NETWORK);
    }
  }

  /**
   * Get current block number
   */
  async getBlockNumber(): Promise<number> {
    return this.provider.getBlockNumber();
  }

  /**
   * Get USDC balance
   */
  async getBalance(address?: string): Promise<number> {
    const addr = address || (this.signer ? await this.signer.getAddress() : null);
    if (!addr) throw new RookError(ErrorCodes.NO_SIGNER);

    const balance = await this.usdcContract.balanceOf(addr);
    return Number(ethers.formatUnits(balance, 6));
  }

  /**
   * Check if address is oracle operator
   */
  async isOperator(address?: string): Promise<boolean> {
    const addr = address || (this.signer ? await this.signer.getAddress() : null);
    if (!addr) throw new RookError(ErrorCodes.NO_SIGNER);

    return this.oracleContract.operators(addr);
  }

  /**
   * Listen for escrow creation events (requires WebSocket provider)
   */
  onEscrowCreated(callback: (escrowId: string, buyer: string, seller: string, amount: bigint) => void) {
    this.escrowContract.on('EscrowCreated', callback);
    return () => this.escrowContract.off('EscrowCreated', callback);
  }

  /**
   * Listen for escrow release events
   */
  onEscrowReleased(callback: (escrowId: string, seller: string, amount: bigint) => void) {
    this.escrowContract.on('EscrowReleased', callback);
    return () => this.escrowContract.off('EscrowReleased', callback);
  }
}

export default RookProtocol;
