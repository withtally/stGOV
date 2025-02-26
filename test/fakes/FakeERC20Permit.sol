// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

/// @dev An ERC20 token that allows for public minting for use in tests.
contract FakeERC20Permit is ERC20Permit, ERC20Votes {
  constructor() ERC20("Fake Token", "FAKE") ERC20Permit("Fake Token") {}

  function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
    ERC20Votes._update(from, to, amount);
  }

  function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
    return Nonces.nonces(owner);
  }

  /// @dev Public mint function useful for testing
  function mint(address _account, uint256 _value) public {
    _mint(_account, _value);
  }
}
