// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {GovLst} from "../GovLst.sol";
import {Staker} from "staker/Staker.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title GovLstOnBehalf
/// @author [ScopeLift](https://scopelift.co)
/// @notice This contract extension adds signature execution functionality to the GovLst
/// base contract, allowing key operations to be executed via signatures rather than requiring the
/// owner or claimer to execute transactions directly. This includes staking, unstaking,
/// and altering the holder's delegatee via updating the LST owned deposit in which their tokens are held.
/// Each operation requires a unique signature that is validated against the appropriate signer before
/// execution.
abstract contract GovLstOnBehalf is GovLst {
  using SafeERC20 for IERC20;

  /// @notice Type hash used when encoding data for `stakeOnBehalf` calls.
  bytes32 public constant STAKE_TYPEHASH =
    keccak256("Stake(address account,uint256 amount,uint256 nonce,uint256 deadline)");

  /// @notice Type hash used when encoding data for `unstakeOnBehalf` calls.
  bytes32 public constant UNSTAKE_TYPEHASH =
    keccak256("Unstake(address account,uint256 amount,uint256 nonce,uint256 deadline)");

  /// @notice Type hash used when encoding data for `updateDepositOnBehalf` calls.
  bytes32 public constant UPDATE_DEPOSIT_TYPEHASH =
    keccak256("UpdateDeposit(address account,uint256 newDepositId,uint256 nonce,uint256 deadline)");

  /// @notice Sets the deposit to which a holder is choosing to assign their staked tokens using a signature to
  /// validate the user's intent.
  /// @param _account The address of the holder whose deposit is being updated.
  /// @param _newDepositId The stake deposit identifier to which this holder's staked tokens will be moved to and
  /// kept in henceforth.
  /// @param _nonce The nonce being consumed by this operation.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _signature Signature of the user authorizing this stake.
  /// @return _oldDepositId The stake deposit identifier which was previously assigned to this holder's staked.
  function updateDepositOnBehalf(
    address _account,
    Staker.DepositIdentifier _newDepositId,
    uint256 _nonce,
    uint256 _deadline,
    bytes memory _signature
  ) external returns (Staker.DepositIdentifier _oldDepositId) {
    _validateSignature(
      _account, Staker.DepositIdentifier.unwrap(_newDepositId), _nonce, _deadline, _signature, UPDATE_DEPOSIT_TYPEHASH
    );
    _oldDepositId = _updateDeposit(_account, _newDepositId);
    _emitDepositUpdatedEvent(_account, _oldDepositId, _newDepositId);
  }

  /// @notice Stake tokens to receive liquid stake tokens on behalf of a user, using a signature to validate the user's
  /// intent. The staking address must pre-approve the LST contract to spend at least the would-be amount of tokens.
  /// @param _account The address on behalf of whom the staking is being performed.
  /// @param _amount The quantity of tokens that will be staked.
  /// @param _nonce The nonce being consumed by this operation.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _signature Signature of the user authorizing this stake.
  /// @dev The increase in the holder's balance after staking may be slightly less than the amount staked due to
  /// rounding.
  /// @return The difference in LST token balance of the account after the stake operation.
  function stakeOnBehalf(address _account, uint256 _amount, uint256 _nonce, uint256 _deadline, bytes memory _signature)
    external
    returns (uint256)
  {
    _validateSignature(_account, _amount, _nonce, _deadline, _signature, STAKE_TYPEHASH);
    // UNI reverts on failure so it's not necessary to check return value.
    STAKE_TOKEN.safeTransferFrom(_account, address(this), _amount);
    _emitStakedEvent(_account, _amount);
    _emitTransferEvent(address(0), msg.sender, _amount);
    return _stake(_account, _amount);
  }

  /// @notice Destroy liquid staked tokens, to receive the underlying token in exchange, on behalf of a user. Use a
  /// signature to validate the user's  intent. Tokens are removed first from the default deposit, if any are present,
  /// then from holder's specified deposit if any are needed.
  /// @param _account The address on behalf of whom the unstaking is being performed.
  /// @param _amount The amount of tokens to unstake.
  /// @param _nonce The nonce being consumed by this operation.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _signature Signature of the user authorizing this stake.
  /// @return The amount of tokens that were withdrawn from the staking contract.
  function unstakeOnBehalf(
    address _account,
    uint256 _amount,
    uint256 _nonce,
    uint256 _deadline,
    bytes memory _signature
  ) external returns (uint256) {
    _validateSignature(_account, _amount, _nonce, _deadline, _signature, UNSTAKE_TYPEHASH);
    _emitUnstakedEvent(_account, _amount);
    _emitTransferEvent(msg.sender, address(0), _amount);
    return _unstake(_account, _amount);
  }

  /// @notice Internal helper method which reverts with GovLst__SignatureExpired if the signature
  /// is invalid.
  /// @param _account The address of the signer.
  /// @param _amount The amount of tokens involved in this operation.
  /// @param _nonce The nonce being consumed by this operation.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _signature Signature of the user authorizing this stake.
  /// @param _typeHash The typehash being signed over for this operation.
  function _validateSignature(
    address _account,
    uint256 _amount,
    uint256 _nonce,
    uint256 _deadline,
    bytes memory _signature,
    bytes32 _typeHash
  ) internal {
    _useCheckedNonce(_account, _nonce);
    if (block.timestamp > _deadline) {
      revert GovLst__SignatureExpired();
    }
    bytes32 _structHash = keccak256(abi.encode(_typeHash, _account, _amount, _nonce, _deadline));
    bytes32 _hash = _hashTypedDataV4(_structHash);
    if (!SignatureChecker.isValidSignatureNow(_account, _hash, _signature)) {
      revert GovLst__InvalidSignature();
    }
  }
}
