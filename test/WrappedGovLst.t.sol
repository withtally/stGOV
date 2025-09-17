// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console2} from "forge-std/Test.sol";
import {GovLstTest, GovLst} from "./GovLst.t.sol";
import {Staker} from "staker/Staker.sol";
import {WrappedGovLst, Ownable} from "../src/WrappedGovLst.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    wrappedLst = new WrappedGovLst(NAME, SYMBOL, lst, delegatee, wrappedLstOwner, 0);

    _unstakeOnDelegateeDeposit(delegateeFunder);
  }

  function _assumeSafeWrapHolder(address _holder) public view {
    _assumeSafeHolder(_holder);
    vm.assume(_holder != address(wrappedLst));
    vm.assume(_holder != address(delegateeFunder));
  }

  function _approveWrapperToTransferLstToken(address _holder) public {
    vm.prank(_holder);
    lst.approve(address(wrappedLst), type(uint256).max);
  }

  function _wrap(address _holder, uint256 _amount) public returns (uint256 _wrappedAmount) {
    vm.prank(_holder);
    _wrappedAmount = wrappedLst.wrapRebasing(_amount);
  }

  function _unwrap(address _holder, uint256 _amount) public returns (uint256 _unwrappedAmount) {
    vm.prank(_holder);
    _unwrappedAmount = wrappedLst.unwrapToRebasing(_amount);
  }

  function _stakeFixed(address _holder, uint256 _amount) internal returns (uint256) {
    vm.startPrank(_holder);
    stakeToken.approve(address(lst.FIXED_LST()), _amount);
    uint256 _fixedTokens = lst.FIXED_LST().stake(_amount);
    vm.stopPrank();
    return _fixedTokens;
  }
}

contract Constructor is WrappedGovLstTest {
  function test_SetsConfigurationParameters() public view {
    assertEq(wrappedLst.name(), NAME);
    assertEq(wrappedLst.symbol(), SYMBOL);
    assertEq(address(wrappedLst.LST()), address(lst));
    assertEq(address(wrappedLst.FIXED_LST()), address(lst.FIXED_LST()));
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
    uint256 _depositId,
    uint256 _prefundAmount
  ) public {
    _assumeSafeMockAddress(_lst);
    _assumeSafeMockAddress(_delegatee);
    _assumeSafeMockAddress(_owner);
    vm.assume(_owner != address(0));
    _prefundAmount = bound(_prefundAmount, 1, 1e18);

    // Mock a fixed LST address
    address _mockFixedLst = makeAddr("MockFixedLst");

    // The constructor calls these methods on the LST to set up its own deposit, so we mock them here when testing the
    // constructor with an arbitrary address for the LST.
    bytes4 shareScaleFactorSelector = hex"f5706759";
    bytes4 fixedLstSelector = hex"52000ec7"; // FIXED_LST() selector - corrected

    vm.mockCall(
      _lst,
      // Hardcode the selector for the scale factor variable which is not a selector we can access here
      abi.encodeWithSelector(shareScaleFactorSelector),
      abi.encode(lst.SHARE_SCALE_FACTOR())
    );
    vm.mockCall(_lst, abi.encodeWithSelector(fixedLstSelector), abi.encode(_mockFixedLst));

    vm.mockCall(
      _mockFixedLst,
      abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), address(0), _prefundAmount),
      abi.encode(true)
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

    WrappedGovLst _wrappedLst = new WrappedGovLst(_name, _symbol, GovLst(_lst), _delegatee, _owner, _prefundAmount);

    assertEq(_wrappedLst.name(), _name);
    assertEq(_wrappedLst.symbol(), _symbol);
    assertEq(address(_wrappedLst.LST()), _lst);
    assertEq(Staker.DepositIdentifier.unwrap(_wrappedLst.depositId()), _depositId);
    assertEq(_wrappedLst.owner(), _owner);
  }
}

