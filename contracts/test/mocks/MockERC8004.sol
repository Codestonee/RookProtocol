// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockERC8004Identity is ERC721 {
    mapping(address => uint256) private _identities;
    mapping(uint256 => bytes) private _metadata;
    uint256 private _tokenIdCounter;
    
    constructor() ERC721("ERC-8004 Identity", "AGENT") {}
    
    function register(address agent, bytes calldata metadata) external returns (uint256) {
        require(_identities[agent] == 0, "Already registered");
        
        _tokenIdCounter++;
        uint256 tokenId = _tokenIdCounter;
        
        _identities[agent] = tokenId;
        _metadata[tokenId] = metadata;
        _mint(agent, tokenId);
        
        return tokenId;
    }
    
    function isRegistered(address agent) external view returns (bool) {
        return _identities[agent] != 0;
    }
    
    function getIdentity(address agent) external view returns (bytes memory) {
        uint256 tokenId = _identities[agent];
        require(tokenId != 0, "Not registered");
        return _metadata[tokenId];
    }
}

contract MockERC8004Reputation {
    mapping(address => uint256) private _reputation;
    mapping(address => uint256) private _feedbackCount;
    mapping(address => uint256) private _totalRating;
    
    function addFeedback(address agent, uint256 rating) external {
        require(rating <= 5, "Rating 0-5");
        _feedbackCount[agent]++;
        _totalRating[agent] += rating;
        _reputation[agent] = (_totalRating[agent] * 100) / (_feedbackCount[agent] * 5);
    }
    
    function getReputation(address agent) external view returns (uint256) {
        return _reputation[agent];
    }
    
    function getFeedbackCount(address agent) external view returns (uint256) {
        return _feedbackCount[agent];
    }
    
    function getAverageRating(address agent) external view returns (uint256) {
        if (_feedbackCount[agent] == 0) return 0;
        return _totalRating[agent] / _feedbackCount[agent];
    }
}
