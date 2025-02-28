// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

/// @title WithdrawGate
/// @author ScopeLift
/// @notice A contract to enforce a withdrawal delay for users exiting the LST.
contract WithdrawGate is Ownable, Multicall, EIP712 {
  using SafeERC20 for IERC20;

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

  /// @notice Thrown when the withdrawal has already been completed.
  error WithdrawGate__WithdrawalAlreadyCompleted();

  /// @notice Thrown when the caller is not the designated receiver.
  error WithdrawGate__CallerNotReceiver();

  /// @notice Thrown when the signature is invalid.
  error WithdrawGate__InvalidSignature();

  /// @notice Thrown when the deadline has expired.
  error WithdrawGate__ExpiredDeadline();

  /// @notice The address of the LST contract.
  address public immutable LST;

  /// @notice The address of the token that can be withdrawn, assumed to revert on failed transfers.
  address public immutable WITHDRAWAL_TOKEN;

  /// @notice The maximum allowed delay for withdrawals.
  uint256 public constant DELAY_MAX = 30 days;

  /// @notice The current delay period for withdrawals.
  uint256 public delay;

  /// @notice The EIP-712 typehash for the CompleteWithdrawal struct.
  bytes32 public constant COMPLETE_WITHDRAWAL_TYPEHASH =
    keccak256("CompleteWithdrawal(uint256 identifier,uint256 deadline)");

  /// @notice A struct to store withdrawal information.
  struct Withdrawal {
    address receiver;
    uint96 amount;
    uint256 eligibleTimestamp;
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
  constructor(address _owner, address _lst, address _withdrawalToken, uint256 _initialDelay)
    Ownable(_owner)
    EIP712("WithdrawGate", "1")
  {
    if (_lst == address(0)) {
      revert WithdrawGate__InvalidLSTAddress();
    }
    if (_initialDelay > DELAY_MAX) {
      revert WithdrawGate__InvalidDelay();
    }

    LST = _lst;
    WITHDRAWAL_TOKEN = _withdrawalToken;
    _setDelay(_initialDelay);
    nextWithdrawalId = 1;
  }

  /// @notice Sets a new delay period for withdrawals.
  /// @param _newDelay The new delay period to set.
  /// @dev Only the contract owner can call this function.
  /// @dev Reverts if the new delay exceeds DELAY_MAX.
  function setDelay(uint256 _newDelay) external virtual {
    _checkOwner();
    _setDelay(_newDelay);
  }

  /// @notice Internal function to set the delay period.
  /// @param _newDelay The new delay period to set.
  /// @dev Reverts if the new delay exceeds DELAY_MAX.
  function _setDelay(uint256 _newDelay) internal virtual {
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
  function initiateWithdrawal(uint96 _amount, address _receiver) external virtual returns (uint256 _identifier) {
    if (msg.sender != LST) {
      revert WithdrawGate__CallerNotLST();
    }
    if (_receiver == address(0)) {
      revert WithdrawGate__CallerNotReceiver();
    }

    _identifier = nextWithdrawalId++;
    uint256 _eligibleTimestamp = block.timestamp + delay;

    withdrawals[_identifier] = Withdrawal({receiver: _receiver, amount: _amount, eligibleTimestamp: _eligibleTimestamp});

    emit WithdrawalInitiated(_amount, _receiver, _eligibleTimestamp, _identifier);
  }

  /// @notice Completes a previously initiated withdrawal.
  /// @param _identifier The unique identifier of the withdrawal to complete.
  function completeWithdrawal(uint256 _identifier) external virtual {
    if (nextWithdrawalId <= _identifier) {
      revert WithdrawGate__WithdrawalNotFound();
    }

    Withdrawal memory _withdrawal = withdrawals[_identifier];

    if (msg.sender != _withdrawal.receiver) {
      revert WithdrawGate__CallerNotReceiver();
    }

    _completeWithdrawal(_identifier, _withdrawal);
  }

  /// @notice Completes a previously initiated withdrawal on behalf of the receiver.
  /// @param _deadline The deadline by which the withdrawal must be completed.
  /// @param _identifier The unique identifier of the withdrawal to complete.
  /// @param _signature The EIP-712 or EIP-1271 signature authorizing the withdrawal.
  function completeWithdrawalOnBehalf(uint256 _identifier, uint256 _deadline, bytes memory _signature) external virtual {
    if (nextWithdrawalId <= _identifier) {
      revert WithdrawGate__WithdrawalNotFound();
    }

    Withdrawal memory _withdrawal = withdrawals[_identifier];
    if (block.timestamp > _deadline) {
      revert WithdrawGate__ExpiredDeadline();
    }

    bytes32 _structHash = keccak256(abi.encode(COMPLETE_WITHDRAWAL_TYPEHASH, _identifier, _deadline));
    bool _isValid =
      SignatureChecker.isValidSignatureNow(_withdrawal.receiver, _hashTypedDataV4(_structHash), _signature);
    if (!_isValid) {
      revert WithdrawGate__InvalidSignature();
    }

    _completeWithdrawal(_identifier, _withdrawal);
  }

  /// @notice Internal function to complete a withdrawal.
  /// @param _identifier The unique identifier of the withdrawal to complete.
  /// @param _withdrawal The memory reference to the Withdrawal struct.
  function _completeWithdrawal(uint256 _identifier, Withdrawal memory _withdrawal) internal virtual {
    if (block.timestamp < _withdrawal.eligibleTimestamp || _withdrawal.eligibleTimestamp == 0) {
      revert WithdrawGate__WithdrawalNotEligible();
    }

    // Clear the withdrawal by zeroing the eligibleTimestamp
    withdrawals[_identifier].eligibleTimestamp = 0;

    // This transfer assumes WITHDRAWAL_TOKEN will revert if the transfer fails.
    IERC20(WITHDRAWAL_TOKEN).safeTransfer(_withdrawal.receiver, _withdrawal.amount);

    emit WithdrawalCompleted(_identifier, _withdrawal.receiver, _withdrawal.amount);
  }

  /// @notice Gets the next withdrawal identifier.
  /// @return The next withdrawal identifier.
  function getNextWithdrawalId() external view virtual returns (uint256) {
    return nextWithdrawalId;
  }
}
