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
        vm.startPrank(owner);
        
        // Deploy USDC mock with 1M supply
        usdc = new MockUSDC(1_000_000 * 10**6);
        
        // Deploy oracle first (needed for escrow)
        oracle = new RookOracle(address(0));
        
        // Deploy escrow
        escrow = new RookEscrow(address(usdc), address(oracle));
        
        // Set escrow in oracle
        oracle.setEscrow(address(escrow));
        
        // Set oracle as operator
        oracle.setOperator(address(this), true);
        
        vm.stopPrank();
        
        // Fund accounts
        usdc.transfer(buyer, 10_000 * 10**6);
        usdc.transfer(challenger, 1_000 * 10**6);
    }
    
    function test_CreateEscrow() public {
        vm.startPrank(buyer);
        
        uint256 amount = 100 * 10**6; // 100 USDC
        bytes32 jobHash = keccak256("Test job");
        uint256 threshold = 65;
        
        usdc.approve(address(escrow), amount);
        
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, threshold);
        
        assertTrue(escrowId != bytes32(0));
        
        (address eBuyer, address eSeller, uint256 eAmount,, uint256 eThreshold,,, uint8 status) = 
            escrow.escrows(escrowId);
        
        assertEq(eBuyer, buyer);
        assertEq(eSeller, seller);
        assertEq(eAmount, amount);
        assertEq(eThreshold, threshold);
        assertEq(status, uint8(RookEscrow.EscrowStatus.Active));
        
        vm.stopPrank();
    }
    
    function test_ReleaseEscrow() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();
        
        // Update seller scores
        oracle.updateScores(seller, 80, 80, 80, 0);
        
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        
        // Release via oracle
        escrow.releaseEscrow(escrowId, 70);
        
        uint256 sellerBalanceAfter = usdc.balanceOf(seller);
        assertEq(sellerBalanceAfter - sellerBalanceBefore, amount);
        
        (,,,,,,, uint8 status) = escrow.escrows(escrowId);
        assertEq(status, uint8(RookEscrow.EscrowStatus.Released));
    }
    
    function test_ReleaseWithConsent() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();
        
        // Fast forward past oracle timeout
        vm.warp(block.timestamp + 2 days);
        
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        
        // Release with consent (buyer triggers)
        vm.prank(buyer);
        escrow.releaseWithConsent(escrowId);
        
        uint256 sellerBalanceAfter = usdc.balanceOf(seller);
        assertEq(sellerBalanceAfter - sellerBalanceBefore, amount);
        
        (,,,,,,, uint8 status) = escrow.escrows(escrowId);
        assertEq(status, uint8(RookEscrow.EscrowStatus.Released));
    }
    
    function test_RefundEscrow() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        
        escrow.refundEscrow(escrowId, "Changed my mind");
        
        uint256 buyerBalanceAfter = usdc.balanceOf(buyer);
        assertEq(buyerBalanceAfter - buyerBalanceBefore, amount);
        
        (,,,,,,, uint8 status) = escrow.escrows(escrowId);
        assertEq(status, uint8(RookEscrow.EscrowStatus.Refunded));
        
        vm.stopPrank();
    }
    
    function test_Revert_SellerCannotRefund() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();
        
        // Seller tries to refund (should fail)
        vm.prank(seller);
        vm.expectRevert(RookEscrow.NotBuyer.selector);
        escrow.refundEscrow(escrowId, "Seller refund");
    }
    
    function test_ChallengeFlow_SellerPasses() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();
        
        // Initiate challenge
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();
        
        (,,,,,,, uint8 status) = escrow.escrows(escrowId);
        assertEq(status, uint8(RookEscrow.EscrowStatus.Challenged));
        
        // Seller responds
        vm.prank(seller);
        escrow.respondChallenge(escrowId, keccak256("I am real"));
        
        // Resolve challenge (seller passes)
        uint256 challengerBalanceBefore = usdc.balanceOf(challenger);
        escrow.resolveChallenge(escrowId, true);
        
        // Challenger gets stake back (not 2x)
        uint256 challengerBalanceAfter = usdc.balanceOf(challenger);
        assertEq(challengerBalanceAfter - challengerBalanceBefore, 5 * 10**6);
        
        // Escrow back to active
        (,,,,,,, uint8 finalStatus) = escrow.escrows(escrowId);
        assertEq(finalStatus, uint8(RookEscrow.EscrowStatus.Active));
    }
    
    function test_ChallengeFlow_SellerFails() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();
        
        // Initiate challenge
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();
        
        // Resolve challenge (seller fails) - no response
        uint256 challengerBalanceBefore = usdc.balanceOf(challenger);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        
        escrow.resolveChallenge(escrowId, false);
        
        // Challenger gets stake back (not 2x)
        assertEq(usdc.balanceOf(challenger) - challengerBalanceBefore, 5 * 10**6);
        // Buyer gets refund
        assertEq(usdc.balanceOf(buyer) - buyerBalanceBefore, amount);
        
        (,,,,,,, uint8 status) = escrow.escrows(escrowId);
        assertEq(status, uint8(RookEscrow.EscrowStatus.Refunded));
    }
    
    function test_ChallengeTimeout() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();
        
        // Initiate challenge
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();
        
        // Fast forward past deadline
        vm.roll(block.number + 51);
        
        uint256 challengerBalanceBefore = usdc.balanceOf(challenger);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        
        // Claim timeout
        escrow.claimChallengeTimeout(escrowId);
        
        // Challenger gets stake back (not 2x)
        assertEq(usdc.balanceOf(challenger) - challengerBalanceBefore, 5 * 10**6);
        // Buyer gets refund
        assertEq(usdc.balanceOf(buyer) - buyerBalanceBefore, amount);
    }
    
    function test_Revert_SelfChallenge() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();
        
        // Seller tries to challenge themselves
        vm.startPrank(seller);
        usdc.approve(address(escrow), 5 * 10**6);
        vm.expectRevert(RookEscrow.SelfChallenge.selector);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();
    }
    
    function test_DisputeAndResolve() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();
        
        // File dispute
        vm.prank(buyer);
        escrow.disputeEscrow(escrowId, "ipfs://Qm...");
        
        (,,,,,,, uint8 status) = escrow.escrows(escrowId);
        assertEq(status, uint8(RookEscrow.EscrowStatus.Disputed));
        
        // Resolve dispute (owner only) - seller wins
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        vm.prank(owner);
        escrow.resolveDispute(escrowId, seller, "Seller delivered");
        
        uint256 sellerBalanceAfter = usdc.balanceOf(seller);
        assertEq(sellerBalanceAfter - sellerBalanceBefore, amount);
        
        (,,,,,,, uint8 finalStatus) = escrow.escrows(escrowId);
        assertEq(finalStatus, uint8(RookEscrow.EscrowStatus.Released));
    }
    
    function test_Pause() public {
        vm.prank(owner);
        escrow.pause();
        
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        
        vm.expectRevert();
        escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();
    }
    
    function test_Revert_InvalidAmount() public {
        vm.startPrank(buyer);
        bytes32 jobHash = keccak256("Test job");
        
        vm.expectRevert(RookEscrow.InvalidAmount.selector);
        escrow.createEscrow(seller, 0, jobHash, 65);
        
        vm.stopPrank();
    }
    
    function test_Revert_InvalidThreshold() public {
        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        bytes32 jobHash = keccak256("Test job");
        
        vm.expectRevert(RookEscrow.InvalidThreshold.selector);
        escrow.createEscrow(seller, 100 * 10**6, jobHash, 40);
        
        vm.stopPrank();
    }
    
    function test_Revert_BelowThreshold() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();
        
        // Try to release with score below threshold
        vm.expectRevert(RookEscrow.BelowThreshold.selector);
        escrow.releaseEscrow(escrowId, 60);
    }

    // ═══════════════════════════════════════════════════════════════
    // PR#2: SECURITY & EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Revert_ReleaseEscrow_NotOracle() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();

        // Non-oracle tries to release
        vm.prank(address(0x999));
        vm.expectRevert(RookEscrow.NotOracle.selector);
        escrow.releaseEscrow(escrowId, 70);
    }

    function test_Revert_OracleTimeoutNotMet() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();

        // Try to release with consent before timeout (should fail)
        vm.prank(buyer);
        vm.expectRevert(RookEscrow.OracleTimeoutNotMet.selector);
        escrow.releaseWithConsent(escrowId);
    }

    function test_Revert_ChallengeCooldownActive() public {
        // Create two escrows
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash1 = keccak256("Job 1");
        bytes32 jobHash2 = keccak256("Job 2");
        usdc.approve(address(escrow), amount * 2);
        bytes32 escrowId1 = escrow.createEscrow(seller, amount, jobHash1, 65);
        bytes32 escrowId2 = escrow.createEscrow(seller, amount, jobHash2, 65);
        vm.stopPrank();

        // Challenge first escrow
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 10 * 10**6);
        escrow.initiateChallenge(escrowId1);

        // Try to challenge second escrow immediately (should fail due to cooldown)
        vm.expectRevert(RookEscrow.ChallengeCooldownActive.selector);
        escrow.initiateChallenge(escrowId2);
        vm.stopPrank();
    }

    function test_Revert_RespondAfterDeadline() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();

        // Initiate challenge
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Fast forward past deadline
        vm.roll(block.number + 51);

        // Seller tries to respond after deadline (should fail)
        vm.prank(seller);
        vm.expectRevert(RookEscrow.ChallengeExpired.selector);
        escrow.respondChallenge(escrowId, keccak256("Late response"));
    }

    function test_Revert_ResolveAfterDeadline() public {
        // Create escrow and challenge
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Fast forward past deadline
        vm.roll(block.number + 51);

        // Oracle tries to resolve after deadline (should fail)
        vm.expectRevert(RookEscrow.ChallengeExpired.selector);
        escrow.resolveChallenge(escrowId, true);
    }

    function test_Revert_NonPartyDispute() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();

        // Random address tries to dispute (should fail)
        vm.prank(address(0x999));
        vm.expectRevert(RookEscrow.NotAuthorized.selector);
        escrow.disputeEscrow(escrowId, "Not my business");
    }

    function test_Revert_DoubleReleaseFinalization() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();

        // Release once
        oracle.updateScores(seller, 80, 80, 80, 0);
        escrow.releaseEscrow(escrowId, 70);

        // Try to release again (should fail)
        vm.expectRevert(RookEscrow.EscrowNotActive.selector);
        escrow.releaseEscrow(escrowId, 70);
    }

    function test_Revert_ResponseWindowExpired() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();

        // Initiate challenge
        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Fast forward past response window (block 26) but before deadline (block 50)
        vm.roll(block.number + 26);

        // Seller tries to respond after response window (should fail per PR#1)
        vm.prank(seller);
        vm.expectRevert(RookEscrow.ChallengeResponseWindowExpired.selector);
        escrow.respondChallenge(escrowId, keccak256("Too late"));
    }

    function test_Revert_NonChallengerClaimTimeout() public {
        // Create escrow and challenge
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Fast forward past deadline
        vm.roll(block.number + 51);

        // Random address tries to claim timeout (should fail per PR#1)
        vm.prank(address(0x999));
        vm.expectRevert(RookEscrow.NotChallenger.selector);
        escrow.claimChallengeTimeout(escrowId);
    }

    function test_Revert_EvidenceTooLong() public {
        // Create escrow
        vm.startPrank(buyer);
        uint256 amount = 100 * 10**6;
        bytes32 jobHash = keccak256("Test job");
        usdc.approve(address(escrow), amount);
        bytes32 escrowId = escrow.createEscrow(seller, amount, jobHash, 65);
        vm.stopPrank();

        // Create evidence string longer than 1000 bytes
        // Use a string that's exactly 1001 characters
        string memory longEvidence = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

        vm.prank(buyer);
        vm.expectRevert(RookEscrow.EvidenceTooLong.selector);
        escrow.disputeEscrow(escrowId, longEvidence);
    }
}
