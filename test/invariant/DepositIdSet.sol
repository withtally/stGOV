// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.23;

import {Staker} from "staker/Staker.sol";

struct DepositIdSet {
  Staker.DepositIdentifier[] ids;
  mapping(Staker.DepositIdentifier => bool) saved;
}

library LibDepositIdSet {
  function add(DepositIdSet storage s, Staker.DepositIdentifier id) internal {
    if (!s.saved[id]) {
      s.ids.push(id);
      s.saved[id] = true;
    }
  }

  function contains(DepositIdSet storage s, Staker.DepositIdentifier id) internal view returns (bool) {
    return s.saved[id];
  }

  function count(DepositIdSet storage s) internal view returns (uint256) {
    return s.ids.length;
  }

  function rand(DepositIdSet storage s, uint256 seed) internal view returns (Staker.DepositIdentifier) {
    if (s.ids.length > 0) {
      return s.ids[seed % s.ids.length];
    } else {
      return Staker.DepositIdentifier.wrap(0);
    }
  }

  function forEach(DepositIdSet storage s, function(Staker.DepositIdentifier) external func) internal {
    for (uint256 i; i < s.ids.length; ++i) {
      func(s.ids[i]);
    }
  }

  function reduce(
    DepositIdSet storage s,
    uint256 acc,
    function(uint256,Staker.DepositIdentifier) external returns (uint256) func
  ) internal returns (uint256) {
    for (uint256 i; i < s.ids.length; ++i) {
      acc = func(acc, s.ids[i]);
    }
    return acc;
  }
}
