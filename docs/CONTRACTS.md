# Smart Contract Documentation

## Deployed Addresses

### Base Sepolia (Testnet)

| Contract | Address | Verified |
|----------|---------|----------|
| RookEscrow | `0x...` | ✅ |
| RookOracle | `0x...` | ✅ |
| MockUSDC | `0x...` | ✅ |

### Base (Mainnet)

Coming soon.

## RookEscrow

### Constants

```solidity
uint256 public constant MIN_THRESHOLD = 50;
uint256 public constant MAX_THRESHOLD = 100;
uint256 public constant CHALLENGE_STAKE = 5 * 10**6;  // 5 USDC
uint256 public constant CHALLENGE_BLOCKS = 50;         // ~2 min
uint256 public constant DEFAULT_EXPIRY = 7 days;
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

struct Challenge {
    address challenger;
    uint256 stake;
    uint256 deadline;
    bool resolved;
    bool passed;
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

Releases funds to seller.

**Requirements:**
- Caller must be oracle
- Escrow must be Active
- `trustScore >= escrow.trustThreshold`

#### `refundEscrow(bytes32 escrowId, string reason)`

Refunds buyer.

**Requirements:**
- Caller must be buyer, seller, or after expiry

#### `disputeEscrow(bytes32 escrowId, string evidence)`

Escalates to dispute.

**Requirements:**
- Caller must be buyer or seller

#### `initiateChallenge(bytes32 escrowId)`

Starts identity challenge.

**Requirements:**
- Caller must stake 5 USDC
- No active challenge

#### `resolveChallenge(bytes32 escrowId, bool passed)`

Resolves challenge.

**Requirements:**
- Caller must be oracle

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

Resolves challenge and updates bonus.

**Requirements:**
- Caller must be operator

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
    uint256 trustScore
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

event ChallengeInitiated(
    bytes32 indexed escrowId,
    address indexed challenger,
    uint256 stake,
    uint256 deadline
);

event ChallengeResolved(
    bytes32 indexed escrowId,
    bool passed,
    address indexed challenger,
    uint256 payout
);
```