contract WrapRebasing is WrappedGovLstTest {
  function testFuzz_TransfersLstTokensFromHolderToWrapperAndWrapsThemToFixedLstTokens(
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

    uint256 _expectedShares = wrappedLst.previewWrapRebasing(_wrapAmount);
    _approveWrapperToTransferLstToken(_holder);
    _wrap(_holder, _wrapAmount);

    uint256 _expectedHolderLstBalance = _stakeAmount + _rewardAmount - _wrapAmount;

    assertLteWithinOneUnit(lst.balanceOf(_holder), _expectedHolderLstBalance);
    assertEq(lst.balanceOf(address(wrappedLst)), 0);
    assertEq(lst.FIXED_LST().balanceOf(address(wrappedLst)), _expectedShares);
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

    // Get the initial fixed balance to track how many fixed tokens will be created
    uint256 _initialFixedBalance = lst.FIXED_LST().balanceOf(address(wrappedLst));
    uint256 _previewWrappedTokens = wrappedLst.previewWrapRebasing(_wrapAmount);

    uint256 _wrappedAmount = _wrap(_holder, _wrapAmount);

    // The wrapped amount should equal the fixed tokens created
    uint256 _fixedTokensCreated = lst.FIXED_LST().balanceOf(address(wrappedLst)) - _initialFixedBalance;
    assertEq(wrappedLst.balanceOf(_holder), _fixedTokensCreated);
    assertEq(wrappedLst.balanceOf(_holder), _wrappedAmount);
    assertEq(wrappedLst.balanceOf(_holder), _previewWrappedTokens);
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
    uint256 _initialBalance = wrappedLst.balanceOf(_holder);
    uint256 _returnValue = _wrap(_holder, _wrapAmount);

    assertEq(_returnValue, wrappedLst.balanceOf(_holder) - _initialBalance);
  }

  function testFuzz_EmitsAWrapRebasingEvent(
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

    uint256 _expectedWrappedTokens = wrappedLst.previewWrapRebasing(_wrapAmount);

    vm.expectEmit();
    emit WrappedGovLst.RebasingWrapped(_holder, _wrapAmount, _expectedWrappedTokens); // We don't know the exact wrapped
      // amount

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

contract WrapUnderlying is WrappedGovLstTest {
  function testFuzz_TransfersStakeTokensFromHolderToWrapper(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _mintStakeToken(_holder, _stakeAmount);
    vm.prank(_holder);
    stakeToken.approve(address(wrappedLst), _stakeAmount);

    uint256 _initialHolderBalance = stakeToken.balanceOf(_holder);
    uint256 _initialWrapperBalance = stakeToken.balanceOf(address(wrappedLst));

    uint256 _expectedShares = wrappedLst.previewWrapUnderlying(_stakeAmount);

    vm.prank(_holder);
    wrappedLst.wrapUnderlying(_stakeAmount);

    assertEq(stakeToken.balanceOf(_holder), _initialHolderBalance - _stakeAmount);
    assertEq(stakeToken.balanceOf(address(wrappedLst)), _initialWrapperBalance);
    assertEq(lst.FIXED_LST().balanceOf(address(wrappedLst)), _expectedShares);
  }

  function testFuzz_MintsCorrectNumberOfWrappedTokens(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _mintStakeToken(_holder, _stakeAmount);
    vm.prank(_holder);
    stakeToken.approve(address(wrappedLst), _stakeAmount);

    uint256 _initialWrappedBalance = wrappedLst.balanceOf(_holder);

    uint256 _expectedWrappedTokens = wrappedLst.previewWrapRebasing(_stakeAmount);
    vm.prank(_holder);
    wrappedLst.wrapUnderlying(_stakeAmount);

    assertEq(wrappedLst.balanceOf(_holder), _initialWrappedBalance + _expectedWrappedTokens);
    assertEq(wrappedLst.totalSupply(), _expectedWrappedTokens);
  }

  function testFuzz_ReturnsCorrectWrappedAmount(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _mintStakeToken(_holder, _stakeAmount);
    vm.prank(_holder);
    stakeToken.approve(address(wrappedLst), _stakeAmount);

    uint256 _initialWrappedBalance = wrappedLst.balanceOf(_holder);

    vm.prank(_holder);
    uint256 _returnedAmount = wrappedLst.wrapUnderlying(_stakeAmount);

    assertEq(_returnedAmount, wrappedLst.balanceOf(_holder) - _initialWrappedBalance);
  }

  function testFuzz_EmitsWrapUnderlyingEvent(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _mintStakeToken(_holder, _stakeAmount);

    vm.prank(_holder);
    stakeToken.approve(address(wrappedLst), _stakeAmount);

    uint256 _expectedWrappedTokens = wrappedLst.previewWrapUnderlying(_stakeAmount);

    vm.expectEmit();
    emit WrappedGovLst.UnderlyingWrapped(_holder, _stakeAmount, _expectedWrappedTokens);

    vm.prank(_holder);
    wrappedLst.wrapUnderlying(_stakeAmount);
  }

  function testFuzz_RevertIf_AmountIsZero(address _holder) public {
    _assumeSafeWrapHolder(_holder);

    vm.expectRevert(WrappedGovLst.WrappedGovLst__InvalidAmount.selector);
    vm.prank(_holder);
    wrappedLst.wrapUnderlying(0);
  }
}

contract WrapFixed is WrappedGovLstTest {
  function testFuzz_TransfersFixedTokensFromHolderToWrapper(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _mintStakeToken(_holder, _stakeAmount);
    uint256 _fixedTokens = _stakeFixed(_holder, _stakeAmount);

    vm.startPrank(_holder);
    lst.FIXED_LST().approve(address(wrappedLst), _fixedTokens);

    uint256 _initialHolderBalance = lst.FIXED_LST().balanceOf(_holder);
    uint256 _initialWrapperBalance = lst.FIXED_LST().balanceOf(address(wrappedLst));

    wrappedLst.wrapFixed(_fixedTokens);
    vm.stopPrank();

    assertEq(lst.FIXED_LST().balanceOf(_holder), _initialHolderBalance - _fixedTokens);
    assertEq(lst.FIXED_LST().balanceOf(address(wrappedLst)), _initialWrapperBalance + _fixedTokens);
  }

  function testFuzz_MintsCorrectNumberOfWrappedTokens(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _mintStakeToken(_holder, _stakeAmount);
    uint256 _fixedTokens = _stakeFixed(_holder, _stakeAmount);
    vm.startPrank(_holder);
    lst.FIXED_LST().approve(address(wrappedLst), _fixedTokens);

    uint256 _initialWrappedBalance = wrappedLst.balanceOf(_holder);
    uint256 _wrappedAmount = wrappedLst.wrapFixed(_fixedTokens);
    vm.stopPrank();

    assertEq(wrappedLst.balanceOf(_holder), _initialWrappedBalance + _wrappedAmount);
    assertEq(wrappedLst.totalSupply(), _initialWrappedBalance + _wrappedAmount);
  }

  function testFuzz_ReturnsCorrectWrappedAmount(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _mintStakeToken(_holder, _stakeAmount);
    uint256 _fixedTokens = _stakeFixed(_holder, _stakeAmount);

    vm.startPrank(_holder);
    lst.FIXED_LST().approve(address(wrappedLst), _fixedTokens);
    uint256 _wrappedAmount = wrappedLst.wrapFixed(_fixedTokens);
    vm.stopPrank();

    assertEq(_wrappedAmount, _fixedTokens);
  }

  function testFuzz_EmitsWrapFixedEvent(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _mintStakeToken(_holder, _stakeAmount);
    uint256 _fixedTokens = _stakeFixed(_holder, _stakeAmount);

    vm.startPrank(_holder);
    lst.FIXED_LST().approve(address(wrappedLst), _fixedTokens);

    vm.expectEmit();
    emit WrappedGovLst.FixedWrapped(_holder, _fixedTokens, _fixedTokens);

    wrappedLst.wrapFixed(_fixedTokens);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_AmountIsZero(address _holder) public {
    _assumeSafeWrapHolder(_holder);

    vm.expectRevert(WrappedGovLst.WrappedGovLst__InvalidAmount.selector);
    vm.prank(_holder);
    wrappedLst.wrapFixed(0);
  }
}

contract UnwrapToRebase is WrappedGovLstTest {
  function testFuzz_TransfersRebasingTokensBackToTheHolder(
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
    uint256 _holderPriorBalance = lst.balanceOf(_holder);
    uint256 _previewUnwrapAmount = wrappedLst.previewUnwrapToRebasing(_unwrapAmount);
    uint256 _lstAmountUnwrapped = _unwrap(_holder, _unwrapAmount);

    assertApproxEqAbs(lst.balanceOf(_holder), _holderPriorBalance + _lstAmountUnwrapped, 1);
    assertLe(_previewUnwrapAmount, lst.balanceOf(_holder) - _holderPriorBalance);
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

    assertEq(wrappedLst.balanceOf(_holder), _wrappedBalance - _unwrapAmount);
    assertEq(wrappedLst.totalSupply(), _wrappedBalance - _unwrapAmount);
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
  }

  function testFuzz_EmitsAnUnwrapRebasingEvent(
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
    uint256 _previewUnwrapAmount = wrappedLst.previewUnwrapToRebasing(_unwrapAmount);

    vm.expectEmit();
    emit WrappedGovLst.RebasingUnwrapped(_holder, _previewUnwrapAmount, _unwrapAmount);
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

contract UnwrapToFixed is WrappedGovLstTest {
  function testFuzz_TransfersFixedTokensToTheHolder(
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

    uint256 _holderPriorBalance = lst.FIXED_LST().balanceOf(_holder);

    uint256 _previewAmount = wrappedLst.previewUnwrapToFixed(_unwrapAmount);
    vm.prank(_holder);
    uint256 _fixedAmountUnwrapped = wrappedLst.unwrapToFixed(_unwrapAmount);

    assertApproxEqAbs(
      lst.FIXED_LST().balanceOf(_holder),
      _holderPriorBalance + _fixedAmountUnwrapped,
      1,
      "Holder should receive the returned FIXED_LST tokens"
    );
    assertLe(_previewAmount, lst.FIXED_LST().balanceOf(_holder) - _holderPriorBalance);
  }

  function testFuzz_BurnsWrappedTokensFromHolder(
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

    vm.prank(_holder);
    wrappedLst.unwrapToFixed(_unwrapAmount);

    // Verify wrapped tokens were burned
    assertEq(wrappedLst.balanceOf(_holder), _wrappedBalance - _unwrapAmount);
    assertGe(wrappedLst.totalSupply(), _wrappedBalance - _unwrapAmount);
  }

  function testFuzz_ReturnsCorrectAmountOfFixedTokens(
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

    uint256 _priorFixedBalance = lst.FIXED_LST().balanceOf(_holder);

    vm.prank(_holder);
    uint256 _returnValue = wrappedLst.unwrapToFixed(_unwrapAmount);

    assertApproxEqAbs(lst.FIXED_LST().balanceOf(_holder), _priorFixedBalance + _returnValue, 1);
    assertApproxEqAbs(_returnValue, _unwrapAmount, 1);
  }

  function testFuzz_EmitsUnwrapFixedEvent(
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

    // We only check that an event was emitted with the correct holder address and wrapped amount
    // The actual amount may differ by 1 wei from the requested amount due to FIXED_LST's rounding
    vm.expectEmit(true, false, true, false);
    emit WrappedGovLst.FixedUnwrapped(_holder, 0, _unwrapAmount);

    vm.prank(_holder);
    wrappedLst.unwrapToFixed(_unwrapAmount);
  }

  function testFuzz_RevertIf_AmountIsZero(address _holder) public {
    _assumeSafeWrapHolder(_holder);

    vm.expectRevert(WrappedGovLst.WrappedGovLst__InvalidAmount.selector);
    vm.prank(_holder);
    wrappedLst.unwrapToFixed(0);
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
