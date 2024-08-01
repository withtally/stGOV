// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {UniLst} from "src/UniLst.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

/// @title WithdrawGate
/// @author ScopeLift
/// @notice A contract to enforce a withdrawal delay for users exiting the LST.
contract WithdrawGate is Ownable {
  /// @notice Thrown when an invalid LST address is provided.
  error WithdrawGate__InvalidLSTAddress();

  /// @notice Thrown when an invalid delay is set.
  error WithdrawGate__InvalidDelay();

  /// @notice Thrown when the caller is not the LST.
  error WithdrawGate__CallerNotLST();

  /// @notice Thrown when the withdrawal is not found.
  error WithdrawGate__WithdrawalNotFound();

  /// @notice Thrown when the withdrawal is not yet eligible.
  error WithdrawGate__WithdrawalNotEligible();

  /// @notice Thrown when the caller is not the designated receiver.
  error WithdrawGate__CallerNotReceiver();

  /// @notice Thrown when the receiver address is not valid.
  error WithdrawGate__InvalidReceiver();

  /// @notice The address of the LST contract.
  address public immutable LST;

  /// @notice The address of the token that can be withdrawn, assumed to revert on failed transfers.
  address public immutable WITHDRAWAL_TOKEN;

  /// @notice The maximum allowed delay for withdrawals.
  uint256 public constant DELAY_MAX = 30 days;

  /// @notice The current delay period for withdrawals.
  uint256 public delay;

  /// @notice A struct to store withdrawal information.
  struct Withdrawal {
    address receiver;
    uint256 amount;
    uint256 eligibleTimestamp;
    bool completed;
  }

  /// @notice Mapping from withdrawal identifier to Withdrawal struct.
  mapping(uint256 withdrawId => Withdrawal withdrawal) public withdrawals;

  /// @notice Counter for generating unique withdrawal identifiers.
  uint256 internal nextWithdrawalId;

  /// @notice Emitted when the delay period is set.
  event DelaySet(uint256 oldDelay, uint256 newDelay);

  /// @notice Emitted when a withdrawal is initiated.
  event WithdrawalInitiated(uint256 amount, address receiver, uint256 eligibleTimestamp, uint256 identifier);

  /// @notice Emitted when a withdrawal is completed.
  event WithdrawalCompleted(uint256 identifier, address receiver, uint256 amount);

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
    nextWithdrawalId = 1;
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

  /// @notice Initiates a withdrawal for a user.
  /// @param _amount The amount of tokens to withdraw.
  /// @param _receiver The address that will receive the tokens.
  /// @return _identifier The unique identifier for this withdrawal.
  /// @dev Can only be called by the LST contract.
  /// @dev Assumes the WITHDRAW_TOKENs have already been transferred to this contract.
  function initiateWithdrawal(uint256 _amount, address _receiver) external returns (uint256 _identifier) {
    if (msg.sender != LST) {
      revert WithdrawGate__CallerNotLST();
    }
    if (_receiver == address(0)) {
      revert WithdrawGate__InvalidReceiver();
    }

    _identifier = nextWithdrawalId++;
    uint256 _eligibleTimestamp = block.timestamp + delay;

    withdrawals[_identifier] =
      Withdrawal({receiver: _receiver, amount: _amount, eligibleTimestamp: _eligibleTimestamp, completed: false});

    emit WithdrawalInitiated(_amount, _receiver, _eligibleTimestamp, _identifier);
  }

  /// @notice Completes a previously initiated withdrawal.
  /// @param _identifier The unique identifier of the withdrawal to complete.
  function completeWithdrawal(uint256 _identifier) external {
    Withdrawal storage withdrawal = withdrawals[_identifier];

    if (nextWithdrawalId < _identifier) {
      revert WithdrawGate__WithdrawalNotFound();
    }
    if (msg.sender != withdrawal.receiver) {
      revert WithdrawGate__CallerNotReceiver();
    }
    if (block.timestamp < withdrawal.eligibleTimestamp) {
      revert WithdrawGate__WithdrawalNotEligible();
    }
    if (withdrawal.completed) {
      revert WithdrawGate__WithdrawalNotFound();
    }

    withdrawal.completed = true;

    // This transfer assumes WITHDRAWAL_TOKEN will revert if the transfer fails.
    IERC20(WITHDRAWAL_TOKEN).transfer(withdrawal.receiver, withdrawal.amount);

    emit WithdrawalCompleted(_identifier, withdrawal.receiver, withdrawal.amount);
  }

  /// @notice Gets the next withdrawal identifier.
  /// @return The next withdrawal identifier.
  function getNextWithdrawalId() external view returns (uint256) {
    return nextWithdrawalId;
  }
}
