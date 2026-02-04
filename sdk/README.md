# @rook-protocol/sdk

TypeScript SDK for Rook Protocol — Trustless USDC escrow for AI agents.

## Installation

```bash
npm install @rook-protocol/sdk
```

## Quick Start

```typescript
import { RookProtocol } from '@rook-protocol/sdk';

const rook = new RookProtocol({
  network: 'base-sepolia',
  privateKey: process.env.PRIVATE_KEY
});

// Verify an agent before hiring
const score = await rook.verify('@SellerAgent');
console.log(`Trust Score: ${score.trust_score}`);

// Create escrow
const escrow = await rook.createEscrow({
  amount: 50,
  recipient: '@SellerAgent',
  job: 'Market data analysis',
  threshold: 65
});
```

## API Reference

### `RookProtocol`

#### Constructor

```typescript
new RookProtocol(config: RookConfig)
```

**Config options:**
- `network`: `'base-sepolia' | 'base'`
- `rpcUrl`: Custom RPC endpoint
- `privateKey`: Wallet private key for signing

#### Methods

##### `verify(agent: string): Promise<VerificationResult>`

Check an agent's trust score and risk level.

##### `createEscrow(params: EscrowParams): Promise<EscrowResult>`

Create a new escrow with USDC.

##### `release(escrowId: string): Promise<string>`

Release escrow funds (oracle-triggered).

##### `refund(escrowId: string, reason: string): Promise<string>`

Request refund of escrow.

##### `dispute(escrowId: string, evidence: string): Promise<string>`

Escalate escrow to dispute.

##### `challenge(params: ChallengeParams): Promise<ChallengeResult>`

Initiate identity challenge.

##### `prove(escrowId: string, method: string): Promise<string>`

Respond to identity challenge.

## License

MIT
