// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {TimestampClockMode} from "../src/auto-delegates/extensions/TimestampClockMode.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract TimestampClockModeTest is Test {
  TimestampClockMode public timestampClockMode;

  function setUp() public {
    timestampClockMode = new TimestampClockMode();
  }
}

contract Clock is TimestampClockModeTest {
  function testFuzz_ReturnsCurrentTimestamp(uint256 _randomTimestamp) public {
    _randomTimestamp = bound(_randomTimestamp, 0, type(uint48).max);
    vm.warp(_randomTimestamp);
    assertEq(timestampClockMode.clock(), SafeCast.toUint48(_randomTimestamp));
  }
}

contract CLOCK_MODE is TimestampClockModeTest {
  function test_ReturnsCorrectClockMode() public view {
    assertEq(timestampClockMode.CLOCK_MODE(), "mode=timestamp");
  }
}
