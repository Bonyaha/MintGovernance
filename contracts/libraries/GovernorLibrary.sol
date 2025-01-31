// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../MyGovernorBase.sol";

library GovernorLibrary {
    struct ProposalPage {
        uint256[] proposalIds;
        MyGovernorBase.ProposalMetadata[] metadata;
        uint256 totalCount;
        bool hasMore;
    }

event ProposalSubmittedForReview(uint256 indexed proposalId, address indexed proposer);

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
}
