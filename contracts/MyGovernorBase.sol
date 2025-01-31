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

abstract contract MyGovernorBase is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    AccessControl,
    ReentrancyGuard
{
    // Error definitions
    error InvalidCategory();
    error InsufficientBalance();
    error BudgetExceeded();
    error AlreadyApproved();
    error OwnProposalApproval();

    // Role constants
    bytes32 public constant PROPOSAL_REVIEWER_ROLE = keccak256("PROPOSAL_REVIEWER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    // Structs
    struct TreasuryState {
        uint128 balance;
        uint128 emergencyMinimumBalance;
        bool emergencyPaused;
    }

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

    struct ProposalPage {
        uint256[] proposalIds;
        ProposalMetadata[] metadata;
        uint256 totalCount;
        bool hasMore;
    }

    // State variables
    TreasuryState public treasuryState;
    mapping(address => address[]) public delegationHistory;
    mapping(address => uint256) public lastDelegationTimestamp;

    uint256 public baseQuorum;
    uint256 public participationMultiplier;

    mapping(uint256 => ProposalMetadata) public proposalMetadata;
    mapping(uint256 => bool) public approvedProposals;    
    mapping(uint256 => uint256) public proposalBudgets;
    mapping(string => uint256[]) public proposalsByCategory;
    mapping(address => uint256[]) public userProposals;
    mapping(uint256 => uint256) public proposalVoterCount;
    mapping(address => mapping(uint256 => bool)) public hasVotedOnProposal;
    uint256 public totalProposals;

    uint256 public constant PROPOSALS_PER_PAGE = 10;

    string[] public proposalCategories;
    mapping(string => bool) public isValidCategory;

    // Events
    event ProposalApproved(uint256 indexed proposalId, address indexed reviewer);
    event ProposalRejected(uint256 indexed proposalId, address indexed reviewer);
    event ProposalSubmittedForReview(uint256 indexed proposalId, address indexed proposer);
    event DelegationChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event QuorumParamsUpdated(uint256 baseQuorum, uint256 participationMultiplier);
    event ProposalCategoryUpdated(uint256 indexed proposalId, string newCategory);

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

    // Virtual functions to be implemented by child contracts
    function addProposalReviewer(address reviewer) external virtual {
        _grantRole(PROPOSAL_REVIEWER_ROLE, reviewer);
    }
    function calculateDynamicQuorum(uint256 blockNumber) public view virtual returns (uint256) {
        return (token().getPastTotalSupply(blockNumber) * baseQuorum) / 10000;
    }

    function setQuorumParameters(uint256 newBaseQuorum, uint256 newParticipationMultiplier) external virtual {
        baseQuorum = newBaseQuorum;
        participationMultiplier = newParticipationMultiplier;
    }

    // Required override methods
    function quorum(uint256 blockNumber) public view virtual override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return GovernorVotesQuorumFraction.quorum(blockNumber);
    }
    function votingDelay() public view virtual override(Governor, GovernorSettings) returns (uint256) {
        return GovernorSettings.votingDelay();
    }
    function votingPeriod() public view virtual override(Governor, GovernorSettings) returns (uint256) {
        return GovernorSettings.votingPeriod();
    }
    function state(uint256 proposalId) public view virtual override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return GovernorTimelockControl.state(proposalId);
    }
    function proposalThreshold() public view virtual override(Governor, GovernorSettings) returns (uint256) {
        return GovernorSettings.proposalThreshold();
    }
    function hasVoted(uint256 proposalId, address account) public view virtual override(IGovernor, GovernorCountingSimple) returns (bool) {
        return GovernorCountingSimple.hasVoted(proposalId, account);
    }

    // Internal helper methods
    function _countParticipation(uint256 blockNumber) internal view virtual returns (uint256) {
        return token().getPastTotalSupply(blockNumber) / 2;
    }

    // Override vote counting
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        bytes memory params
    ) internal virtual override(Governor, GovernorCountingSimple) returns (uint256) {
        return GovernorCountingSimple._countVote(proposalId, account, support, weight, params);
    }


    // Additional interface compliance methods
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual override(Governor, GovernorTimelockControl) returns (uint48) {
        return GovernorTimelockControl._queueOperations(
            proposalId, targets, values, calldatas, descriptionHash
        );
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual override(Governor, GovernorTimelockControl) {
        GovernorTimelockControl._executeOperations(
            proposalId, targets, values, calldatas, descriptionHash
        );
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual override(Governor, GovernorTimelockControl) returns (uint256) {
        return GovernorTimelockControl._cancel(
            targets, values, calldatas, descriptionHash
        );
    }

    function _executor() internal view virtual override(Governor, GovernorTimelockControl) returns (address) {
        return GovernorTimelockControl._executor();
    }

    function proposalNeedsQueuing(uint256 proposalId) public view virtual override(Governor, GovernorTimelockControl) returns (bool) {
        return GovernorTimelockControl.proposalNeedsQueuing(proposalId);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(Governor, AccessControl) returns (bool) {
        return Governor.supportsInterface(interfaceId) || AccessControl.supportsInterface(interfaceId);
    }
}