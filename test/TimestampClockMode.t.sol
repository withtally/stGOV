// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {TimestampClockMode} from "../src/auto-delegates/extensions/TimestampClockMode.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract MockTimestampClockMode is TimestampClockMode {
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

contract TimestampClockModeTest is Test {
  TimestampClockMode public timestampClockMode;
  MockTimestampClockMode public mockTimestampClockMode;

  function setUp() public {
    timestampClockMode = new TimestampClockMode();
    mockTimestampClockMode = new MockTimestampClockMode();
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

  function test_RevertIf_ClockIsInconsistent() public {
    // Set a mock clock value inconsistent with the current block number
    mockTimestampClockMode.setMockClock(SafeCast.toUint48(block.number + 1));

    // Expect the ERC6372InconsistentClock error to be reverted
    vm.expectRevert(TimestampClockMode.ERC6372InconsistentClock.selector);
    mockTimestampClockMode.CLOCK_MODE();
  }
}
