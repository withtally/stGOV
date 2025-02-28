// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {BlockNumberClockMode} from "../src/auto-delegates/extensions/BlockNumberClockMode.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract BlockNumberClockModeTest is Test {
  BlockNumberClockMode public blockNumberClockMode;

  function setUp() public {
    blockNumberClockMode = new BlockNumberClockMode();
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
