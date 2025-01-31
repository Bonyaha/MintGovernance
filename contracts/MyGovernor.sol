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
    error InvalidCategory();
    error InsufficientBalance();
    error BudgetExceeded();
    error AlreadyApproved();
    error OwnProposalApproval();

    bytes32 public constant PROPOSAL_REVIEWER_ROLE =
        keccak256("PROPOSAL_REVIEWER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    // Treasury state
    struct TreasuryState {
        uint128 balance;
        uint128 emergencyMinimumBalance;
        bool emergencyPaused;
    }
    TreasuryState public treasuryState;

    // Enhanced delegation tracking
    mapping(address => address[]) public delegationHistory;
    mapping(address => uint256) public lastDelegationTimestamp;

    // Dynamic quorum settings
    uint256 public baseQuorum; // Base quorum percentage (in basis points, e.g., 1000 = 10%)
    uint256 public participationMultiplier; // Multiplier for participation rate

    // Enhanced proposal tracking
    struct ProposalMetadata {
        string title;
        address proposer;
        uint40 timestamp;
        string status;
        string category;
        uint96 votesFor;
        uint96 votesAgainst;
        uint96 votesAbstain;
        bool isActive;
    }
    // Enhanced pagination and filtering support
    struct ProposalPage {
        uint256[] proposalIds;
        ProposalMetadata[] metadata;
        uint256 totalCount;
        bool hasMore;
    }

    mapping(uint256 => ProposalMetadata) public proposalMetadata;
    mapping(uint256 => bool) public approvedProposals;
    mapping(uint256 => ProposalDetails) public proposalsAwaitingReview;
    mapping(uint256 => uint256) public proposalBudgets;
    mapping(string => uint256[]) public proposalsByCategory;
    mapping(address => uint256[]) public userProposals;
    mapping(uint256 => uint256) public proposalVoterCount;
    mapping(address => mapping(uint256 => bool)) public hasVotedOnProposal;
    uint256 public totalProposals;

    // Constants for pagination
    uint256 public constant PROPOSALS_PER_PAGE = 10;

    // Categories for proposals
    string[] public proposalCategories;
    mapping(string => bool) public isValidCategory;

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
    event TreasuryWithdrawal(address indexed to, uint256 amount, string reason);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event EmergencyPauseSet(bool isPaused);
    event DelegationChanged(
        address indexed delegator,
        address indexed fromDelegate,
        address indexed toDelegate
    );
    event QuorumParamsUpdated(
        uint256 baseQuorum,
        uint256 participationMultiplier
    );
    event ProposalCategoryUpdated(
        uint256 indexed proposalId,
        string newCategory
    );
    event TreasuryBalanceUpdated(uint256 newBalance);

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

        baseQuorum = 1000;
        participationMultiplier = 100;
        treasuryState.emergencyMinimumBalance = 1 ether;

        // Initialize default categories
        proposalCategories = ["General", "Treasury", "Protocol", "Community"];
        for (uint i = 0; i < proposalCategories.length; i++) {
            isValidCategory[proposalCategories[i]] = true;
        }
    }

    // Enhanced view functions for frontend
    function getProposalsByPage(
        uint256 page,
        uint256 pageSize
    ) external view returns (ProposalPage memory) {
        uint256 startIndex = page * pageSize;
        uint256 endIndex = startIndex + pageSize;
        if (endIndex > totalProposals) {
            endIndex = totalProposals;
        }

        uint256[] memory ids = new uint256[](endIndex - startIndex);
        ProposalMetadata[] memory metas = new ProposalMetadata[](
            endIndex - startIndex
        );

        for (uint256 i = startIndex; i < endIndex; i++) {
            ids[i - startIndex] = i + 1; // Assuming proposal IDs start from 1
            metas[i - startIndex] = proposalMetadata[ids[i - startIndex]];
        }

        return
            ProposalPage({
                proposalIds: ids,
                metadata: metas,
                totalCount: totalProposals,
                hasMore: endIndex < totalProposals
            });
    }

    function getProposalsByCategory(
        string calldata category,
        uint256 page
    ) external view returns (ProposalPage memory) {
        if (!isValidCategory[category]) revert InvalidCategory();
        uint256[] storage categoryProposals = proposalsByCategory[category];

        uint256 startIndex = page * PROPOSALS_PER_PAGE;
        uint256 endIndex = startIndex + PROPOSALS_PER_PAGE;
        if (endIndex > categoryProposals.length) {
            endIndex = categoryProposals.length;
        }

        uint256[] memory ids = new uint256[](endIndex - startIndex);
        ProposalMetadata[] memory metas = new ProposalMetadata[](
            endIndex - startIndex
        );

        for (uint256 i = startIndex; i < endIndex; i++) {
            ids[i - startIndex] = categoryProposals[i];
            metas[i - startIndex] = proposalMetadata[categoryProposals[i]];
        }

        return
            ProposalPage({
                proposalIds: ids,
                metadata: metas,
                totalCount: categoryProposals.length,
                hasMore: endIndex < categoryProposals.length
            });
    }

    function getUserVotingInfo(
        address user
    )
        external
        view
        returns (
            uint256 votingPower,
            uint256 delegatedPower,
            address[] memory delegators,
            uint256 proposalsVoted
        )
    {
        votingPower = IVotes(token()).getVotes(user);
        // Count proposals where user has voted
        uint256 voted = 0;
        for (uint256 i = 1; i <= totalProposals; i++) {
            if (hasVotedOnProposal[user][i]) {
                voted++;
            }
        }
        return (
            votingPower,
            0, // Delegated power calculation would need additional tracking
            new address[](0), // Delegators list would need additional tracking
            voted
        );
    }

    function getProposalVotes(
        uint256 proposalId
    )
        external
        view
        returns (
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            uint256 voterCount
        )
    {
        ProposalMetadata storage metadata = proposalMetadata[proposalId];
        return (
            metadata.votesFor,
            metadata.votesAgainst,
            metadata.votesAbstain,
            proposalVoterCount[proposalId]
        );
    }

    function addProposalReviewer(
        address reviewer
    ) external onlyRole(ADMIN_ROLE) {
        _grantRole(PROPOSAL_REVIEWER_ROLE, reviewer);
    }

    // Treasury Management Functions
    receive() external payable override {
        treasuryState.balance += uint128(msg.value);
        emit TreasuryDeposit(msg.sender, msg.value);
        emit TreasuryBalanceUpdated(treasuryState.balance);
    }

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

    function setEmergencyPause(bool paused) external onlyRole(ADMIN_ROLE) {
        treasuryState.emergencyPaused = paused;
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
        string memory category,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        uint256 budget
    ) external {
        require(isValidCategory[category], "Invalid category");
        if (budget > treasuryState.balance) revert BudgetExceeded();

        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        uint40 currentTimestamp = uint40(block.timestamp);
        proposalMetadata[proposalId] = ProposalMetadata({
            title: title,
            proposer: msg.sender,
            timestamp: currentTimestamp,
            status: "Under Review",
            category: category,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            isActive: true
        });

        proposalsByCategory[category].push(proposalId);
        userProposals[msg.sender].push(proposalId);

        emit ProposalSubmittedForReview(proposalId, msg.sender);
        emit ProposalCategoryUpdated(proposalId, category);
    }

    // Override vote counting to update metadata
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        bytes memory params
    )
        internal
        virtual
        override(Governor, GovernorCountingSimple)
        returns (uint256)
    {
        uint256 result = super._countVote(
            proposalId,
            account,
            support,
            weight,
            params
        );

        ProposalMetadata storage metadata = proposalMetadata[proposalId];
        if (support == 0) {
            metadata.votesAgainst = uint96(
                uint256(metadata.votesAgainst) + weight
            ); // Safe conversion
        } else if (support == 1) {
            metadata.votesFor = uint96(uint256(metadata.votesFor) + weight); // Safe conversion
        } else if (support == 2) {
            metadata.votesAbstain = uint96(
                uint256(metadata.votesAbstain) + weight
            ); // Safe conversion
        }

        if (!hasVotedOnProposal[account][proposalId]) {
            hasVotedOnProposal[account][proposalId] = true;
            proposalVoterCount[proposalId]++;
        }

        emit VoteCast(account, proposalId, support, weight, "");
        return result;
    }

    function approveProposal(
        uint256 proposalId
    ) external onlyRole(PROPOSAL_REVIEWER_ROLE) {
        require(
            proposalsAwaitingReview[proposalId].exists,
            "Proposal not found"
        );
        if (approvedProposals[proposalId]) revert AlreadyApproved();
        if (proposalsAwaitingReview[proposalId].proposer == msg.sender)
            revert OwnProposalApproval();

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