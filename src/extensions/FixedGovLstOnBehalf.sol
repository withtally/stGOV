// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {FixedGovLst} from "../FixedGovLst.sol";
import {Staker} from "staker/Staker.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title FixedGovLstOnBehalf
/// @author [ScopeLift](https://scopelift.co)
/// @notice This contract extension adds signature execution functionality to the FixedGovLstOnBehalf
/// base contract, allowing key operations to be executed via signatures rather than requiring the
/// owner or claimer to execute transactions directly. This includes staking, unstaking, converting to and from the
/// rebasing LST, and altering the holder's delegatee via updating the LST owned deposit in which their tokens are
/// held. Each operation requires a unique signature that is validated against the appropriate signer before
/// execution.
abstract contract FixedGovLstOnBehalf is FixedGovLst {
  /// @notice Type hash used when encoding data for `updateDepositOnBehalf` calls.
  bytes32 public constant UPDATE_DEPOSIT_TYPEHASH =
    keccak256("UpdateDeposit(address account,uint256 depositId,uint256 nonce,uint256 deadline)");

  /// @notice Type hash used when encoding data for `stakeOnBehalf` calls.
  bytes32 public constant STAKE_TYPEHASH =
    keccak256("Stake(address account,uint256 amount,uint256 nonce,uint256 deadline)");

  /// @notice Type hash used when encoding data for `convertToFixedOnBehalf` calls.
  bytes32 public constant CONVERT_TO_FIXED_TYPEHASH =
    keccak256("ConvertToFixed(address account,uint256 amount,uint256 nonce,uint256 deadline)");

  /// @notice Type hash used when encoding data for `convertToRebasingOnBehalf` calls.
  bytes32 public constant CONVERT_TO_REBASING_TYPEHASH =
    keccak256("ConvertToRebasing(address account,uint256 amount,uint256 nonce,uint256 deadline)");

  /// @notice Type hash used when encoding data for `unstakeOnBehalf` calls.
  bytes32 public constant UNSTAKE_TYPEHASH =
    keccak256("Unstake(address account,uint256 amount,uint256 nonce,uint256 deadline)");

  /// @notice Type hash used when encoding data for `rescueOnBehalf` calls.
  bytes32 public constant RESCUE_TYPEHASH = keccak256("Rescue(address account,uint256 nonce,uint256 deadline)");

  /// @notice Updates the deposit identifier for an account using a signed message for authorization. The deposit
  /// identifier determines which delegatee receives the voting weight of the account's staked tokens.
  /// @param _account The address of the account whose deposit identifier is being updated.
  /// @param _newDepositId The new deposit identifier to associate with the account. Must be a deposit owned by the
  /// rebasing LST. The underlying tokens staked in the fixed LST will be moved into this deposit.
  /// @param _nonce The nonce being consumed by this operation to prevent replay attacks.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _signature The signed message authorizing this deposit update, signed by the account.
  function updateDepositOnBehalf(
    address _account,
    Staker.DepositIdentifier _newDepositId,
    uint256 _nonce,
    uint256 _deadline,
    bytes memory _signature
  ) external {
    _validateSignature(
      _account, Staker.DepositIdentifier.unwrap(_newDepositId), _nonce, _deadline, _signature, UPDATE_DEPOSIT_TYPEHASH
    );
    _updateDeposit(_account, _newDepositId);
  }

  /// @notice Stake tokens to receive fixed liquid stake tokens on behalf of a user, using a signature to validate the
  /// user's intent. The staking address must pre-approve the LST contract to spend at least the would-be amount
  /// of tokens.
  /// @param _account The address on behalf of whom the staking is being performed.
  /// @param _amount The quantity of tokens that will be staked.
  /// @param _nonce The nonce being consumed by this operation.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _signature Signature of the user authorizing this stake.
  /// @dev The increase in the holder's balance after staking may be slightly less than the amount staked due to
  /// rounding.
  /// @return The amount of fixed tokens created after staking.
  function stakeOnBehalf(address _account, uint256 _amount, uint256 _nonce, uint256 _deadline, bytes memory _signature)
    external
    returns (uint256)
  {
    _validateSignature(_account, _amount, _nonce, _deadline, _signature, STAKE_TYPEHASH);
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
  /// @return The amount of stake tokens created after unstaking.
  function unstakeOnBehalf(
    address _account,
    uint256 _amount,
    uint256 _nonce,
    uint256 _deadline,
    bytes memory _signature
  ) external returns (uint256) {
    _validateSignature(_account, _amount, _nonce, _deadline, _signature, UNSTAKE_TYPEHASH);
    return _unstake(_account, _amount);
  }

  /// @notice Convert existing rebasing LST tokens to fixed balance LST tokens on behalf of an account.
  /// @param _account The address on behalf of whom the conversion is being performed.
  /// @param _amount The amount of rebasing LST tokens to convert.
  /// @param _nonce The nonce being consumed by this operation.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _signature Signature of the user authorizing this stake.
  /// @return The amount of fixed tokens.
  function convertToFixedOnBehalf(
    address _account,
    uint256 _amount,
    uint256 _nonce,
    uint256 _deadline,
    bytes memory _signature
  ) external returns (uint256) {
    _validateSignature(_account, _amount, _nonce, _deadline, _signature, CONVERT_TO_FIXED_TYPEHASH);
    return _convertToFixed(_account, _amount);
  }

  /// @notice Convert fixed LST tokens to rebasing LST tokens on behalf of an account.
  /// @param _account The address on behalf of whom the conversion is being performed.
  /// @param _amount The amount of fixed LST tokens to convert.
  /// @param _nonce The nonce being consumed by this operation.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _signature Signature of the user authorizing this stake.
  /// @return The amount of rebasing tokens.
  function convertToRebasingOnBehalf(
    address _account,
    uint256 _amount,
    uint256 _nonce,
    uint256 _deadline,
    bytes memory _signature
  ) external returns (uint256) {
    _validateSignature(_account, _amount, _nonce, _deadline, _signature, CONVERT_TO_REBASING_TYPEHASH);
    return _convertToRebasing(_account, _amount);
  }

  /// @notice Save rebasing LST tokens that were mistakenly sent to the fixed holder alias address on behalf of an
  /// account.
  /// @param _account The address on behalf of whom the rescue is being performed.
  /// @param _nonce The nonce being consumed by this operation.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _signature Signature of the user authorizing this stake.
  /// @return The amount of fixed tokens rescued.
  function rescueOnBehalf(address _account, uint256 _nonce, uint256 _deadline, bytes memory _signature)
    external
    returns (uint256)
  {
    _validateSignature(_account, _nonce, _deadline, _signature, RESCUE_TYPEHASH);
    return _rescue(_account);
  }

  /// @notice Internal helper method which reverts with FixedGovLst__SignatureExpired if the signature
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
      revert FixedGovLst__SignatureExpired();
    }
    bytes32 _structHash = keccak256(abi.encode(_typeHash, _account, _amount, _nonce, _deadline));
    bytes32 _hash = _hashTypedDataV4(_structHash);
    if (!SignatureChecker.isValidSignatureNow(_account, _hash, _signature)) {
      revert FixedGovLst__InvalidSignature();
    }
  }

  /// @notice Internal helper method which reverts with FixedGovLst__SignatureExpired if the signature
  /// is invalid.
  /// @param _account The address of the signer.
  /// @param _nonce The nonce being consumed by this operation.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _signature Signature of the user authorizing this stake.
  /// @param _typeHash The typehash being signed over for this operation.
  function _validateSignature(
    address _account,
    uint256 _nonce,
    uint256 _deadline,
    bytes memory _signature,
    bytes32 _typeHash
  ) internal {
    _useCheckedNonce(_account, _nonce);
    if (block.timestamp > _deadline) {
      revert FixedGovLst__SignatureExpired();
    }
    bytes32 _structHash = keccak256(abi.encode(_typeHash, _account, _nonce, _deadline));
    bytes32 _hash = _hashTypedDataV4(_structHash);
    if (!SignatureChecker.isValidSignatureNow(_account, _hash, _signature)) {
      revert FixedGovLst__InvalidSignature();
    }
  }
}
