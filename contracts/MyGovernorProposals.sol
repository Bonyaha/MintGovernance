// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./MyGovernorTreasury.sol";
import "./libraries/GovernorLibrary.sol";

contract MyGovernorProposals is MyGovernorTreasury {
    using GovernorLibrary for *;
    
    mapping(uint256 => GovernorLibrary.CompactProposalDetails) private proposalsAwaitingReview;
    mapping(uint256 => string) private proposalDescriptions;

    constructor(IVotes _token, TimelockController _timelock) 
        MyGovernorTreasury(_token, _timelock) 
    {}

    function getProposals(uint256 page, string calldata category) 
        external 
        view 
        returns (GovernorLibrary.ProposalPage memory) 
    {
        if (bytes(category).length == 0) {
            return GovernorLibrary.getProposalsPage(
                page,
                PROPOSALS_PER_PAGE,
                totalProposals,
                proposalMetadata
            );
        }
        
        if (!isValidCategory[category]) revert InvalidCategory();
        return GovernorLibrary.getCategoryProposals(
            category,
            page,
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
        uint96 budget
    ) external returns (uint256) {
        if (!isValidCategory[category]) revert InvalidCategory();
        if (budget > treasuryState.balance) revert GovernorLibrary.BudgetExceeded();

        GovernorLibrary.ProposalCreationParams memory params = GovernorLibrary
            .ProposalCreationParams({
                proposalId: totalProposals,
                description: description,
                category: category,
                budget: budget,
                proposer: msg.sender
            });

        uint256 newTotalProposals;
        uint256 proposalId;
        (newTotalProposals, proposalId) = GovernorLibrary.createProposal(
            params,
            targets,
            values,
            calldatas,
            proposalsAwaitingReview,
            proposalDescriptions,
            userProposals,
            proposalsByCategory,
            proposalMetadata
        );

        totalProposals = newTotalProposals;
        emit ProposalSubmittedForReview(proposalId, msg.sender);
        return proposalId;
    }

    function reviewProposal(uint256 proposalId, bool approve) 
        external 
        onlyRole(PROPOSAL_REVIEWER_ROLE) 
    {
        GovernorLibrary.CompactProposalDetails storage proposal = proposalsAwaitingReview[proposalId];
        
        bool isApproved = GovernorLibrary.executeReview(
            proposalId,
            approve,
            proposal,
            treasuryState.balance,
            approvedProposals,
            proposalMetadata,
            proposalsAwaitingReview,
            proposalDescriptions
        );

        if (isApproved) {
            emit ProposalApproved(proposalId, msg.sender);
        } else {
            emit ProposalRejected(proposalId, msg.sender);
        }
    }

    // MyGovernorProposals.sol
function _countVote(
    uint256 proposalId,
    address account,
    uint8 support,
    uint256 weight,
    bytes memory
) internal override returns (uint256) {
    return GovernorLibrary.countVote(
        proposalId,
        account,
        support,
        weight,
        hasVotedOnProposal, 
        proposalVoterCount,
        proposalMetadata
    );
}


}