import { ethers, Contract, Wallet, Provider } from 'ethers';
import { 
  EscrowParams, 
  EscrowResult, 
  VerificationResult, 
  ChallengeParams,
  ChallengeResult,
  TrustScoreBreakdown,
  RookConfig 
} from './types';
import { CONTRACTS, DEFAULT_THRESHOLD, CHALLENGE_STAKE } from './utils/constants';
import { RookError, ErrorCodes } from './utils/errors';
import RookEscrowABI from './abi/RookEscrow.json';
import RookOracleABI from './abi/RookOracle.json';
import ERC20ABI from './abi/ERC20.json';

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
 * });
 * 
 * const escrow = await rook.createEscrow({
 *   amount: 50,
 *   recipient: '0x...',
 *   job: 'Market analysis',
 *   threshold: 65
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

  constructor(config: RookConfig) {
    this.network = config.network || 'base-sepolia';
    
    const rpcUrl = config.rpcUrl || this.getDefaultRpc(this.network);
    this.provider = new ethers.JsonRpcProvider(rpcUrl);
    
    if (config.privateKey) {
      this.signer = new Wallet(config.privateKey, this.provider);
    } else {
      this.signer = null;
    }
    
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

  // ═══════════════════════════════════════════════════════════════
  // ESCROW OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /**
   * Create a new escrow
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
    
    const amount = ethers.parseUnits(params.amount.toString(), 6);
    const jobHash = ethers.keccak256(ethers.toUtf8Bytes(params.job));
    const threshold = params.threshold || DEFAULT_THRESHOLD;
    
    // Resolve recipient address
    const seller = await this.resolveAddress(params.recipient);
    
    // Approve USDC
    const approveTx = await this.usdcContract.approve(
      await this.escrowContract.getAddress(),
      amount
    );
    await approveTx.wait();
    
    // Create escrow
    const tx = await this.escrowContract.createEscrow(
      seller,
      amount,
      jobHash,
      threshold
    );
    const receipt = await tx.wait();
    
    // Parse escrow ID from event using interface
    const iface = this.escrowContract.interface;
    const escrowCreatedEvent = receipt.logs
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
      buyer: await this.signer.getAddress(),
      seller,
      amount: params.amount,
      job: params.job,
      threshold,
      status: 'Active',
      txHash: receipt.hash
    };
  }

  /**
   * Release escrow (requires oracle authorization)
   * 
   * @param escrowId - Escrow identifier
   * @returns Transaction hash
   */
  async release(escrowId: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);
    
    // Check if caller is oracle operator
    const isOperator = await this.oracleContract.operators(await this.signer.getAddress());
    if (!isOperator) {
      throw new RookError(ErrorCodes.UNAUTHORIZED, 'Only oracle operators can release escrows');
    }
    
    const tx = await this.oracleContract.triggerRelease(escrowId);
    const receipt = await tx.wait();
    
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
    
    const tx = await this.escrowContract.releaseWithConsent(escrowId);
    const receipt = await tx.wait();
    
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
    
    const tx = await this.escrowContract.refundEscrow(escrowId, reason);
    const receipt = await tx.wait();
    
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
    
    const tx = await this.escrowContract.disputeEscrow(escrowId, evidence);
    const receipt = await tx.wait();
    
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
    
    const tx = await this.escrowContract.resolveDispute(escrowId, winner, reason);
    const receipt = await tx.wait();
    
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
    
    return {
      id: escrowId,
      buyer: escrow.buyer,
      seller: escrow.seller,
      amount: Number(ethers.formatUnits(escrow.amount, 6)),
      job: '', // Job hash only stored on-chain
      threshold: Number(escrow.trustThreshold),
      status: ['Active', 'Released', 'Refunded', 'Disputed', 'Challenged'][escrow.status],
      createdAt: Number(escrow.createdAt),
      expiresAt: Number(escrow.expiresAt)
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // VERIFICATION
  // ═══════════════════════════════════════════════════════════════

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
    
    let riskLevel: string;
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

  // ═══════════════════════════════════════════════════════════════
  // CHALLENGES (Voight-Kampff)
  // ═══════════════════════════════════════════════════════════════

  /**
   * Initiate identity challenge
   * 
   * @param params - Challenge parameters
   * @returns Challenge result
   * 
   * @remarks The stake amount is fixed at 5 USDC by the contract.
   * Any stake value provided in params is ignored.
   */
  async challenge(params: ChallengeParams): Promise<ChallengeResult> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);
    
    // NOTE: Contract uses fixed CHALLENGE_STAKE (5 USDC)
    // We use the constant instead of params.stake to avoid approval mismatch
    const stakeAmount = CHALLENGE_STAKE;
    
    // Approve USDC for stake
    const approveTx = await this.usdcContract.approve(
      await this.escrowContract.getAddress(),
      stakeAmount
    );
    await approveTx.wait();
    
    // Initiate challenge
    const tx = await this.escrowContract.initiateChallenge(params.escrowId);
    const receipt = await tx.wait();
    
    // Get challenge details
    const challenge = await this.escrowContract.getChallenge(params.escrowId);
    
    return {
      escrowId: params.escrowId,
      challenger: await this.signer.getAddress(),
      stake: Number(ethers.formatUnits(stakeAmount, 6)),
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
    
    const responseHash = ethers.keccak256(ethers.toUtf8Bytes(responseData));
    
    const tx = await this.escrowContract.respondChallenge(escrowId, responseHash);
    const receipt = await tx.wait();
    
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
    
    // Check if caller is oracle operator
    const isOperator = await this.oracleContract.operators(await this.signer.getAddress());
    if (!isOperator) {
      throw new RookError(ErrorCodes.UNAUTHORIZED, 'Only oracle operators can resolve challenges');
    }
    
    const tx = await this.oracleContract.resolveChallenge(escrowId, passed);
    const receipt = await tx.wait();
    
    return receipt.hash;
  }

  /**
   * Claim challenge timeout (challenger wins)
   * 
   * @param escrowId - Escrow identifier
   * @returns Transaction hash
   */
  async claimTimeout(escrowId: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);
    
    const tx = await this.escrowContract.claimChallengeTimeout(escrowId);
    const receipt = await tx.wait();
    
    return receipt.hash;
  }

  // ═══════════════════════════════════════════════════════════════
  // UTILITIES
  // ═══════════════════════════════════════════════════════════════

  /**
   * Resolve agent handle to address
   */
  private async resolveAddress(agent: string): Promise<string> {
    // If already an address, return it
    if (ethers.isAddress(agent)) {
      return agent;
    }
    
    // If Moltbook handle (@username), resolve via API
    if (agent.startsWith('@')) {
      // TODO: Implement Moltbook API lookup
      throw new RookError(ErrorCodes.NOT_IMPLEMENTED, 'Moltbook resolution coming soon');
    }
    
    // If ENS name, resolve
    if (agent.endsWith('.eth')) {
      const address = await this.provider.resolveName(agent);
      if (!address) throw new RookError(ErrorCodes.INVALID_AGENT, `Could not resolve ${agent}`);
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
}

export default RookProtocol;
