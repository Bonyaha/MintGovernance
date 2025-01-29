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
    bytes32 public constant PROPOSAL_REVIEWER_ROLE =
        keccak256("PROPOSAL_REVIEWER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    // Treasury state
    uint256 public treasuryBalance;
    uint256 public emergencyMinimumBalance;
    bool public emergencyPaused;

    // Enhanced delegation tracking
    mapping(address => address[]) public delegationHistory;
    mapping(address => uint256) public lastDelegationTimestamp;

    // Dynamic quorum settings
    uint256 public baseQuorum; // Base quorum percentage (in basis points, e.g., 1000 = 10%)
    uint256 public participationMultiplier; // Multiplier for participation rate

    // Enhanced proposal tracking
    struct ProposalMetadata {
        string title;
        string description;
        address proposer;
        uint256 timestamp;
        string status;
    }

    mapping(uint256 => ProposalMetadata) public proposalMetadata;
    mapping(uint256 => bool) public approvedProposals;
    mapping(uint256 => ProposalDetails) public proposalsAwaitingReview;
    mapping(uint256 => uint256) public proposalBudgets;
    uint256 public totalProposals;

    struct ProposalDetails {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
        address proposer;
        uint256 budget;
        bool exists;
    }

    // Events
    event ProposalApproved(
        uint256 indexed proposalId,
        address indexed reviewer
    );
    event ProposalRejected(
        uint256 indexed proposalId,
        address indexed reviewer
    );
    event ProposalSubmittedForReview(
        uint256 indexed proposalId,
        address indexed proposer
    );
    event DelegationChanged(
        address indexed delegator,
        address indexed fromDelegate,
        address indexed toDelegate
    );
    event TreasuryWithdrawal(address indexed to, uint256 amount, string reason);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event EmergencyPauseSet(bool isPaused);
    event QuorumParamsUpdated(
        uint256 baseQuorum,
        uint256 participationMultiplier
    );

    constructor(
        IVotes _token,
        TimelockController _timelock
    )
        Governor("MyGovernor")
        GovernorSettings(1, 1, 0)
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4)
        GovernorTimelockControl(_timelock)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(TREASURER_ROLE, msg.sender);
        _setRoleAdmin(PROPOSAL_REVIEWER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(TREASURER_ROLE, ADMIN_ROLE);

        baseQuorum = 1000; // 10% base quorum
        participationMultiplier = 100; // 1x multiplier
        emergencyMinimumBalance = 1 ether; // Set default emergency minimum
    }

    function addProposalReviewer(
        address reviewer
    ) external onlyRole(ADMIN_ROLE) {
        _grantRole(PROPOSAL_REVIEWER_ROLE, reviewer);
    }

    // Treasury Management Functions
    receive() external payable override {
        treasuryBalance += msg.value;
        emit TreasuryDeposit(msg.sender, msg.value);
    }

    function withdrawTreasury(
        address payable to,
        uint256 amount,
        string memory reason
    ) external onlyRole(TREASURER_ROLE) nonReentrant {
        require(!emergencyPaused, "Treasury is paused");
        require(amount <= treasuryBalance, "Insufficient treasury balance");
        require(
            treasuryBalance - amount >= emergencyMinimumBalance,
            "Must maintain minimum balance"
        );

        treasuryBalance -= amount;
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");

        emit TreasuryWithdrawal(to, amount, reason);
    }

    function setEmergencyPause(bool paused) external onlyRole(ADMIN_ROLE) {
        emergencyPaused = paused;
        emit EmergencyPauseSet(paused);
    }

    // Enhanced Delegation Functions
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

    // Dynamic Quorum Functions
    function setQuorumParameters(
        uint256 newBaseQuorum,
        uint256 newParticipationMultiplier
    ) external onlyRole(ADMIN_ROLE) {
        require(newBaseQuorum <= 10000, "Base quorum cannot exceed 100%");
        baseQuorum = newBaseQuorum;
        participationMultiplier = newParticipationMultiplier;
        emit QuorumParamsUpdated(newBaseQuorum, newParticipationMultiplier);
    }

    function calculateDynamicQuorum(
        uint256 blockNumber
    ) public view returns (uint256) {
        uint256 baseQuorumVotes = (token().getPastTotalSupply(blockNumber) *
            baseQuorum) / 10000;
        uint256 participation = _countParticipation(blockNumber);
        return
            baseQuorumVotes + ((participation * participationMultiplier) / 100);
    }

    function _countParticipation(
        uint256 blockNumber
    ) internal view returns (uint256) {
        // This is a simplified version - you might want to implement more sophisticated logic
        return token().getPastTotalSupply(blockNumber) / 2;
    }

    // Enhanced Proposal Functions
    function submitProposalForReview(
        string memory title,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        uint256 budget
    ) external {
        require(budget <= treasuryBalance, "Budget exceeds treasury balance");

        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        require(
            !proposalsAwaitingReview[proposalId].exists,
            "Proposal already submitted"
        );
        require(!approvedProposals[proposalId], "Proposal already approved");

        proposalMetadata[proposalId] = ProposalMetadata({
            title: title,
            description: description,
            proposer: msg.sender,
            timestamp: block.timestamp,
            status: "Under Review"
        });

        proposalsAwaitingReview[proposalId] = ProposalDetails({
            targets: targets,
            values: values,
            calldatas: calldatas,
            description: description,
            proposer: msg.sender,
            budget: budget,
            exists: true
        });

        totalProposals++;
        emit ProposalSubmittedForReview(proposalId, msg.sender);
    }

    function approveProposal(
        uint256 proposalId
    ) external onlyRole(PROPOSAL_REVIEWER_ROLE) {
        require(
            proposalsAwaitingReview[proposalId].exists,
            "Proposal not found"
        );
        require(!approvedProposals[proposalId], "Already approved");
        require(
            proposalsAwaitingReview[proposalId].proposer != msg.sender,
            "Cannot approve own proposal"
        );

        approvedProposals[proposalId] = true;
        proposalBudgets[proposalId] = proposalsAwaitingReview[proposalId]
            .budget;
        emit ProposalApproved(proposalId, msg.sender);
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        require(
            approvedProposals[proposalId],
            "Proposal must be approved by reviewer"
        );

        uint256 actualProposalId = super.propose(
            targets,
            values,
            calldatas,
            description
        );

        // Clean up
        delete proposalsAwaitingReview[proposalId];
        delete approvedProposals[proposalId];

        return actualProposalId;
    }

    // Get active proposals
    function getActiveProposals() external view returns (uint256[] memory) {
        // This is a simplified version - you might want to enhance this based on your needs
        return new uint256[](totalProposals);
    }

    // Get total number of eligible voters
    function getEligibleVotersCount() external view returns (uint256) {
        return IVotes(token()).getPastTotalSupply(block.number - 1);
    }

    // Check if address has voted on proposal
    // Fix the override for hasVoted by specifying all parent contracts
function hasVoted(
    uint256 proposalId,
    address account
) public view override(IGovernor, GovernorCountingSimple) returns (bool) {
    return super.hasVoted(proposalId, account);
}

    // Required overrides
    function quorum(
        uint256 blockNumber
    )
        public
        view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return calculateDynamicQuorum(blockNumber);
    }

    function votingDelay()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function state(
        uint256 proposalId
    )
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return
            super._queueOperations(
                proposalId,
                targets,
                values,
                calldatas,
                descriptionHash
            );
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(
            proposalId,
            targets,
            values,
            calldatas,
            descriptionHash
        );
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }

    function proposalNeedsQueuing(
        uint256 proposalId
    ) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(Governor, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
