  // SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OverwhelmingSupportAutoDelegate} from "src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

abstract contract BlockNumberClockMode is OverwhelmingSupportAutoDelegate {
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

  function CLOCK_MODE() public pure virtual override returns (string memory) {
    return "mode=blocknumber&from=default";
  }

  function clock() public view virtual override returns (uint48) {
    return SafeCast.toUint48(block.number);
  }
}
