diff --git a/REVIEW.md b/REVIEW.md
index d8ec3c8dccbec2bacd877fbe185744027254d6a2..f2a438f7ea9a3274da0f8bf6b415f401e9372dff 100644
--- a/REVIEW.md
+++ b/REVIEW.md
@@ -1,423 +1,372 @@
-# Code Review: Rook Protocol Core Files
-
-## Executive Summary
-
-**Overall Quality: Good** ✅
-
-The codebase is well-structured with good security practices, but has several areas for improvement in gas optimization, edge case handling, and SDK robustness.
-
-**Critical Issues: 0**
-**High Priority: 3**
-**Medium Priority: 8**
-**Low Priority: 12**
+# Rook Protocol — Autonomous Code Review + Tests + Patch Plan
+
+## 1. System Model & Invariants
+
+### Escrow lifecycle (state machine)
+- **States**: `Active`, `Released`, `Refunded`, `Disputed`, `Challenged` are defined in `RookEscrow.EscrowStatus`. Transitions are driven by `createEscrow`, `releaseEscrow`, `releaseWithConsent`, `refundEscrow`, `disputeEscrow`, `resolveDispute`, `initiateChallenge`, `resolveChallenge`, and `claimChallengeTimeout`.
+- **Transitions**:
+  - **Create**: `createEscrow` → `Active`.
+  - **Release (oracle)**: `Active` → `Released` in `releaseEscrow` if trust score ≥ threshold.
+  - **Release (timeout consent)**: `Active` → `Released` in `releaseWithConsent` after `ORACLE_TIMEOUT`.
+  - **Refund (buyer)**: `Active` → `Refunded` in `refundEscrow`.
+  - **Dispute**: `Active` or `Challenged` → `Disputed` in `disputeEscrow`; `resolveDispute` → `Released` or `Refunded`.
+  - **Challenge**: `Active` → `Challenged` in `initiateChallenge`; `resolveChallenge(true)` → `Active`, `resolveChallenge(false)`/`claimChallengeTimeout` → `Refunded`.
+
+#### Critical invariants
+- **Funds conservation**: once `Active`, escrowed USDC amount must only leave via release/refund/dispute resolution. Custody is the escrow contract until a terminal transition.
+- **Single terminal transition**: `Released` and `Refunded` must be terminal; no further balance transfer should be possible once set.
+- **Oracle release requires trustScore >= trustThreshold**.
+- **Dispute resolution sends funds to either buyer or seller; no third-party recipients**.
+
+#### Authority model
+- **Buyer**: can `refundEscrow` and `disputeEscrow` (when in `Active` or `Challenged`).
+- **Seller**: can `respondChallenge` and `disputeEscrow`.
+- **Oracle**: `releaseEscrow` and `resolveChallenge` (must be `onlyOracle`).
+- **Owner**: `resolveDispute`, `setOracle`, `pause/unpause`.
+- **Challenger**: `initiateChallenge` and `claimChallengeTimeout` (no explicit check to ensure caller is challenger in `claimChallengeTimeout`).
+
+#### Funds flow
+- **Create**: buyer approves and transfers USDC to escrow contract via `transferFrom`.
+- **Release**: escrow transfers USDC to seller via `transfer`.
+- **Refund**: escrow transfers USDC to buyer via `transfer`.
+- **Dispute resolve**: escrow transfers USDC to winner via `transfer`.
+- **Challenge**: challenger stakes USDC via `transferFrom`; stake is returned to challenger in both pass/fail paths.
+
+### Challenge (“Voight-Kampff”) lifecycle
+- **Open**: `initiateChallenge` on an `Active` escrow; escrow state becomes `Challenged`. Stake is locked.
+- **Respond**: `respondChallenge` by seller before deadline.
+- **Resolve**: oracle `resolveChallenge` before deadline; or `claimChallengeTimeout` after deadline (any caller).
+- **Slash/release**:
+  - Pass: stake returned to challenger, escrow back to `Active`.
+  - Fail/timeout: escrow refunded to buyer and challenger’s stake returned (no double payout).
+
+#### Critical invariants
+- **Challenge stake never mints value**: total outflow equals stake + escrow amount.
+- **Challenge resolution should be single-shot**: status changes to `Resolved` once; no repeated transfer should be possible.
+
+#### Authority model
+- **Challenger** opens challenge (requires stake + cooldown).
+- **Seller** responds.
+- **Oracle** resolves before deadline; anyone can claim timeout after deadline.
+
+#### Funds flow
+- Challenger stake locked at initiation; returned to challenger when resolved (pass/fail/timeout).
+- If failed/timeout, escrow amount returns to buyer.
+
+### Oracle inputs/outputs (trust scoring)
+- **On-chain**: `RookOracle.computeTrustScore` uses cached `identityScores`, `reputationScores`, `sybilScores`, `challengeBonuses`, plus on-chain completion history from `escrow.getCompletionRate`.
+- **Off-chain (oracle service)**: `ScoringService.calculateScore` pulls ERC-8004 identity/reputation, Moltbook social signals, sybil signals, and escrow history; weights are 25/25/20/20/10 in both TS and Solidity.
+
+#### Critical invariants
+- **Score bounds**: components expected 0–100; oracle enforces component cap in `updateScores`.
+- **Operator-only updates**: only oracle operators (or owner) can update cached scores.
+
+#### Authority model
+- **Operators** (off-chain oracle) call `updateScores`, `triggerRelease`, `resolveChallenge`.
+- **Owner** can set operators and registries.
+
+#### Funds flow
+- Oracle triggers release by calling escrow; oracle does not custody funds.
 
 ---
 
