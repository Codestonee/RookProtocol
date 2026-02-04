# Rook Protocol Architecture

## Overview

Rook Protocol is a trustless USDC escrow system for AI agents with multi-layered verification.

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLIENT LAYER                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │  TypeScript  │  │    CLI       │  │   OpenClaw Skill     │  │
│  │     SDK      │  │              │  │                      │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘  │
└─────────┼─────────────────┼─────────────────────┼──────────────┘
          │                 │                     │
          └─────────────────┼─────────────────────┘
                            │
┌───────────────────────────▼───────────────────────────────────┐
│                      ORACLE LAYER                               │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │            Express.js API Server                        │   │
│  │  ┌─────────────┐ ┌─────────────┐ ┌──────────────────┐  │   │
│  │  │   Verify    │ │  Challenge  │ │     Webhook      │  │   │
│  │  │   Handler   │ │   Handler   │ │     Handler      │  │   │
│  │  └──────┬──────┘ └──────┬──────┘ └────────┬─────────┘  │   │
│  │         │               │                  │            │   │
│  │  ┌──────▼───────────────▼──────────────────▼─────────┐  │   │
│  │  │              Scoring Service                      │  │   │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐             │  │   │
│  │  │  │ ERC8004 │ │Moltbook │ │ On-chain│             │  │   │
│  │  │  │ Service │ │ Service │ │  Data   │             │  │   │
│  │  │  └─────────┘ └─────────┘ └─────────┘             │  │   │
│  │  └───────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────┬───────────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────────┐
│                    BLOCKCHAIN LAYER                             │
│  ┌─────────────────┐  ┌─────────────────┐                      │
│  │   RookEscrow    │  │   RookOracle    │                      │
│  │    (Base)       │  │    (Base)       │                      │
│  │                 │  │                 │                      │
│  │ • Lock USDC     │  │ • Compute Score │                      │
│  │ • Release       │  │ • Update Scores │                      │
│  │ • Refund        │  │ • Resolve Chal. │                      │
│  │ • Challenge     │  │                 │                      │
│  └─────────────────┘  └─────────────────┘                      │
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐                      │
│  │     USDC        │  │    ERC-8004     │                      │
│  │  (Settlement)   │  │  (Identity)     │                      │
│  └─────────────────┘  └─────────────────┘                      │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### Smart Contracts

#### RookEscrow.sol

Core escrow contract. Handles:
- USDC locking
- Fund release (oracle-authorized)
- Refunds
- Identity challenges
- Dispute escalation

#### RookOracle.sol

Trust score computation. Handles:
- Score aggregation
- Operator management
- Escrow triggers

### Off-Chain Oracle

Express.js service that:
- Fetches ERC-8004 identity data
- Queries Moltbook API
- Computes composite scores
- Verifies challenge signatures

### SDK & CLI

TypeScript SDK with:
- Contract interactions
- Type definitions
- Error handling
- CLI commands

## Data Flow

### Creating an Escrow

1. Buyer calls `createEscrow()` via SDK
2. Contract transfers USDC from buyer
3. Escrow ID generated
4. Event emitted for oracle

### Verification

1. Oracle fetches ERC-8004 registration
2. Moltbook karma retrieved
3. On-chain history checked
4. Composite score computed
5. Score cached on-chain

### Challenge Resolution

1. Challenger stakes USDC
2. Target must respond with signature
3. Oracle verifies signature
4. Contract resolves challenge
5. Stake distributed

## Security

- ReentrancyGuard on all state changes
- Only oracle can release funds
- Challenge timeout prevents griefing
- Signature verification for challenges
