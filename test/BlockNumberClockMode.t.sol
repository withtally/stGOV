// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {BlockNumberClockMode} from "../src/auto-delegates/extensions/BlockNumberClockMode.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MockBlockNumberClockMode} from "./mocks/MockBlockNumberClockMode.sol";

contract BlockNumberClockModeTest is Test {
  BlockNumberClockMode public blockNumberClockMode;
  MockBlockNumberClockMode public mockBlockNumberClockMode;

  function setUp() public {
    blockNumberClockMode = new BlockNumberClockMode();
    mockBlockNumberClockMode = new MockBlockNumberClockMode();
  }
}

contract Clock is BlockNumberClockModeTest {
  function testFuzz_ReturnsCurrentBlockNumber(uint256 _randomBlockNumber) public {
    _randomBlockNumber = bound(_randomBlockNumber, 0, type(uint48).max);
    vm.roll(_randomBlockNumber);
    assertEq(blockNumberClockMode.clock(), SafeCast.toUint48(_randomBlockNumber));
  }
}

contract CLOCK_MODE is BlockNumberClockModeTest {
  function test_ReturnsCorrectClockMode() public view {
    assertEq(blockNumberClockMode.CLOCK_MODE(), "mode=blocknumber&from=default");
  }
}

contract CLOCK_MODE_Revert is BlockNumberClockModeTest {
  function test_RevertIf_ClockInconsistent() public {
    // Set a mock clock value inconsistent with the current block number
    mockBlockNumberClockMode.setMockClock(SafeCast.toUint48(block.number + 1));

    // Expect the ERC6372InconsistentClock error to be reverted
    vm.expectRevert(BlockNumberClockMode.ERC6372InconsistentClock.selector);
    mockBlockNumberClockMode.CLOCK_MODE();
  }
}
