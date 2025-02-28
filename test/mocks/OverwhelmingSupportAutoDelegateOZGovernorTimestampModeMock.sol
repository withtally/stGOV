// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OverwhelmingSupportAutoDelegate} from "../../src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {TimestampClockMode} from "../../src/auto-delegates/extensions/TimestampClockMode.sol";
import {AutoDelegateOpenZeppelinGovernor} from
  "../../src/auto-delegates/extensions/AutoDelegateOpenZeppelinGovernor.sol";

contract OverwhelmingSupportAutoDelegateOZGovernorTimestampModeMock is
  OverwhelmingSupportAutoDelegate,
  AutoDelegateOpenZeppelinGovernor,
  TimestampClockMode
{
  uint256 public constant MIN_VOTING_WINDOW_IN_SECONDS = 3600;
  uint256 public constant MAX_VOTING_WINDOW_IN_SECONDS = 604_800;

  constructor(address _initialOwner, uint256 _votingWindow, uint256 _subQuorumBips, uint256 _supportThreshold)
    OverwhelmingSupportAutoDelegate(
      _initialOwner,
      MIN_VOTING_WINDOW_IN_SECONDS,
      MAX_VOTING_WINDOW_IN_SECONDS,
      _votingWindow,
      _subQuorumBips,
      _supportThreshold
    )
  {}

  function clock()
    public
    view
    override(OverwhelmingSupportAutoDelegate, AutoDelegateOpenZeppelinGovernor, TimestampClockMode)
    returns (uint48)
  {
    return TimestampClockMode.clock();
  }

  function CLOCK_MODE()
    public
    view
    override(OverwhelmingSupportAutoDelegate, TimestampClockMode)
    returns (string memory)
  {
    return TimestampClockMode.CLOCK_MODE();
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
