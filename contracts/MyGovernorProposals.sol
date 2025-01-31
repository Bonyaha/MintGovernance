// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./MyGovernorTreasury.sol";
import "./libraries/GovernorLibrary.sol";

contract MyGovernorProposals is MyGovernorTreasury {
    using GovernorLibrary for *;

error InvalidProposal();

    struct CompactProposalDetails {
        address proposer;
        uint96 budget;
        bool exists;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
    }

    mapping(uint256 => CompactProposalDetails) private proposalsAwaitingReview;
    mapping(uint256 => string) private proposalDescriptions;

    constructor(
        IVotes _token,
        TimelockController _timelock
    ) MyGovernorTreasury(_token, _timelock) {}

    // Simplified getProposalsByPage with minimal parameters
    function getProposalsByPage(uint256 page) external view returns (GovernorLibrary.ProposalPage memory) {
        return GovernorLibrary.getProposalsPage(
            page,
            PROPOSALS_PER_PAGE,
            totalProposals,
            proposalMetadata
        );
    }

    // Simplified getProposalsByCategory with minimal parameters
    function getProposalsByCategory(string calldata category) external view returns (GovernorLibrary.ProposalPage memory) {
        if (!isValidCategory[category]) revert InvalidCategory();
        return GovernorLibrary.getCategoryProposals(
            category,
            0,
            PROPOSALS_PER_PAGE,
            proposalsByCategory,
            proposalMetadata
        );
    }

    function submitProposal(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description,
        string calldata category,
        uint96 budget  // Changed to uint96
    ) external returns (uint256) {
        if (!isValidCategory[category]) revert InvalidCategory();
        if (budget > treasuryState.balance) revert BudgetExceeded();

        uint256 proposalId = ++totalProposals;

        proposalsAwaitingReview[proposalId] = CompactProposalDetails({
            proposer: msg.sender,
            budget: budget,
            exists: true,
            targets: targets,
            values: values,
            calldatas: calldatas
        });
        proposalDescriptions[proposalId] = description;

        userProposals[msg.sender].push(proposalId);
        proposalsByCategory[category].push(proposalId);

        proposalMetadata[proposalId] = ProposalMetadata({
            title: GovernorLibrary.extractTitle(description),
            proposer: msg.sender,
            timestamp: uint40(block.timestamp),
            status: "Pending",
            category: category,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            isActive: true
        });

        emit ProposalSubmittedForReview(proposalId, msg.sender);
        return proposalId;
    }

    function reviewProposal(uint256 proposalId, bool approve) external onlyRole(PROPOSAL_REVIEWER_ROLE) {
        CompactProposalDetails storage proposal = proposalsAwaitingReview[proposalId];
        if (!proposal.exists) revert InvalidProposal();
        
        if (approve) {
            if (proposal.budget > treasuryState.balance) revert BudgetExceeded();
            approvedProposals[proposalId] = true;
            proposalMetadata[proposalId].status = "Approved";
            emit ProposalApproved(proposalId, msg.sender);
        } else {
            delete proposalsAwaitingReview[proposalId];
            delete proposalDescriptions[proposalId];
            proposalMetadata[proposalId].status = "Rejected";
            proposalMetadata[proposalId].isActive = false;
            emit ProposalRejected(proposalId, msg.sender);
        }
    }

    // Optimized _extractTitle function
    function _extractTitle(string memory description) internal pure returns (string memory) {
        bytes memory descBytes = bytes(description);
        uint256 len = descBytes.length;
        for (uint256 i = 0; i < len; i++) {
            if (descBytes[i] == 0x0A) {
                bytes memory titleBytes = new bytes(i);
                for (uint256 j = 0; j < i; j++) {
                    titleBytes[j] = descBytes[j];
                }
                return string(titleBytes);
            }
        }
        return description;
    }

    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        bytes memory
    ) internal override returns (uint256) {
        if (!hasVotedOnProposal[account][proposalId]) {
            proposalVoterCount[proposalId]++;
            hasVotedOnProposal[account][proposalId] = true;
        }

        ProposalMetadata storage metadata = proposalMetadata[proposalId];
        if (support == 0) metadata.votesAgainst += uint96(weight);
        else if (support == 1) metadata.votesFor += uint96(weight);
        else metadata.votesAbstain += uint96(weight);

        return weight;
    }
}