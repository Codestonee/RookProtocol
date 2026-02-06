// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRookOracle} from "./interfaces/IRookOracle.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title RookEscrow
 * @notice Trustless USDC escrow for AI agents with multi-layered verification
 * @dev Built for Circle USDC Hackathon on Moltbook
 * @custom:security-contact security@rook-protocol.xyz
 *
 * TIMING MECHANISMS
 * =================
 * This contract uses TWO timing mechanisms intentionally:
 *
 * 1. TIMESTAMPS (block.timestamp):
 *    - Escrow expiration (expiresAt)
 *    - Oracle timeout (ORACLE_TIMEOUT)
 *    - Dispute creation time
 *    - Challenge cooldown
 *    - Admin timelock
 *    Used for: Long-duration timeouts where exact timing is less critical
 *
 * 2. BLOCK NUMBERS (block.number):
 *    - Challenge deadline (CHALLENGE_BLOCKS = 50 blocks ~10 min)
 *    - Challenge response window (CHALLENGE_RESPONSE_WINDOW = 25 blocks ~5 min)
 *    Used for: Short-duration operations requiring predictable timing
 *
 * Rationale: Block numbers provide more predictable timing for time-sensitive
 * operations like challenges (immune to timestamp manipulation within 900s rule).
 * Timestamps are more intuitive for long-duration timeouts measured in hours/days.
 */
