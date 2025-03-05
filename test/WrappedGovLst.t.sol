// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console2} from "forge-std/Test.sol";
import {GovLstTest, GovLst} from "./GovLst.t.sol";
import {Staker} from "staker/Staker.sol";
import {WrappedGovLst, Ownable} from "../src/WrappedGovLst.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract WrappedGovLstTest is GovLstTest {
  WrappedGovLst wrappedLst;
  string NAME = "Wrapped Test LST";
  string SYMBOL = "wtLST";
  address delegatee = makeAddr("Initial Delegatee");
  address wrappedLstOwner = makeAddr("Wrapped LST Owner");

  function setUp() public virtual override {
    super.setUp();
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(delegatee);
    _stakeOnDelegateeDeposit(_depositId, delegateeFunder);

    wrappedLst = new WrappedGovLst(NAME, SYMBOL, lst, delegatee, wrappedLstOwner);

    _unstakeOnDelegateeDeposit(delegateeFunder);
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

contract Constructor is WrappedGovLstTest {
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
    bytes4 shareScaleFactorSelector = hex"f5706759";
    vm.mockCall(
      _lst,
      // Hardcode the selector for the scale factor variable which is not a selector we can access here
      abi.encodeWithSelector(shareScaleFactorSelector),
      abi.encode(lst.SHARE_SCALE_FACTOR())
    );
    vm.mockCall(
      _lst,
      abi.encodeWithSelector(GovLst.fetchOrInitializeDepositForDelegatee.selector, _delegatee),
      abi.encode(_depositId)
    );
    vm.mockCall(_lst, abi.encodeWithSelector(GovLst.updateDeposit.selector, _depositId), "");

    // need wrappedLstAddress in order to mock the following call
    address _expectedWrappedLstAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
    vm.mockCall(
      _lst,
      abi.encodeWithSelector(GovLst.delegateeForHolder.selector, _expectedWrappedLstAddress),
      abi.encode(address(0)) // in actuality this would return the defaultDelegatee, but we don't need to mock that
    );

    WrappedGovLst _wrappedLst = new WrappedGovLst(_name, _symbol, GovLst(_lst), _delegatee, _owner);

    assertEq(_wrappedLst.name(), _name);
    assertEq(_wrappedLst.symbol(), _symbol);
    assertEq(address(_wrappedLst.LST()), _lst);
    assertEq(Staker.DepositIdentifier.unwrap(_wrappedLst.depositId()), _depositId);
    assertEq(_wrappedLst.owner(), _owner);
  }
}

contract Wrap is WrappedGovLstTest {
  function testFuzz_TransfersLstTokensFromHolderToWrapper(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _wrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    // As the only staker, the holder's balance now includes all the rewards. They can wrap some amount up to their
    // stake and the rewards they have now received.
    _wrapAmount = bound(_wrapAmount, 1, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    _wrap(_holder, _wrapAmount);

    uint256 _expectedHolderLstBalance = _stakeAmount + _rewardAmount - _wrapAmount;

    assertApproxEqAbs(lst.balanceOf(_holder), _expectedHolderLstBalance, 1);
    assertLe(lst.balanceOf(_holder), _expectedHolderLstBalance);
    assertApproxEqAbs(lst.balanceOf(address(wrappedLst)), _wrapAmount, 1);
    assertGe(lst.balanceOf(address(wrappedLst)), _wrapAmount);
  }

  function testFuzz_MintsNumberOfWrappedTokensEqualToUnderlyingLstShares(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _wrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
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
    uint80 _rewardAmount,
    uint256 _wrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 1, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _returnValue = _wrap(_holder, _wrapAmount);

    assertEq(_returnValue, wrappedLst.balanceOf(_holder));
  }

  function testFuzz_EmitsAWrappedEvent(address _holder, uint256 _stakeAmount, uint80 _rewardAmount, uint256 _wrapAmount)
    public
  {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 1, _stakeAmount + _rewardAmount);
    uint256 _expectedMintAmount = lst.sharesForStake(_wrapAmount) / lst.SHARE_SCALE_FACTOR();

    _approveWrapperToTransferLstToken(_holder);
    vm.expectEmit();
    emit WrappedGovLst.Wrapped(_holder, _wrapAmount, _expectedMintAmount);
    _wrap(_holder, _wrapAmount);
  }

  function testFuzz_RevertIf_TheAmountToWrapIsZero(address _holder, uint256 _stakeAmount, uint80 _rewardAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _approveWrapperToTransferLstToken(_holder);

    vm.expectRevert(WrappedGovLst.WrappedGovLst__InvalidAmount.selector);
    _wrap(_holder, 0);
  }
}

