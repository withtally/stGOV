// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20Permit} from "openzeppelin/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {UniLst, IUniStaker} from "src/UniLst.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";

contract WrappedUniLst is ERC20Permit, Ownable {
  error WrappedUniLst__InvalidAmount();

  event Wrapped(address indexed holder, uint256 lstAmount, uint256 wrappedAmount);
  event Unwrapped(address indexed holder, uint256 lstAmount, uint256 wrappedAmount);
  event DelegateeSet(address indexed oldDelegatee, address indexed newDelegatee);

  UniLst public immutable LST;
  IUniStaker.DepositIdentifier public depositId;

  constructor(string memory _name, string memory _symbol, UniLst _lst, address _delegatee, address _initialOwner)
    ERC20Permit(_name)
    ERC20(_name, _symbol)
    Ownable(_initialOwner)
  {
    LST = _lst;
    _setDelegatee(_delegatee);
  }

  function delegatee() public view returns (address) {
    return LST.delegateeForHolder(address(this));
  }

  function wrap(uint256 _lstAmount) external returns (uint256 _wrappedAmount) {
    if (_lstAmount == 0) {
      revert WrappedUniLst__InvalidAmount();
    }

    _wrappedAmount = LST.sharesForStake(_lstAmount) / LST.SHARE_SCALE_FACTOR();
    _mint(msg.sender, _wrappedAmount);
    LST.transferFrom(msg.sender, address(this), _lstAmount);
    emit Wrapped(msg.sender, _lstAmount, _wrappedAmount);
  }

  function unwrap(uint256 _wrappedAmount) external returns (uint256 _unwrappedAmount) {
    _unwrappedAmount = LST.stakeForShares(_wrappedAmount * LST.SHARE_SCALE_FACTOR());

    if (_unwrappedAmount == 0) {
      revert WrappedUniLst__InvalidAmount();
    }

    _burn(msg.sender, _wrappedAmount);
    LST.transfer(msg.sender, _unwrappedAmount);
    emit Unwrapped(msg.sender, _unwrappedAmount, _wrappedAmount);
  }

  function setDelegatee(address _newDelegatee) public {
    _checkOwner();
    _setDelegatee(_newDelegatee);
  }

  function _setDelegatee(address _newDelegatee) internal {
    emit DelegateeSet(delegatee(), _newDelegatee);
    depositId = LST.fetchOrInitializeDepositForDelegatee(_newDelegatee);
    LST.updateDeposit(depositId);
  }
}
