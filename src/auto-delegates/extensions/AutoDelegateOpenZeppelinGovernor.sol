// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OverwhelmingSupportAutoDelegate} from "src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {IGovernor} from "openzeppelin/governance/IGovernor.sol";
import {IGovernorCountingExtensions} from "src/auto-delegates/interfaces/IGovernorCountingExtensions.sol";

abstract contract AutoDelegateOpenZeppelinGovernor is OverwhelmingSupportAutoDelegate {
  function _castVote(address _governor, uint256 _proposalId) internal virtual override {
    IGovernor(_governor).castVote(_proposalId, FOR);
  }

  function _getProposalDetails(address _governor, uint256 _proposalId)
    internal
    view
    virtual
    override
    returns (uint256 _proposalDeadline, uint256 _forVotes, uint256 _againstVotes, uint256 _quorumVotes)
  {
    _proposalDeadline = IGovernor(_governor).proposalDeadline(_proposalId);
    (_againstVotes, _forVotes,) = IGovernorCountingExtensions(_governor).proposalVotes(_proposalId);
    _quorumVotes = IGovernor(_governor).quorum(clock());
  }
}
