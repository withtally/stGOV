// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GovLst} from "./GovLst.sol";
import {Staker} from "staker/Staker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
  function wrap(uint256 _lstAmountToWrap) external virtual returns (uint256 _wrappedAmount) {
    if (_lstAmountToWrap == 0) {
      revert WrappedGovLst__InvalidAmount();
    }

    uint256 _initialShares = LST.sharesOf(address(this));
    LST.transferFrom(msg.sender, address(this), _lstAmountToWrap);
    // The amount of tokens issued to the caller is based on number of shares actually issued to the wrapper
    // token contract. The balance is the number of shares divided by the share scale factor. This means the holder may
    // lose claim to a slight number of shares the wrapper contract takes possession of, meaning rounding favors the
    // wrapper, which is desired.
    _wrappedAmount = (LST.sharesOf(address(this)) - _initialShares) / SHARE_SCALE_FACTOR;
    _mint(msg.sender, _wrappedAmount);

    emit Wrapped(msg.sender, _lstAmountToWrap, _wrappedAmount);
  }

  /// @notice Burn wrapped tokens to receive liquid stake tokens in return.
  /// @param _wrappedAmount The quantity of wrapped tokens to burn.
  /// @return _lstAmountUnwrapped The quantity of liquid staked tokens received in exchange for the wrapped tokens.
  /// @dev The caller must approve at least the amount wrapped tokens on the wrapper token contract.
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