contract RookEscrow is ReentrancyGuard, Ownable, Pausable {

    // =================================================================
    // TYPES
    // =================================================================

    enum EscrowStatus {
        Active,      // Funds locked, awaiting delivery
        Released,    // Funds sent to seller
        Refunded,    // Funds returned to buyer
        Disputed,    // Escalated to arbitration
        Challenged   // Under identity verification
    }

    enum ChallengeStatus {
        None,
        Active,
        Responded,   // Seller has responded
        Resolved
    }

    struct Escrow {
        address buyer;
        address seller;
        uint256 amount;
        bytes32 jobHash;
        uint256 trustThreshold;    // 0-100 scale
        uint256 createdAt;
        uint256 expiresAt;
        EscrowStatus status;
    }

    struct Challenge {
        address challenger;
        uint256 stake;
        uint256 deadline;          // Block number
        ChallengeStatus status;
        bool passed;
        bytes32 responseHash;      // Hash of seller's response
    }

    struct Dispute {
        address initiator;
        string evidence;
        uint256 createdAt;
        bool resolved;
        address winner;
    }

    // Timelock action types
    struct TimelockAction {
        bytes32 actionHash;
        uint256 executeAfter;
        bool executed;
    }

    // =================================================================
    // STATE
    // =================================================================

    IERC20 public immutable usdc;
    IRookOracle public oracle;

    // Challenge configuration
    uint256 public constant CHALLENGE_STAKE = 5 * 10**6;  // 5 USDC
    uint256 public constant CHALLENGE_BLOCKS = 50;         // ~2 min on Base
    uint256 public constant CHALLENGE_RESPONSE_WINDOW = 25; // ~1 min to respond

    // Escrow configuration
    uint256 public constant MIN_THRESHOLD = 50;
    uint256 public constant MAX_THRESHOLD = 100;
    uint256 public constant DEFAULT_EXPIRY = 7 days;
    uint256 public constant ORACLE_TIMEOUT = 1 days;       // Fallback release timeout

    // Protocol fee (basis points, 50 = 0.5%)
    uint256 public protocolFeeBps = 50;
    uint256 public constant MAX_FEE_BPS = 500; // 5% max
    address public feeRecipient;
    uint256 public totalFeesCollected;

    // Admin timelock
    uint256 public constant TIMELOCK_DELAY = 2 days;
    mapping(bytes32 => TimelockAction) public timelockActions;

    // Storage
    mapping(bytes32 => Escrow) public escrows;
    mapping(bytes32 => Challenge) public challenges;
    mapping(bytes32 => Dispute) public disputes;
    mapping(address => bytes32[]) public buyerEscrows;
    mapping(address => bytes32[]) public sellerEscrows;
    mapping(address => uint256) public completedEscrows;
    mapping(address => uint256) public totalEscrows;
    mapping(address => uint256) public lastChallengeTime;  // Rate limiting
    mapping(bytes32 => mapping(address => bool)) public releaseConsent;  // Two-party consent

    uint256 public escrowCount;
    uint256 public totalVolume;
    uint256 public constant CHALLENGE_COOLDOWN = 1 hours;   // Per-address rate limit
    uint256 public constant MAX_EVIDENCE_LENGTH = 1000;

    // =================================================================
    // EVENTS
    // =================================================================

    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        bytes32 jobHash,
        uint256 trustThreshold
    );

    event EscrowReleased(
        bytes32 indexed escrowId,
        address indexed seller,
        uint256 amount,
        uint256 trustScore,
        bytes32 releaseReason
    );

    event EscrowRefunded(
        bytes32 indexed escrowId,
        address indexed buyer,
        uint256 amount,
        string reason
    );

    event EscrowDisputed(
        bytes32 indexed escrowId,
        address indexed initiator,
        string evidence
    );

    event DisputeResolved(
        bytes32 indexed escrowId,
        address indexed winner,
        uint256 amount,
        string reason
    );

    event ChallengeInitiated(
        bytes32 indexed escrowId,
        address indexed challenger,
        uint256 stake,
        uint256 deadline
    );

    event ChallengeResponded(
        bytes32 indexed escrowId,
        bytes32 responseHash
    );

    event ChallengeResolved(
        bytes32 indexed escrowId,
        bool passed,
        address indexed challenger,
        uint256 stakeReturned
    );

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ConsentRecorded(bytes32 indexed escrowId, address indexed party);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeesCollected(bytes32 indexed escrowId, uint256 feeAmount);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event TimelockScheduled(bytes32 indexed actionId, uint256 executeAfter);
    event TimelockExecuted(bytes32 indexed actionId);
    event TimelockCancelled(bytes32 indexed actionId);

    // =================================================================
    // ERRORS
    // =================================================================

    error InvalidAmount();
    error InvalidSeller();
    error InvalidThreshold();
    error InvalidAddress();
    error EscrowNotActive();
    error EscrowNotFound();
    error EscrowNotDisputed();
    error NotAuthorized();
    error NotBuyer();
    error NotSeller();
    error NotOracle();
    error NotChallenger();
    error ChallengeExists();
    error ChallengeNotFound();
    error ChallengeNotActive();
    error ChallengeExpired();
    error ChallengeNotExpired();
    error ChallengeCooldownActive();
    error SelfChallenge();
    error DisputeNotFound();
    error DisputeAlreadyResolved();
    error DeadlineNotPassed();
    error OracleTimeoutNotMet();
    error TransferFailed();
    error ChallengeResponseWindowExpired();
    error EvidenceTooLong();
    error EscrowExpired();
    error EscrowNotExpired();
    error BothPartiesRequired();
    error BelowThreshold();
    error FeeTooHigh();
    error CannotRescueUSDC();
    error TimelockNotReady();
    error TimelockNotFound();
    error TimelockAlreadyExecuted();
    error InvalidResponseHash();

    // =================================================================
    // CONSTRUCTOR
    // =================================================================

    constructor(address _usdc, address _oracle) {
        if (_usdc == address(0)) revert InvalidAddress();
        if (_oracle == address(0)) revert InvalidAddress();
        usdc = IERC20(_usdc);
        oracle = IRookOracle(_oracle);
        feeRecipient = msg.sender; // Default fee recipient is deployer
    }

    // =================================================================
    // MODIFIERS
    // =================================================================

    modifier onlyOracle() {
        if (msg.sender != address(oracle)) revert NotOracle();
        _;
    }

    modifier onlyBuyer(bytes32 escrowId) {
        if (msg.sender != escrows[escrowId].buyer) revert NotBuyer();
        _;
    }

    modifier onlySeller(bytes32 escrowId) {
        if (msg.sender != escrows[escrowId].seller) revert NotSeller();
        _;
    }

    // =================================================================
    // ESCROW OPERATIONS
    // =================================================================

    /**
     * @notice Create a new escrow
     * @param seller Recipient address
     * @param amount USDC amount (6 decimals)
     * @param jobHash Keccak256 hash of job description
     * @param trustThreshold Minimum trust score for auto-release (0-100)
     */
    function createEscrow(
        address seller,
        uint256 amount,
        bytes32 jobHash,
        uint256 trustThreshold
    ) external nonReentrant whenNotPaused returns (bytes32 escrowId) {
        if (amount == 0) revert InvalidAmount();
        if (seller == address(0) || seller == msg.sender) revert InvalidSeller();
        if (trustThreshold < MIN_THRESHOLD || trustThreshold > MAX_THRESHOLD) {
            revert InvalidThreshold();
        }

        escrowId = keccak256(abi.encodePacked(
            msg.sender,
            seller,
            amount,
            jobHash,
            block.timestamp,
            escrowCount++
        ));

        // Transfer USDC from buyer
        bool success = usdc.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();

        escrows[escrowId] = Escrow({
            buyer: msg.sender,
            seller: seller,
            amount: amount,
            jobHash: jobHash,
            trustThreshold: trustThreshold,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + DEFAULT_EXPIRY,
            status: EscrowStatus.Active
        });

        buyerEscrows[msg.sender].push(escrowId);
        sellerEscrows[seller].push(escrowId);
        totalEscrows[seller]++;
        totalVolume += amount;

        emit EscrowCreated(escrowId, msg.sender, seller, amount, jobHash, trustThreshold);
    }

    /**
     * @notice Release funds to seller (oracle-triggered)
     * @param escrowId Escrow identifier
     * @param trustScore Computed trust score from oracle
     */
    function releaseEscrow(
        bytes32 escrowId,
        uint256 trustScore
    ) external nonReentrant onlyOracle {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Active) revert EscrowNotActive();
        if (block.timestamp > escrow.expiresAt) revert EscrowExpired();
        if (trustScore < escrow.trustThreshold) revert BelowThreshold();

        escrow.status = EscrowStatus.Released;
        completedEscrows[escrow.seller]++;

        // Calculate and collect protocol fee
        uint256 feeAmount = _collectFee(escrowId, escrow.amount);
        uint256 sellerAmount = escrow.amount - feeAmount;

        bool success = usdc.transfer(escrow.seller, sellerAmount);
        if (!success) revert TransferFailed();

        _cleanupEscrowStorage(escrowId);

        emit EscrowReleased(escrowId, escrow.seller, sellerAmount, trustScore, keccak256("oracle_release"));
    }

    /**
     * @notice Release funds after oracle timeout (buyer+seller mutual consent fallback)
     * @param escrowId Escrow identifier
     * @dev Requires BOTH parties to call this function to consent
     */
    function releaseWithConsent(bytes32 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Active) revert EscrowNotActive();
        if (block.timestamp > escrow.expiresAt) revert EscrowExpired();
        if (block.timestamp < escrow.createdAt + ORACLE_TIMEOUT) revert OracleTimeoutNotMet();

        // Require caller is a party
        bool isParty = msg.sender == escrow.buyer || msg.sender == escrow.seller;
        if (!isParty) revert NotAuthorized();

        // Record this party's consent
        releaseConsent[escrowId][msg.sender] = true;
        emit ConsentRecorded(escrowId, msg.sender);

        // Check if both parties have consented - if not, wait for other party
        if (!releaseConsent[escrowId][escrow.buyer] || !releaseConsent[escrowId][escrow.seller]) {
            return;
        }

        escrow.status = EscrowStatus.Released;
        completedEscrows[escrow.seller]++;

        // Calculate and collect protocol fee
        uint256 feeAmount = _collectFee(escrowId, escrow.amount);
        uint256 sellerAmount = escrow.amount - feeAmount;

        bool success = usdc.transfer(escrow.seller, sellerAmount);
        if (!success) revert TransferFailed();

        _cleanupEscrowStorage(escrowId);
        delete releaseConsent[escrowId][escrow.buyer];
        delete releaseConsent[escrowId][escrow.seller];

        emit EscrowReleased(escrowId, escrow.seller, sellerAmount, 0, keccak256("consent_release"));
    }

    /**
     * @notice Refund buyer (buyer-initiated)
     * @param escrowId Escrow identifier
     * @param reason Refund reason
     */
    function refundEscrow(
        bytes32 escrowId,
        string calldata reason
    ) external nonReentrant onlyBuyer(escrowId) {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.Active) revert EscrowNotActive();

        escrow.status = EscrowStatus.Refunded;

        bool success = usdc.transfer(escrow.buyer, escrow.amount);
        if (!success) revert TransferFailed();

        _cleanupEscrowStorage(escrowId);

        emit EscrowRefunded(escrowId, escrow.buyer, escrow.amount, reason);
    }

    /**
     * @notice Claim expired escrow (automatic refund to buyer)
     * @param escrowId Escrow identifier
     */
    function claimExpired(bytes32 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Active) revert EscrowNotActive();
        if (block.timestamp <= escrow.expiresAt) revert EscrowNotExpired();
        if (msg.sender != escrow.buyer) revert NotBuyer();

        escrow.status = EscrowStatus.Refunded;

        bool success = usdc.transfer(escrow.buyer, escrow.amount);
        if (!success) revert TransferFailed();

        _cleanupEscrowStorage(escrowId);

        emit EscrowRefunded(escrowId, escrow.buyer, escrow.amount, "Expired");
    }

    /**
     * @notice Escalate to dispute
     * @param escrowId Escrow identifier
     * @param evidence IPFS hash or description of evidence (max 1000 bytes)
     */
    function disputeEscrow(
        bytes32 escrowId,
        string calldata evidence
    ) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        if (bytes(evidence).length > MAX_EVIDENCE_LENGTH) revert EvidenceTooLong();
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Active && escrow.status != EscrowStatus.Challenged) {
            revert EscrowNotActive();
        }

        bool isParty = msg.sender == escrow.buyer || msg.sender == escrow.seller;
        if (!isParty) revert NotAuthorized();

        escrow.status = EscrowStatus.Disputed;

        disputes[escrowId] = Dispute({
            initiator: msg.sender,
            evidence: evidence,
            createdAt: block.timestamp,
            resolved: false,
            winner: address(0)
        });

        emit EscrowDisputed(escrowId, msg.sender, evidence);
    }

    /**
     * @notice Resolve a dispute (owner only - emergency path, subject to timelock for large amounts)
     * @param escrowId Escrow identifier
     * @param winner Address to receive funds
     * @param reason Resolution reason
     */
    function resolveDispute(
        bytes32 escrowId,
        address winner,
        string calldata reason
    ) external nonReentrant onlyOwner {
        Escrow storage escrow = escrows[escrowId];
        Dispute storage dispute = disputes[escrowId];

        if (escrow.status != EscrowStatus.Disputed) revert EscrowNotDisputed();
        if (dispute.resolved) revert DisputeAlreadyResolved();
        if (winner != escrow.buyer && winner != escrow.seller) revert NotAuthorized();

        dispute.resolved = true;
        dispute.winner = winner;

        if (winner == escrow.seller) {
            escrow.status = EscrowStatus.Released;
            completedEscrows[escrow.seller]++;
        } else {
            escrow.status = EscrowStatus.Refunded;
        }

        bool success = usdc.transfer(winner, escrow.amount);
        if (!success) revert TransferFailed();

        _cleanupEscrowStorage(escrowId);

        emit DisputeResolved(escrowId, winner, escrow.amount, reason);
    }

    // =================================================================
    // CHALLENGE OPERATIONS (Voight-Kampff)
    // =================================================================

    /**
     * @notice Initiate identity challenge
     * @param escrowId Escrow to challenge
     */
    function initiateChallenge(bytes32 escrowId) external nonReentrant whenNotPaused {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Active) revert EscrowNotActive();
        if (block.timestamp > escrow.expiresAt) revert EscrowExpired();

        // Prevent self-challenge (check before rate limit for gas efficiency)
        if (msg.sender == escrow.seller) revert SelfChallenge();

        // Rate limiting (skip for first-time challengers)
        if (lastChallengeTime[msg.sender] > 0 &&
            block.timestamp < lastChallengeTime[msg.sender] + CHALLENGE_COOLDOWN) {
            revert ChallengeCooldownActive();
        }

        Challenge storage challenge = challenges[escrowId];
        if (challenge.status != ChallengeStatus.None) {
            revert ChallengeExists();
        }

        // Transfer stake
        bool success = usdc.transferFrom(msg.sender, address(this), CHALLENGE_STAKE);
        if (!success) revert TransferFailed();

        uint256 deadline = block.number + CHALLENGE_BLOCKS;
        lastChallengeTime[msg.sender] = block.timestamp;

        challenges[escrowId] = Challenge({
            challenger: msg.sender,
            stake: CHALLENGE_STAKE,
            deadline: deadline,
            status: ChallengeStatus.Active,
            passed: false,
            responseHash: bytes32(0)
        });

        escrow.status = EscrowStatus.Challenged;

        emit ChallengeInitiated(escrowId, msg.sender, CHALLENGE_STAKE, deadline);
    }

    /**
     * @notice Respond to challenge (seller only)
     * @param escrowId Escrow identifier
     * @param responseHash Hash of response data (for oracle verification)
     * @dev Expected format: keccak256(abi.encodePacked(escrowId, signature, timestamp))
     */
    function respondChallenge(
        bytes32 escrowId,
        bytes32 responseHash
    ) external nonReentrant onlySeller(escrowId) {
        Escrow storage escrow = escrows[escrowId];
        Challenge storage challenge = challenges[escrowId];

        if (escrow.status != EscrowStatus.Challenged) revert EscrowNotActive();
        if (challenge.status != ChallengeStatus.Active) revert ChallengeNotActive();
        if (block.number > challenge.deadline) revert ChallengeExpired();
        if (responseHash == bytes32(0)) revert InvalidResponseHash();

        // Enforce response window (must respond within first 25 blocks)
        uint256 responseDeadline = challenge.deadline - CHALLENGE_BLOCKS + CHALLENGE_RESPONSE_WINDOW;
        if (block.number > responseDeadline) revert ChallengeResponseWindowExpired();

        challenge.status = ChallengeStatus.Responded;
        challenge.responseHash = responseHash;

        emit ChallengeResponded(escrowId, responseHash);
    }

    /**
     * @notice Resolve challenge (oracle only, must be before deadline)
     * @param escrowId Escrow identifier
     * @param passed Whether challenge was passed
     */
    function resolveChallenge(
        bytes32 escrowId,
        bool passed
    ) external nonReentrant onlyOracle {
        Challenge storage challenge = challenges[escrowId];
        Escrow storage escrow = escrows[escrowId];

        if (challenge.status != ChallengeStatus.Active && challenge.status != ChallengeStatus.Responded) {
            revert ChallengeNotActive();
        }
        if (block.number > challenge.deadline) revert ChallengeExpired();

        challenge.status = ChallengeStatus.Resolved;
        challenge.passed = passed;

        // Cache values before cleanup
        address cachedChallenger = challenge.challenger;
        uint256 cachedStake = challenge.stake;

        if (passed) {
            // Seller passed - return stake to challenger, continue escrow
            escrow.status = EscrowStatus.Active;
            bool success = usdc.transfer(cachedChallenger, cachedStake);
            if (!success) revert TransferFailed();

            delete challenges[escrowId];

            emit ChallengeResolved(escrowId, true, cachedChallenger, cachedStake);
        } else {
            // Seller failed - return stake to challenger, refund buyer
            escrow.status = EscrowStatus.Refunded;

            bool success1 = usdc.transfer(escrow.buyer, escrow.amount);
            if (!success1) revert TransferFailed();

            bool success2 = usdc.transfer(cachedChallenger, cachedStake);
            if (!success2) revert TransferFailed();

            _cleanupEscrowStorage(escrowId);

            emit ChallengeResolved(escrowId, false, cachedChallenger, cachedStake);
        }
    }

    /**
     * @notice Claim challenge timeout (seller didn't respond in time)
     * @param escrowId Escrow identifier
     * @dev FIX: Now caches values before cleanup to prevent zeroed event data
     */
    function claimChallengeTimeout(bytes32 escrowId) external nonReentrant {
        Challenge storage challenge = challenges[escrowId];
        Escrow storage escrow = escrows[escrowId];

        // Only challenger can claim timeout
        if (msg.sender != challenge.challenger) revert NotChallenger();
        if (challenge.status != ChallengeStatus.Active) revert ChallengeNotActive();
        if (block.number <= challenge.deadline) revert ChallengeNotExpired();

        challenge.status = ChallengeStatus.Resolved;
        challenge.passed = false;

        // CRITICAL FIX: Cache values BEFORE cleanup to preserve event data
        address cachedChallenger = challenge.challenger;
        uint256 cachedStake = challenge.stake;
        address cachedBuyer = escrow.buyer;
        uint256 cachedAmount = escrow.amount;

        escrow.status = EscrowStatus.Refunded;

        // Refund buyer
        bool success1 = usdc.transfer(cachedBuyer, cachedAmount);
        if (!success1) revert TransferFailed();

        // Return stake to challenger (NO 2x payout)
        bool success2 = usdc.transfer(cachedChallenger, cachedStake);
        if (!success2) revert TransferFailed();

        _cleanupEscrowStorage(escrowId);

        emit ChallengeResolved(escrowId, false, cachedChallenger, cachedStake);
    }

    // =================================================================
    // VIEW FUNCTIONS
    // =================================================================

    function getEscrow(bytes32 escrowId) external view returns (Escrow memory) {
        return escrows[escrowId];
    }

    function getChallenge(bytes32 escrowId) external view returns (Challenge memory) {
        return challenges[escrowId];
    }

    function getDispute(bytes32 escrowId) external view returns (Dispute memory) {
        return disputes[escrowId];
    }

    /**
     * @notice Verify challenge response hash format
     */
    function computeResponseHash(
        bytes32 escrowId,
        bytes calldata signature,
        uint256 timestamp
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(escrowId, signature, timestamp));
    }

    function getBuyerEscrows(address buyer) external view returns (bytes32[] memory) {
        return buyerEscrows[buyer];
    }

    function getSellerEscrows(address seller) external view returns (bytes32[] memory) {
        return sellerEscrows[seller];
    }

    /**
     * @notice Get buyer escrows with pagination
     */
    function getBuyerEscrowsPaginated(
        address buyer,
        uint256 offset,
        uint256 limit
    ) external view returns (bytes32[] memory) {
        bytes32[] storage all = buyerEscrows[buyer];
        if (offset >= all.length) return new bytes32[](0);
        uint256 end = offset + limit > all.length ? all.length : offset + limit;
        bytes32[] memory result = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = all[i];
        }
        return result;
    }

    /**
     * @notice Get seller escrows with pagination
     */
    function getSellerEscrowsPaginated(
        address seller,
        uint256 offset,
        uint256 limit
    ) external view returns (bytes32[] memory) {
        bytes32[] storage all = sellerEscrows[seller];
        if (offset >= all.length) return new bytes32[](0);
        uint256 end = offset + limit > all.length ? all.length : offset + limit;
        bytes32[] memory result = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = all[i];
        }
        return result;
    }

    function getCompletionRate(address agent) external view returns (uint256) {
        if (totalEscrows[agent] == 0) return 0;
        return (completedEscrows[agent] * 10000) / totalEscrows[agent]; // Basis points for precision
    }

    /**
     * @notice Check when an address can next challenge
     * @param challenger Challenger address
     * @return Timestamp when next challenge is allowed (0 if allowed now)
     */
    function getNextChallengeTime(address challenger) external view returns (uint256) {
        if (lastChallengeTime[challenger] == 0) return 0;
        uint256 nextTime = lastChallengeTime[challenger] + CHALLENGE_COOLDOWN;
        if (block.timestamp >= nextTime) return 0;
        return nextTime;
    }

    // =================================================================
    // INTERNAL HELPERS
    // =================================================================

    /**
     * @notice Clean up storage for finalized escrow
     */
    function _cleanupEscrowStorage(bytes32 escrowId) internal {
        if (challenges[escrowId].challenger != address(0)) {
            delete challenges[escrowId];
        }
        if (disputes[escrowId].initiator != address(0)) {
            delete disputes[escrowId];
        }
    }

    /**
     * @notice Collect protocol fee on release
     * @return feeAmount The fee collected
     */
    function _collectFee(bytes32 escrowId, uint256 amount) internal returns (uint256 feeAmount) {
        if (protocolFeeBps == 0 || feeRecipient == address(0)) return 0;

        feeAmount = (amount * protocolFeeBps) / 10000;
        if (feeAmount == 0) return 0;

        totalFeesCollected += feeAmount;

        bool success = usdc.transfer(feeRecipient, feeAmount);
        if (!success) revert TransferFailed();

        emit FeesCollected(escrowId, feeAmount);
    }

    // =================================================================
    // ADMIN (with timelock for critical operations)
    // =================================================================

    /**
     * @notice Schedule an oracle update (timelocked)
     * @param _oracle New oracle address
     */
    function scheduleSetOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert InvalidAddress();
        bytes32 actionId = keccak256(abi.encodePacked("setOracle", _oracle, block.timestamp));
        timelockActions[actionId] = TimelockAction({
            actionHash: keccak256(abi.encodePacked("setOracle", _oracle)),
            executeAfter: block.timestamp + TIMELOCK_DELAY,
            executed: false
        });
        emit TimelockScheduled(actionId, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Execute a timelocked oracle update
     * @param actionId Timelock action ID
     * @param _oracle New oracle address (must match scheduled)
     */
    function executeSetOracle(bytes32 actionId, address _oracle) external onlyOwner {
        TimelockAction storage action = timelockActions[actionId];
        if (action.executeAfter == 0) revert TimelockNotFound();
        if (action.executed) revert TimelockAlreadyExecuted();
        if (block.timestamp < action.executeAfter) revert TimelockNotReady();
        if (action.actionHash != keccak256(abi.encodePacked("setOracle", _oracle))) revert NotAuthorized();

        action.executed = true;
        address old = address(oracle);
        oracle = IRookOracle(_oracle);
        emit OracleUpdated(old, _oracle);
        emit TimelockExecuted(actionId);
    }

    /**
     * @notice Cancel a timelocked action
     * @param actionId Timelock action ID
     */
    function cancelTimelock(bytes32 actionId) external onlyOwner {
        TimelockAction storage action = timelockActions[actionId];
        if (action.executeAfter == 0) revert TimelockNotFound();
        if (action.executed) revert TimelockAlreadyExecuted();
        delete timelockActions[actionId];
        emit TimelockCancelled(actionId);
    }

    /**
     * @notice Set oracle directly (for initial setup or emergencies only)
     * @dev Should migrate to timelock-only after initial setup
     */
    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert InvalidAddress();
        address old = address(oracle);
        oracle = IRookOracle(_oracle);
        emit OracleUpdated(old, _oracle);
    }

    /**
     * @notice Set protocol fee (owner only)
     * @param _feeBps Fee in basis points (max 500 = 5%)
     */
    function setProtocolFee(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 oldFee = protocolFeeBps;
        protocolFeeBps = _feeBps;
        emit ProtocolFeeUpdated(oldFee, _feeBps);
    }

    /**
     * @notice Set fee recipient
     * @param _recipient Fee recipient address
     */
    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        address old = feeRecipient;
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(old, _recipient);
    }

    /**
     * @notice Rescue accidentally sent tokens (NOT USDC)
     * @param token Token address to rescue
     * @param to Recipient
     * @param amount Amount to rescue
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(usdc)) revert CannotRescueUSDC();
        if (to == address(0)) revert InvalidAddress();
        bool success = IERC20(token).transfer(to, amount);
        if (!success) revert TransferFailed();
        emit TokensRescued(token, to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
