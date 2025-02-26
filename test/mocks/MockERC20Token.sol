// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract MockERC20Token {
  address public lastParam__transfer_to;
  uint256 public lastParam__transfer_amount;

  bool public shouldRevertOnNextCall;

  function __setShouldRevertOnNextCall(bool _shouldRevert) external {
    shouldRevertOnNextCall = _shouldRevert;
  }

  function transfer(address _to, uint256 _amount) external returns (bool) {
    require(!shouldRevertOnNextCall, "MockERC20Token Revert Requested");
    lastParam__transfer_amount = _amount;
    lastParam__transfer_to = _to;
    return true;
  }
}
