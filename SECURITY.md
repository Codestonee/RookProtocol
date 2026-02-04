# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.1.x   | :white_check_mark: |
| < 1.1.0 | :x:                |

## Reporting a Vulnerability

Please report security vulnerabilities to security@rook-protocol.xyz or via the GitHub Security Advisories feature.

## Critical Fixes in v1.1.0

The following critical vulnerabilities were identified and fixed in version 1.1.0:

### 1. Challenge Reward Insolvency (CRITICAL - FIXED)

**Issue:** The contract paid `stake * 2` while only collecting `stake * 1`, allowing attackers to drain funds.

**Fix:** Challenger now only receives their original stake back (no profit). The contract no longer mints money.

### 2. No Seller Response Path (CRITICAL - FIXED)

**Issue:** Sellers had no on-chain method to respond to challenges.

**Fix:** Added `respondChallenge()` function for sellers to submit proof.

### 3. Dispute Deadlock (CRITICAL - FIXED)

**Issue:** Disputed escrows could never be resolved, permanently locking funds.

**Fix:** Added `resolveDispute()` function callable by contract owner (emergency path).

### 4. Oracle Liveness Risk (HIGH - FIXED)

**Issue:** If oracle was down, funds could not be released.

**Fix:** Added `releaseWithConsent()` for mutual release after 1-day timeout.

### 5. Deadline Not Enforced (HIGH - FIXED)

**Issue:** Oracle could resolve challenges after deadline.

**Fix:** Added `block.number <= deadline` check in `resolveChallenge()`.

### 6. Seller Unilateral Refund (MEDIUM - FIXED)

**Issue:** Seller could unilaterally refund buyer.

**Fix:** Changed `refundEscrow()` to `onlyBuyer` modifier.

### 7. SDK Stake Mismatch (MEDIUM - FIXED)

**Issue:** SDK allowed custom stake but contract used fixed 5 USDC.

**Fix:** SDK now uses `CHALLENGE_STAKE` constant and ignores user input.

### 8. Event Parsing Failure (LOW - FIXED)

**Issue:** SDK event parsing could fail in ethers v6.

**Fix:** Uses `interface.parseLog()` for robust event parsing.

## Additional Security Measures

- **Pausable**: Contract can be paused in emergencies
- **Rate Limiting**: 1-hour cooldown between challenges per address
- **Self-Challenge Prevention**: Sellers cannot challenge their own escrows
- **Access Control**: Strict modifiers for sensitive functions

## Known Limitations

1. **Oracle Centralization**: Trust scores are computed off-chain by oracle operators. Multi-sig or decentralized oracle recommended for production.

2. **Dispute Resolution Centralization**: Emergency dispute resolution is owner-controlled. Kleros integration planned for Phase 2.

3. **No Challenge Bond**: Current design doesn't require seller bond. Consider adding bonded challenges for high-value escrows.

## Audit Status

- [x] Internal review
- [x] Automated analysis (Slither)
- [ ] External audit (planned for mainnet)

## Deployment Checklist

Before deploying to mainnet:

- [ ] Complete external audit
- [ ] Deploy with multi-sig owner
- [ ] Set up monitoring for challenge timeouts
- [ ] Configure oracle operator keys securely
- [ ] Test emergency pause functionality
- [ ] Document dispute resolution process
