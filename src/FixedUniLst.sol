// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UniLst} from "src/UniLst.sol";
import {FixedLstAddressAlias} from "src/FixedLstAddressAlias.sol";
import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

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
contract FixedUniLst is IERC20, IERC20Metadata {
  using FixedLstAddressAlias for address;

  /// @notice Thrown when a holder attempts to transfer more tokens than they hold.
  error FixedUniLst__InsufficientBalance();

  /// @notice The corresponding rebasing LST token for which this contract serves as a fixed balance counterpart.
  UniLst public immutable LST;

  /// @notice The underlying governance token which is staked.
  IERC20 public immutable STAKE_TOKEN;

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

  /// @notice Mapping used to determine the amount of Fixed LST tokens the spender has been approved to transfer on
  /// the holder's behalf.
  mapping(address holder => mapping(address spender => uint256 amount)) public allowance;

  /// @param _name The name for the fixed balance liquid stake token.
  /// @param _symbol The symbol for the fixed balance liquid stake token.
  /// @param _lst The rebasing LST for which this contract will serve as the fixed balance counterpart.
  constructor(string memory _name, string memory _symbol, UniLst _lst, IERC20 _stakeToken, uint256 _shareScaleFactor) {
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
  function updateDeposit(IUniStaker.DepositIdentifier _newDepositId) external {
    LST.updateFixedDeposit(msg.sender, _newDepositId);
  }

  /// @notice Stake tokens and receive fixed balance LST tokens directly.
  /// @param _stakeTokens The number of governance tokens that will be staked.
  /// @return _fixedTokens The number of fixed balance LST tokens received upon staking. These tokens are *not*
  /// exchanged 1:1 with the stake tokens.
  /// @dev The caller must approve *the rebasing LST contract* to transfer at least the number of stake tokens being
  /// staked before calling this method. This is different from a typical experience, where one would expect to approve
  /// the address on which the `stake` method was being called.
  function stake(uint256 _stakeTokens) external returns (uint256 _fixedTokens) {
    // Send the stake tokens to the LST.
    STAKE_TOKEN.transferFrom(msg.sender, address(LST), _stakeTokens);
    uint256 _shares = LST.stakeAndConvertToFixed(msg.sender, _stakeTokens);
    shareBalances[msg.sender] += _shares;
    totalShares += _shares;
    _fixedTokens = _scaleDown(_shares);
    emit IERC20.Transfer(address(0), msg.sender, _fixedTokens);
  }

  /// @notice Convert existing rebasing LST tokens to fixed balance LST tokens.
  /// @param _lstTokens The number of rebasing LST tokens that will be converted to fixed balance LST tokens.
  /// @return _fixedTokens The number of fixed balance LST tokens received upon fixing. These tokens are *not*
  /// exchanged 1:1 with the stake tokens.
  function convertToFixed(uint256 _lstTokens) external returns (uint256 _fixedTokens) {
    uint256 _shares = LST.convertToFixed(msg.sender, _lstTokens);
    shareBalances[msg.sender] += _shares;
    totalShares += _shares;
    _fixedTokens = _scaleDown(_shares);
    emit IERC20.Transfer(address(0), msg.sender, _fixedTokens);
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
  function convertToRebasing(uint256 _fixedTokens) external returns (uint256 _lstTokens) {
    uint256 _shares = _scaleUp(_fixedTokens);
    // revert on overflow prevents unfixing more than balance
    shareBalances[msg.sender] -= _shares;
    totalShares -= _shares;
    emit IERC20.Transfer(msg.sender, address(0), _fixedTokens);
    return LST.convertToRebasing(msg.sender, _shares);
  }

  /// @notice Unstake fixed LST tokens and receive underlying staked tokens back. If a withdrawal delay is being
  /// enforced by the rebasing LST, tokens will be moved into the withdrawal gate.
  /// @param _fixedTokens The number of fixed LST tokens to unstake.
  /// @return _stakeTokens The number of underlying governance tokens received in exchange.
  function unstake(uint256 _fixedTokens) external returns (uint256 _stakeTokens) {
    uint256 _shares = _scaleUp(_fixedTokens);
    // revert on overflow prevents unfixing more than balance
    shareBalances[msg.sender] -= _shares;
    totalShares -= _shares;
    emit IERC20.Transfer(msg.sender, address(0), _fixedTokens);
    return LST.convertToRebasingAndUnstake(msg.sender, _shares);
  }

  /// @notice Save rebasing LST tokens that were mistakenly sent to the fixed holder alias address. Each fixed LST
  /// holder has an alias in the rebasing LST contract that manages the fixed holder's position. This alias is purely
  /// an implementation detail of the system, and not meant to be interacted with my regular users in anyway. However,
  /// if the holder of the rebasing LST token mistakenly sends tokens to a fixed LST alias address, this method allows
  /// the receiver of those tokens to reclaim them as part of their balance here in the LST.
  /// @return _fixedTokens The number of fixed LST tokens rescued by reclaiming rebasing LST tokens sent the caller's
  /// alias address.
  function rescue() external returns (uint256 _fixedTokens) {
    // Shares not accounted for inside this Fixed LST accounting system are the ones to rescue.
    uint256 _sharesToRescue = LST.sharesOf(msg.sender.fixedAlias()) - shareBalances[msg.sender];

    // We intentionally scale down then scale up. The method is not intended for reclaiming dust below
    // the precision of the Fixed LST, but only for tokens accidentally sent to the alias address inside
    // the Rebasing LST contract.
    _fixedTokens = _scaleDown(_sharesToRescue);
    _sharesToRescue = _scaleUp(_fixedTokens);

    shareBalances[msg.sender] += _sharesToRescue;
    totalShares += _sharesToRescue;
    emit IERC20.Transfer(address(0), msg.sender, _fixedTokens);
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
}
