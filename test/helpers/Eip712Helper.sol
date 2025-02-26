// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

abstract contract Eip712Helper {
  // EIP-712 constants
  bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
  bytes32 public constant DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

  function _domainSeperator(bytes32 _typeHash, bytes memory _name, bytes memory _version, address _verifyingContract)
    internal
    view
    returns (bytes32)
  {
    if (_typeHash == DOMAIN_TYPEHASH) {
      return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(_name), block.chainid, _verifyingContract));
    } else if (_typeHash == EIP712_DOMAIN_TYPEHASH) {
      return keccak256(
        abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(_name), keccak256(_version), block.chainid, _verifyingContract)
      );
    } else {
      return bytes32(0);
    }
  }
}