-## 1. RookEscrow.sol
-
-### 🔴 High Priority Issues
-
-#### H1: Unused Error Definitions
-**Lines:** 183, 184, 186, 595
-```solidity
-error DeadlineNotPassed();      // Never used
-error NotChallenger();          // Never used
-error ContractPaused();         // Redundant (Pausable has its own)
-error BelowThreshold();         // Defined at end, should be with others
-```
-**Fix:** Remove unused errors or implement the checks.
-
-#### H2: Missing Address(0) Check in Constructor for Oracle
-**Line:** 192-197
-The constructor checks `_usdc` but not `_oracle` for zero address.
-```solidity
-constructor(address _usdc, address _oracle) {
-    if (_usdc == address(0)) revert InvalidSeller();
-    if (_oracle == address(0)) revert InvalidSeller(); // Missing!
-    // ...
-}
-```
-
-#### H3: Potential DoS via Unbounded Arrays
-**Lines:** 265-266
-```solidity
-buyerEscrows[msg.sender].push(escrowId);
-sellerEscrows[seller].push(escrowId);
-```
-These arrays can grow indefinitely. While only used in view functions, this could cause issues if someone creates many escrows.
-
-**Fix:** Consider pagination or limiting array size.
+## 2. Test Map + Likely Failures
+
+### Test Map
+| Test file | Contract/Function | Scenario | Assertions | Missing asserts |
+| --- | --- | --- | --- | --- |
+| `contracts/test/RookEscrow.t.sol` | `createEscrow` | Happy-path escrow creation | State fields, status set, nonzero ID | No asserts on `buyerEscrows`/`sellerEscrows` arrays or `totalVolume`. |
+| `contracts/test/RookEscrow.t.sol` | `releaseEscrow` | Oracle release happy path | Seller balance increased, status `Released` | No assert on `completedEscrows` increment or release event. |
+| `contracts/test/RookEscrow.t.sol` | `releaseWithConsent` | Timeout release | Seller balance increased, status `Released` | No assert on timeout guard or unauthorized caller reverts. |
+| `contracts/test/RookEscrow.t.sol` | `refundEscrow` | Buyer refund | Buyer balance increased, status `Refunded` | No assert on reentrancy guard or `EscrowNotActive` revert. |
+| `contracts/test/RookEscrow.t.sol` | Challenge flow | Pass/fail/timeout | Balances updated, statuses updated | Missing assertions on challenge status transitions and response deadline enforcement. |
+| `contracts/test/RookEscrow.t.sol` | `disputeEscrow`/`resolveDispute` | Dispute resolution | Winner paid, status `Released` | No assert on `dispute.resolved`/`dispute.winner` fields, or `EscrowNotDisputed` revert. |
+| `contracts/test/RookEscrow.t.sol` | Pausable + invalid params | Reverts | Revert checks | No coverage for `pause` on challenge operations. |
+| `contracts/test/RookOracle.t.sol` | `updateScores` | Operator updates | Cached scores | Missing `lastUpdated` or event assertions. |
+| `contracts/test/RookOracle.t.sol` | `computeTrustScore` | Composite weighting | Score 64 (floored) | No asserts for history score > 0 paths. |
+| `contracts/test/RookOracle.t.sol` | `getScoreBreakdown` | Breakdown correctness | component equality | No asserts for `composite` vs `computeTrustScore` match.
+
+### Likely failures or flaky tests
+- **Time/block dependence**: `RookEscrow` mixes `block.timestamp` (timeouts) and `block.number` (challenge deadline), meaning tests that assume “time” semantics for `CHALLENGE_BLOCKS` may break if block increments are not managed properly.
+- **ERC20 mocking pitfalls**: `MockUSDC` is a standard ERC20; no coverage for non-standard tokens returning `false` without revert or for fee-on-transfer tokens.
+- **Oracle operator assumptions**: tests call `escrow.releaseEscrow` directly, bypassing `RookOracle.triggerRelease` logic, which could mask integration errors.
 
 ---
 
