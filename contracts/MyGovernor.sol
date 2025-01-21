// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract MyGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    AccessControl
{
    bytes32 public constant PROPOSAL_REVIEWER_ROLE =
        keccak256("PROPOSAL_REVIEWER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Mapping to track approved proposal hashes
    mapping(bytes32 => bool) public approvedProposals;

    // Events
    event ProposalApproved(bytes32 proposalHash, address reviewer);
    event ProposalRejected(bytes32 proposalHash, address reviewer);
    event ProposalSubmittedForReview(bytes32 proposalHash, address proposer);

    // Struct to store proposal details for review
    struct ProposalDetails {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
        address proposer;
        bool exists;
    }

    // Mapping to store proposals waiting for review
    mapping(bytes32 => ProposalDetails) public proposalsAwaitingReview;

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
        // Setup initial roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _setRoleAdmin(PROPOSAL_REVIEWER_ROLE, ADMIN_ROLE);
    }

    // Function for users to submit proposals for review
    function submitProposalForReview(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external {
        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        bytes32 proposalHash = bytes32(proposalId);

        require(
            !proposalsAwaitingReview[proposalHash].exists,
            "Proposal already submitted for review"
        );
        require(!approvedProposals[proposalHash], "Proposal already approved");

        proposalsAwaitingReview[proposalHash] = ProposalDetails({
            targets: targets,
            values: values,
            calldatas: calldatas,
            description: description,
            proposer: msg.sender,
            exists: true
        });

        emit ProposalSubmittedForReview(proposalHash, msg.sender);
    }

    // Function to approve proposals before they can be voted on
    function approveProposal(
        bytes32 proposalHash
    ) external onlyRole(PROPOSAL_REVIEWER_ROLE) {
        require(
            proposalsAwaitingReview[proposalHash].exists,
            "Proposal not found"
        );
        require(!approvedProposals[proposalHash], "Proposal already approved");

        // Prevent reviewers from approving their own proposals
        require(
            proposalsAwaitingReview[proposalHash].proposer != msg.sender,
            "Cannot approve own proposal"
        );

        approvedProposals[proposalHash] = true;
        emit ProposalApproved(proposalHash, msg.sender);
    }

    // Function to reject proposals
    function rejectProposal(
        bytes32 proposalHash
    ) external onlyRole(PROPOSAL_REVIEWER_ROLE) {
        require(
            proposalsAwaitingReview[proposalHash].exists,
            "Proposal not found"
        );
        require(
            !approvedProposals[proposalHash],
            "Cannot reject approved proposal"
        );

        // Prevent reviewers from rejecting their own proposals
        require(
            proposalsAwaitingReview[proposalHash].proposer != msg.sender,
            "Cannot reject own proposal"
        );

        delete proposalsAwaitingReview[proposalHash];
        emit ProposalRejected(proposalHash, msg.sender);
    }

    // Override propose function to require approval for all proposals
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
        bytes32 proposalHash = bytes32(proposalId);
        require(
            approvedProposals[proposalHash],
            "Proposal must be approved by reviewer"
        );

        // Clean up the approved proposal after it's been proposed
        delete proposalsAwaitingReview[proposalHash];
        delete approvedProposals[proposalHash];

        return super.propose(targets, values, calldatas, description);
    }

    // Function to add proposal reviewers
    function addProposalReviewer(
        address reviewer
    ) external onlyRole(ADMIN_ROLE) {
        grantRole(PROPOSAL_REVIEWER_ROLE, reviewer);
    }

    // Function to remove proposal reviewers
    function removeProposalReviewer(
        address reviewer
    ) external onlyRole(ADMIN_ROLE) {
        revokeRole(PROPOSAL_REVIEWER_ROLE, reviewer);
    }

    // The following functions are overrides required by Solidity.

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

    function quorum(
        uint256 blockNumber
    )
        public
        view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
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

    function proposalNeedsQueuing(
        uint256 proposalId
    ) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
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

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(Governor, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
