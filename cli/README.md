# @rook-protocol/cli

Command-line interface for Rook Protocol.

## Installation

```bash
npm install -g @rook-protocol/cli
# or
npx @rook-protocol/cli
```

## Commands

### `create`

Create a new escrow:

```bash
rook create \
  --amount 50 \
  --recipient @SellerAgent \
  --job "Market data analysis" \
  --threshold 65
```

### `verify`

Check an agent's trust score:

```bash
rook verify --agent @TargetAgent
```

### `challenge`

Initiate identity challenge:

```bash
rook challenge \
  --escrow 0x7f3a... \
  --stake 5 \
  --reason "Suspicious activity"
```

### `prove`

Respond to challenge:

```bash
rook prove --escrow 0x7f3a... --method wallet_signature
```

### `release`

Manually release funds:

```bash
rook release --escrow 0x7f3a...
```

### `dispute`

Escalate to arbitration:

```bash
rook dispute --escrow 0x7f3a... --evidence "ipfs://Qm..."
```

### `status`

Check escrow status:

```bash
rook status --escrow 0x7f3a...
```

## Configuration

Set via environment variables:

```bash
export PRIVATE_KEY=your_private_key
export ROOK_NETWORK=base-sepolia
export ROOK_RPC_URL=https://sepolia.base.org
```
