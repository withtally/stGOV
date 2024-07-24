// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {UniLst} from "src/UniLst.sol";

/// @title WithdrawGate
/// @author ScopeLift
/// @notice A contract to enforce a withdrawal delay for users exiting the LST.
contract WithdrawGate is Ownable {
  /// @notice Thrown when an invalid LST address is provided.
  error WithdrawGate__InvalidLSTAddress();

  /// @notice Thrown when an invalid delay is set.
  error WithdrawGate__InvalidDelay();

  /// @notice The address of the LST contract.
  address public immutable LST;

  /// @notice The address of the token that can be withdrawn.
  address public immutable WITHDRAWAL_TOKEN;

  /// @notice The maximum allowed delay for withdrawals.
  uint256 public constant DELAY_MAX = 30 days;

  /// @notice Emitted when the delay period is set.
  event DelaySet(uint256 oldDelay, uint256 newDelay);

  /// @notice The current delay period for withdrawals.
  uint256 public delay;

  /// @notice Initializes the WithdrawGate contract.
  /// @param _owner The address that will own this contract.
  /// @param _lst The address of the LST contract.
  /// @param _initialDelay The initial withdrawal delay period.
  constructor(address _owner, address _lst, uint256 _initialDelay) Ownable(_owner) {
    if (_lst == address(0)) {
      revert WithdrawGate__InvalidLSTAddress();
    }
    if (_initialDelay > DELAY_MAX) {
      revert WithdrawGate__InvalidDelay();
    }

    LST = _lst;
    WITHDRAWAL_TOKEN = address(UniLst(_lst).STAKE_TOKEN());
    delay = _initialDelay;
  }

  /// @notice Sets a new delay period for withdrawals.
  /// @param _newDelay The new delay period to set.
  /// @dev Only the contract owner can call this function.
  /// @dev Reverts if the new delay exceeds DELAY_MAX.
  function setDelay(uint256 _newDelay) external {
    _checkOwner();
    if (_newDelay > DELAY_MAX) {
      revert WithdrawGate__InvalidDelay();
    }

    uint256 _oldDelay = delay;

    emit DelaySet(_oldDelay, _newDelay);
    delay = _newDelay;
  }
}
