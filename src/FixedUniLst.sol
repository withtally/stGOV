// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UniLst} from "src/UniLst.sol";
import {FixedLstAddressAlias} from "src/FixedLstAddressAlias.sol";
import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {EIP712} from "openzeppelin/utils/cryptography/EIP712.sol";
import {Nonces} from "openzeppelin/utils/Nonces.sol";
import {IUni} from "src/interfaces/IUni.sol";
import {Multicall} from "openzeppelin/utils/Multicall.sol";
import {SignatureChecker} from "openzeppelin/utils/cryptography/SignatureChecker.sol";

/// @title FixedUniLst
/// @author [ScopeLift](https://scopelift.co)
/// @notice This contract creates a fixed balance counterpart LST to the rebasing LST implemented in `UniLst.sol`.
/// In most ways, it can be thought of as a peer to the rebasing LST with a different accounting system. Whereas the
/// rebasing LST token is 1:1 with the underlying governance token, this fixed LST has an exchange rate. Whereas the
/// total supply and holder balances of the rebasing LST token increase automatically as rewards are distributed, this
/// fixed LST token has balances that stay fixed when rewards are distributed. Instead, the exchange rate changes such
/// that the same number of fixed LST tokens are now worth more of the underlying governance tokens.
///
/// While peers in most respects, the fixed LST ultimately hooks into the rebasing LST's accounting system under
/// the hood. One practical effect of this is slightly higher gas costs for operations using the fixed LST. Another
/// effect is that governance tokens staked in the fixed LST show up in the total supply of the of rebasing LST, but
/// not vice versa. In other words, the total supply of the rebasing LST is the sum of tokens staked in the rebasing
/// LST _and_ the fixed LST. The total supply of the fixed LST is isolated to itself. Note that this is *not* true of
/// user balances. A holder's fixed LST balance and rebasing LST balance are independent. All of these accounting
/// properties are effectively the same as the wrapped version of the rebasing LST.
///
/// One very important way in which the fixed LST is different from a wrapped version of the rebasing LST is with
/// regards to delegation. Holders of a wrapped LST tokens are not able to specify their own delegatee, instead all
/// tokens are delegated to the default. Holders of the fixed LST do not have to make this tradeoff. They are able to
/// specify a delegate in the same way as holders of the rebasing LST.
contract FixedUniLst is IERC20, IERC20Metadata, Multicall, EIP712, Nonces {
  using FixedLstAddressAlias for address;

  /// @notice Emitted when a holder updates their deposit identifier, which determines the delegatee of their voting
  /// weight.
  /// @param holder The address of the account updating their deposit.
  /// @param depositId The new deposit identifier that will receive the holder's voting weight.
  event DepositUpdated(address indexed holder, IUniStaker.DepositIdentifier depositId);

  /// @notice Emitted when governance tokens are staked to receive fixed LST tokens.
  /// @param account The address of the account staking tokens.
  /// @param amount The number of governance tokens staked.
  event Staked(address indexed account, uint256 amount);

  /// @notice Emitted when rebasing LST tokens are converted to fixed LST tokens.
  /// @param account The address of the account converting their tokens.
  /// @param amount The number of rebasing LST tokens converted to fixed LST tokens.
  event Fixed(address indexed account, uint256 amount);

  /// @notice Emitted when fixed LST tokens are converted to rebasing LST tokens.
  /// @param account The address of the account converting their tokens.
  /// @param amount The number of rebasing LST tokens received.
  event Unfixed(address indexed account, uint256 amount);

  /// @notice Emitted when fixed LST tokens are unstaked to receive governance tokens.
  /// @param account The address of the account unstaking tokens.
  /// @param amount The number of governance tokens received.
  event Unstaked(address indexed account, uint256 amount);

  /// @notice Emitted when rebasing LST tokens mistakenly sent to a fixed holder alias address are rescued.
  /// @param account The address of the account rescuing their tokens.
  /// @param amount The number of rebasing LST tokens received from the rescue.
  event Rescued(address indexed account, uint256 amount);

  /// @notice Thrown when a holder attempts to transfer more tokens than they hold.
  error FixedUniLst__InsufficientBalance();

  /// @notice Thrown by signature-based "onBehalf" methods when a signature is past its expiry date.
  error FixedUniLst__SignatureExpired();

  /// @notice Thrown by signature-based "onBehalf" methods when a signature is invalid.
  error FixedUniLst__InvalidSignature();

  /// @notice The corresponding rebasing LST token for which this contract serves as a fixed balance counterpart.
  UniLst public immutable LST;

  /// @notice The underlying governance token which is staked.
  IUni public immutable STAKE_TOKEN;

  /// @notice The factor by which scales are multiplied in the underlying rebasing LST.
  uint256 public immutable SHARE_SCALE_FACTOR;

  /// @notice The number of decimals for the fixed LST token.
  uint8 private constant DECIMALS = 18;

  /// @notice The number of rebasing LST shares a given fixed LST token holder controls via their fixed LST holdings.
  /// @dev The fixed LST `balanceOf` the holder is this number scaled down by the `SHARE_SCALE_FACTOR`
  mapping(address _holder => uint256 _balance) private shareBalances;

  /// @notice The total number of rebasing LST shares controlled across all fixed LST token holders.
  /// @dev The fixed LST `totalSupply` is this number scaled down by the `SHARE_SCALE_FACTOR`.
  uint256 private totalShares;

  /// @notice The ERC20 Metadata compliant name of the fixed LST token.
  string public name;

  /// @notice The ERC20 Metadata compliant symbol of the fixed LST token.
  string public symbol;

  /// @notice Type hash used when encoding data for `permit` calls.
  bytes32 public constant PERMIT_TYPEHASH =
    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

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

  /// @notice Mapping used to determine the amount of Fixed LST tokens the spender has been approved to transfer on
  /// the holder's behalf.
  mapping(address holder => mapping(address spender => uint256 amount)) public allowance;

  /// @param _name The name for the fixed balance liquid stake token.
  /// @param _symbol The symbol for the fixed balance liquid stake token.
  /// @param _lst The rebasing LST for which this contract will serve as the fixed balance counterpart.
  constructor(string memory _name, string memory _symbol, UniLst _lst, IUni _stakeToken, uint256 _shareScaleFactor)
    EIP712("FixedUniLst", "1")
  {
    name = _name;
    symbol = _symbol;
    LST = _lst;
    SHARE_SCALE_FACTOR = _shareScaleFactor;
    STAKE_TOKEN = _stakeToken;
  }

  /// @notice The decimal precision with which the fixed LST token stores its balances.
  function decimals() external pure returns (uint8) {
    return DECIMALS;
  }

  /// @notice The balance of the holder in fixed LST tokens. Unlike the rebasing LST, this balance is stable even as
  /// rewards accrue. As a result, a fixed LST token does not map 1:1 with the balance of the underlying staked tokens.
  /// Instead, the holder's fixed LST balance remains the same, but the number of stake tokens he would receive if he
  /// were to unstake increases.
  /// @param _holder The account whose balance is being queried.
  /// @return The balance of the holder in fixed tokens.
  function balanceOf(address _holder) public view returns (uint256) {
    return _scaleDown(shareBalances[_holder]);
  }

  /// @notice The total number of fixed LST tokens in existence. As with a holder's balance, this number does not
  /// change when rewards are distributed.
  function totalSupply() public view returns (uint256) {
    return _scaleDown(totalShares);
  }

  /// @notice Sets the delegatee which will receive the voting weight of the caller's tokens staked in the fixed LST
  /// by specifying the deposit identifier associated with that delegatee.
  /// @param _newDepositId The identifier of a deposit which must be one owned by the rebasing LST. Underlying tokens
  /// staked in the fixed LST will be moved into this deposit.
  function updateDeposit(IUniStaker.DepositIdentifier _newDepositId) public {
    _updateDeposit(msg.sender, _newDepositId);
  }

  /// @notice Stake tokens and receive fixed balance LST tokens directly.
  /// @param _stakeTokens The number of governance tokens that will be staked.
  /// @return _fixedTokens The number of fixed balance LST tokens received upon staking. These tokens are *not*
  /// exchanged 1:1 with the stake tokens.
  /// @dev The caller must approve *the rebasing LST contract* to transfer at least the number of stake tokens being
  /// staked before calling this method. This is different from a typical experience, where one would expect to approve
  /// the address on which the `stake` method was being called.
  function stake(uint256 _stakeTokens) public returns (uint256) {
    return _stake(msg.sender, _stakeTokens);
  }

  /// @notice Convert existing rebasing LST tokens to fixed balance LST tokens.
  /// @param _lstTokens The number of rebasing LST tokens that will be converted to fixed balance LST tokens.
  /// @return _fixedTokens The number of fixed balance LST tokens received upon fixing. These tokens are *not*
  /// exchanged 1:1 with the stake tokens.
  function convertToFixed(uint256 _lstTokens) external returns (uint256) {
    return _convertToFixed(msg.sender, _lstTokens);
  }

  /// @notice Move fixed LST tokens held by the caller to another account.
  /// @param _to The address that will receive the transferred tokens.
  /// @param _fixedTokens The number of tokens to send.
  /// @return Whether the transfer was successful or not.
  /// @dev This method will always return true. It reverts in conditions where the transfer was not successful.
  function transfer(address _to, uint256 _fixedTokens) external returns (bool) {
    _transfer(msg.sender, _to, _fixedTokens);
    return true;
  }

  /// @notice Move fixed LST tokens from one account to another, where the sender has provided an allowance to move
  /// tokens to the caller.
  /// @param _from The address that will send the transferred tokens.
  /// @param _to The address that will receive the transferred tokens.
  /// @param _fixedTokens The number of tokens to transfer.
  /// @return Whether the transfer was successful or not.
  /// @dev This method will always return true. It reverts in conditions where the transfer was not successful.
  function transferFrom(address _from, address _to, uint256 _fixedTokens) external returns (bool) {
    _checkAndUpdateAllowance(_from, _fixedTokens);
    _transfer(_from, _to, _fixedTokens);
    return true;
  }

  /// @notice Convert fixed LST tokens to rebasing LST tokens.
  /// @param _fixedTokens The number of fixed LST tokens to convert.
  /// @return _lstTokens The number of rebasing LST tokens received.
  function convertToRebasing(uint256 _fixedTokens) external returns (uint256) {
    return _convertToRebasing(msg.sender, _fixedTokens);
  }

  /// @notice Unstake fixed LST tokens and receive underlying staked tokens back. If a withdrawal delay is being
  /// enforced by the rebasing LST, tokens will be moved into the withdrawal gate.
  /// @param _fixedTokens The number of fixed LST tokens to unstake.
  /// @return _stakeTokens The number of underlying governance tokens received in exchange.
  function unstake(uint256 _fixedTokens) external returns (uint256 _stakeTokens) {
    return _unstake(msg.sender, _fixedTokens);
  }

  /// @notice Allow a depositor to change the address they are delegating their staked tokens.
  /// @param _delegatee The address where voting is delegated.
  function delegate(address _delegatee) public virtual {
    IUniStaker.DepositIdentifier _depositId = LST.fetchOrInitializeDepositForDelegatee(_delegatee);
    updateDeposit(_depositId);
  }

  function delegates(address _holder) external virtual returns (address) {
    return LST.delegateeForHolder(_holder.fixedAlias());
  }

  /// @notice Save rebasing LST tokens that were mistakenly sent to the fixed holder alias address. Each fixed LST
  /// holder has an alias in the rebasing LST contract that manages the fixed holder's position. This alias is purely
  /// an implementation detail of the system, and not meant to be interacted with my regular users in anyway. However,
  /// if the holder of the rebasing LST token mistakenly sends tokens to a fixed LST alias address, this method allows
  /// the receiver of those tokens to reclaim them as part of their balance here in the LST.
  /// @return _fixedTokens The number of fixed LST tokens rescued by reclaiming rebasing LST tokens sent the caller's
  /// alias address.
  function rescue() external returns (uint256 _fixedTokens) {
    return _rescue(msg.sender);
  }

  /// @notice Grant an allowance to the spender to transfer up to a certain amount of fixed LST tokens on behalf of the
  /// message sender.
  /// @param _spender The address which is granted the allowance to transfer from the message sender.
  /// @param _amount The total amount of the message sender's fixed LST tokens that the spender will be permitted to
  /// transfer.
  function approve(address _spender, uint256 _amount) external virtual returns (bool) {
    allowance[msg.sender][_spender] = _amount;
    emit Approval(msg.sender, _spender, _amount);
    return true;
  }

  /// @notice Grant an allowance to the spender to transfer up to a certain amount of fixed LST tokens on behalf of a
  /// user who has signed a message testifying to their intent to grant this allowance.
  /// @param _owner The account which is granting the allowance.
  /// @param _spender The address which is granted the allowance to transfer from the holder.
  /// @param _value The total amount of fixed LST tokens the spender will be permitted to transfer from the holder.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _v ECDSA signature component: Parity of the `y` coordinate of point `R`
  /// @param _r ECDSA signature component: x-coordinate of `R`
  /// @param _s ECDSA signature component: `s` value of the signature
  function permit(address _owner, address _spender, uint256 _value, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
    external
    virtual
  {
    if (block.timestamp > _deadline) {
      revert FixedUniLst__SignatureExpired();
    }

    bytes32 _structHash;
    // Unchecked because the only math done is incrementing
    // the owner's nonce which cannot realistically overflow.
    unchecked {
      _structHash = keccak256(abi.encode(PERMIT_TYPEHASH, _owner, _spender, _value, _useNonce(_owner), _deadline));
    }

    bytes32 _hash = _hashTypedDataV4(_structHash);

    address _recoveredAddress = ecrecover(_hash, _v, _r, _s);

    if (_recoveredAddress == address(0) || _recoveredAddress != _owner) {
      revert FixedUniLst__InvalidSignature();
    }

    allowance[_recoveredAddress][_spender] = _value;

    emit Approval(_owner, _spender, _value);
  }

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
    IUniStaker.DepositIdentifier _newDepositId,
    uint256 _nonce,
    uint256 _deadline,
    bytes memory _signature
  ) external {
    _validateSignature(
      _account,
      IUniStaker.DepositIdentifier.unwrap(_newDepositId),
      _nonce,
      _deadline,
      _signature,
      UPDATE_DEPOSIT_TYPEHASH
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

  /// @notice Stake tokens to receive fixed liquid stake tokens. Before the staking operation occurs, a signature is
  /// passed to the token contract's permit method to spend the would-be staked amount of the token.
  /// @param _amount The quantity of fixed tokens that will be staked.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _v ECDSA signature component: Parity of the `y` coordinate of point `R`
  /// @param _r ECDSA signature component: x-coordinate of `R`
  /// @param _s ECDSA signature component: `s` value of the signature
  /// @return The number of fixed tokens after staking.
  function permitAndStake(uint256 _amount, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
    public
    returns (uint256)
  {
    try STAKE_TOKEN.permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s) {} catch {}
    return stake(_amount);
  }

  /// @notice Internal convenience method which performs transfer operations.
  /// @dev This method must only be called after proper authorization has been completed.
  /// @dev See public transfer methods for additional documentation.
  function _transfer(address _from, address _to, uint256 _fixedTokens) internal virtual {
    if (balanceOf(_from) < _fixedTokens) {
      revert FixedUniLst__InsufficientBalance();
    }

    (uint256 _senderShares, uint256 _receiverShares) = LST.transferFixed(_from, _to, _scaleUp(_fixedTokens));
    shareBalances[_from] -= _senderShares;
    shareBalances[_to] += _receiverShares;

    emit IERC20.Transfer(_from, _to, _fixedTokens);
  }

  /// @notice Internal helper method for updating the deposit identifier associated with a holder's account.
  /// @dev The deposit identifier determines which delegatee receives the voting weight of the holder's staked tokens.
  /// @param _newDepositId The identifier of a deposit which must be one owned by the rebasing LST. Underlying tokens
  /// staked in the fixed LST will be moved into this deposit.
  function _updateDeposit(address _account, IUniStaker.DepositIdentifier _newDepositId) internal virtual {
    LST.updateFixedDeposit(_account, _newDepositId);
    emit DepositUpdated(_account, _newDepositId);
  }

  /// @notice Internal convenience method which performs the stake operation.
  /// @param _account The account to perform the stake action.
  /// @param _stakeTokens The amount of governance tokens to stake.
  /// @return The number of fixed tokens after staking.
  function _stake(address _account, uint256 _stakeTokens) internal virtual returns (uint256) {
    // Send the stake tokens to the LST.
    STAKE_TOKEN.transferFrom(_account, address(LST), _stakeTokens);
    uint256 _shares = LST.stakeAndConvertToFixed(_account, _stakeTokens);
    shareBalances[_account] += _shares;
    totalShares += _shares;
    uint256 _fixedTokens = _scaleDown(_shares);
    emit IERC20.Transfer(address(0), _account, _fixedTokens);
    emit Staked(_account, _stakeTokens);
    return _fixedTokens;
  }

  /// @notice Internal convenience method which performs the unstake operation.
  /// @param _account The account to perform the unstake action.
  /// @param _amount The amount of fixed tokens to unstake.
  /// @return The number of governance tokens after unstaking.
  function _unstake(address _account, uint256 _amount) internal virtual returns (uint256) {
    uint256 _shares = _scaleUp(_amount);
    // revert on overflow prevents unfixing more than balance
    shareBalances[_account] -= _shares;
    totalShares -= _shares;
    emit IERC20.Transfer(_account, address(0), _amount);
    uint256 _stakeTokens = LST.convertToRebasingAndUnstake(_account, _shares);
    emit Unstaked(_account, _stakeTokens);
    return _stakeTokens;
  }

  /// @notice Internal convenience method which performs the convert to fixed tokens operation.
  /// @param _account The account to perform the conversion action.
  /// @param _lstTokens The amount of rebasing tokens to convert.
  /// @return The number of fixed tokens.
  function _convertToFixed(address _account, uint256 _lstTokens) internal virtual returns (uint256) {
    uint256 _shares = LST.convertToFixed(_account, _lstTokens);
    shareBalances[_account] += _shares;
    totalShares += _shares;
    uint256 _fixedTokens = _scaleDown(_shares);
    emit IERC20.Transfer(address(0), _account, _fixedTokens);
    emit Fixed(_account, _lstTokens);
    return _fixedTokens;
  }

  /// @notice Internal convenience method which performs the convert to rebasing tokens operation.
  /// @param _account The account to perform the conversion action.
  /// @param _fixedTokens The amount of rebasing tokens to convert.
  /// @return The number of rebasing tokens.
  function _convertToRebasing(address _account, uint256 _fixedTokens) internal virtual returns (uint256) {
    uint256 _shares = _scaleUp(_fixedTokens);
    // revert on overflow prevents unfixing more than balance
    shareBalances[_account] -= _shares;
    totalShares -= _shares;
    emit IERC20.Transfer(_account, address(0), _fixedTokens);
    uint256 _lstTokens = LST.convertToRebasing(_account, _shares);
    emit Unfixed(_account, _lstTokens);
    return _lstTokens;
  }

  /// @notice Internal convenience method which performs the rescue operation.
  /// @param _account The account to perform the rescue action.
  /// @return The number of fixed tokens rescued.
  function _rescue(address _account) internal virtual returns (uint256) {
    // Shares not accounted for inside this Fixed LST accounting system are the ones to rescue.
    uint256 _sharesToRescue = LST.sharesOf(_account.fixedAlias()) - shareBalances[_account];

    // We intentionally scale down then scale up. The method is not intended for reclaiming dust below
    // the precision of the Fixed LST, but only for tokens accidentally sent to the alias address inside
    // the Rebasing LST contract.
    uint256 _fixedTokens = _scaleDown(_sharesToRescue);
    _sharesToRescue = _scaleUp(_fixedTokens);

    shareBalances[_account] += _sharesToRescue;
    totalShares += _sharesToRescue;
    emit IERC20.Transfer(address(0), _account, _fixedTokens);
    uint256 _stakeTokens = LST.stakeForShares(_sharesToRescue);
    emit Rescued(_account, _stakeTokens);
    return _fixedTokens;
  }

  /// @notice Internal helper that updates the allowance of the from address for the message sender, and reverts if the
  /// message sender does not have sufficient allowance.
  /// @param _from The address for which the message sender's allowance should be checked & updated.
  /// @param _fixedTokens The amount of the allowance to check and decrement.
  function _checkAndUpdateAllowance(address _from, uint256 _fixedTokens) internal {
    uint256 allowed = allowance[_from][msg.sender];
    if (allowed != type(uint256).max) {
      allowance[_from][msg.sender] = allowed - _fixedTokens;
    }
  }

  /// @notice Internal helper that converts fixed LST tokens up to rebasing LST shares.
  /// @param _fixedTokens The number of fixed LST tokens.
  /// @return _lstShares The number of LST shares.
  function _scaleUp(uint256 _fixedTokens) internal view returns (uint256 _lstShares) {
    _lstShares = _fixedTokens * SHARE_SCALE_FACTOR;
  }

  /// @notice Internal helper that converts rebasing LST shares down to fixed LST tokens
  /// @param _lstShares The number of LST shares.
  /// @return _fixedTokens The number of fixed LST tokens.
  function _scaleDown(uint256 _lstShares) internal view returns (uint256 _fixedTokens) {
    _fixedTokens = _lstShares / SHARE_SCALE_FACTOR;
  }

  /// @notice Internal helper method which reverts with FixedUniLst__SignatureExpired if the signature
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
      revert FixedUniLst__SignatureExpired();
    }
    bytes32 _structHash = keccak256(abi.encode(_typeHash, _account, _amount, _nonce, _deadline));
    bytes32 _hash = _hashTypedDataV4(_structHash);
    if (!SignatureChecker.isValidSignatureNow(_account, _hash, _signature)) {
      revert FixedUniLst__InvalidSignature();
    }
  }

  /// @notice Internal helper method which reverts with FixedUniLst__SignatureExpired if the signature
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
      revert FixedUniLst__SignatureExpired();
    }
    bytes32 _structHash = keccak256(abi.encode(_typeHash, _account, _nonce, _deadline));
    bytes32 _hash = _hashTypedDataV4(_structHash);
    if (!SignatureChecker.isValidSignatureNow(_account, _hash, _signature)) {
      revert FixedUniLst__InvalidSignature();
    }
  }
}
