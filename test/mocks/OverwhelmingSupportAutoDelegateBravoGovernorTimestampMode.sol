// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OverwhelmingSupportAutoDelegate} from "src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {TimestampClockMode} from "src/auto-delegates/extensions/TimestampClockMode.sol";

contract OverwhelmingSupportAutoDelegateBravoGovernorTimestampMode is
  OverwhelmingSupportAutoDelegate,
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

  function clock() public view override(OverwhelmingSupportAutoDelegate, TimestampClockMode) returns (uint48) {
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
}