-### 🟡 Medium Priority Issues
-
-#### M1: Storage Packing Optimization
-**Current:**
+## 3. Missing Tests (10+)
+
+### Foundry test ideas (titles + steps + expected asserts)
+1. **Revert when non-oracle calls `releaseEscrow`**
+   - Create escrow, `vm.prank(buyer)` calls `releaseEscrow`.
+   - Assert revert `NotOracle`.
+2. **Oracle timeout release: rejects before timeout**
+   - Create escrow, call `releaseWithConsent` before `ORACLE_TIMEOUT`.
+   - Assert revert `OracleTimeoutNotMet`.
+3. **Challenge cooldown enforcement**
+   - Initiate challenge once; immediately try again from same address.
+   - Assert `ChallengeCooldownActive`.
+4. **Challenge response after deadline**
+   - Initiate challenge, roll blocks beyond deadline, seller calls `respondChallenge`.
+   - Assert `ChallengeExpired`.
+5. **Challenge resolved after deadline**
+   - Initiate challenge, roll blocks beyond deadline, oracle calls `resolveChallenge`.
+   - Assert `ChallengeExpired`.
+6. **Non-buyer dispute**
+   - Non-party calls `disputeEscrow`.
+   - Assert `NotAuthorized`.
+7. **Double finalization**
+   - Release escrow once; call `releaseEscrow` or `refundEscrow` again.
+   - Assert `EscrowNotActive` or `EscrowNotDisputed`.
+8. **Dispute resolution only when in `Disputed`**
+   - Call `resolveDispute` without dispute.
+   - Assert `EscrowNotDisputed`.
+9. **Transfer failure on release**
+   - Use mock token that returns `false` on transfer, attempt `releaseEscrow`.
+   - Assert `TransferFailed` and state not updated.
+10. **USDC allowance mismatch on challenge**
+   - Approve less than `CHALLENGE_STAKE`, call `initiateChallenge`.
+   - Assert `TransferFailed` and status remains `Active`.
+11. **Reentrancy attempt on release/refund**
+   - Use malicious ERC20 with reentrant `transfer`/`transferFrom` to call escrow.
+   - Assert `nonReentrant` blocks reentry.
+12. **Oracle trust score stale**
+   - Update score, advance time, trigger release with stale scores.
+   - Assert behavior is still allowed (documents risk), or add new check.
+
+### Foundry skeleton (≤ 40 lines each)
 ```solidity
-struct Escrow {
-    address buyer;          // 20 bytes (slot 0)
-    address seller;         // 20 bytes (slot 1)
-    uint256 amount;         // 32 bytes (slot 2)
-    bytes32 jobHash;        // 32 bytes (slot 3)
-    uint256 trustThreshold; // 32 bytes (slot 4) - could be uint8
-    uint256 createdAt;      // 32 bytes (slot 5) - could be uint64
-    uint256 expiresAt;      // 32 bytes (slot 6) - could be uint64
-    EscrowStatus status;    // 32 bytes (slot 7) - could be uint8
+function test_Revert_ReleaseEscrow_NotOracle() public {
+    vm.startPrank(buyer);
+    usdc.approve(address(escrow), 100 * 1e6);
+    bytes32 escrowId = escrow.createEscrow(seller, 100 * 1e6, keccak256("job"), 65);
+    vm.stopPrank();
+
+    vm.expectRevert(RookEscrow.NotOracle.selector);
+    escrow.releaseEscrow(escrowId, 80);
 }
-// Total: 8 slots
 ```
 
