// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OverwhelmingSupportAutoDelegate} from "src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

abstract contract AutoDelegateTimestampClockMode is OverwhelmingSupportAutoDelegate {
  function CLOCK_MODE() public pure virtual override returns (string memory) {
    return "mode=timestamp";
  }

  function clock() public view virtual override returns (uint48) {
    return SafeCast.toUint48(block.timestamp);
  }

  function _setVotingWindow(uint256 _votingWindow) internal virtual override {
    if (_votingWindow < MIN_VOTING_WINDOW_IN_BLOCKS * 12 || _votingWindow > MAX_VOTING_WINDOW_IN_BLOCKS * 12) {
      revert OverwhelmingSupportAutoDelegate__InvalidVotingWindow();
    }
    emit VotingWindowSet(votingWindow, _votingWindow);
    votingWindow = _votingWindow;
  }
}
