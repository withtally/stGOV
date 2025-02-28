// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OverwhelmingSupportAutoDelegate} from "../../src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {BlockNumberClockMode} from "../../src/auto-delegates/extensions/BlockNumberClockMode.sol";
import {AutoDelegateOpenZeppelinGovernor} from
  "../../src/auto-delegates/extensions/AutoDelegateOpenZeppelinGovernor.sol";

contract OverwhelmingSupportAutoDelegateOZGovernorBlockNumberModeMock is
  OverwhelmingSupportAutoDelegate,
  AutoDelegateOpenZeppelinGovernor,
  BlockNumberClockMode
{
  uint256 public constant MIN_VOTING_WINDOW_IN_BLOCKS = 300;
  uint256 public constant MAX_VOTING_WINDOW_IN_BLOCKS = 50_400;

  constructor(address _initialOwner, uint256 _votingWindow, uint256 _subQuorumBips, uint256 _supportThreshold)
    OverwhelmingSupportAutoDelegate(
      _initialOwner,
      MIN_VOTING_WINDOW_IN_BLOCKS,
      MAX_VOTING_WINDOW_IN_BLOCKS,
      _votingWindow,
      _subQuorumBips,
      _supportThreshold
    )
  {}

  function clock()
    public
    view
    override(OverwhelmingSupportAutoDelegate, AutoDelegateOpenZeppelinGovernor, BlockNumberClockMode)
    returns (uint48)
  {
    return BlockNumberClockMode.clock();
  }

  function CLOCK_MODE()
    public
    view
    override(OverwhelmingSupportAutoDelegate, BlockNumberClockMode)
    returns (string memory)
  {
    return BlockNumberClockMode.CLOCK_MODE();
  }

  function _castVote(address _governor, uint256 _proposalId)
    internal
    override(OverwhelmingSupportAutoDelegate, AutoDelegateOpenZeppelinGovernor)
  {
    AutoDelegateOpenZeppelinGovernor._castVote(_governor, _proposalId);
  }

  function _getProposalDetails(address _governor, uint256 _proposalId)
    internal
    view
    override(OverwhelmingSupportAutoDelegate, AutoDelegateOpenZeppelinGovernor)
    returns (uint256 _proposalDeadline, uint256 _forVotes, uint256 _againstVotes, uint256 _quorumVotes)
  {
    return AutoDelegateOpenZeppelinGovernor._getProposalDetails(_governor, _proposalId);
  }
}