-**Optimized:**
 ```solidity
-struct Escrow {
-    address buyer;          // 20 bytes
-    address seller;         // 20 bytes
-    uint64 createdAt;       // 8 bytes
-    uint64 expiresAt;       // 8 bytes
-    uint8 trustThreshold;   // 1 byte
-    uint8 status;           // 1 byte
-    // Total: 58 bytes (fits in 2 slots!)
-    uint256 amount;         // 32 bytes (slot 2)
-    bytes32 jobHash;        // 32 bytes (slot 3)
+function test_Revert_ReleaseWithConsent_BeforeTimeout() public {
+    vm.startPrank(buyer);
+    usdc.approve(address(escrow), 100 * 1e6);
+    bytes32 escrowId = escrow.createEscrow(seller, 100 * 1e6, keccak256("job"), 65);
+    vm.stopPrank();
+
+    vm.expectRevert(RookEscrow.OracleTimeoutNotMet.selector);
+    vm.prank(buyer);
+    escrow.releaseWithConsent(escrowId);
 }
-// Total: 4 slots (50% reduction)
-```
-
-#### M2: String Storage Cost
-**Line:** 59
-```solidity
-string evidence;  // Expensive dynamic storage
-```
-Consider using `bytes32` for IPFS hash (CID) instead of string.
-
-#### M3: Duplicate External Call in `releaseWithConsent`
-**Line:** 314
-```solidity
-bool success = usdc.transfer(escrow.seller, escrow.amount);
-```
-Consider adding a try-catch or handling transfer failures more gracefully.
-
-#### M4: No Maximum Evidence Length
-**Line:** 347
-```solidity
-string calldata evidence
 ```
-No length check - could be exploited with very long strings (gas griefing).
 
-#### M5: Block Number vs Timestamp Inconsistency
-**Lines:** 75, 81
 ```solidity
-uint256 public constant CHALLENGE_BLOCKS = 50;    // Uses block.number
-uint256 public constant ORACLE_TIMEOUT = 1 days;   // Uses block.timestamp
-```
-Consider using one or the other consistently for time-based logic.
-
-#### M6: Missing Event for `setOracle`
-**Line:** 576-581
-The function emits `OracleUpdated` but doesn't include the new oracle address in indexed params.
-
-#### M7: No Escrow Expiration Enforcement
-**Line:** 261
-```solidity
-expiresAt: block.timestamp + DEFAULT_EXPIRY,
-```
-The `expiresAt` field is set but never checked or enforced.
-
-**Fix:** Add automatic refund after expiry or extend functionality.
-
-#### M8: Challenge Response Window Not Enforced
-**Line:** 75
-```solidity
-uint256 public constant CHALLENGE_RESPONSE_WINDOW = 25; // Unused!
-```
-The constant is defined but never used. The response deadline is the same as the challenge deadline.
-
----
-
-### 🟢 Low Priority Issues
-
-#### L1: Missing NatSpec for Some Functions
-Functions like `getEscrow`, `getChallenge`, `pause`, `unpause` lack full NatSpec.
-
-#### L2: Magic Numbers
-Consider defining `50`, `25`, `100` as named constants.
-
-#### L3: Inconsistent Error Naming
-```solidity
-error NotAuthorized();  // Generic
-error NotBuyer();       // Specific
-error NotSeller();      // Specific
-```
-Consider more descriptive errors.
-
-#### L4: Constructor Parameter Shadowing
-Consider adding underscore prefix or different naming:
-```solidity
-constructor(address usdc_, address oracle_)  // or _usdc, _oracle
-```
-
-#### L5: Function Ordering
-Consider grouping functions by visibility (external, public, internal, view).
-
-#### L6: Redundant Check in `claimChallengeTimeout`
-**Line:** 526
-```solidity
-if (block.number <= challenge.deadline) revert ChallengeNotExpired();
-```
-Already checked by `ChallengeNotActive` on line 525 in most cases.
-
-#### L7: Missing Indexed Parameters in Events
-Some events could benefit from more indexed parameters for filtering.
-
-#### L8: No Emergency Withdrawal
-If tokens are accidentally sent to the contract, there's no recovery mechanism (except dispute resolution).
-
-#### L9: Trust Score Not Stored
-The trust score used for release is not stored in the escrow struct for audit purposes.
-
-#### L10: Completion Rate Precision
-**Line:** 569
-```solidity
-return (completedEscrows[agent] * 100) / totalEscrows[agent];
-```
-Integer division - precision loss. Consider using basis points (10000).
-
-#### L11: Self-Challenge Check Location
-**Line:** 419
-The self-challenge check is done after rate limit check. Consider reversing order for gas efficiency.
-
-#### L12: Missing `view` Function for Challenge Cooldown
-No way to check when a user can challenge again.
-
----
-
-## 2. RookOracle.sol
-
-### 🔴 High Priority Issues
-
-#### H1: Missing Zero Address Check
-**Line:** 75-77
-```solidity
-constructor(address _escrow) {
-    escrow = IRookEscrow(_escrow);  // No zero check!
-}
-```
-
-### 🟡 Medium Priority Issues
-
-#### M1: Unused Registries
-**Lines:** 20-21
-```solidity
-IERC8004Identity public identityRegistry;
-IERC8004Reputation public reputationRegistry;
-```
-These are set but never used on-chain. Consider removing or implementing on-chain verification.
-
-#### M2: No Events for Registry Updates
-**Lines:** 203-213
-`setRegistries` and `setEscrow` don't emit events.
-
-#### M3: No Input Validation on Setters
-```solidity
-function setEscrow(address _escrow) external onlyOwner {
-    // No zero address check!
-    escrow = IRookEscrow(_escrow);
+function test_Revert_ChallengeResponse_AfterDeadline() public {
+    vm.startPrank(buyer);
+    usdc.approve(address(escrow), 100 * 1e6);
+    bytes32 escrowId = escrow.createEscrow(seller, 100 * 1e6, keccak256("job"), 65);
+    vm.stopPrank();
+
+    vm.startPrank(challenger);
+    usdc.approve(address(escrow), 5 * 1e6);
+    escrow.initiateChallenge(escrowId);
+    vm.stopPrank();
+
+    vm.roll(block.number + 51);
+    vm.expectRevert(RookEscrow.ChallengeExpired.selector);
+    vm.prank(seller);
+    escrow.respondChallenge(escrowId, keccak256("resp"));
 }
 ```
 
