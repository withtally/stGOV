// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

/// @title TimestampClockMode
/// @author [ScopeLift](https://scopelift.co)
/// @notice Implementation of IERC6372 that uses block timestamps as the clock.
/// @dev This contract provides timestamp-based clock functionality for contracts that need time tracking.
contract TimestampClockMode is IERC6372 {
  /// @dev Error thrown when the clock is not consistent with clock mode.
  error ERC6372InconsistentClock();

  /// @notice Returns the current timestamp as the clock value.
  /// @return Current block timestamp cast to uint48.
  function clock() public view virtual returns (uint48) {
    return SafeCast.toUint48(block.timestamp);
  }

  /// @notice Returns a machine-readable string description of the clock mode.
  /// @return String indicating that this contract uses timestamp mode.
  /// @dev Verifies clock consistency before returning the mode string.
  function CLOCK_MODE() public view virtual returns (string memory) {
    if (clock() != SafeCast.toUint48(block.timestamp)) {
      revert ERC6372InconsistentClock();
    }
    return "mode=timestamp";
  }
}
