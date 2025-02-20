// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OverwhelmingSupportAutoDelegate} from "src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {IGovernor} from "openzeppelin/governance/IGovernor.sol";

interface IGovernorCounting {
  function proposalVotes(uint256 proposalId)
    external
    view
    returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes);
}

abstract contract AutoDelegateOpenZeppelinGovernor is OverwhelmingSupportAutoDelegate {
  function castVote(address _governor, uint256 _proposalId) public override {
    IGovernor(_governor).castVote(_proposalId, FOR);
  }

  function _getProposalDetails(address _governor, uint256 _proposalId)
    internal
    view
    virtual
    override
    returns (uint256 _proposalDeadline, uint256 _againstVotes, uint256 _forVotes, uint256 _quorumVotes)
  {
    // Fetch proposal data once
    _proposalDeadline = IGovernor(_governor).proposalDeadline(_proposalId);
    (_againstVotes, _forVotes,) = IGovernorCounting(_governor).proposalVotes(_proposalId);
    _quorumVotes = IGovernor(_governor).quorum(clock());
  }
}
