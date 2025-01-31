// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MyGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    AccessControl,
    ReentrancyGuard
{
    // Custom errors save gas and bytecode compared to require statements
    error InvalidCategory();
    error InsufficientBalance();
    error BudgetExceeded();
    error AlreadyApproved();
    error OwnProposalApproval();
    error NotFound();
    error MinimumBalanceRequired();
    error TransferFailed();
    error InvalidQuorum();

    bytes32 public constant PROPOSAL_REVIEWER_ROLE = keccak256("PROPOSAL_REVIEWER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    // Consolidated treasury state to save storage slots
    struct TreasuryState {
        uint128 balance;
        uint128 emergencyMinimumBalance;
        bool emergencyPaused;
    }
    TreasuryState public treasuryState;

    // Simplified proposal metadata
    struct ProposalMetadata {
        address proposer;
        uint40 timestamp;
        uint96 votesFor;
        uint96 votesAgainst;
        uint96 votesAbstain;
        bool isActive;
        string category;
    }

    mapping(uint256 => ProposalMetadata) public proposalMetadata;
    mapping(uint256 => bool) public approvedProposals;
    mapping(uint256 => uint256) public proposalBudgets;
    mapping(string => bool) public isValidCategory;
    mapping(address => uint256) public lastDelegationTimestamp;

    uint256 public baseQuorum;
    uint256 public participationMultiplier;
    uint256 public totalProposals;

    event ProposalApproved(uint256 indexed proposalId, address indexed reviewer);
    event ProposalRejected(uint256 indexed proposalId, address indexed reviewer);
    event TreasuryWithdrawal(address indexed to, uint256 amount);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event EmergencyPauseSet(bool isPaused);
    event QuorumParamsUpdated(uint256 baseQuorum, uint256 participationMultiplier);

    constructor(IVotes _token, TimelockController _timelock)
        Governor("MyGovernor")
        GovernorSettings(1, 1, 0)
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4)
        GovernorTimelockControl(_timelock)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(TREASURER_ROLE, msg.sender);
        
        baseQuorum = 1000; // 10%
        participationMultiplier = 100;
        treasuryState.emergencyMinimumBalance = 1 ether;

        // Initialize default categories
        isValidCategory["General"] = true;
        isValidCategory["Treasury"] = true;
        isValidCategory["Protocol"] = true;
        isValidCategory["Community"] = true;
    }

    receive() external payable override {
        treasuryState.balance += uint128(msg.value);
        emit TreasuryDeposit(msg.sender, msg.value);
    }

    function withdrawTreasury(address payable to, uint256 amount) external onlyRole(TREASURER_ROLE) nonReentrant {
        if (treasuryState.emergencyPaused) revert("Treasury paused");
        if (amount > treasuryState.balance) revert InsufficientBalance();
        if (treasuryState.balance - amount < treasuryState.emergencyMinimumBalance) revert MinimumBalanceRequired();

        treasuryState.balance -= uint128(amount);
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit TreasuryWithdrawal(to, amount);
    }

    function submitProposal(
        string calldata category,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        uint256 budget
    ) external {
        if (!isValidCategory[category]) revert InvalidCategory();
        if (budget > treasuryState.balance) revert BudgetExceeded();

        uint256 proposalId = hashProposal(targets, values, calldatas, keccak256(bytes(description)));

        proposalMetadata[proposalId] = ProposalMetadata({
            proposer: msg.sender,
            timestamp: uint40(block.timestamp),
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            isActive: true,
            category: category
        });

        proposalBudgets[proposalId] = budget;
        totalProposals++;
    }

    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        bytes memory params
    ) internal virtual override(Governor, GovernorCountingSimple) returns (uint256) {
        uint256 result = super._countVote(proposalId, account, support, weight, params);

        ProposalMetadata storage metadata = proposalMetadata[proposalId];
        if (support == 0) {
            metadata.votesAgainst = uint96(uint256(metadata.votesAgainst) + weight);
        } else if (support == 1) {
            metadata.votesFor = uint96(uint256(metadata.votesFor) + weight);
        } else if (support == 2) {
            metadata.votesAbstain = uint96(uint256(metadata.votesAbstain) + weight);
        }

        return result;
    }

    // Required overrides (minimized)
    function quorum(uint256 blockNumber) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return (token().getPastTotalSupply(blockNumber) * baseQuorum) / 10000;
    }

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
 function proposalNeedsQueuing(
        uint256 proposalId
    ) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(Governor, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}