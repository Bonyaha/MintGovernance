// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

contract MyToken is ERC20, ERC20Permit, ERC20Votes {
    address public governor;
    
    // Token distribution features
    mapping(address => uint256) public lastClaimTimestamp;
    uint256 public constant CLAIM_AMOUNT = 100 * 10**18; // 100 tokens
    uint256 public constant CLAIM_INTERVAL = 24 hours;

    constructor(address initialGovernor) 
        ERC20("MyToken", "MTK") 
        ERC20Permit("MyToken") 
    {
        governor = initialGovernor;
        _mint(msg.sender, 10000e18);
    }

    function mint(address to, uint256 amount) external {
        require(governor == msg.sender, "Only governor can mint");
        _mint(to, amount);
    }

    function claimTokens() external {
        require(
            block.timestamp >= lastClaimTimestamp[msg.sender] + CLAIM_INTERVAL, 
            "Wait for claim interval"
        );
        lastClaimTimestamp[msg.sender] = block.timestamp;
        _mint(msg.sender, CLAIM_AMOUNT);
    }

    function getVotingPower(address account) external view returns (uint256) {
        return getVotes(account);
    }

    // The functions below are overrides required by Solidity.
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, amount);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    function setGovernor(address _governor) external {
        require(governor == address(0), "Governor already set");
        governor = _governor;
    }
}