-#### M4: Trust Score Cache Never Expires
-**Line:** 106
-```solidity
-lastUpdated[agent] = block.timestamp;
-```
-The timestamp is stored but never checked. Stale scores could be used indefinitely.
-
-#### M5: Potential Reentrancy (Defense in Depth)
-**Lines:** 152-157, 164-172
-Functions calling external contracts should have `nonReentrant` even if called functions have it.
-
 ---
 
-### 🟢 Low Priority Issues
-
-#### L1: Missing NatSpec for View Functions
-#### L2: No Maximum Score Age Enforcement
-#### L3: Challenge Bonus Not Reset
-**Line:** 170
-```solidity
-challengeBonuses[e.seller] = 100;  // Never reset
-```
+## 4. Security Findings (Ranked)
+
+### High: Oracle trustScore freshness not enforced
+- **Where**: `RookOracle.triggerRelease` uses cached scores without staleness check; `RookOracle.lastUpdated` is tracked but never checked.
+- **Exploit story**: An operator sets a high trust score once; months later, an escrow release is triggered without recomputing scores even if the agent’s reputation has degraded off-chain.
+- **Impact**: Escrow auto-release can happen based on stale or compromised scoring.
+- **Fix**: Add a staleness threshold (e.g., `MAX_SCORE_AGE`) to `triggerRelease` and/or `releaseEscrow`, reverting if `block.timestamp - lastUpdated[seller]` exceeds threshold.
+- **Test**: Update scores, advance time beyond `MAX_SCORE_AGE`, call `triggerRelease`, expect revert.
+
+### High: Challenge timeout can be claimed by anyone (front-running/griefing)
+- **Where**: `RookEscrow.claimChallengeTimeout` has no `msg.sender == challenger` check.
+- **Exploit story**: Any actor can front-run the legitimate challenger to force timeout resolution, which may be acceptable but creates griefing vectors (e.g., MEV bots claiming timeout to control timing, potentially in combination with score updates).
+- **Impact**: Unclear trust model; enables third-party interference in challenge resolution timing.
+- **Fix**: Require `msg.sender == challenge.challenger` or allow only challenger + buyer to call timeout.
+- **Test**: Non-challenger calls `claimChallengeTimeout` after deadline; expect revert.
+
+### Medium: Missing challenge response window enforcement
+- **Where**: `CHALLENGE_RESPONSE_WINDOW` is defined but unused; response deadline is the full `CHALLENGE_BLOCKS`.
+- **Exploit story**: Seller can wait until the last block to respond, increasing uncertainty and griefing challenger.
+- **Impact**: Slower resolution, more MEV/timing risk.
+- **Fix**: Add a requirement that `block.number <= (challenge.deadline - CHALLENGE_RESPONSE_WINDOW)` for responses.
+- **Test**: Respond after window but before deadline; expect revert.
+
+### Medium: `releaseWithConsent` is not actually mutual consent
+- **Where**: `releaseWithConsent` allows either party to unilaterally release after timeout.
+- **Exploit story**: Seller can release funds after timeout even if buyer disputes; buyer has no on-chain veto.
+- **Impact**: Trust model mismatch; disputes could be bypassed after timeout.
+- **Fix**: Require explicit on-chain consent from both parties (e.g., 2-step approvals), or rename to `releaseAfterTimeout` to match behavior.
+- **Test**: Buyer does not approve, seller calls `releaseWithConsent`; ensure revert or new two-step logic.
+
+### Medium: Dispute evidence is unbounded string
+- **Where**: `disputeEscrow` stores `string evidence` without length checks.
+- **Exploit story**: Gas griefing by submitting huge evidence strings, increasing storage cost.
+- **Impact**: Elevated gas costs and storage bloat.
+- **Fix**: Store `bytes32` IPFS CID hash or enforce maximum length.
+- **Test**: Attempt to store oversized evidence and ensure revert.
+
+### Low: Mixed block timestamp vs block number timing
+- **Where**: `ORACLE_TIMEOUT` uses timestamp; challenge uses block number.
+- **Exploit story**: Inconsistent timing assumptions, especially in testing or L2 contexts with variable block times.
+- **Impact**: Timing edge cases; confusion for integrators.
+- **Fix**: Standardize to block timestamps for all timeouts.
+- **Test**: Confirm both paths use same time source.
 
 ---
 
