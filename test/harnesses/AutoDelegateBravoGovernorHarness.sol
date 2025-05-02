// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AutoDelegateBravoGovernor} from "../../src/auto-delegates/extensions/AutoDelegateBravoGovernor.sol";

contract AutoDelegateBravoGovernorHarness is AutoDelegateBravoGovernor {
  function exposed_castVote(address _governor, uint256 _proposalId) external {
    _castVote(_governor, _proposalId);
  }

  function exposed_getProposalDetails(address _governor, uint256 _proposalId)
    external
    view
    returns (uint256 _proposalDeadline, uint256 _forVotes, uint256 _againstVotes, uint256 _quorumVotes)
  {
    return _getProposalDetails(_governor, _proposalId);
  }
}
