// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {UniLstTest, UniLst, IUniStaker} from "test/UniLst.t.sol";
import {WrappedUniLst, Ownable} from "src/WrappedUniLst.sol";
import {IERC20Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";

contract WrappedUniLstTest is UniLstTest {
  WrappedUniLst wrappedLst;
  string NAME = "Wrapped Test LST";
  string SYMBOL = "wtLST";
  address delegatee = makeAddr("Initial Delegatee");
  address wrappedLstOwner = makeAddr("Wrapped LST Owner");

  function setUp() public virtual override {
    super.setUp();
    wrappedLst = new WrappedUniLst(NAME, SYMBOL, lst, delegatee, wrappedLstOwner);
  }

  function _assumeSafeWrapHolder(address _holder) public view {
    _assumeSafeHolder(_holder);
    vm.assume(_holder != address(wrappedLst));
  }

  function _approveWrapperToTransferLstToken(address _holder) public {
    vm.prank(_holder);
    lst.approve(address(wrappedLst), type(uint256).max);
  }

  function _wrap(address _holder, uint256 _amount) public returns (uint256 _wrappedAmount) {
    vm.prank(_holder);
    _wrappedAmount = wrappedLst.wrap(_amount);
  }

  function _unwrap(address _holder, uint256 _amount) public returns (uint256 _unwrappedAmount) {
    vm.prank(_holder);
    _unwrappedAmount = wrappedLst.unwrap(_amount);
  }
}

contract Constructor is WrappedUniLstTest {
  function test_SetsConfigurationParameters() public view {
    assertEq(wrappedLst.name(), NAME);
    assertEq(wrappedLst.symbol(), SYMBOL);
    assertEq(address(wrappedLst.LST()), address(lst));
    assertEq(wrappedLst.delegatee(), delegatee);
    assertEq(lst.delegateeForHolder(address(wrappedLst)), delegatee);
    assertEq(wrappedLst.owner(), wrappedLstOwner);
  }

  function testFuzz_DeploysTheContractWithArbitraryValuesForParameters(
    string memory _name,
    string memory _symbol,
    address _lst,
    address _delegatee,
    address _owner,
    uint256 _depositId
  ) public {
    _assumeSafeMockAddress(_lst);
    _assumeSafeMockAddress(_delegatee);
    _assumeSafeMockAddress(_owner);
    vm.assume(_owner != address(0));

    // The constructor calls these methods on the LST to set up its own deposit, so we mock them here when testing the
    // constructor with an arbitrary address for the LST.
    vm.mockCall(
      _lst,
      abi.encodeWithSelector(UniLst.fetchOrInitializeDepositForDelegatee.selector, _delegatee),
      abi.encode(_depositId)
    );
    vm.mockCall(_lst, abi.encodeWithSelector(UniLst.updateDeposit.selector, _depositId), "");

    WrappedUniLst _wrappedLst = new WrappedUniLst(_name, _symbol, UniLst(_lst), _delegatee, _owner);

    assertEq(_wrappedLst.name(), _name);
    assertEq(_wrappedLst.symbol(), _symbol);
    assertEq(address(_wrappedLst.LST()), _lst);
    assertEq(IUniStaker.DepositIdentifier.unwrap(_wrappedLst.depositId()), _depositId);
    assertEq(_wrappedLst.owner(), _owner);
  }
}

contract Wrap is WrappedUniLstTest {
  function testFuzz_TransfersLstTokensFromHolderToWrapper(
    address _holder,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _wrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    // As the only staker, the holder's balance now includes all the rewards. They can wrap some amount up to their
    // stake and the rewards they have now received.
    _wrapAmount = bound(_wrapAmount, 1, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    _wrap(_holder, _wrapAmount);

    uint256 _expectedHolderLstBalance = _stakeAmount + _rewardAmount - _wrapAmount;
    assertEq(lst.balanceOf(_holder), _expectedHolderLstBalance);
    // TODO: another example of the rounding issues we still need to work through
    assertLteWithinOneUnit(lst.balanceOf(address(wrappedLst)), _wrapAmount);
  }

  function testFuzz_MintsNumberOfWrappedTokensEqualToUnderlyingLstShares(
    address _holder,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _wrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 1, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    _wrap(_holder, _wrapAmount);

    uint256 _expectedHolderWrappedLstBalance = lst.sharesForStake(_wrapAmount) / lst.SHARE_SCALE_FACTOR();
    assertEq(wrappedLst.balanceOf(_holder), _expectedHolderWrappedLstBalance);
  }

  function testFuzz_ReturnsTheAmountOfTheWrappedTokenThatWasMinted(
    address _holder,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _wrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 1, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _returnValue = _wrap(_holder, _wrapAmount);

    assertEq(_returnValue, wrappedLst.balanceOf(_holder));
  }

  function testFuzz_EmitsAWrappedEvent(
    address _holder,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _wrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 1, _stakeAmount + _rewardAmount);
    uint256 _expectedMintAmount = lst.sharesForStake(_wrapAmount) / lst.SHARE_SCALE_FACTOR();

    _approveWrapperToTransferLstToken(_holder);
    vm.expectEmit();
    emit WrappedUniLst.Wrapped(_holder, _wrapAmount, _expectedMintAmount);
    _wrap(_holder, _wrapAmount);
  }

  function testFuzz_RevertIf_TheAmountToWrapIsZero(address _holder, uint256 _stakeAmount, uint256 _rewardAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _approveWrapperToTransferLstToken(_holder);

    vm.expectRevert(WrappedUniLst.WrappedUniLst__InvalidAmount.selector);
    _wrap(_holder, 0);
  }
}

contract Unwrap is WrappedUniLstTest {
  function testFuzz_TransfersLstTokensBackToTheHolder(
    address _holder,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _wrapAmount,
    uint256 _unwrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);
    // After the holder wraps, we bound the amount they will unwrap to be less than or equal to their wrapped balance
    _unwrapAmount = bound(_unwrapAmount, 1, _wrappedBalance);

    // Remember the holder's prior LST balance and calculate their expected balance after unwrapping
    uint256 _holderPriorBalance = lst.balanceOf(_holder);
    uint256 _holderExpectedBalance = _holderPriorBalance + lst.stakeForShares(_unwrapAmount * lst.SHARE_SCALE_FACTOR());

    _unwrap(_holder, _unwrapAmount);

    assertLteWithinOneUnit(lst.balanceOf(_holder), _holderExpectedBalance);
  }

  function testFuzz_BurnsUnwrappedTokensFromHoldersWrappedLstBalance(
    address _holder,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _wrapAmount,
    uint256 _unwrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);
    _unwrapAmount = bound(_unwrapAmount, 1, _wrappedBalance);

    _unwrap(_holder, _unwrapAmount);

    assertEq(wrappedLst.balanceOf(_holder), _wrappedBalance - _unwrapAmount);
    assertEq(wrappedLst.totalSupply(), _wrappedBalance - _unwrapAmount);
  }

  function testFuzz_ReturnsTheAmountOfLstTokenThatWasUnwrapped(
    address _holder,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _wrapAmount,
    uint256 _unwrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);
    _unwrapAmount = bound(_unwrapAmount, 1, _wrappedBalance);

    uint256 _priorLstBalance = lst.balanceOf(_holder);
    uint256 _returnValue = _unwrap(_holder, _unwrapAmount);

    // TODO: more truncation issues to consider. Because the holder's lst.balanceOf calculation is subject to
    // truncation, the balance after the unwrapped amount is transferred is less than the amount the unwrap
    // function actually transferred.
    assertLteWithinOneUnit(lst.balanceOf(_holder), _priorLstBalance + _returnValue);
  }

  function testFuzz_EmitsAnUnwrappedEvent(
    address _holder,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _wrapAmount,
    uint256 _unwrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);
    _unwrapAmount = bound(_unwrapAmount, 1, _wrappedBalance);
    uint256 _expectedLstReturned = lst.stakeForShares(_unwrapAmount * lst.SHARE_SCALE_FACTOR());

    vm.expectEmit();
    emit WrappedUniLst.Unwrapped(_holder, _expectedLstReturned, _unwrapAmount);
    _unwrap(_holder, _unwrapAmount);
  }

  function testFuzz_RevertIf_HolderHasInsufficientBalanceToUnwrap(
    address _holder,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _wrapAmount,
    uint256 _unwrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);
    // The holder will try to unwrap more than their balance. The maximum number is meant to be high,
    // but not enough to overflow the shares with the scale factor applied.
    _unwrapAmount = bound(_unwrapAmount, _wrappedBalance + 1, type(uint96).max);

    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, _holder, _wrappedBalance, _unwrapAmount)
    );
    _unwrap(_holder, _unwrapAmount);
  }

  function testFuzz_RevertIf_TheAmountToUnwrapIsZero(
    address _holder,
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _wrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    _wrap(_holder, _wrapAmount);

    vm.expectRevert(WrappedUniLst.WrappedUniLst__InvalidAmount.selector);
    _unwrap(_holder, 0);
  }
}

