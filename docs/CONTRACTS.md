# Smart Contract Documentation

## Security Notice

**Version 1.1.0 contains critical security fixes. Do not use versions < 1.1.0 with real funds.**

See [SECURITY.md](../SECURITY.md) for details on fixed vulnerabilities.

## Deployed Addresses

### Base Sepolia (Testnet)

| Contract | Address | Verified |
|----------|---------|----------|
| RookEscrow | `0x...` | ✅ |
| RookOracle | `0x...` | ✅ |
| MockUSDC | `0x...` | ✅ |

### Base (Mainnet)

Coming soon (pending external audit).

## RookEscrow

### Constants

```solidity
uint256 public constant MIN_THRESHOLD = 50;
uint256 public constant MAX_THRESHOLD = 100;
uint256 public constant CHALLENGE_STAKE = 5 * 10**6;  // 5 USDC
uint256 public constant CHALLENGE_BLOCKS = 50;         // ~2 min
uint256 public constant CHALLENGE_RESPONSE_WINDOW = 25; // ~1 min
uint256 public constant DEFAULT_EXPIRY = 7 days;
uint256 public constant ORACLE_TIMEOUT = 1 days;       // For consent release
uint256 public constant CHALLENGE_COOLDOWN = 1 hours;  // Per-address rate limit
```

### Structs

```solidity
struct Escrow {
    address buyer;
    address seller;
    uint256 amount;
    bytes32 jobHash;
    uint256 trustThreshold;
    uint256 createdAt;
    uint256 expiresAt;
    EscrowStatus status;
}

enum ChallengeStatus { None, Active, Responded, Resolved }

struct Challenge {
    address challenger;
    uint256 stake;
    uint256 deadline;
    ChallengeStatus status;
    bool passed;
    bytes32 responseHash;
}

struct Dispute {
    address initiator;
    string evidence;
    uint256 createdAt;
    bool resolved;
    address winner;
}
```

### Functions

#### `createEscrow(address seller, uint256 amount, bytes32 jobHash, uint256 trustThreshold) → bytes32 escrowId`

Creates a new escrow. Transfers USDC from caller.

**Requirements:**
- `amount > 0`
- `seller != address(0) && seller != msg.sender`
- `50 <= trustThreshold <= 100`

#### `releaseEscrow(bytes32 escrowId, uint256 trustScore)`

Releases funds to seller (oracle only).

**Requirements:**
- Caller must be oracle
- Escrow must be Active
- `trustScore >= escrow.trustThreshold`

#### `releaseWithConsent(bytes32 escrowId)`

Releases funds after oracle timeout (1 day) with mutual consent.

**Requirements:**
- Caller must be buyer or seller
- `block.timestamp >= escrow.createdAt + ORACLE_TIMEOUT`

#### `refundEscrow(bytes32 escrowId, string reason)`

Refunds buyer (buyer only).

**Requirements:**
- Caller must be buyer
- Escrow must be Active

#### `disputeEscrow(bytes32 escrowId, string evidence)`

Escalates to dispute.

**Requirements:**
- Caller must be buyer or seller
- Escrow must be Active or Challenged

#### `resolveDispute(bytes32 escrowId, address winner, string reason)`

Resolves dispute (owner only - emergency path).

**Requirements:**
- Caller must be owner
- Escrow must be Disputed
- Winner must be buyer or seller

#### `initiateChallenge(bytes32 escrowId)`

Starts identity challenge.

**Requirements:**
- Caller must not be seller (anti-self-challenge)
- No active challenge
- Rate limit: 1 hour cooldown per address
- Must stake 5 USDC (fixed)

#### `respondChallenge(bytes32 escrowId, bytes32 responseHash)`

Seller responds to challenge.

**Requirements:**
- Caller must be seller
- Challenge must be Active
- Must be before deadline

#### `resolveChallenge(bytes32 escrowId, bool passed)`

Resolves challenge (oracle only).

**Requirements:**
- Caller must be oracle
- Challenge must be Active or Responded
- Must be before deadline

**Important:** Challenger only receives original stake back (no profit). This prevents economic attacks.

#### `claimChallengeTimeout(bytes32 escrowId)`

Claims challenge timeout if seller didn't respond.

**Requirements:**
- Challenge must be Active
- `block.number > deadline`

**Important:** Challenger only receives original stake back (no profit).

#### `pause()` / `unpause()`

Emergency pause functions (owner only).

## RookOracle

### Constants

```solidity
uint256 public constant WEIGHT_IDENTITY = 25;
uint256 public constant WEIGHT_REPUTATION = 25;
uint256 public constant WEIGHT_SYBIL = 20;
uint256 public constant WEIGHT_HISTORY = 20;
uint256 public constant WEIGHT_CHALLENGE = 10;
```

### Functions

#### `updateScores(address agent, uint256 identity, uint256 reputation, uint256 sybil, uint256 challengeBonus)`

Updates cached scores.

**Requirements:**
- Caller must be operator
- All scores <= 100

#### `computeTrustScore(address agent) → uint256`

Computes weighted composite score.

#### `triggerRelease(bytes32 escrowId)`

Triggers escrow release.

**Requirements:**
- Caller must be operator

#### `resolveChallenge(bytes32 escrowId, bool passed)`

Resolves challenge.

**Requirements:**
- Caller must be operator

## Security Features

- **ReentrancyGuard**: All state-changing functions protected
- **Pausable**: Emergency pause functionality
- **Access Control**: Strict modifiers (onlyOracle, onlyBuyer, onlySeller, onlyOwner)
- **Rate Limiting**: Challenge cooldown per address
- **Self-Challenge Prevention**: Sellers cannot challenge themselves
- **Economic Safety**: No profitable griefing (stake returned only, no 2x payout)

## Events

### RookEscrow

```solidity
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
```
