// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract FakeERC1271Wallet {
  address public owner;

  constructor(address _owner) {
    owner = _owner;
  }

  function isValidSignature(bytes32 _hash, bytes memory _signature) public view returns (bytes4) {
    address signer = ECDSA.recover(_hash, _signature);
    if (signer == owner) {
      return 0x1626ba7e; // Magic value for ERC1271
    } else {
      return 0xffffffff;
    }
  }
}
