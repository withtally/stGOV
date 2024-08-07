// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

abstract contract Eip712Helper {
  // EIP-712 constants
  bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  function _domainSeperator(bytes memory _name, bytes memory _version, address _verifyingContract)
    internal
    view
    returns (bytes32)
  {
    return keccak256(
      abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(_name), keccak256(_version), block.chainid, _verifyingContract)
    );
  }
}
