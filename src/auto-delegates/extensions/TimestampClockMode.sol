// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

contract TimestampClockMode {
  function clock() public view virtual returns (uint48) {
    return SafeCast.toUint48(block.timestamp);
  }

  function CLOCK_MODE() public pure virtual returns (string memory) {
    return "mode=timestamp";
  }
}
