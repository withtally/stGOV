// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

contract BlockNumberClockMode {
  function clock() public view virtual returns (uint48) {
    return SafeCast.toUint48(block.number);
  }

  function CLOCK_MODE() public pure virtual returns (string memory) {
    return "mode=blocknumber&from=default";
  }
}