-## 3. SDK (client.ts)
-
-### 🔴 High Priority Issues
-
-#### H1: Private Key Exposure Risk
-**Line:** 45-55
-```typescript
-if (config.privateKey) {
-  this.signer = new Wallet(config.privateKey, this.provider);
-}
-```
-Private key is accepted in constructor. If this is logged or error messages include config, key could leak.
-
-**Fix:** Accept signer interface instead, or warn about security.
+## 5. Trust Score Red-Team + Revised Scoring
 
-### 🟡 Medium Priority Issues
+### Gameable inputs (current)
+- **ERC-8004 identity score** is a binary 80/0 based on registration; easy to sybil if registration is cheap.
+- **ERC-8004 reputation** depends on average ratings and feedback count; can be inflated via self-rating farms.
+- **Moltbook social score** relies on karma, follower ratio, and account age, which can be faked with coordinated sybils.
+- **Sybil score** in `ScoringService` is affected by transaction count and Moltbook sybil score; both can be inflated cheaply.
 
-#### M1: No Input Validation
-**Example:**
-```typescript
-async createEscrow(params: EscrowParams): Promise<EscrowResult> {
-  // No validation that amount > 0, threshold valid, etc.
-}
-```
-SDK should validate inputs before sending transactions.
+### 5+ sybil strategies
+1. **Cheap ERC-8004 registrations**: register many identities to gain 80-point identity component.
+2. **Reputation loop farming**: self-reviews or cross-sybil reviews to boost `getReputationScore`.
+3. **Karma velocity gaming**: post bursts while staying under suspicious threshold (<100/day) to farm karma-based social score.
+4. **Follower ring**: sybil accounts follow each other to raise follower ratios.
+5. **Transaction count inflation**: send self-transfers to inflate `getTransactionCount` activity score.
 
-#### M2: Weak Type for Status
-**Line:** 255
-```typescript
-status: ['Active', 'Released', 'Refunded', 'Disputed', 'Challenged'][escrow.status],
+### Revised scoring formula (pseudocode)
 ```
-Should be a union type:
-```typescript
-type EscrowStatus = 'Active' | 'Released' | 'Refunded' | 'Disputed' | 'Challenged';
-```
-
-#### M3: No Gas Estimation or Limits
-No way to specify gas limit or price.
-
-#### M4: No Retry Logic
-Network failures require manual retry.
-
-#### M5: Event Listening Not Implemented
-No way to listen for events in real-time.
-
-#### M6: Provider Disconnection Not Handled
-No reconnection logic.
-
-#### M7: Missing Transaction Confirmation Checks
-**Line:** 122
-```typescript
-const receipt = await tx.wait();
+identity = gate(erc8004_registered, account_age >= 30d) ? 70 : 0
+reputation = clamp(erc8004_reputation, 0, 100)
+reputation = reputation * log1p(feedback_count) / log1p(100)
+sybil = moltbook_sybil * age_decay + activity_score * 0.5
+history = clamp(completion_rate, 0, 100)
+challenge_bonus = min(challenge_success_rate * 100, 20)
+composite =
+  0.20 * identity +
+  0.30 * reputation +
+  0.20 * sybil +
+  0.20 * history +
+  0.10 * challenge_bonus
+
+apply_penalties:
+  - if anomalous_growth -> composite *= 0.7
+  - if new_account (<7d) -> composite *= 0.5
 ```
