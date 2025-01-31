// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./MyGovernorTreasury.sol";

contract MyGovernorProposals is MyGovernorTreasury {
constructor(
        IVotes _token,
        TimelockController _timelock
    ) MyGovernorTreasury(_token, _timelock) {
    }
    // User-friendly proposal retrieval methods
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

    // Proposal Submission and Management Methods
    function submitProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        string memory category,
        uint256 budget
    ) external returns (uint256) {
        // Validate category
        if (!isValidCategory[category]) revert InvalidCategory();

        // Create a new proposal
        uint256 proposalId = totalProposals + 1;
        totalProposals++;

        // Store proposal details
        proposalsAwaitingReview[proposalId] = ProposalDetails({
            targets: targets,
            values: values,
            calldatas: calldatas,
            description: description,
            proposer: msg.sender,
            budget: budget,
            exists: true
        });

        // Track user's proposals
        userProposals[msg.sender].push(proposalId);

        // Categorize proposal
        proposalsByCategory[category].push(proposalId);

        // Create proposal metadata
        proposalMetadata[proposalId] = ProposalMetadata({
            title: _extractTitle(description),
            proposer: msg.sender,
            timestamp: uint40(block.timestamp),
            status: "Pending Review",
            category: category,
            votesFor: 0,
            votesAgainst: 0,
            votesAbstain: 0,
            isActive: true
        });

        emit ProposalSubmittedForReview(proposalId, msg.sender);
        return proposalId;
    }

    function reviewProposal(
        uint256 proposalId,
        bool approve
    ) external onlyRole(PROPOSAL_REVIEWER_ROLE) {
        if (!proposalsAwaitingReview[proposalId].exists) {
            revert("Proposal does not exist");
        }

        if (approve) {
            // Check budget constraints
            uint256 budget = proposalsAwaitingReview[proposalId].budget;
            if (budget > treasuryState.balance) revert BudgetExceeded();

            // Mark proposal as approved
            approvedProposals[proposalId] = true;
            proposalMetadata[proposalId].status = "Approved";

            emit ProposalApproved(proposalId, msg.sender);
        } else {
            // Reject the proposal
            delete proposalsAwaitingReview[proposalId];
            proposalMetadata[proposalId].status = "Rejected";
            proposalMetadata[proposalId].isActive = false;

            emit ProposalRejected(proposalId, msg.sender);
        }
    }

    function updateProposalCategory(
        uint256 proposalId,
        string calldata newCategory
    ) external onlyRole(PROPOSAL_REVIEWER_ROLE) {
        if (!isValidCategory[newCategory]) revert InvalidCategory();

        // Remove from old category
        string memory oldCategory = proposalMetadata[proposalId].category;
        uint256[] storage oldCategoryProposals = proposalsByCategory[oldCategory];
        for (uint256 i = 0; i < oldCategoryProposals.length; i++) {
            if (oldCategoryProposals[i] == proposalId) {
                oldCategoryProposals[i] = oldCategoryProposals[oldCategoryProposals.length - 1];
                oldCategoryProposals.pop();
                break;
            }
        }

        // Add to new category
        proposalsByCategory[newCategory].push(proposalId);
        proposalMetadata[proposalId].category = newCategory;

        emit ProposalCategoryUpdated(proposalId, newCategory);
    }

    // Internal helper to extract title from description
    function _extractTitle(string memory description) internal pure returns (string memory) {
        bytes memory descBytes = bytes(description);
        bytes memory titleBytes = new bytes(descBytes.length);
        uint256 titleLength = 0;

        // Extract first line as title
        for (uint256 i = 0; i < descBytes.length; i++) {
            if (descBytes[i] == '\n') break;
            titleBytes[titleLength] = descBytes[i];
            titleLength++;
        }

        // Trim the title
        assembly {
            mstore(titleBytes, titleLength)
        }

        return string(titleBytes);
    }

    // Placeholder implementation for required override methods
    function quorum(uint256 blockNumber) public view override returns (uint256) {
        return calculateDynamicQuorum(blockNumber);
    }

    function votingDelay() public pure override returns (uint256) {
        return 1; // blocks
    }

    function votingPeriod() public pure override returns (uint256) {
        return 1; // blocks
    }

    function state(uint256 proposalId) public view override returns (ProposalState) {
        // Basic state management - this would need more complex logic in a real implementation
        if (!proposalMetadata[proposalId].isActive) return ProposalState.Canceled;
        if (!approvedProposals[proposalId]) return ProposalState.Pending;
        return ProposalState.Active;
    }

    function proposalThreshold() public pure override returns (uint256) {
        return 0; // No threshold for proposal submission
    }

    function hasVoted(uint256 proposalId, address account) public view override returns (bool) {
        return hasVotedOnProposal[account][proposalId];
    }

    // Placeholder implementation of abstract methods from base contract
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        bytes memory /* params */
    ) internal virtual override returns (uint256) {
        // Track voting details
        ProposalMetadata storage metadata = proposalMetadata[proposalId];
        
        if (!hasVotedOnProposal[account][proposalId]) {
            proposalVoterCount[proposalId]++;
            hasVotedOnProposal[account][proposalId] = true;
        }

        if (support == 0) {
            metadata.votesAgainst += uint96(weight);
        } else if (support == 1) {
            metadata.votesFor += uint96(weight);
        } else if (support == 2) {
            metadata.votesAbstain += uint96(weight);
        }

        return weight;
    }

    // These methods are placeholders and would need full implementation
    function _queueOperations(
        uint256 /* proposalId */,
        address[] memory /* targets */,
        uint256[] memory /* values */,
        bytes[] memory /* calldatas */,
        bytes32 /* descriptionHash */
    ) internal pure override returns (uint48) {
        // Placeholder implementation
        return 0;
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override {
        // Placeholder implementation
    }

    function _cancel(
        address[] memory /* targets */,
        uint256[] memory /* values */,
        bytes[] memory /* calldatas */,
        bytes32 /* descriptionHash */
    ) internal pure override returns (uint256) {
        // Placeholder implementation
        return 0;
    }

    function _executor() internal view override returns (address) {
        return address(this);
    }

    function proposalNeedsQueuing(uint256 /* proposalId */) public pure override returns (bool) {
        return true;
    }

    function supportsInterface(bytes4 /* interfaceId */) public pure override returns (bool) {
        // Placeholder implementation
        return true;
    }
}