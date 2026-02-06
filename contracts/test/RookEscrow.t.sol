// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/RookEscrow.sol";
import "../src/RookOracle.sol";
import "./mocks/MockUSDC.sol";

contract RookEscrowTest is Test {
    RookEscrow public escrow;
    RookOracle public oracle;
    MockUSDC public usdc;

    address public owner = address(1);
    address public buyer = address(2);
    address public seller = address(3);
    address public challenger = address(4);

    function setUp() public {
        // Deploy MockUSDC outside prank so address(this) gets the supply
        usdc = new MockUSDC(1_000_000 * 10**6);

        vm.startPrank(owner);
        oracle = new RookOracle(address(0));
        escrow = new RookEscrow(address(usdc), address(oracle));
        oracle.setEscrow(address(escrow));
        oracle.setOperator(address(this), true);
        vm.stopPrank();

        // Fund accounts (from address(this) which holds the supply)
        usdc.transfer(buyer, 10_000 * 10**6);
        usdc.transfer(challenger, 1_000 * 10**6);
    }

    // =================================================================
    // ESCROW CREATION
    // =================================================================

    function test_CreateEscrow() public {
        vm.startPrank(buyer);

        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        uint256 threshold = 65;

        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, threshold);

        assertTrue(escrowId != bytes32(0));

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.buyer, buyer);
        assertEq(e.seller, seller);
        assertEq(e.amount, amount);
        assertEq(e.trustThreshold, threshold);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Active));

        // Verify tracking arrays
        bytes32[] memory buyerArr = escrow.getBuyerEscrows(buyer);
        assertEq(buyerArr.length, 1);
        assertEq(buyerArr[0], escrowId);

        bytes32[] memory sellerArr = escrow.getSellerEscrows(seller);
        assertEq(sellerArr.length, 1);
        assertEq(sellerArr[0], escrowId);

        // Verify counters
        assertEq(escrow.totalEscrows(seller), 1);
        assertEq(escrow.totalVolume(), amount);

        vm.stopPrank();
    }

    function test_Revert_InvalidAmount() public {
        vm.startPrank(buyer);
        vm.expectRevert(RookEscrow.InvalidAmount.selector);
        escrow.createEscrow(seller, 0, keccak256("job"), 65);
        vm.stopPrank();
    }

    function test_Revert_InvalidSeller_ZeroAddress() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        vm.expectRevert(RookEscrow.InvalidSeller.selector);
        escrow.createEscrow(address(0), 100 * 10**6, keccak256("job"), 65);
        vm.stopPrank();
    }

    function test_Revert_InvalidSeller_SelfEscrow() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        vm.expectRevert(RookEscrow.InvalidSeller.selector);
        escrow.createEscrow(buyer, 100 * 10**6, keccak256("job"), 65);
        vm.stopPrank();
    }

    function test_Revert_InvalidThreshold_TooLow() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        vm.expectRevert(RookEscrow.InvalidThreshold.selector);
        escrow.createEscrow(seller, 100 * 10**6, keccak256("job"), 40);
        vm.stopPrank();
    }

    function test_Revert_InvalidThreshold_TooHigh() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        vm.expectRevert(RookEscrow.InvalidThreshold.selector);
        escrow.createEscrow(seller, 100 * 10**6, keccak256("job"), 101);
        vm.stopPrank();
    }

    // =================================================================
    // ORACLE RELEASE
    // =================================================================

    function test_ReleaseEscrow() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        oracle.updateScores(seller, 80, 80, 80, 0);

        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(address(oracle));
        escrow.releaseEscrow(escrowId, 70);

        uint256 sellerAfter = usdc.balanceOf(seller);

        // Seller receives amount minus protocol fee
        uint256 expectedFee = (100 * 10**6 * 50) / 10000; // 0.5%
        assertEq(sellerAfter - sellerBefore, 100 * 10**6 - expectedFee);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));

        // Verify completed count incremented
        assertEq(escrow.completedEscrows(seller), 1);
    }

    function test_Revert_ReleaseEscrow_NotOracle() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(address(0x999));
        vm.expectRevert(RookEscrow.NotOracle.selector);
        escrow.releaseEscrow(escrowId, 70);
    }

    function test_Revert_BelowThreshold() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(address(oracle));
        vm.expectRevert(RookEscrow.BelowThreshold.selector);
        escrow.releaseEscrow(escrowId, 60);
    }

    function test_Revert_DoubleRelease() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        oracle.updateScores(seller, 80, 80, 80, 0);

        vm.prank(address(oracle));
        escrow.releaseEscrow(escrowId, 70);

        vm.prank(address(oracle));
        vm.expectRevert(RookEscrow.EscrowNotActive.selector);
        escrow.releaseEscrow(escrowId, 70);
    }

    function test_Revert_ReleaseExpiredEscrow() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        oracle.updateScores(seller, 80, 80, 80, 0);

        vm.warp(block.timestamp + 8 days); // Past 7 day expiry

        vm.prank(address(oracle));
        vm.expectRevert(RookEscrow.EscrowExpired.selector);
        escrow.releaseEscrow(escrowId, 70);
    }

    // =================================================================
    // CONSENT RELEASE (TWO-PARTY)
    // =================================================================

    function test_ReleaseWithConsent_BothParties() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        // Fast forward past oracle timeout
        vm.warp(block.timestamp + 2 days);

        // Buyer consents first (consent recorded but no release yet)
        vm.prank(buyer);
        escrow.releaseWithConsent(escrowId);

        // Verify escrow is still Active after single consent
        RookEscrow.Escrow memory eBefore = escrow.getEscrow(escrowId);
        assertEq(uint8(eBefore.status), uint8(RookEscrow.EscrowStatus.Active));

        // Seller consents (should now succeed since buyer already consented)
        uint256 sellerBefore = usdc.balanceOf(seller);
        vm.prank(seller);
        escrow.releaseWithConsent(escrowId);

        uint256 expectedFee = (100 * 10**6 * 50) / 10000;
        assertEq(usdc.balanceOf(seller) - sellerBefore, 100 * 10**6 - expectedFee);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));
    }

    function test_ReleaseWithConsent_SinglePartyDoesNotRelease() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        vm.warp(block.timestamp + 2 days);

        // Only buyer consents (consent saved but no release)
        vm.prank(buyer);
        escrow.releaseWithConsent(escrowId);

        // Verify escrow is still Active
        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Active));
    }

    function test_Revert_ReleaseWithConsent_BeforeTimeout() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(buyer);
        vm.expectRevert(RookEscrow.OracleTimeoutNotMet.selector);
        escrow.releaseWithConsent(escrowId);
    }

    function test_Revert_ReleaseWithConsent_NonParty() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        vm.warp(block.timestamp + 2 days);

        vm.prank(address(0x999));
        vm.expectRevert(RookEscrow.NotAuthorized.selector);
        escrow.releaseWithConsent(escrowId);
    }

    // =================================================================
    // REFUND
    // =================================================================

    function test_RefundEscrow() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        escrow.refundEscrow(escrowId, "Changed my mind");
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 100 * 10**6);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Refunded));
    }

    function test_Revert_SellerCannotRefund() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(seller);
        vm.expectRevert(RookEscrow.NotBuyer.selector);
        escrow.refundEscrow(escrowId, "Seller refund");
    }

    function test_Revert_RefundAfterRelease() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        oracle.updateScores(seller, 80, 80, 80, 0);

        vm.prank(address(oracle));
        escrow.releaseEscrow(escrowId, 70);

        vm.prank(buyer);
        vm.expectRevert(RookEscrow.EscrowNotActive.selector);
        escrow.refundEscrow(escrowId, "Too late");
    }

    // =================================================================
    // CLAIM EXPIRED
    // =================================================================

    function test_ClaimExpired() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.warp(block.timestamp + 8 days);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        escrow.claimExpired(escrowId);
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 100 * 10**6);
    }

    function test_Revert_ClaimExpired_NotExpired() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(buyer);
        vm.expectRevert(RookEscrow.EscrowNotExpired.selector);
        escrow.claimExpired(escrowId);
    }

    function test_Revert_ClaimExpired_NotBuyer() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        vm.warp(block.timestamp + 8 days);

        vm.prank(seller);
        vm.expectRevert(RookEscrow.NotBuyer.selector);
        escrow.claimExpired(escrowId);
    }

    // =================================================================
    // CHALLENGE FLOW
    // =================================================================

    function test_ChallengeFlow_SellerPasses() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        // Initiate challenge
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Challenged));

        // Seller responds
        vm.prank(seller);
        escrow.respondChallenge(escrowId, keccak256("I am real"));

        // Resolve challenge (seller passes) - must come from oracle
        // NOTE: With stake slashing, challenger only gets 50% back (2.5 USDC)
        // The other 50% goes to seller as reward for wrongful challenge
        uint256 challengerBefore = usdc.balanceOf(challenger);
        uint256 sellerBefore = usdc.balanceOf(seller);
        vm.prank(address(oracle));
        escrow.resolveChallenge(escrowId, true);

        uint256 expectedReturn = (5 * 10**6 * 50) / 100; // 50% = 2.5 USDC
        assertEq(usdc.balanceOf(challenger) - challengerBefore, expectedReturn);
        assertEq(usdc.balanceOf(seller) - sellerBefore, 5 * 10**6 - expectedReturn);

        e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Active));
    }

    function test_ChallengeFlow_SellerFails() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        uint256 challengerBefore = usdc.balanceOf(challenger);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(address(oracle));
        escrow.resolveChallenge(escrowId, false);

        assertEq(usdc.balanceOf(challenger) - challengerBefore, 5 * 10**6);
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 100 * 10**6);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Refunded));
    }

    function test_ChallengeTimeout() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.roll(block.number + 51);

        uint256 challengerBefore = usdc.balanceOf(challenger);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(challenger);
        escrow.claimChallengeTimeout(escrowId);

        assertEq(usdc.balanceOf(challenger) - challengerBefore, 5 * 10**6);
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 100 * 10**6);
    }

    function test_Revert_SelfChallenge() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(seller);
        usdc.approve(address(escrow), 5 * 10**6);
        vm.expectRevert(RookEscrow.SelfChallenge.selector);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();
    }

    function test_Revert_ChallengeCooldownActive() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 200 * 10**6);
        bytes32 id1 = escrow.createEscrow(seller, 100 * 10**6, keccak256("Job 1"), 65);
        bytes32 id2 = escrow.createEscrow(seller, 100 * 10**6, keccak256("Job 2"), 65);
        vm.stopPrank();

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 10 * 10**6);
        escrow.initiateChallenge(id1);

        vm.expectRevert(RookEscrow.ChallengeCooldownActive.selector);
        escrow.initiateChallenge(id2);
        vm.stopPrank();
    }

    function test_Revert_RespondAfterDeadline() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.roll(block.number + 51);

        vm.prank(seller);
        vm.expectRevert(RookEscrow.ChallengeExpired.selector);
        escrow.respondChallenge(escrowId, keccak256("Late response"));
    }

    function test_Revert_ResolveAfterDeadline() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.roll(block.number + 51);

        vm.prank(address(oracle));
        vm.expectRevert(RookEscrow.ChallengeExpired.selector);
        escrow.resolveChallenge(escrowId, true);
    }

    function test_Revert_ResponseWindowExpired() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.roll(block.number + 26); // Past 25-block response window

        vm.prank(seller);
        vm.expectRevert(RookEscrow.ChallengeResponseWindowExpired.selector);
        escrow.respondChallenge(escrowId, keccak256("Too late"));
    }

    function test_Revert_NonChallengerClaimTimeout() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.roll(block.number + 51);

        vm.prank(address(0x999));
        vm.expectRevert(RookEscrow.NotChallenger.selector);
        escrow.claimChallengeTimeout(escrowId);
    }

    function test_Revert_EmptyResponseHash() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.prank(seller);
        vm.expectRevert(RookEscrow.InvalidResponseHash.selector);
        escrow.respondChallenge(escrowId, bytes32(0));
    }

    function test_Revert_ChallengeExpiredEscrow() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        vm.warp(block.timestamp + 8 days);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        vm.expectRevert(RookEscrow.EscrowExpired.selector);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();
    }

    // =================================================================
    // DISPUTE
    // =================================================================

    function test_DisputeAndResolve() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(buyer);
        escrow.disputeEscrow(escrowId, "ipfs://Qm...");

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Disputed));

        uint256 sellerBefore = usdc.balanceOf(seller);
        vm.prank(owner);
        escrow.resolveDispute(escrowId, seller, "Seller delivered");

        assertEq(usdc.balanceOf(seller) - sellerBefore, 100 * 10**6);

        e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Released));
    }

    function test_Revert_NonPartyDispute() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(address(0x999));
        vm.expectRevert(RookEscrow.NotAuthorized.selector);
        escrow.disputeEscrow(escrowId, "Not my business");
    }

    function test_Revert_EvidenceTooLong() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        // Create 1001-char evidence
        bytes memory longEvidence = new bytes(1001);
        for (uint256 i = 0; i < 1001; i++) {
            longEvidence[i] = 0x61; // 'a'
        }

        vm.prank(buyer);
        vm.expectRevert(RookEscrow.EvidenceTooLong.selector);
        escrow.disputeEscrow(escrowId, string(longEvidence));
    }

    function test_Revert_DisputeResolve_NotDisputed() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(owner);
        vm.expectRevert(RookEscrow.EscrowNotDisputed.selector);
        escrow.resolveDispute(escrowId, seller, "No dispute");
    }

    function test_Revert_DisputeResolve_InvalidWinner() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(buyer);
        escrow.disputeEscrow(escrowId, "evidence");

        vm.prank(owner);
        vm.expectRevert(RookEscrow.NotAuthorized.selector);
        escrow.resolveDispute(escrowId, address(0x999), "Invalid winner");
    }

    // =================================================================
    // PAUSE
    // =================================================================

    function test_Pause() public {
        vm.prank(owner);
        escrow.pause();

        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        vm.expectRevert();
        escrow.createEscrow(seller, 100 * 10**6, keccak256("job"), 65);
        vm.stopPrank();
    }

    function test_PauseBlocksChallenge() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(owner);
        escrow.pause();

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        vm.expectRevert();
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();
    }

    // =================================================================
    // PROTOCOL FEE
    // =================================================================

    function test_ProtocolFee() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        oracle.updateScores(seller, 80, 80, 80, 0);

        uint256 ownerBefore = usdc.balanceOf(owner); // owner is feeRecipient

        vm.prank(address(oracle));
        escrow.releaseEscrow(escrowId, 70);

        // 0.5% fee = 500000 (0.5 USDC)
        uint256 expectedFee = (100 * 10**6 * 50) / 10000;
        assertEq(usdc.balanceOf(owner) - ownerBefore, expectedFee);
        assertEq(escrow.totalFeesCollected(), expectedFee);
    }

    function test_SetProtocolFee() public {
        vm.prank(owner);
        escrow.setProtocolFee(100); // 1%

        assertEq(escrow.protocolFeeBps(), 100);
    }

    function test_Revert_FeeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(RookEscrow.FeeTooHigh.selector);
        escrow.setProtocolFee(501); // > 5%
    }

    function test_ZeroFee() public {
        vm.prank(owner);
        escrow.setProtocolFee(0);

        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        oracle.updateScores(seller, 80, 80, 80, 0);

        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(address(oracle));
        escrow.releaseEscrow(escrowId, 70);

        assertEq(usdc.balanceOf(seller) - sellerBefore, 100 * 10**6); // Full amount
    }

    // =================================================================
    // TOKEN RESCUE
    // =================================================================

    function test_RescueTokens() public {
        MockUSDC fakeToken = new MockUSDC(1000 * 10**6);
        fakeToken.transfer(address(escrow), 100 * 10**6); // Accidentally sent

        vm.prank(owner);
        escrow.rescueTokens(address(fakeToken), owner, 100 * 10**6);
        assertEq(fakeToken.balanceOf(owner), 100 * 10**6);
    }

    function test_Revert_CannotRescueUSDC() public {
        vm.prank(owner);
        vm.expectRevert(RookEscrow.CannotRescueUSDC.selector);
        escrow.rescueTokens(address(usdc), owner, 100 * 10**6);
    }

    // =================================================================
    // TIMELOCK
    // =================================================================

    function test_TimelockSetOracle() public {
        address newOracle = address(0xBEEF);

        vm.startPrank(owner);
        escrow.scheduleSetOracle(newOracle);

        bytes32 actionId = keccak256(abi.encodePacked("setOracle", newOracle, block.timestamp));

        vm.expectRevert(RookEscrow.TimelockNotReady.selector);
        escrow.executeSetOracle(actionId, newOracle);

        // Advance past timelock delay
        vm.warp(block.timestamp + 2 days + 1);
        escrow.executeSetOracle(actionId, newOracle);

        assertEq(address(escrow.oracle()), newOracle);
        vm.stopPrank();
    }

    // =================================================================
    // PAGINATION
    // =================================================================

    function test_Pagination() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 500 * 10**6);

        for (uint256 i = 0; i < 5; i++) {
            escrow.createEscrow(seller, 100 * 10**6, keccak256(abi.encodePacked("Job", i)), 65);
        }
        vm.stopPrank();

        bytes32[] memory page1 = escrow.getBuyerEscrowsPaginated(buyer, 0, 3);
        assertEq(page1.length, 3);

        bytes32[] memory page2 = escrow.getBuyerEscrowsPaginated(buyer, 3, 3);
        assertEq(page2.length, 2);

        bytes32[] memory empty = escrow.getBuyerEscrowsPaginated(buyer, 10, 3);
        assertEq(empty.length, 0);
    }

    // =================================================================
    // COMPLETION RATE (BASIS POINTS)
    // =================================================================

    function test_CompletionRate_BasisPoints() public {
        // Create 3 escrows, complete 1
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 300 * 10**6);
        bytes32 id1 = escrow.createEscrow(seller, 100 * 10**6, keccak256("J1"), 65);
        escrow.createEscrow(seller, 100 * 10**6, keccak256("J2"), 65);
        escrow.createEscrow(seller, 100 * 10**6, keccak256("J3"), 65);
        vm.stopPrank();

        oracle.updateScores(seller, 80, 80, 80, 0);

        vm.prank(address(oracle));
        escrow.releaseEscrow(id1, 70);

        // 1/3 = 3333 basis points (33.33%)
        assertEq(escrow.getCompletionRate(seller), 3333);
    }

    // =================================================================
    // NEXT CHALLENGE TIME
    // =================================================================

    function test_GetNextChallengeTime() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        // Before any challenge, should return 0 (allowed)
        assertEq(escrow.getNextChallengeTime(challenger), 0);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // After challenge, should return future timestamp
        uint256 nextTime = escrow.getNextChallengeTime(challenger);
        assertGt(nextTime, block.timestamp);

        // After cooldown, should return 0
        vm.warp(block.timestamp + 1 hours + 1);
        assertEq(escrow.getNextChallengeTime(challenger), 0);
    }

    // =================================================================
    // FUZZ TESTS
    // =================================================================

    function testFuzz_CreateEscrow_ValidThreshold(uint256 threshold) public {
        threshold = bound(threshold, 50, 100);

        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 id = escrow.createEscrow(seller, 100 * 10**6, keccak256("Fuzz job"), threshold);
        vm.stopPrank();

        RookEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(e.trustThreshold, threshold);
    }

    function testFuzz_CreateEscrow_ValidAmount(uint256 amount) public {
        amount = bound(amount, 1, 10_000 * 10**6);

        vm.startPrank(buyer);
        usdc.approve(address(escrow), amount);
        bytes32 id = escrow.createEscrow(seller, amount, keccak256("Fuzz"), 65);
        vm.stopPrank();

        RookEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(e.amount, amount);
    }

    function testFuzz_ProtocolFee(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, 500);

        vm.prank(owner);
        escrow.setProtocolFee(feeBps);

        bytes32 escrowId = _createEscrow(1000 * 10**6, 65);
        oracle.updateScores(seller, 80, 80, 80, 0);

        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 feeBefore = usdc.balanceOf(owner);

        vm.prank(address(oracle));
        escrow.releaseEscrow(escrowId, 70);

        uint256 expectedFee = (1000 * 10**6 * feeBps) / 10000;
        if (feeBps > 0) {
            assertEq(usdc.balanceOf(owner) - feeBefore, expectedFee);
        }
        assertEq(usdc.balanceOf(seller) - sellerBefore, 1000 * 10**6 - expectedFee);
    }

    // =================================================================
    // ADDITIONAL TIMELOCK TESTS
    // =================================================================

    function test_TimelockAlreadyExecuted() public {
        address newOracle = address(0xBEEF);

        vm.startPrank(owner);
        escrow.scheduleSetOracle(newOracle);
        bytes32 actionId = keccak256(abi.encodePacked("setOracle", newOracle, block.timestamp));

        vm.warp(block.timestamp + 2 days + 1);
        escrow.executeSetOracle(actionId, newOracle);

        // Try to execute again
        vm.expectRevert(RookEscrow.TimelockAlreadyExecuted.selector);
        escrow.executeSetOracle(actionId, newOracle);
        vm.stopPrank();
    }

    function test_CancelTimelock() public {
        address newOracle = address(0xBEEF);

        vm.startPrank(owner);
        escrow.scheduleSetOracle(newOracle);
        bytes32 actionId = keccak256(abi.encodePacked("setOracle", newOracle, block.timestamp));

        // Cancel the timelock
        escrow.cancelTimelock(actionId);

        // Try to execute after cancel
        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert(RookEscrow.TimelockNotFound.selector);
        escrow.executeSetOracle(actionId, newOracle);
        vm.stopPrank();
    }

    function test_TimelockExecuteWithoutSchedule() public {
        address newOracle = address(0xBEEF);
        bytes32 fakeActionId = keccak256(abi.encodePacked("setOracle", newOracle, block.timestamp));

        vm.prank(owner);
        vm.expectRevert(RookEscrow.TimelockNotFound.selector);
        escrow.executeSetOracle(fakeActionId, newOracle);
    }

    // =================================================================
    // ADDITIONAL PAUSE TESTS
    // =================================================================

    function test_Unpause() public {
        vm.prank(owner);
        escrow.pause();

        // Verify paused
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        vm.expectRevert();
        escrow.createEscrow(seller, 100 * 10**6, keccak256("Job"), 65);
        vm.stopPrank();

        // Unpause
        vm.prank(owner);
        escrow.unpause();

        // Should work now
        vm.startPrank(buyer);
        bytes32 id = escrow.createEscrow(seller, 100 * 10**6, keccak256("Job"), 65);
        assertTrue(id != bytes32(0));
        vm.stopPrank();
    }

    function test_PauseBlocksRelease() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        oracle.updateScores(seller, 80, 80, 80, 0);

        vm.prank(owner);
        escrow.pause();

        vm.prank(address(oracle));
        vm.expectRevert();
        escrow.releaseEscrow(escrowId, 70);
    }

    function test_PauseBlocksRefund() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(owner);
        escrow.pause();

        vm.prank(buyer);
        vm.expectRevert();
        escrow.refundEscrow(escrowId, "Test refund");
    }

    function test_PauseBlocksDispute() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(owner);
        escrow.pause();

        vm.prank(buyer);
        vm.expectRevert();
        escrow.disputeEscrow(escrowId, "Evidence");
    }

    function test_Revert_NonOwnerCannotPause() public {
        vm.prank(buyer);
        vm.expectRevert();
        escrow.pause();
    }

    function test_Revert_NonOwnerCannotUnpause() public {
        vm.prank(owner);
        escrow.pause();

        vm.prank(buyer);
        vm.expectRevert();
        escrow.unpause();
    }

    // =================================================================
    // DISPUTE RESOLUTION TESTS
    // =================================================================

    function test_DisputeResolve_BuyerWins() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(buyer);
        escrow.disputeEscrow(escrowId, "Buyer evidence");

        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(owner);
        escrow.resolveDispute(escrowId, buyer, "Buyer wins");

        uint256 buyerAfter = usdc.balanceOf(buyer);
        assertEq(buyerAfter - buyerBefore, 100 * 10**6);

        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Refunded));
    }

    // =================================================================
    // STAKE SLASHING TESTS
    // =================================================================

    function test_ChallengeSlashing_SellerPasses() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        uint256 challengerBefore = usdc.balanceOf(challenger);
        uint256 sellerBefore = usdc.balanceOf(seller);

        // Oracle resolves - seller passes (vindicated)
        vm.prank(address(oracle));
        escrow.resolveChallenge(escrowId, true);

        uint256 challengerAfter = usdc.balanceOf(challenger);
        uint256 sellerAfter = usdc.balanceOf(seller);

        // Challenger gets 50% back (2.5 USDC)
        uint256 expectedReturn = (5 * 10**6 * 50) / 100;
        assertEq(challengerAfter - challengerBefore, expectedReturn);

        // Seller gets 50% as reward (2.5 USDC)
        uint256 expectedReward = 5 * 10**6 - expectedReturn;
        assertEq(sellerAfter - sellerBefore, expectedReward);
    }

    function test_ChallengeNoSlashing_SellerFails() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        uint256 challengerBefore = usdc.balanceOf(challenger);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        // Oracle resolves - seller fails
        vm.prank(address(oracle));
        escrow.resolveChallenge(escrowId, false);

        uint256 challengerAfter = usdc.balanceOf(challenger);
        uint256 buyerAfter = usdc.balanceOf(buyer);

        // Challenger gets full stake back (no slashing)
        assertEq(challengerAfter - challengerBefore, 5 * 10**6);

        // Buyer gets refund
        assertEq(buyerAfter - buyerBefore, 100 * 10**6);
    }

    // =================================================================
    // DISPUTE TIMELOCK TESTS
    // =================================================================

    function test_DisputeTimelock_HighValue() public {
        // Create high-value escrow (> 10,000 USDC)
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 15_000 * 10**6);

        // Need more funds
        vm.stopPrank();
        usdc.transfer(buyer, 15_000 * 10**6);
        vm.startPrank(buyer);

        usdc.approve(address(escrow), 15_000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 15_000 * 10**6, keccak256("High value job"), 65);
        vm.stopPrank();

        // Dispute
        vm.prank(buyer);
        escrow.disputeEscrow(escrowId, "Dispute evidence");

        // Resolve - should be timelocked
        vm.prank(owner);
        escrow.resolveDispute(escrowId, seller, "Seller wins");

        // Verify pending resolution exists
        (address winner, , uint256 executeAfter, bool executed) = escrow.pendingDisputeResolutions(escrowId);
        assertEq(winner, seller);
        assertGt(executeAfter, block.timestamp);
        assertFalse(executed);

        // Should not be executable yet
        vm.prank(owner);
        vm.expectRevert(RookEscrow.DisputeResolutionNotReady.selector);
        escrow.executeDisputeResolution(escrowId);

        // Advance time
        vm.warp(executeAfter + 1);

        uint256 sellerBefore = usdc.balanceOf(seller);

        // Now execute
        vm.prank(owner);
        escrow.executeDisputeResolution(escrowId);

        uint256 sellerAfter = usdc.balanceOf(seller);
        assertEq(sellerAfter - sellerBefore, 15_000 * 10**6);
    }

    function test_DisputeTimelock_LowValue_Immediate() public {
        // Create low-value escrow (< 10,000 USDC)
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(buyer);
        escrow.disputeEscrow(escrowId, "Dispute evidence");

        uint256 sellerBefore = usdc.balanceOf(seller);

        // Resolve - should execute immediately (no timelock)
        vm.prank(owner);
        escrow.resolveDispute(escrowId, seller, "Seller wins");

        uint256 sellerAfter = usdc.balanceOf(seller);
        assertEq(sellerAfter - sellerBefore, 100 * 10**6);
    }

    function test_CancelDisputeResolution() public {
        // Create high-value escrow
        vm.stopPrank();
        usdc.transfer(buyer, 15_000 * 10**6);

        vm.startPrank(buyer);
        usdc.approve(address(escrow), 15_000 * 10**6);
        bytes32 escrowId = escrow.createEscrow(seller, 15_000 * 10**6, keccak256("High value"), 65);
        escrow.disputeEscrow(escrowId, "Evidence");
        vm.stopPrank();

        // Schedule resolution
        vm.prank(owner);
        escrow.resolveDispute(escrowId, seller, "Seller wins");

        // Cancel
        vm.prank(owner);
        escrow.cancelDisputeResolution(escrowId);

        // Verify cancelled
        vm.prank(owner);
        vm.expectRevert(RookEscrow.DisputeResolutionNotFound.selector);
        escrow.executeDisputeResolution(escrowId);
    }

    // =================================================================
    // EDGE CASE TESTS
    // =================================================================

    function test_Revert_RefundThenDispute() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        // Refund first
        vm.prank(buyer);
        escrow.refundEscrow(escrowId, "Refunding");

        // Try to dispute after refund
        vm.prank(buyer);
        vm.expectRevert(RookEscrow.EscrowNotActive.selector);
        escrow.disputeEscrow(escrowId, "Evidence");
    }

    function test_Revert_ChallengeThenRefund() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        // Challenge first
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Try to refund while challenged
        vm.prank(buyer);
        vm.expectRevert(RookEscrow.EscrowNotActive.selector);
        escrow.refundEscrow(escrowId, "Refunding");
    }

    function test_Revert_DisputeThenChallenge() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        // Dispute first
        vm.prank(buyer);
        escrow.disputeEscrow(escrowId, "Evidence");

        // Try to challenge after dispute
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        vm.expectRevert(RookEscrow.EscrowNotActive.selector);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();
    }

    function test_Revert_DoubleRefund() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(buyer);
        escrow.refundEscrow(escrowId, "First refund");

        vm.prank(buyer);
        vm.expectRevert(RookEscrow.EscrowNotActive.selector);
        escrow.refundEscrow(escrowId, "Second refund");
    }

    function test_Revert_DoubleDispute() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(buyer);
        escrow.disputeEscrow(escrowId, "First dispute");

        vm.prank(buyer);
        vm.expectRevert(RookEscrow.EscrowNotActive.selector);
        escrow.disputeEscrow(escrowId, "Second dispute");
    }

    // =================================================================
    // HELPERS
    // =================================================================

    function _createEscrow(uint256 amount, uint256 threshold) internal returns (bytes32) {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), amount);
        bytes32 id = escrow.createEscrow(seller, amount, keccak256("Test job"), threshold);
        vm.stopPrank();
        return id;
    }
}