contract Unwrap is WrappedGovLstTest {
  function testFuzz_TransfersLstTokensBackToTheHolder(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _wrapAmount,
    uint256 _unwrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
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

    assertApproxEqAbs(lst.balanceOf(_holder), _holderExpectedBalance, 1);
    assertGe(lst.balanceOf(_holder), _holderExpectedBalance);
  }

  function testFuzz_BurnsUnwrappedTokensFromHoldersWrappedLstBalance(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _wrapAmount,
    uint256 _unwrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);
    _unwrapAmount = bound(_unwrapAmount, 1, _wrappedBalance);

    _unwrap(_holder, _unwrapAmount);

    assertLteWithinOneUnit(_wrappedBalance - _unwrapAmount, wrappedLst.balanceOf(_holder));
    assertLteWithinOneUnit(_wrappedBalance - _unwrapAmount, wrappedLst.totalSupply());
  }

  function testFuzz_ReturnsTheAmountOfLstTokenThatWasUnwrapped(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _wrapAmount,
    uint256 _unwrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);
    _unwrapAmount = bound(_unwrapAmount, 1, _wrappedBalance);

    uint256 _priorLstBalance = lst.balanceOf(_holder);
    uint256 _returnValue = _unwrap(_holder, _unwrapAmount);

    assertApproxEqAbs(lst.balanceOf(_holder), _priorLstBalance + _returnValue, 1);
    assertGe(lst.balanceOf(_holder), _priorLstBalance + _returnValue);
  }

  function testFuzz_EmitsAnUnwrappedEvent(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _wrapAmount,
    uint256 _unwrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);
    _unwrapAmount = bound(_unwrapAmount, 1, _wrappedBalance);
    uint256 _expectedLstReturned = lst.stakeForShares(_unwrapAmount * lst.SHARE_SCALE_FACTOR());

    vm.expectEmit();
    emit WrappedGovLst.Unwrapped(_holder, _expectedLstReturned, _unwrapAmount);
    _unwrap(_holder, _unwrapAmount);
  }

  function testFuzz_RevertIf_HolderHasInsufficientBalanceToUnwrap(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _wrapAmount,
    uint256 _unwrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    address _otherHolder = makeAddr("Other Holder");
    vm.assume(_holder != _otherHolder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);

    // Another holder wraps a large number of tokens. This is to make sure the revert is because the revert we are
    // expecting below is happening because the *holder* has insufficient balance, not because the wrapper doesn't
    // itself own too few LST tokens.
    uint256 _otherWrapAmount = 10_000_000_000e18;
    _mintAndStake(_otherHolder, _otherWrapAmount);
    _approveWrapperToTransferLstToken(_otherHolder);
    _wrap(_otherHolder, lst.balanceOf(_otherHolder));

    // A reward is distributed
    Staker.DepositIdentifier _depositId2 = lst.depositIdForHolder(address(lst));
    _distributeReward(_rewardAmount, _depositId2, _toPercentage(_stakeAmount, _stakeAmount + _otherWrapAmount));

    // The holder wraps some amount of their LST tokens
    _wrapAmount = bound(_wrapAmount, 0.0001e18, lst.balanceOf(_holder));
    _approveWrapperToTransferLstToken(_holder);
    uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);

    // The holder will try to unwrap more than their balance.
    _unwrapAmount = bound(_unwrapAmount, _wrappedBalance + 1, 5_000_000_000e18);

    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, _holder, _wrappedBalance, _unwrapAmount)
    );
    _unwrap(_holder, _unwrapAmount);
  }

  function testFuzz_RevertIf_TheAmountToUnwrapIsZero(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _wrapAmount
  ) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);
    _wrap(_holder, _wrapAmount);

    vm.expectRevert(WrappedGovLst.WrappedGovLst__InvalidAmount.selector);
    _unwrap(_holder, 0);
  }
}

contract SetDelegatee is WrappedGovLstTest {
  function testFuzz_SetsTheNewDelegatee(address _newDelegatee) public {
    _assumeSafeDelegatee(_newDelegatee);

    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);
    _stakeOnDelegateeDeposit(_depositId, delegateeFunder);

    vm.prank(wrappedLstOwner);
    wrappedLst.setDelegatee(_newDelegatee);

    assertEq(wrappedLst.delegatee(), _newDelegatee);
  }

  function testFuzz_UpdatesTheDelegateeOnTheLst(address _newDelegatee) public {
    _assumeSafeDelegatee(_newDelegatee);

    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);
    _stakeOnDelegateeDeposit(_depositId, delegateeFunder);

    vm.prank(wrappedLstOwner);
    wrappedLst.setDelegatee(_newDelegatee);

    assertEq(lst.delegateeForHolder(address(wrappedLst)), _newDelegatee);
  }

  function testFuzz_EmitsADelegateeSetEvent(address _newDelegatee) public {
    _assumeSafeDelegatee(_newDelegatee);
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);
    _stakeOnDelegateeDeposit(_depositId, delegateeFunder);

    vm.prank(wrappedLstOwner);
    vm.expectEmit();
    emit WrappedGovLst.DelegateeSet(delegatee, _newDelegatee);
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
