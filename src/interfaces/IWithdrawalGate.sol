// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IWithdrawalGate {
  function initiateWithdrawal(uint256 _amount, address _receiver) external;
}
