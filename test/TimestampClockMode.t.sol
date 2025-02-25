// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimestampClockMode} from "src/auto-delegates/extensions/TimestampClockMode.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

contract TimestampClockModeTest is Test {
  TimestampClockMode public timestampClockMode;

  function setUp() public {
    timestampClockMode = new TimestampClockMode();
  }

  function testFuzz_ReturnsCurrentTimestamp(uint256 _randomTimestamp) public {
    _randomTimestamp = bound(_randomTimestamp, 0, type(uint48).max);
    vm.warp(_randomTimestamp);
    assertEq(timestampClockMode.clock(), SafeCast.toUint48(_randomTimestamp));
  }

  function test_ReturnsClockMode() public view {
    assertEq(timestampClockMode.CLOCK_MODE(), "mode=timestamp");
  }
}
