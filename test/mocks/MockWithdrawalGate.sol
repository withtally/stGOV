// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWithdrawalGate} from "src/interfaces/IWithdrawalGate.sol";

contract MockWithdrawalGate is IWithdrawalGate {
  uint256 public lastParam__initiateWithdrawal_amount;
  address public lastParam__initiateWithdrawal_receiver;

  bool public shouldRevertOnNextCall;

  function __setShouldRevertOnNextCall(bool _shouldRevert) external {
    shouldRevertOnNextCall = _shouldRevert;
  }

  function initiateWithdrawal(uint256 _amount, address _receiver) external {
    require(!shouldRevertOnNextCall, "MockWithdrawalGate Revert Requested");
    lastParam__initiateWithdrawal_amount = _amount;
    lastParam__initiateWithdrawal_receiver = _receiver;
  }
}
