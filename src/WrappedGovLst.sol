// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Staker} from "staker/Staker.sol";

import {FixedGovLst} from "./FixedGovLst.sol";
import {GovLst} from "./GovLst.sol";

/// @title WrappedGovLst
/// @author [ScopeLift](https://scopelift.co)
/// @notice A wrapper contract that provides a non-rebasing interface to liquid stake tokens. The wrapper accepts
/// stake tokens, rebasing LST, or fixed LST tokens. Wrapped tokens maintain 1:1 backing with fixed LST shares,
/// allowing holders to benefit from staking rewards without balance changes and avoid off-by-one rounding issues when
/// transferring tokens. The voting weight for all tokens held by a given wrapper deployment is assigned to a single
/// delegatee, which is controlled by the wrapper's owner.
contract WrappedGovLst is ERC20Permit, Ownable {
  using SafeERC20 for FixedGovLst;

  /// @notice Emitted when a holder wraps rebasing `GovLst` tokens.
  event WrappedRebasing(address indexed holder, uint256 rebasingAmount, uint256 wrappedAmount);

  /// @notice Emitted when a holder wraps fixed `GovLst` tokens.
  event WrappedFixed(address indexed holder, uint256 fixedAmount, uint256 wrappedAmount);

  /// @notice Emitted when a holder wraps underlying `GovLst` tokens.
  event WrappedUnderlying(address indexed holder, uint256 underlyingAmount, uint256 wrappedAmount);

  /// @notice Emitted when a holder unwraps wrapped tokens into rebseing `GovLst` tokens.
  event UnwrapRebasing(address indexed holder, uint256 lstAmount, uint256 wrappedAmount);

  /// @notice Emitted when a holder unwraps wrapped tokens into fixed `GovLst` tokens.
  event UnwrapFixed(address indexed holder, uint256 lstAmount, uint256 wrappedAmount);

  /// @notice Emitted when the wrapper's owner updates the delegatee to which wrapped tokens voting weight is assigned.
  event DelegateeSet(address indexed oldDelegatee, address indexed newDelegatee);

  /// @notice Emitted when a holder tries to wrap or unwrap 0 liquid stake tokens.
  error WrappedGovLst__InvalidAmount();

  /// @notice The address of the LST contract which will be wrapped.
  GovLst public immutable LST;

  /// @notice The address of the FIXED_LST contract which will be wrapped and the asset that backs wrapped tokens 1:1.
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
  /// TODO Pre fund to handle rounding issues
  constructor(string memory _name, string memory _symbol, GovLst _lst, address _delegatee, address _initialOwner, uint256 _preFundWrapped)
    ERC20Permit(_name)
    ERC20(_name, _symbol)
    Ownable(_initialOwner)
  {
    LST = _lst;
    FIXED_LST = _lst.FIXED_LST();
    SHARE_SCALE_FACTOR = _lst.SHARE_SCALE_FACTOR();
	FIXED_LST.safeTransferFrom(msg.sender, address(this), _preFundWrapped);
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
  function wrapRebasing(uint256 _lstAmountToWrap) external virtual returns (uint256 _wrappedAmount) {
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

    emit WrappedRebasing(msg.sender, _lstAmountToWrap, _wrappedAmount);
  }

  // Everything converts to the rebasing
  // can convert out to different things
  // Must approve to FIXED_LST
  // There could be some rounding weirdness
  function wrapUnderlying(uint256 _stakeTokensToWrap) public virtual returns (uint256) {
    if (_stakeTokensToWrap == 0) {
      revert WrappedGovLst__InvalidAmount();
    }

    // User must have approved the wrapper to spend their stake tokens
    IERC20 stakeToken = IERC20(address(LST.STAKE_TOKEN()));
    stakeToken.transferFrom(msg.sender, address(this), _stakeTokensToWrap);

    // Approve FIXED_LST to transfer the stake tokens from wrapper
    stakeToken.approve(address(FIXED_LST), _stakeTokensToWrap);

    // Calculate expected wrapped amount using preview
    uint256 _wrappedAmount = previewWrapUnderlying(_stakeTokensToWrap);

    // Stake through FIXED_LST which will transfer tokens to LST and stake them
    FIXED_LST.stake(_stakeTokensToWrap);

    // Mint wrapped tokens to the user
    _mint(msg.sender, _wrappedAmount);

    // Emit event for consistency with wrap function
    emit WrappedUnderlying(msg.sender, _stakeTokensToWrap, _wrappedAmount);

    return _wrappedAmount;
  }

  function wrapFixed(uint256 _fixedTokensToWrap) external virtual returns (uint256) {
    if (_fixedTokensToWrap == 0) {
      revert WrappedGovLst__InvalidAmount();
    }

    // Transfer fixed tokens from user to wrapper
    FIXED_LST.transferFrom(msg.sender, address(this), _fixedTokensToWrap);

    // Calculate wrapped amount using preview (should be 1:1)
    uint256 _wrappedAmount = previewWrapFixed(_fixedTokensToWrap);

    // Mint wrapped tokens to user
    _mint(msg.sender, _wrappedAmount);

    // Emit event for consistency
    emit WrappedFixed(msg.sender, _fixedTokensToWrap, _wrappedAmount);

    return _wrappedAmount;
  }

  /// Return the number of vault shares or less
  function previewWrapRebasing(uint256 _stakeTokensToWrap) public view virtual returns (uint256) {
    // Calculate the shares that will be transferred when converting to fixed
    // This needs to match the rounding behavior of _calcSharesForStakeUp in GovLst
    return _calcSharesForStakeUp(_stakeTokensToWrap) / SHARE_SCALE_FACTOR;
  }

  // TODO: Does this cause rounding issues
  function previewWrapUnderlying(uint256 _stakeTokensToWrap) public view virtual returns (uint256) {
    // Calculate shares that will be created from staking (same as _calcSharesForStake)
    if (LST.totalSupply() == 0) {
      // First staker gets SHARE_SCALE_FACTOR * amount shares
      return (SHARE_SCALE_FACTOR * _stakeTokensToWrap) / SHARE_SCALE_FACTOR;
    }

    // Fixed tokens are shares divided by SHARE_SCALE_FACTOR (same as _scaleDown in FixedGovLst)
    return ((_stakeTokensToWrap * LST.totalShares()) / LST.totalSupply()) / SHARE_SCALE_FACTOR;
  }

  function previewWrapFixed(uint256 _fixedTokensToWrap) public view virtual returns (uint256) {
    return _fixedTokensToWrap;
  }

  function previewUnwrapToRebase(uint256 _wrappedAmount) public view virtual returns (uint256) {
    // Wrapped tokens are 1:1 with FIXED_LST tokens
    // Convert to shares by scaling up
    uint256 _shares = _wrappedAmount * SHARE_SCALE_FACTOR;
    // Convert shares to rebasing tokens, rounding down to favor the protocol
    return _calcStakeForShares(_shares);
  }

  function previewUnwrapToFixed(uint256 _wrappedAmount) public view virtual returns (uint256) {
    // At worst 1 wei less than what has been requested will be returned.
    // The preview will return the minimum amount of assets returned.
    return _wrappedAmount - 1;
  }

  function _calcStakeForShares(uint256 _shares) internal view virtual returns (uint256) {
    if (LST.totalShares() == 0) {
      return _shares / SHARE_SCALE_FACTOR;
    }

    // Rounds down, favoring the protocol
    return (_shares * LST.totalSupply()) / LST.totalShares();
  }

  function _calcSharesForStakeUp(uint256 _amount) internal view virtual returns (uint256) {
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
  /// Behaves like redeem in erc4626
  function unwrapToRebase(uint256 _wrappedAmount) external virtual returns (uint256) {
    if (_wrappedAmount == 0) {
      revert WrappedGovLst__InvalidAmount();
    }

    // Burn wrapped tokens from the user
    _burn(msg.sender, _wrappedAmount);

    // Convert FIXED_LST tokens back to rebasing LST tokens
    // We need to call convertToRebasing to properly update the FIXED_LST accounting
    uint256 _lstAmountUnwrapped = FIXED_LST.convertToRebasing(_wrappedAmount);

    // Transfer the rebasing LST tokens to the user
    LST.transfer(msg.sender, _lstAmountUnwrapped);

    emit UnwrapRebasing(msg.sender, _lstAmountUnwrapped, _wrappedAmount);
    return _lstAmountUnwrapped;
  }

  /// @notice Burn wrapped tokens to receive FIXED_LST tokens.
  /// @param _wrappedAmount The quantity of wrapped tokens to burn.
  /// @return _fixedTokensUnwrapped The quantity of FIXED_LST tokens received.
  /// @dev Since wrapped tokens are 1:1 with FIXED_LST tokens, this is a simple transfer.
  /// @dev May transfer up to 1 extra wei due to FIXED_LST's internal rounding.
  function unwrapToFixed(uint256 _wrappedAmount) external virtual returns (uint256 _fixedTokensUnwrapped) {
    if (_wrappedAmount == 0) {
      revert WrappedGovLst__InvalidAmount();
    }

    // Burn wrapped tokens from the user first
    _burn(msg.sender, _wrappedAmount);

    // Check the wrapper's actual FIXED_LST balance before transfer
    uint256 _wrapperBalanceBefore = FIXED_LST.balanceOf(address(this));

    // Transfer FIXED_LST tokens to the user (1:1 with wrapped tokens)
    // The actual transfer amount might be 1 wei more due to FIXED_LST rounding
    FIXED_LST.transfer(msg.sender, _wrappedAmount);

    // Calculate actual amount transferred by checking balance change
    uint256 _wrapperBalanceAfter = FIXED_LST.balanceOf(address(this));
    _fixedTokensUnwrapped = _wrapperBalanceBefore - _wrapperBalanceAfter;

    // Emit event with actual transferred amount
    emit UnwrapFixed(msg.sender, _fixedTokensUnwrapped, _wrappedAmount);

    // Return the actual amount transferred (may be up to 1 wei more than _wrappedAmount)
    return _fixedTokensUnwrapped;
  }

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
