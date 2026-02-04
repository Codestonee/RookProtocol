// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC8004Identity {
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getIdentity(address agent) external view returns (bytes memory);
    function isRegistered(address agent) external view returns (bool);
}
