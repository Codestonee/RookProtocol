# Rook Protocol Smart Contracts

Smart contracts for trustless USDC escrow with multi-layered verification.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     RookEscrow.sol                           │
│  - Lock/Release/Refund USDC                                  │
│  - Challenge management                                      │
│  - Dispute escalation                                        │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│                    RookOracle.sol                            │
│  - Trust score computation                                   │
│  - ERC-8004 integration                                      │
│  - Off-chain oracle interface                                │
└──────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test

# Deploy to Base Sepolia
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
```

## Contract Addresses

### Base Sepolia (Testnet)

| Contract | Address | Verified |
|----------|---------|----------|
| RookEscrow | `0x...` | ✅ |
| RookOracle | `0x...` | ✅ |
| MockUSDC | `0x...` | ✅ |

## Key Concepts

### Trust Score

Composite score computed from:
- ERC-8004 Identity (25%)
- Reputation Signals (25%)
- Sybil Resistance (20%)
- Escrow History (20%)
- Challenge Bonus (10%)

### Voight-Kampff Challenge

Active identity verification:
1. Challenger stakes 5 USDC
2. Target has 50 blocks to respond
3. Oracle verifies response
4. Winner takes stake

## Security

- ReentrancyGuard on all state-changing functions
- Only oracle can release funds
- Challenge timeout prevents griefing
- Non-transferable escrow IDs