-Doesn't check `receipt.status` for failures.
-
----
-
-### 🟢 Low Priority Issues
 
-#### L1: Missing JSDoc for Some Methods
-#### L2: No Pagination for Array Methods
-#### L3: Hardcoded RPC URLs
-**Line:** 446-448
-```typescript
-case 'base-sepolia':
-  return 'https://sepolia.base.org';
-```
-Should be configurable or use multiple fallbacks.
-
-#### L4: No Batch Request Support
-#### L5: Missing Rate Limiting
-#### L6: ENS Resolution Error Handling
-**Line:** 434-437
-```typescript
-if (agent.endsWith('.eth')) {
-  const address = await this.provider.resolveName(agent);
-  if (!address) throw new RookError(...);
-  return address;
-}
-```
-No timeout or retry for ENS resolution.
+### Defenses
+- **Weight shift**: increase history weight; reduce social score influence.
+- **Time-decay**: account-age and reputation recency multipliers.
+- **Diversity heuristic**: require feedback from distinct counter-parties.
+- **Challenge penalty**: failed challenges reduce composite for a time window.
+- **Confidence interval**: conservative score if data sources are missing.
+
+### Red team checklist
+- Can a new account achieve ≥65 trust score with <7 days age?
+- Can sybil ring artificially raise follower ratio or karma without spending real cost?
+- Does a single high-activity spike over-influence score?
+- Are missing data sources treated as neutral instead of conservative?
+- Are penalties for failed challenges time-bound and meaningful?
+
+### Unit tests (scoring)
+- `calculateScore` caps output within 0–100.
+- Missing Moltbook handle should not increase score above ERC-8004 baseline.
+- Large txCount spike should saturate activity score.
+- New account age penalty should reduce composite.
+- Failed challenge should reduce composite for a fixed window.
 
 ---
 
-## 4. Missing Functionality
+## 6. Performance & Optimization
 
-### Critical Missing Features
+### Solidity (gas + storage)
+- **Storage packing**: `Escrow` uses multiple `uint256` fields that could be packed into `uint64`/`uint8` fields; could reduce SSTORE costs significantly.
+- **Challenge/escrow arrays**: `buyerEscrows`/`sellerEscrows` grow unbounded; could be replaced with events and off-chain indexing.
+- **Events**: consider indexing `buyer`/`seller`/`challenger` consistently; avoid large `string` in events if moving evidence to hash.
 
-1. **Emergency Fund Recovery**
-   - No way to recover accidentally sent tokens
-   - No way to rescue stuck funds in edge cases
+**Estimated impact**: storage packing is **large**; event indexing changes are **small/medium**.
 
-2. **Batch Operations**
-   - Can't create multiple escrows in one transaction
-   - Can't release multiple escrows efficiently
+### TypeScript (latency + reliability)
+- **ScoringService**: parallel calls already used, but no caching/memoization for ERC-8004 or Moltbook responses.
+- **RPC calls**: `calculateSybilScore` hits `getCode` and `getTransactionCount` sequentially; can parallelize or cache.
+- **Error handling**: `getHistoryScore` returns neutral on errors; consider return conservative lower scores instead.
 
-3. **Fee Mechanism**
-   - No protocol fee for sustainability
-   - No way to fund oracle operations
-
-4. **Upgradeability**
-   - Contracts are not upgradeable
-   - Bugs require full redeployment
-
-5. **Timelock for Admin Actions**
-   - `setOracle`, `resolveDispute` have no delay
-   - Compromised owner key = immediate disaster
-
-### Nice-to-Have Features
-
-1. **ERC-20 Support Beyond USDC**
-2. **Partial Releases** (milestone payments)
-3. **Challenge Appeal Process**
-4. **On-Chain Reputation NFT**
-5. **Meta-Transactions** (gasless operations)
-
----
-
-## 5. Recommended Fixes (Priority Order)
-
-### Immediate (Before Testnet)
-1. ✅ Remove/fix unused error definitions
-2. ✅ Add missing zero-address checks
-3. ✅ Validate SDK inputs
-4. ✅ Add transaction status checks
-
-### Before Mainnet
-5. Optimize storage packing (gas savings)
-6. Add reentrancy guards to Oracle
-7. Implement score expiration
-8. Add emergency withdrawal
-9. Add fee mechanism
-10. Add timelock for admin
-
-### Future Enhancements
-11. Batch operations
-12. Meta-transactions
-13. Upgradeability
-14. Event listening in SDK
+**Plan**:
+- **Quick wins (≤1 hour)**: add in-memory caching for ERC-8004/Moltbook calls; parallelize RPC requests.
+- **Next sprint (1–3 days)**: add retry/backoff for external API; batch on-chain reads.
+- **Hard but worth it (1–2 weeks)**: implement off-chain scoring job queue + persisted scoring cache.
 
 ---
 
