// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OverwhelmingSupportAutoDelegate} from "../../src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {BlockNumberClockMode} from "../../src/auto-delegates/extensions/BlockNumberClockMode.sol";
import {AutoDelegateBravoGovernor} from "../../src/auto-delegates/extensions/AutoDelegateBravoGovernor.sol";

contract OverwhelmingSupportAutoDelegateBravoGovernorBlockNumberModeMock is
  OverwhelmingSupportAutoDelegate,
  AutoDelegateBravoGovernor,
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

  function clock() public view override(OverwhelmingSupportAutoDelegate, BlockNumberClockMode) returns (uint48) {
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
}
