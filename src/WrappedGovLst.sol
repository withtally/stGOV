// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GovLst} from "./GovLst.sol";
import {Staker} from "staker/Staker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedGovLst} from "./FixedGovLst.sol";

/// @title WrappedGovLst
/// @author [ScopeLift](https://scopelift.co)
/// @notice A wrapper contract for the liquid stake token. Whereas the LST is a rebasing token, the wrapper token
/// has a fixed balance. While the balance is fixed, it is not 1:1 with the underlying token. As rewards are
/// distributed to the LST contracts, the amount of liquid staked tokens that 1 wrapped token can be exchanged for
/// increases. The voting weight for all tokens held by a given wrapper deployment is assigned to a singled delegatee,
/// which is controlled by the wrapper's owner.
contract WrappedGovLst is ERC20Permit, Ownable {
  /// @notice Emitted when a holder wraps liquid stake tokens.
  event Wrapped(address indexed holder, uint256 lstAmount, uint256 wrappedAmount);

  /// @notice Emitted when a holder unwraps liquid stake tokens.
  event Unwrapped(address indexed holder, uint256 lstAmount, uint256 wrappedAmount);

  /// @notice Emitted when the wrapper's owner updates the delegatee to which wrapped tokens voting weight is assigned.
  event DelegateeSet(address indexed oldDelegatee, address indexed newDelegatee);

  /// @notice Emitted when a holder tries to wrap or unwrap 0 liquid stake tokens.
  error WrappedGovLst__InvalidAmount();

  /// @notice The address of the LST contract which will be wrapped.
  GovLst public immutable LST;

  FixedGovLst public immutable FIXED_LST;

  /// @notice Local copy of the LST's scale factor that is stored at deployment for use in wrapper calculations.
  uint256 internal immutable SHARE_SCALE_FACTOR;

  /// @notice The Staker deposit identifier which holds the wrapper's underlying tokens.
  Staker.DepositIdentifier public depositId;

  /// @param _name The name of the wrapper token.
  /// @param _symbol The symbol of the wrapper token.
  /// @param _lst The contract of the liquid stake token being wrapped.
  /// @param _delegatee The initial delegatee to whom the wrapper's voting weight will be delegated.
  /// @param _initialOwner The initial owner of the wrapper contract.
  constructor(string memory _name, string memory _symbol, GovLst _lst, address _delegatee, address _initialOwner)
    ERC20Permit(_name)
    ERC20(_name, _symbol)
    Ownable(_initialOwner)
  {
    LST = _lst;
    FIXED_LST = _lst.FIXED_LST();
    SHARE_SCALE_FACTOR = _lst.SHARE_SCALE_FACTOR();
    _setDelegatee(_delegatee);
  }

  /// @notice The address of the delegatee to which the wrapped token's voting weight is currently delegated.
  function delegatee() public view virtual returns (address) {
    return LST.delegateeForHolder(address(this));
  }

  /// @notice Deposit liquid stake tokens and receive wrapped tokens in exchange.
  /// @param _lstAmountToWrap The quantity of liquid stake tokens to wrap.
  /// @return _wrappedAmount The quantity of wrapped tokens issued to the caller.
  /// @dev The caller must approve at least the amount of tokens to wrap on the lst contract before calling. Amount to
  /// wrap may not be zero.
  /// TODO: Rename wrapped rebasing
  function wrap(uint256 _lstAmountToWrap) external virtual returns (uint256 _wrappedAmount) {
    if (_lstAmountToWrap == 0) {
      revert WrappedGovLst__InvalidAmount();
    }

    LST.transferFrom(msg.sender, address(this), _lstAmountToWrap);
    // TODO: Add control flow for the off by 1 error
    // I think this should error in the tests
    FIXED_LST.convertToFixed(_lstAmountToWrap);
    // The fixed tokens are already scaled appropriately, so we just mint the same amount of wrapped tokens
    _wrappedAmount = previewWrapRebasing(_lstAmountToWrap);
    _mint(msg.sender, _wrappedAmount);

    emit Wrapped(msg.sender, _lstAmountToWrap, _wrappedAmount);
  }

  // Everything converts to the rebasing
  // can convert out to different things
  // Must approve to FIXED_LST
  function wrapUnderlying(uint256 _stakeTokensToWrap) public virtual returns (uint256) {
    if (_stakeTokensToWrap == 0) {
      revert WrappedGovLst__InvalidAmount();
    }

    // uint256 _initialShares = FIXED_LST.balanceOf(address(this));
	uint256 _wrappedAmount = previewWrapUnderlying(_stakeTokensToWrap);
    FIXED_LST.stake(_stakeTokensToWrap);
    // uint256 _wrappedAmount = (FIXED_LST.balanceOf(address(this)) - ) / SHARE_SCALE_FACTOR;
    return _wrappedAmount;
  }

  function wrapFixed(uint256 _fixedTokensToWrap) external virtual returns (uint256) {
    if (_fixedTokensToWrap == 0) {
      revert WrappedGovLst__InvalidAmount();
    }

    uint256 _initialShares = FIXED_LST.balanceOf(address(this));
    FIXED_LST.transferFrom(msg.sender, address(this), _fixedTokensToWrap);
    uint256 _wrappedAmount = (FIXED_LST.balanceOf(address(this)) - _initialShares) / SHARE_SCALE_FACTOR;
    return _wrappedAmount;
  }

  function previewWrapRebasing(uint256 _stakeTokensToWrap) internal virtual returns (uint256) {
    // LST transfer
    // - Get the shares for stake
    uint256 _shares = _calcSharesForStakeUp(_stakeTokensToWrap);
    // - Convert the shares to stake
    uint256 _convertedStake = _calcStakeForShares(_shares);
    // - Calculate shares with rounding up from stake
    uint256 _finalShares = _calcSharesForStakeUp(_convertedStake);
    // Than rebase
    return _finalShares;
  }

  // TODO: Does this cause rounding issues
  function previewWrapUnderlying(uint256 _stakeTokensToWrap) internal virtual returns (uint256) {
    // This may round up up by 1 wei. The preview
    // MUST return as close to and no more than the exact amount
    // We subtract 1 to always be over the number the of shares
    //
    // This can round up the shares,but on stake the shares are not rounded up
    // Shares are rounded down
    if (LST.totalSupply() == 0) {
      return SHARE_SCALE_FACTOR * _stakeTokensToWrap;
    }

    uint256 _sharesForUnderlying = (_stakeTokensToWrap * LST.totalShares()) / LST.totalSupply();
    return _sharesForUnderlying;
  }

  function previewWrapFixed(uint256 _fixedTokensToWrap) external virtual returns (uint256) {
    uint256 _stake = _calcStakeForShares(_fixedTokensToWrap);
    uint256 _shares = _calcSharesForStakeUp(_stake);
    return _shares;
  }

  function _calcStakeForShares(uint256 _shares) internal virtual returns (uint256) {
    if (LST.totalShares() == 0) {
      return _shares / SHARE_SCALE_FACTOR;
    }

    return (_shares * LST.totalSupply()) / LST.totalShares();
  }

  function _calcSharesForStakeUp(uint256 _amount) internal virtual returns (uint256) {
    if (LST.totalSupply() == 0) {
      return SHARE_SCALE_FACTOR * _amount;
    }

    uint256 _result = (_amount * LST.totalShares()) / LST.totalSupply();

    if (mulmod(_amount, LST.totalShares(), LST.totalSupply()) > 0) {
      _result += 1;
    }

    return _result;
  }

  /// @notice Burn wrapped tokens to receive liquid stake tokens in return.
  /// @param _wrappedAmount The quantity of wrapped tokens to burn.
  /// @return _lstAmountUnwrapped The quantity of liquid staked tokens received in exchange for the wrapped tokens.
  /// @dev The caller must approve at least the amount wrapped tokens on the wrapper token contract.
  /// TODO add an unwrap for each LST variant
  function unwrap(uint256 _wrappedAmount) external virtual returns (uint256 _lstAmountUnwrapped) {
    _lstAmountUnwrapped = LST.stakeForShares(_wrappedAmount * SHARE_SCALE_FACTOR);

    if (_lstAmountUnwrapped == 0) {
      revert WrappedGovLst__InvalidAmount();
    }

    // The number of shares moved back to the caller may actually be less than the number specified by the
    // caller. This favors the wrapper contract, which is desired.
    _burn(msg.sender, _wrappedAmount);
    LST.transfer(msg.sender, _lstAmountUnwrapped);
    emit Unwrapped(msg.sender, _lstAmountUnwrapped, _wrappedAmount);
  }

  function unwrapToUnderlying() external virtual {}
  function unwrapToFixed() external virtual {}

  /// @notice Method that can be called only by the owner to update the address to which all the wrapped token's voting
  /// weight will be delegated.
  function setDelegatee(address _newDelegatee) public virtual {
    _checkOwner();
    _setDelegatee(_newDelegatee);
  }

  /// @notice Internal method that sets the deposit identifier for the delegate specified on the LST.
  function _setDelegatee(address _newDelegatee) internal virtual {
    emit DelegateeSet(delegatee(), _newDelegatee);
    depositId = LST.fetchOrInitializeDepositForDelegatee(_newDelegatee);
    LST.updateDeposit(depositId);
  }
}
