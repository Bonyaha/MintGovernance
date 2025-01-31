// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./MyGovernorBase.sol";

contract MyGovernorTreasury is MyGovernorBase {
    // Treasury Management Events
    event TreasuryWithdrawal(address indexed to, uint256 amount, string reason);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event EmergencyPauseSet(bool isPaused);
    event TreasuryBalanceUpdated(uint256 newBalance);

    // Constructor to pass required parameters to base contract
    constructor(
        IVotes _token,
        TimelockController _timelock
    ) MyGovernorBase(_token, _timelock) {}

    // Override receive function with override specifier
    receive() external payable override {
        treasuryState.balance += uint128(msg.value);
        emit TreasuryDeposit(msg.sender, msg.value);
        emit TreasuryBalanceUpdated(treasuryState.balance);
    }

    // Withdraw funds from treasury
    function withdrawTreasury(
        address payable to,
        uint256 amount,
        string calldata reason
    ) external onlyRole(TREASURER_ROLE) nonReentrant {
        require(!treasuryState.emergencyPaused, "Treasury is paused");
        if (amount > treasuryState.balance) revert InsufficientBalance();
        require(
            treasuryState.balance - amount >=
                treasuryState.emergencyMinimumBalance,
            "Must maintain minimum balance"
        );

        treasuryState.balance -= uint128(amount);
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");

        emit TreasuryWithdrawal(to, amount, reason);
    }

    // Set emergency pause on treasury
    function setEmergencyPause(bool paused) external onlyRole(ADMIN_ROLE) {
        treasuryState.emergencyPaused = paused;
        emit EmergencyPauseSet(paused);
    }

    // Delegation tracking methods
    function delegateWithTracking(address newDelegate) external {
        address oldDelegate = IVotes(token()).delegates(msg.sender);

        // Update delegation history
        delegationHistory[msg.sender].push(newDelegate);
        lastDelegationTimestamp[msg.sender] = block.timestamp;

        // Perform actual delegation
        IVotes(token()).delegate(newDelegate);

        emit DelegationChanged(msg.sender, oldDelegate, newDelegate);
    }

    function getDelegationHistory(
        address account
    ) external view returns (address[] memory) {
        return delegationHistory[account];
    }

    // Dynamic Quorum Methods
    function setQuorumParameters(
        uint256 newBaseQuorum,
        uint256 newParticipationMultiplier
    ) external override onlyRole(ADMIN_ROLE) {
        require(newBaseQuorum <= 10000, "Base quorum cannot exceed 100%");
        baseQuorum = newBaseQuorum;
        participationMultiplier = newParticipationMultiplier;
        emit QuorumParamsUpdated(newBaseQuorum, newParticipationMultiplier);
    }

    function calculateDynamicQuorum(
        uint256 blockNumber
    ) public view override returns (uint256) {
        uint256 baseQuorumVotes = (token().getPastTotalSupply(blockNumber) *
            baseQuorum) / 10000;
        uint256 participation = _countParticipation(blockNumber);
        return
            baseQuorumVotes + ((participation * participationMultiplier) / 100);
    }

    // Override _countParticipation with override specifier
    function _countParticipation(
        uint256 blockNumber
    ) internal view override returns (uint256) {
        // Simplified participation counting
        return token().getPastTotalSupply(blockNumber) / 2;
    }

    // Add Proposal Reviewer method
    function addProposalReviewer(
        address reviewer
    ) external override onlyRole(ADMIN_ROLE) {
        _grantRole(PROPOSAL_REVIEWER_ROLE, reviewer);
    }
}