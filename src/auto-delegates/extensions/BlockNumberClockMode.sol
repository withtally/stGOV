// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

/// @title BlockNumberClockMode
/// @author [ScopeLift](https://scopelift.co)
/// @notice Implementation of IERC6372 that uses block numbers as the clock.
/// @dev This contract provides block number-based clock functionality for contracts that need block tracking.
contract BlockNumberClockMode is IERC6372 {
  /// @dev Error thrown when the clock is not consistent with clock mode.
  error ERC6372InconsistentClock();

  /// @notice Returns the current block number as the clock value.
  /// @return Current block number cast to uint48.
  function clock() public view virtual returns (uint48) {
    return SafeCast.toUint48(block.number);
  }

  /// @notice Returns a machine-readable string description of the clock mode.
  /// @return String indicating that this contract uses block number mode.
  /// @dev Verifies clock consistency before returning the mode string.
  function CLOCK_MODE() public view virtual returns (string memory) {
    if (clock() != SafeCast.toUint48(block.number)) {
      revert ERC6372InconsistentClock();
    }
    return "mode=blocknumber&from=default";
  }
}
