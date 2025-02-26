// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title FixedLstAddressAlias
/// @author [ScopeLift](https://scopelift.co)
/// @notice Library code for calculating the alias of an address.
library FixedLstAddressAlias {
  /// @notice The constant value that is added to an existing address to calculate its offset.
  uint160 public constant ALIAS_OFFSET = 0x010101;

  /// @notice Calculates the alias of a given address by adding a fixed constant to it.
  /// @param _account The address for which the alias will be calculated.
  /// @return _alias The calculated alias of the address provided.
  function fixedAlias(address _account) internal pure returns (address _alias) {
    /// Overflow is desireable as addresses that are close to 0xFF...FF will overflow to a lower alias address.
    unchecked {
      _alias = address(uint160(_account) + ALIAS_OFFSET);
    }
  }
}
