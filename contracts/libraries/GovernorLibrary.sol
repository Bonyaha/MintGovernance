// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../MyGovernorBase.sol";

library GovernorLibrary {
 error InvalidProposal();
error BudgetExceeded();

    struct ProposalPage {
        uint256[] proposalIds;
        MyGovernorBase.ProposalMetadata[] metadata;
        uint256 totalCount;
        bool hasMore;
    }

    struct CompactProposalDetails {
        address proposer;
        uint96 budget;
        bool exists;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
    }

    struct ProposalCreationParams {
        uint256 proposalId;
        string description;
        string category;
        uint96 budget;
        address proposer;
    }

    function createProposal(
    ProposalCreationParams memory params,
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata calldatas,
    mapping(uint256 => CompactProposalDetails) storage proposalsAwaitingReview,
    mapping(uint256 => string) storage proposalDescriptions,
    mapping(address => uint256[]) storage userProposals,
    mapping(string => uint256[]) storage proposalsByCategory,
    mapping(uint256 => MyGovernorBase.ProposalMetadata) storage proposalMetadata
) internal returns (uint256 newTotalProposals, uint256 proposalId) {
    newTotalProposals = params.proposalId + 1;
    proposalId = newTotalProposals;

    _storeProposalDetails(
        proposalId,
        params.proposer,
        params.budget,
        targets,
        values,
        calldatas,
        proposalsAwaitingReview
    );

    proposalDescriptions[proposalId] = params.description;
    userProposals[params.proposer].push(proposalId);
    proposalsByCategory[params.category].push(proposalId);

    _createProposalMetadata(
        proposalId,
        params.description,
        params.category,
        params.proposer,
        proposalMetadata
    );
}


    function _storeProposalDetails(
        uint256 proposalId,
        address proposer,
        uint96 budget,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        mapping(uint256 => CompactProposalDetails)
            storage proposalsAwaitingReview
    ) private {
        proposalsAwaitingReview[proposalId] = CompactProposalDetails({
            proposer: proposer,
            budget: budget,
            exists: true,
            targets: targets,
            values: values,
            calldatas: calldatas
        });
    }

    function _createProposalMetadata(
        uint256 proposalId,
        string memory description,
        string memory category,
        address proposer,
        mapping(uint256 => MyGovernorBase.ProposalMetadata)
            storage proposalMetadata
    ) private {
        proposalMetadata[proposalId] = MyGovernorBase.ProposalMetadata({
            title: extractTitle(description),
            proposer: proposer,
            timestamp: uint40(block.timestamp),
            status: "Pending",
            category: category,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            isActive: true
        });
    }

    function getProposalsPage(
        uint256 page,
        uint256 pageSize,
        uint256 totalProposals,
        mapping(uint256 => MyGovernorBase.ProposalMetadata)
            storage proposalMetadata
    ) internal view returns (ProposalPage memory) {
        uint256 startIndex = page * pageSize;
        uint256 endIndex = startIndex + pageSize;
        if (endIndex > totalProposals) {
            endIndex = totalProposals;
        }

        uint256[] memory ids = new uint256[](endIndex - startIndex);
        MyGovernorBase.ProposalMetadata[]
            memory metas = new MyGovernorBase.ProposalMetadata[](
                endIndex - startIndex
            );

        for (uint256 i = startIndex; i < endIndex; i++) {
            ids[i - startIndex] = i + 1;
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

    function getCategoryProposals(
        string memory category,
        uint256 page,
        uint256 pageSize,
        mapping(string => uint256[]) storage proposalsByCategory,
        mapping(uint256 => MyGovernorBase.ProposalMetadata)
            storage proposalMetadata
    ) internal view returns (ProposalPage memory) {
        uint256[] storage categoryProposals = proposalsByCategory[category];

        uint256 startIndex = page * pageSize;
        uint256 endIndex = startIndex + pageSize;
        if (endIndex > categoryProposals.length) {
            endIndex = categoryProposals.length;
        }

        uint256[] memory ids = new uint256[](endIndex - startIndex);
        MyGovernorBase.ProposalMetadata[]
            memory metas = new MyGovernorBase.ProposalMetadata[](
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

    function extractTitle(
        string memory description
    ) internal pure returns (string memory) {
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

    function executeReview(
        uint256 proposalId,
        bool approve,
        CompactProposalDetails storage proposal,
        uint256 treasuryBalance,
        mapping(uint256 => bool) storage approvedProposals,
        mapping(uint256 => MyGovernorBase.ProposalMetadata) storage proposalMetadata,
        mapping(uint256 => CompactProposalDetails)
            storage proposalsAwaitingReview,
        mapping(uint256 => string) storage proposalDescriptions
    ) internal returns (bool isApproved) {
        if (!proposal.exists) revert InvalidProposal();

        if (approve) {
            if (proposal.budget > treasuryBalance) revert BudgetExceeded();
            approvedProposals[proposalId] = true;
            proposalMetadata[proposalId].status = "Approved";
            isApproved = true;
        } else {
            delete proposalsAwaitingReview[proposalId];
            delete proposalDescriptions[proposalId];
            proposalMetadata[proposalId].status = "Rejected";
            proposalMetadata[proposalId].isActive = false;
            isApproved = false;
        }
    }

    function countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        mapping(address => mapping(uint256 => bool)) storage hasVotedOnProposal,
        mapping(uint256 => uint256) storage proposalVoterCount,
        mapping(uint256 => MyGovernorBase.ProposalMetadata) storage proposalMetadata
    ) internal returns (uint256) {
        if (!hasVotedOnProposal[account][proposalId]) {
            proposalVoterCount[proposalId]++;
            hasVotedOnProposal[account][proposalId] = true;
        }

        MyGovernorBase.ProposalMetadata storage metadata = proposalMetadata[proposalId];
        if (support == 0) metadata.votesAgainst += uint96(weight);
        else if (support == 1) metadata.votesFor += uint96(weight);
        else metadata.votesAbstain += uint96(weight);

        return weight; // Return weight directly
    }

}
