// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";

contract OpenZeppelinGovernorMock is Governor, GovernorCountingSimple {
  mapping(uint256 proposalId => uint8 support) public mockProposalVotes;
  /// @notice Mock proposal data registry
  mapping(uint256 proposalId => ProposalCoreCustom) public mockProposals;
  /// @notice The number of votes in support of a proposal required in order for a quorum to be reached and for a vote
  /// to succeed
  uint256 public quorumVotesOverride = 40_000_000e18; // 40,000,000 = 4% of GOV
  uint256 public votingPeriodOverride = 40_320;

  // Custom ProposalCore struct for the mock
  struct ProposalCoreCustom {
    uint256 voteStart;
    uint256 voteEnd;
    bool executed;
    bool canceled;
    uint256 forVotes;
    uint256 againstVotes;
    uint256 abstainVotes;
  }

  // Methods used for configuring the mock during testing.
  function __setProposals(uint256 _proposalId, uint256 _endBlock, uint256 _forVotes, uint256 _againstVotes) external {
    mockProposals[_proposalId] = ProposalCoreCustom({
      voteStart: 0,
      voteEnd: _endBlock,
      executed: false,
      canceled: false,
      forVotes: _forVotes,
      againstVotes: _againstVotes,
      abstainVotes: 0
    });
  }

  function __setQuorumVotes(uint256 _quorumVotes) external {
    quorumVotesOverride = _quorumVotes;
  }

  function __setVotingPeriod(uint256 _votingPeriod) external {
    votingPeriodOverride = _votingPeriod;
  }

  function quorum(uint256) public view override returns (uint256) {
    return quorumVotesOverride;
  }

  function quorumVotes() public view returns (uint256) {
    return quorumVotesOverride;
  }

  function votingPeriod() public view override returns (uint256) {
    return votingPeriodOverride;
  }

  function castVote(uint256 proposalId, uint8 support) public override returns (uint256) {
    mockProposalVotes[proposalId] = support;
    return 0;
  }

  function proposalVotes(uint256 proposalId)
    public
    view
    override
    returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)
  {
    ProposalCoreCustom memory proposal = mockProposals[proposalId];
    return (proposal.againstVotes, proposal.forVotes, proposal.abstainVotes);
  }

  function proposalSnapshot(uint256 proposalId) public view override returns (uint256) {
    return mockProposals[proposalId].voteStart;
  }

  function proposalDeadline(uint256 proposalId) public view override returns (uint256) {
    return mockProposals[proposalId].voteEnd;
  }

  constructor() Governor("Mock Governor") {}

  function clock() public view override returns (uint48) {
    return uint48(block.number);
  }

  function CLOCK_MODE() public pure override returns (string memory) {
    return "mode=blocknumber";
  }

  function _getVotes(address, /* account */ uint256, /* timepoint */ bytes memory /* params */ )
    internal
    pure
    override
    returns (uint256)
  {}

  function votingDelay() public pure override returns (uint256) {}
}
