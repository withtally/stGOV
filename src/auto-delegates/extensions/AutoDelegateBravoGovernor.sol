// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OverwhelmingSupportAutoDelegate} from "src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {IGovernorBravoDelegate} from "src/interfaces/IGovernorBravoDelegate.sol";

abstract contract AutoDelegateBravoGovernor is OverwhelmingSupportAutoDelegate {
  function _castVote(address _governor, uint256 _proposalId) internal virtual override {
    IGovernorBravoDelegate(_governor).castVote(_proposalId, FOR);
  }

  function _getProposalDetails(address _governor, uint256 _proposalId)
    internal
    view
    virtual
    override
    returns (uint256 _proposalDeadline, uint256 _forVotes, uint256 _againstVotes, uint256 _quorumVotes)
  {
    (,,,, _proposalDeadline, _forVotes, _againstVotes,,,) = IGovernorBravoDelegate(_governor).proposals(_proposalId);
    _quorumVotes = IGovernorBravoDelegate(_governor).quorumVotes();
  }
}
