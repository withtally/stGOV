// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title FixedLstAddressAlias
/// @author [ScopeLift](https://scopelift.co)
/// @notice Library code for calculating the alias of an address.
library FixedLstAddressAlias {
  /// @notice The constant value that is added to an existing address to calculate its offset before it is hashed.
  uint160 public constant ALIAS_OFFSET_SALT = 0x1000010100000110011011010010;

  /// @notice Calculates the alias of a given address by adding a fixed constant and hashing it.
  /// @param _account The address for which the alias will be calculated.
  /// @return _alias The calculated alias of the address provided.
  /// @dev Adding a fixed constant before hashing acts as a kind of "salt", ensuring the address produced is not simply
  /// the keccak256 of the address in question, as this might conflict in some unexpected way with some other
  /// application. At the same time, adding the "salt" to the address, rather than concatenating it, avoids adding
  /// extra bytes to the keccak operation, which would incur additional gas costs.
  function fixedAlias(address _account) internal pure returns (address _alias) {
    /// Overflow is desirable as addresses that are close to 0xFF...FF will overflow to a lower alias address.
    unchecked {
      _alias = address(uint160(uint256(keccak256(abi.encode(uint160(_account) + ALIAS_OFFSET_SALT)))));
    }
  }
}
