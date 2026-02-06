// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/RookEscrow.sol";
import "../src/RookOracle.sol";
import "./mocks/MockUSDCFailure.sol";

/**
 * @title RookEscrowTransferFailureTest
 * @notice Tests for ERC20 transfer failure paths using MockUSDCFailure
 */
contract RookEscrowTransferFailureTest is Test {
    RookEscrow public escrow;
    RookOracle public oracle;
    MockUSDCFailure public usdc;

    address public owner = address(1);
    address public buyer = address(2);
    address public seller = address(3);
    address public challenger = address(4);

    function setUp() public {
        usdc = new MockUSDCFailure(1_000_000 * 10**6);

        vm.startPrank(owner);
        oracle = new RookOracle(address(0));
        escrow = new RookEscrow(address(usdc), address(oracle));
        oracle.setEscrow(address(escrow));
        oracle.setOperator(address(this), true);
        vm.stopPrank();

        usdc.transfer(buyer, 10_000 * 10**6);
        usdc.transfer(challenger, 1_000 * 10**6);
    }

    /**
     * @notice Test transfer failure on escrow creation (transferFrom fails)
     */
    function test_Revert_CreateEscrow_TransferFromFails() public {
        usdc.setShouldFailTransferFrom(true);

        vm.startPrank(buyer);
        usdc.approve(address(escrow), 100 * 10**6);
        vm.expectRevert(RookEscrow.TransferFailed.selector);
        escrow.createEscrow(seller, 100 * 10**6, keccak256("job"), 65);
        vm.stopPrank();
    }

    /**
     * @notice Test transfer failure on release
     */
    function test_Revert_ReleaseEscrow_TransferFails() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);
        oracle.updateScores(seller, 90, 90, 90, 0);

        // Enable transfer failure AFTER creation
        usdc.setShouldFailTransfer(true);

        vm.prank(address(oracle));
        vm.expectRevert(RookEscrow.TransferFailed.selector);
        escrow.releaseEscrow(escrowId, 70);

        // Verify state was NOT changed (revert rolled back everything)
        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Active));
    }

    /**
     * @notice Test transfer failure on refund
     */
    function test_Revert_RefundEscrow_TransferFails() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        usdc.setShouldFailTransfer(true);

        vm.prank(buyer);
        vm.expectRevert(RookEscrow.TransferFailed.selector);
        escrow.refundEscrow(escrowId, "Refund reason");

        // Verify state unchanged
        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Active));
    }

    /**
     * @notice Test transferFrom failure on challenge initiation
     */
    function test_Revert_InitiateChallenge_TransferFromFails() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        usdc.setShouldFailTransferFrom(true);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        vm.expectRevert(RookEscrow.TransferFailed.selector);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        // Verify escrow is still Active, not Challenged
        RookEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(RookEscrow.EscrowStatus.Active));
    }

    /**
     * @notice Test transfer failure on challenge resolution (pass - stake return)
     */
    function test_Revert_ResolveChallenge_Pass_TransferFails() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.prank(seller);
        escrow.respondChallenge(escrowId, keccak256("response"));

        usdc.setShouldFailTransfer(true);

        vm.prank(address(oracle));
        vm.expectRevert(RookEscrow.TransferFailed.selector);
        escrow.resolveChallenge(escrowId, true);
    }

    /**
     * @notice Test transfer failure on challenge timeout claim
     */
    function test_Revert_ClaimTimeout_TransferFails() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.startPrank(challenger);
        usdc.approve(address(escrow), 5 * 10**6);
        escrow.initiateChallenge(escrowId);
        vm.stopPrank();

        vm.roll(block.number + 51);

        usdc.setShouldFailTransfer(true);

        vm.prank(challenger);
        vm.expectRevert(RookEscrow.TransferFailed.selector);
        escrow.claimChallengeTimeout(escrowId);
    }

    /**
     * @notice Test transfer failure on dispute resolution
     */
    function test_Revert_ResolveDispute_TransferFails() public {
        bytes32 escrowId = _createEscrow(100 * 10**6, 65);

        vm.prank(buyer);
        escrow.disputeEscrow(escrowId, "evidence");

        usdc.setShouldFailTransfer(true);

        vm.prank(owner);
        vm.expectRevert(RookEscrow.TransferFailed.selector);
        escrow.resolveDispute(escrowId, seller, "Seller wins");
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
