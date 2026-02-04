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
    
    // Extract escrow ID from event
    const event = receipt.logs.find(
      (log: any) => log.fragment?.name === 'EscrowCreated'
    );
    const escrowId = event?.args?.escrowId;
    
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
   */
  async release(escrowId: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);
    
    // This is typically triggered by the oracle, but can be manual
    const tx = await this.oracleContract.triggerRelease(escrowId);
    const receipt = await tx.wait();
    
    return receipt.hash;
  }

  /**
   * Request refund
   */
  async refund(escrowId: string, reason: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);
    
    const tx = await this.escrowContract.refundEscrow(escrowId, reason);
    const receipt = await tx.wait();
    
    return receipt.hash;
  }

  /**
   * Escalate to dispute
   */
  async dispute(escrowId: string, evidence: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);
    
    const tx = await this.escrowContract.disputeEscrow(escrowId, evidence);
    const receipt = await tx.wait();
    
    return receipt.hash;
  }

  /**
   * Get escrow details
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
   */
  async challenge(params: ChallengeParams): Promise<ChallengeResult> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);
    
    const stake = params.stake || CHALLENGE_STAKE;
    const stakeAmount = ethers.parseUnits(stake.toString(), 6);
    
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
      stake,
      deadline: Number(challenge.deadline),
      reason: params.reason,
      txHash: receipt.hash
    };
  }

  /**
   * Respond to challenge (prove identity)
   */
  async prove(
    escrowId: string, 
    method: 'wallet_signature' | 'behavioral' | 'tee_attestation'
  ): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);
    
    switch (method) {
      case 'wallet_signature':
        return this.proveWithSignature(escrowId);
      case 'behavioral':
        return this.proveWithBehavioral(escrowId);
      case 'tee_attestation':
        throw new RookError(ErrorCodes.NOT_IMPLEMENTED, 'TEE attestation coming soon');
      default:
        throw new RookError(ErrorCodes.INVALID_METHOD);
    }
  }

  private async proveWithSignature(escrowId: string): Promise<string> {
    if (!this.signer) throw new RookError(ErrorCodes.NO_SIGNER);
    
    // Generate challenge nonce
    const nonce = ethers.keccak256(
      ethers.solidityPacked(
        ['bytes32', 'uint256'],
        [escrowId, Date.now()]
      )
    );
    
    // Sign the nonce
    const signature = await this.signer.signMessage(ethers.getBytes(nonce));
    
    // Submit proof to oracle (off-chain verification)
    // In production, this would call an API
    console.log('Proof submitted:', { escrowId, nonce, signature });
    
    return signature;
  }

  private async proveWithBehavioral(escrowId: string): Promise<string> {
    // Behavioral proof is verified off-chain
    throw new RookError(ErrorCodes.NOT_IMPLEMENTED, 'Use oracle API for behavioral proof');
  }

  /**
   * Claim challenge timeout (challenger wins)
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
}

export default RookProtocol;
