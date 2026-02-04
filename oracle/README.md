# @rook-protocol/oracle

Off-chain oracle service for Rook Protocol. Computes trust scores and verifies challenges.

## Features

- **Trust Score Calculation**: Multi-layered scoring from ERC-8004, Moltbook, and on-chain data
- **Challenge Verification**: Validates wallet signatures for identity challenges
- **Webhook Support**: Listens for blockchain events
- **REST API**: Endpoints for verification and challenge resolution

## API Endpoints

### POST /verify

Calculate trust score for an agent:

```bash
curl -X POST http://localhost:3000/verify \
  -H "Content-Type: application/json" \
  -d '{
    "agent": "0x1234...",
    "moltbookHandle": "@AgentName"
  }'
```

### POST /challenge

Verify a challenge response:

```bash
curl -X POST http://localhost:3000/challenge \
  -H "Content-Type: application/json" \
  -d '{
    "escrowId": "0x7f3a...",
    "signature": "0x...",
    "expectedSigner": "0x1234...",
    "action": "resolve"
  }'
```

### POST /webhook

Receive blockchain event webhooks.

## Deployment

### Docker

```bash
docker build -t rook-oracle .
docker run -p 3000:3000 --env-file .env rook-oracle
```

### Railway/Fly.io

1. Set environment variables
2. Deploy with `railway up` or `fly deploy`
