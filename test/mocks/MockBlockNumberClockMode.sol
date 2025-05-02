// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BlockNumberClockMode} from "../../src/auto-delegates/extensions/BlockNumberClockMode.sol";

contract MockBlockNumberClockMode is BlockNumberClockMode {
  uint48 private mockClockValue;

  /// @notice Allows overriding the clock value for testing.
  function setMockClock(uint48 _mockClockValue) public {
    mockClockValue = _mockClockValue;
  }

  /// @notice Overrides the clock function to return the mocked value.
  function clock() public view override returns (uint48) {
    return mockClockValue;
  }
}
