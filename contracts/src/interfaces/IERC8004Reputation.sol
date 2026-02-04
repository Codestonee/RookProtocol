// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC8004Reputation {
    function getReputation(address agent) external view returns (uint256);
    function getFeedbackCount(address agent) external view returns (uint256);
    function getAverageRating(address agent) external view returns (uint256);
}
