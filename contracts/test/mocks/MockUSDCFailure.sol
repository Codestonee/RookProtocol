// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./MockUSDC.sol";

/**
 * @title MockUSDCFailure
 * @notice PR#2: Mock USDC that can simulate transfer failures
 * @dev Used for testing transfer failure paths in escrow contract
 */
contract MockUSDCFailure is MockUSDC {
    bool public shouldFailTransfer;
    bool public shouldFailTransferFrom;

    constructor(uint256 initialSupply) MockUSDC(initialSupply) {}

    /**
     * @notice Enable/disable transfer failures
     * @param _fail Whether transfers should fail
     */
    function setShouldFailTransfer(bool _fail) external {
        shouldFailTransfer = _fail;
    }

    /**
     * @notice Enable/disable transferFrom failures
     * @param _fail Whether transferFrom should fail
     */
    function setShouldFailTransferFrom(bool _fail) external {
        shouldFailTransferFrom = _fail;
    }

    /**
     * @notice Override transfer to optionally return false
     * @dev Returns false instead of reverting to test transfer failure handling
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (shouldFailTransfer) {
            return false;
        }
        return super.transfer(to, amount);
    }

    /**
     * @notice Override transferFrom to optionally return false
     * @dev Returns false instead of reverting to test transferFrom failure handling
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (shouldFailTransferFrom) {
            return false;
        }
        return super.transferFrom(from, to, amount);
    }
}
