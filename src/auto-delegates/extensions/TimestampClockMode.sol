// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OverwhelmingSupportAutoDelegate} from "src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

abstract contract TimestampClockMode is OverwhelmingSupportAutoDelegate {
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

  function CLOCK_MODE() public pure virtual override returns (string memory) {
    return "mode=timestamp";
  }

  function clock() public view virtual override returns (uint48) {
    return SafeCast.toUint48(block.timestamp);
  }
}