contract SetDelegatee is WrappedUniLstTest {
  function testFuzz_SetsTheNewDelegatee(address _newDelegatee) public {
    _assumeSafeDelegatee(_newDelegatee);

    vm.prank(wrappedLstOwner);
    wrappedLst.setDelegatee(_newDelegatee);

    assertEq(wrappedLst.delegatee(), _newDelegatee);
  }

  function testFuzz_UpdatesTheDelegateeOnTheLst(address _newDelegatee) public {
    _assumeSafeDelegatee(_newDelegatee);

    vm.prank(wrappedLstOwner);
    wrappedLst.setDelegatee(_newDelegatee);

    assertEq(lst.delegateeForHolder(address(wrappedLst)), _newDelegatee);
  }

  function testFuzz_EmitsADelegateeSetEvent(address _newDelegatee) public {
    _assumeSafeDelegatee(_newDelegatee);

    vm.prank(wrappedLstOwner);
    vm.expectEmit();
    emit WrappedUniLst.DelegateeSet(delegatee, _newDelegatee);
    wrappedLst.setDelegatee(_newDelegatee);
  }

  function testFuzz_RevertIf_CalledByNonOwnerAccount(address _newDelegatee, address _notWrappedLstOwner) public {
    _assumeSafeDelegatee(_newDelegatee);
    vm.assume(_notWrappedLstOwner != address(0));

    vm.prank(_notWrappedLstOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notWrappedLstOwner));
    wrappedLst.setDelegatee(_newDelegatee);
  }
}
