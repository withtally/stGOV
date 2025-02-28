// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IGovernorBravoDelegate} from "../../src/interfaces/IGovernorBravoDelegate.sol";
import {GovernorBravoDelegateStorageV1} from "../helpers/GovernorBravoDelegateStorageV1.sol";

contract GovernorBravoDelegateMock is IGovernorBravoDelegate {
  mapping(uint256 proposalId => uint8 support) public mockProposalVotes;
  /// @notice Mock proposal data registry
  mapping(uint256 => GovernorBravoDelegateStorageV1.Proposal) public mockProposals;
  /// @notice The number of votes in support of a proposal required in order for a quorum to be reached and for a vote
  /// to succeed
  uint256 public quorumVotesOverride = 40_000_000e18; // 40,000,000 = 4% of GOV
  uint256 public votingPeriodOverride = 40_320;

  // Methods implementing the IGovernorBravoDelegate interface
  function castVote(uint256 proposalId, uint8 support) external {
    mockProposalVotes[proposalId] = support;
  }

  function proposals(uint256 _proposalId)
    external
    view
    returns (
      uint256 id,
      address proposer,
      uint256 eta,
      uint256 startBlock,
      uint256 endBlock,
      uint256 forVotes,
      uint256 againstVotes,
      uint256 abstainVotes,
      bool canceled,
      bool executed
    )
  {
    GovernorBravoDelegateStorageV1.Proposal storage _proposal = mockProposals[_proposalId];
    return (
      _proposal.id,
      _proposal.proposer,
      _proposal.eta,
      _proposal.startBlock,
      _proposal.endBlock,
      _proposal.forVotes,
      _proposal.againstVotes,
      _proposal.abstainVotes,
      _proposal.canceled,
      _proposal.executed
    );
  }

  function quorumVotes() external view returns (uint256) {
    return quorumVotesOverride;
  }

  function votingPeriod() external view returns (uint256) {
    return votingPeriodOverride;
  }

  // Methods used for configuring the mock during testing.
  function __setProposals(uint256 _proposalId, uint256 _endBlock, uint256 _forVotes, uint256 _againstVotes) external {
    mockProposals[_proposalId] = GovernorBravoDelegateStorageV1.Proposal({
      id: _proposalId,
      proposer: address(0),
      eta: 0,
      startBlock: 0,
      endBlock: _endBlock,
      forVotes: _forVotes,
      againstVotes: _againstVotes,
      abstainVotes: 0,
      canceled: false,
      executed: false
    });
  }

  function __setQuorumVotes(uint256 _quorumVotes) external {
    quorumVotesOverride = _quorumVotes;
  }

  function __setVotingPeriod(uint256 _votingPeriod) external {
    votingPeriodOverride = _votingPeriod;
  }
}