-## 6. Gas Optimization Summary
-
-| Optimization | Current Gas | Optimized Gas | Savings |
-|-------------|-------------|---------------|---------|
-| Storage Packing | ~200k | ~150k | 25% |
-| String → bytes32 | ~50k | ~5k | 90% |
-| Remove redundant checks | ~5k | ~3k | 40% |
-| **Total Potential** | | | **~30-35%** |
+## 7. Patch Plan (PR breakdown)
+
+### P0/P1/P2 TODOs
+- **P0**: add staleness checks for scores and restrict challenge timeout caller.
+- **P1**: enforce response windows, add mutual consent flow or rename semantics, limit evidence size.
+- **P2**: storage packing, event indexing improvements, expanded tests.
+
+### PR#1 — Security fixes
+- **Files**: `contracts/src/RookOracle.sol`, `contracts/src/RookEscrow.sol`
+- **Summary**: add score staleness checks, restrict timeout caller, enforce response window.
+- **Acceptance**:
+  - Score updates must be recent to release.
+  - Non-challenger cannot claim timeout.
+  - Responses after response window revert.
+
+### PR#2 — Test suite hardening
+- **Files**: `contracts/test/*.sol`, `contracts/test/mocks/*`
+- **Summary**: add unhappy-path tests, non-standard ERC20 tests, reentrancy attempts.
+- **Acceptance**:
+  - 10+ new tests for failure paths pass.
+  - Coverage includes revert paths for non-oracle, timeout before deadline, transfer failures.
+
+### PR#3 — Scoring robustness
+- **Files**: `oracle/src/services/scoring.ts`, `oracle/src/services/moltbook.ts`, `oracle/src/services/erc8004.ts`
+- **Summary**: incorporate decay, penalties, and conservative defaults.
+- **Acceptance**:
+  - Unit tests show sybil resistance improvements and bounded scores.
+
+### PR#4 — Performance
+- **Files**: `contracts/src/RookEscrow.sol`, `oracle/src/services/scoring.ts`, `sdk/src/client.ts`
+- **Summary**: storage packing, cache, batching, and RPC parallelism.
+- **Acceptance**:
+  - Gas reduction measured for `createEscrow` and `initiateChallenge`.
+  - Scoring latency reduced in benchmarks.
 
 ---
 
-## 7. Security Checklist
-
-- [x] Reentrancy protection
-- [x] Access control
-- [x] Input validation
-- [x] Emergency pause
-- [x] Economic safety (no 2x payout)
-- [ ] Zero-address checks (incomplete)
-- [ ] Score expiration
-- [ ] Timelock for admin
-- [ ] Upgradeability
-
----
+## 8. Creative Enhancements (TEE/ZK/Bounties + Agent-native VK)
+
+### Innovative trust features (3)
+1. **TEE-attested scoring**
+   - **Threat model**: protects against oracle operator tampering.
+   - **Integration**: oracle service signs scores with TEE attestation; on-chain checks attestation signature.
+2. **ZK reputation proofs**
+   - **Threat model**: prevent disclosure of raw reputation signals.
+   - **Integration**: submit ZK proof that `reputation_score >= X` without revealing raw data.
+3. **Counterparty diversity score**
+   - **Threat model**: limits reputation farming with sybils.
+   - **Integration**: weight history by distinct counterparty count, not raw total.
+
+### Agent-native Voight-Kampff improvements
+- **On-chain commitment**: seller commits to a nonce/answer hash; oracle verifies against off-chain challenge.
+- **Stake-weighted probing**: higher-stake challengers can request more stringent challenges.
+- **Adaptive challenges**: difficulty scales with observed anomalies (e.g., karma velocity spikes).
+
+### Hunter bounties mechanism
+- **Funding**: percentage fee on escrow creation funds a bounty pool.
+- **Verification**: reporters submit evidence + stake; oracle/DAO validates and slashes false reports.
+- **Payout**: successful reports receive bounty plus stake refund; false reports lose stake.
+- **Tests needed**:
+  - Report success path (payout + slashing offender).
+  - False report slashing.
+  - Double-report prevention.
+  - Funding pool accounting.
 
-**Review Date:** 2026-02-04
-**Reviewer:** AI Code Review
-**Overall Score:** 7.5/10 (Good, needs improvements before mainnet)
