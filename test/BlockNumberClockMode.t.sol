// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BlockNumberClockMode} from "src/auto-delegates/extensions/BlockNumberClockMode.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

contract BlockNumberClockModeTest is Test {
  BlockNumberClockMode public blockNumberClockMode;

  function setUp() public {
    blockNumberClockMode = new BlockNumberClockMode();
  }

  function testFuzz_ReturnsCurrentBlockNumber(uint256 _randomBlockNumber) public {
    _randomBlockNumber = bound(_randomBlockNumber, 0, type(uint48).max);
    vm.roll(_randomBlockNumber);
    assertEq(blockNumberClockMode.clock(), SafeCast.toUint48(_randomBlockNumber));
  }

  function test_ReturnsClockMode() public view {
    assertEq(blockNumberClockMode.CLOCK_MODE(), "mode=blocknumber&from=default");
  }
}
