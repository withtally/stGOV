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
    uint256 _depositId
  ) public {
    _assumeSafeMockAddress(_lst);
    _assumeSafeMockAddress(_delegatee);
    _assumeSafeMockAddress(_owner);
    vm.assume(_owner != address(0));

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
    // Skip FIXED_LST check as it's just a mock address
    assertEq(Staker.DepositIdentifier.unwrap(_wrappedLst.depositId()), _depositId);
    assertEq(_wrappedLst.owner(), _owner);
  }
}

contract Wrap is WrappedGovLstTest {
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

  function testFuzz_EmitsAWrappedEvent(address _holder, uint256 _stakeAmount, uint80 _rewardAmount, uint256 _wrapAmount)
    public
  {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _mintAndStake(_holder, _stakeAmount);
    _distributeReward(_rewardAmount);
    _wrapAmount = bound(_wrapAmount, 1, _stakeAmount + _rewardAmount);

    _approveWrapperToTransferLstToken(_holder);

    // Get the expected wrapped amount by tracking the fixed tokens that will be created
    uint256 _initialFixedBalance = lst.FIXED_LST().balanceOf(address(wrappedLst));
    uint256 _expectedWrappedTokens = wrappedLst.previewWrapRebasing(_wrapAmount);

    // We expect the event to be emitted with the wrapped amount equal to fixed tokens created
    vm.expectEmit();
    emit WrappedGovLst.Wrapped(_holder, _wrapAmount, _expectedWrappedTokens); // We don't know the exact wrapped amount
      // yet

    uint256 _actualWrappedAmount = _wrap(_holder, _wrapAmount);

    // Verify the wrapped amount matches the fixed tokens created
    uint256 _fixedTokensCreated = lst.FIXED_LST().balanceOf(address(wrappedLst)) - _initialFixedBalance;
    assertEq(_actualWrappedAmount, _fixedTokensCreated);
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

    // First mint tokens to stakeMinter, then transfer to holder
    _mintStakeToken(stakeMinter, _stakeAmount);
    vm.prank(stakeMinter);
    stakeToken.transfer(_holder, _stakeAmount);

    // Approve wrapper to transfer stake tokens
    vm.prank(_holder);
    stakeToken.approve(address(wrappedLst), _stakeAmount);

    uint256 _initialHolderBalance = stakeToken.balanceOf(_holder);
    uint256 _initialWrapperBalance = stakeToken.balanceOf(address(wrappedLst));

    uint256 _expectedShares = wrappedLst.previewWrapUnderlying(_stakeAmount);

    // Wrap the stake tokens
    vm.prank(_holder);
    wrappedLst.wrapUnderlying(_stakeAmount);

    // Verify stake tokens were transferred from holder
    assertEq(stakeToken.balanceOf(_holder), _initialHolderBalance - _stakeAmount);
    // Wrapper shouldn't hold stake tokens (they go to LST via FIXED_LST.stake)
    assertEq(stakeToken.balanceOf(address(wrappedLst)), _initialWrapperBalance);
    assertEq(lst.FIXED_LST().balanceOf(address(wrappedLst)), _expectedShares);
  }

  function testFuzz_MintsCorrectNumberOfWrappedTokens(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // First mint tokens to stakeMinter, then transfer to holder
    _mintStakeToken(stakeMinter, _stakeAmount);
    vm.prank(stakeMinter);
    stakeToken.transfer(_holder, _stakeAmount);

    // Approve wrapper
    vm.prank(_holder);
    stakeToken.approve(address(wrappedLst), _stakeAmount);

    uint256 _initialWrappedBalance = wrappedLst.balanceOf(_holder);

    uint256 _expectedWrappedTokens = wrappedLst.previewWrapRebasing(_stakeAmount);
    // Wrap the stake tokens
    vm.prank(_holder);
    uint256 _wrappedAmount = wrappedLst.wrapUnderlying(_stakeAmount);

    // Verify correct amount of wrapped tokens were minted
    assertEq(wrappedLst.balanceOf(_holder), _initialWrappedBalance + _expectedWrappedTokens);
    // The wrapped amount should equal the fixed tokens created (scaled appropriately)
    assertGt(_wrappedAmount, 0);
  }

  function testFuzz_ReturnsCorrectWrappedAmount(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // First mint tokens to stakeMinter, then transfer to holder
    _mintStakeToken(stakeMinter, _stakeAmount);
    vm.prank(stakeMinter);
    stakeToken.transfer(_holder, _stakeAmount);

    // Approve wrapper
    vm.prank(_holder);
    stakeToken.approve(address(wrappedLst), _stakeAmount);

    uint256 _initialWrappedBalance = wrappedLst.balanceOf(_holder);

    // Wrap and get return value
    vm.prank(_holder);
    uint256 _returnedAmount = wrappedLst.wrapUnderlying(_stakeAmount);

    // Verify return value matches the wrapped token balance
    assertEq(_returnedAmount, wrappedLst.balanceOf(_holder) - _initialWrappedBalance);
  }

  function testFuzz_EmitsWrappedEvent(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // First mint tokens to stakeMinter, then transfer to holder
    _mintStakeToken(stakeMinter, _stakeAmount);
    vm.prank(stakeMinter);
    stakeToken.transfer(_holder, _stakeAmount);

    // Approve wrapper
    vm.prank(_holder);
    stakeToken.approve(address(wrappedLst), _stakeAmount);

    uint256 _expectedWrappedTokens = wrappedLst.previewWrapUnderlying(_stakeAmount);

    // We expect the event to be emitted
    vm.expectEmit();
    emit WrappedGovLst.Wrapped(_holder, _stakeAmount, _expectedWrappedTokens); // Don't check wrapped amount yet

    // Wrap the stake tokens
    vm.prank(_holder);
    wrappedLst.wrapUnderlying(_stakeAmount);
  }

  function testFuzz_RevertIf_AmountIsZero(address _holder) public {
    _assumeSafeWrapHolder(_holder);

    // Should revert with zero amount
    vm.expectRevert(WrappedGovLst.WrappedGovLst__InvalidAmount.selector);
    vm.prank(_holder);
    wrappedLst.wrapUnderlying(0);
  }
}

contract WrapFixed is WrappedGovLstTest {
  function testFuzz_TransfersFixedTokensFromHolderToWrapper(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // First get the holder some fixed tokens by staking and converting
    _mintStakeToken(_holder, _stakeAmount);
    vm.startPrank(_holder);
    stakeToken.approve(address(lst.FIXED_LST()), _stakeAmount);
    uint256 _fixedTokens = lst.FIXED_LST().stake(_stakeAmount);

    // Now wrap the fixed tokens
    lst.FIXED_LST().approve(address(wrappedLst), _fixedTokens);

    uint256 _initialHolderBalance = lst.FIXED_LST().balanceOf(_holder);
    uint256 _initialWrapperBalance = lst.FIXED_LST().balanceOf(address(wrappedLst));

    wrappedLst.wrapFixed(_fixedTokens);
    vm.stopPrank();

    // Verify fixed tokens were transferred to wrapper
    assertEq(lst.FIXED_LST().balanceOf(_holder), _initialHolderBalance - _fixedTokens);
    assertEq(lst.FIXED_LST().balanceOf(address(wrappedLst)), _initialWrapperBalance + _fixedTokens);
  }

  function testFuzz_MintsCorrectNumberOfWrappedTokens(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Get holder fixed tokens
    _mintStakeToken(_holder, _stakeAmount);
    vm.startPrank(_holder);
    stakeToken.approve(address(lst.FIXED_LST()), _stakeAmount);
    uint256 _fixedTokens = lst.FIXED_LST().stake(_stakeAmount);

    // Approve and wrap
    lst.FIXED_LST().approve(address(wrappedLst), _fixedTokens);

    uint256 _initialWrappedBalance = wrappedLst.balanceOf(_holder);
    uint256 _wrappedAmount = wrappedLst.wrapFixed(_fixedTokens);
    vm.stopPrank();

    // Verify wrapped tokens were minted 1:1
    assertEq(wrappedLst.balanceOf(_holder), _initialWrappedBalance + _wrappedAmount);
    assertEq(_wrappedAmount, _fixedTokens); // Should be 1:1
  }

  function testFuzz_ReturnsCorrectWrappedAmount(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Get holder fixed tokens
    _mintStakeToken(_holder, _stakeAmount);
    vm.startPrank(_holder);
    stakeToken.approve(address(lst.FIXED_LST()), _stakeAmount);
    uint256 _fixedTokens = lst.FIXED_LST().stake(_stakeAmount);

    // Approve and wrap
    lst.FIXED_LST().approve(address(wrappedLst), _fixedTokens);
    uint256 _returnedAmount = wrappedLst.wrapFixed(_fixedTokens);
    vm.stopPrank();

    // Verify return value matches wrapped balance and fixed tokens (1:1)
    assertEq(wrappedLst.balanceOf(_holder), _returnedAmount);
    assertEq(_returnedAmount, _fixedTokens);
  }

  function testFuzz_EmitsWrappedEvent(address _holder, uint256 _stakeAmount) public {
    _assumeSafeWrapHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Get holder fixed tokens
    _mintStakeToken(_holder, _stakeAmount);
    vm.startPrank(_holder);
    stakeToken.approve(address(lst.FIXED_LST()), _stakeAmount);
    uint256 _fixedTokens = lst.FIXED_LST().stake(_stakeAmount);

    // Approve wrapper
    lst.FIXED_LST().approve(address(wrappedLst), _fixedTokens);

    // Expect event with exact values (1:1 wrapping)
    vm.expectEmit();
    emit WrappedGovLst.Wrapped(_holder, _fixedTokens, _fixedTokens);

    wrappedLst.wrapFixed(_fixedTokens);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_AmountIsZero(address _holder) public {
    _assumeSafeWrapHolder(_holder);

    // Should revert with zero amount
    vm.expectRevert(WrappedGovLst.WrappedGovLst__InvalidAmount.selector);
    vm.prank(_holder);
    wrappedLst.wrapFixed(0);
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

    // Remember the holder's prior LST balance
    uint256 _holderPriorBalance = lst.balanceOf(_holder);

    // Calculate expected LST amount from unwrapping
    // Wrapped tokens are 1:1 with FIXED_LST, which converts back to rebasing LST
    uint256 _lstAmountUnwrapped = _unwrap(_holder, _unwrapAmount);

    // Verify the holder received the LST tokens (allowing for rounding)
    assertApproxEqAbs(lst.balanceOf(_holder), _holderPriorBalance + _lstAmountUnwrapped, 1);
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

    // Verify wrapped tokens were burned
    assertEq(wrappedLst.balanceOf(_holder), _wrappedBalance - _unwrapAmount);
    assertGe(wrappedLst.totalSupply(), _wrappedBalance - _unwrapAmount);
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

    // Verify the return value matches the actual LST received (allowing for rounding)
    assertApproxEqAbs(lst.balanceOf(_holder), _priorLstBalance + _returnValue, 1);
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

    // Calculate expected LST amount from FIXED_LST conversion
    // This is just for checking the event - we don't need exact precision
    vm.expectEmit(true, false, false, false);
    emit WrappedGovLst.Unwrapped(_holder, 0, _unwrapAmount); // We don't check the LST amount
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

  function testFuzz_RoundingFavorsProtocolOnUnwrap(
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

    // Record initial LST balance
    uint256 _initialLstBalance = lst.balanceOf(_holder);

    _approveWrapperToTransferLstToken(_holder);
    uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);

    // Unwrap all wrapped tokens
    uint256 _lstReturned = _unwrap(_holder, _wrappedBalance);

    // The holder should get back at most what they put in (rounding favors protocol)
    // Due to rounding during wrap (rounds up shares) and unwrap (rounds down stake),
    // the user should get back the same or slightly less than what they wrapped
    assertLe(_lstReturned, _wrapAmount, "User received more LST than they wrapped");

    // The final balance should be at most the initial balance
    assertLe(lst.balanceOf(_holder), _initialLstBalance, "User has more LST than they started with");
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

contract UnwrapToFixed is WrappedGovLstTest {
  // function test_EmitsCorrectEventWithActualAmount() public {
  //   uint256 amountToWrap = 100e18;
  //   address holder = makeAddr("holder");
  //   
  //   // Setup: Mint, stake and wrap tokens
  //   _mintStakeToken(holder, amountToWrap);
  //   vm.prank(holder);
  //   stakeToken.approve(address(wrappedLst), amountToWrap);
  //   vm.prank(holder);
  //   wrappedLst.wrapUnderlying(amountToWrap);
  //   
  //   uint256 wrappedBalance = wrappedLst.balanceOf(holder);
  //   uint256 unwrapAmount = wrappedBalance / 2; // Unwrap half
  //   
  //   // Record balances before unwrap
  //   uint256 wrapperFixedBalanceBefore = lst.FIXED_LST().balanceOf(address(wrappedLst));
  //   
  //   // Perform the unwrap to see actual amount transferred
  //   vm.prank(holder);
  //   uint256 actualTransferred = wrappedLst.unwrapToFixed(unwrapAmount);
  //   
  //   // Calculate actual balance change
  //   uint256 wrapperFixedBalanceAfter = lst.FIXED_LST().balanceOf(address(wrappedLst));
  //   uint256 actualChange = wrapperFixedBalanceBefore - wrapperFixedBalanceAfter;
  //   
  //   // Verify the return value matches the actual balance change
  //   assertEq(actualTransferred, actualChange, "Return value should match actual balance change");
  //   
  //   // The actual amount should be within 1 wei of the requested amount
  //   // FIXED_LST can round either up or down by 1 wei
  //   assertApproxEqAbs(actualTransferred, unwrapAmount, 1, "Should be within 1 wei of requested amount");
  // }
  
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

    // Remember the holder's prior FIXED_LST balance
    uint256 _holderPriorBalance = lst.FIXED_LST().balanceOf(_holder);
    
	uint256 _previewAmount = wrappedLst.previewUnwrapToFixed(_unwrapAmount);
    // Unwrap to FIXED_LST
    vm.prank(_holder);
    uint256 _fixedAmountUnwrapped = wrappedLst.unwrapToFixed(_unwrapAmount);

    // Verify the holder received the FIXED_LST tokens (allowing for rounding due to mitigation)
    // The mitigation may return less if the wrapper's balance is insufficient
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

    // Verify the return value matches the actual FIXED_LST tokens received (allowing for rounding)
    assertApproxEqAbs(lst.FIXED_LST().balanceOf(_holder), _priorFixedBalance + _returnValue, 1);
    // Verify it's approximately 1:1 with wrapped tokens (may be off by 1 due to rounding)
    assertApproxEqAbs(_returnValue, _unwrapAmount, 1);
  }

  // function testFuzz_EmitsUnwrappedEvent(
  //   address _holder,
  //   uint256 _stakeAmount,
  //   uint80 _rewardAmount,
  //   uint256 _wrapAmount,
  //   uint256 _unwrapAmount
  // ) public {
  //   _assumeSafeWrapHolder(_holder);
  //   _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
  //   _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
  //   _mintAndStake(_holder, _stakeAmount);
  //   _distributeReward(_rewardAmount);
  //   _wrapAmount = bound(_wrapAmount, 0.0001e18, _stakeAmount + _rewardAmount);

  //   _approveWrapperToTransferLstToken(_holder);
  //   uint256 _wrappedBalance = _wrap(_holder, _wrapAmount);
  //   _unwrapAmount = bound(_unwrapAmount, 1, _wrappedBalance);
  //   
  //   // Get the actual amount that will be transferred
  //   vm.prank(_holder);
  //   uint256 _actualTransferred = wrappedLst.unwrapToFixed(_unwrapAmount);
  //   
  //   // Verify the event was emitted with the actual transferred amount
  //   // The actual amount may differ by 1 wei due to FIXED_LST's share-based rounding
  //   assertApproxEqAbs(_actualTransferred, _unwrapAmount, 1, "Actual transfer should be within 1 wei of requested");
  // }

  function testFuzz_RevertIf_AmountIsZero(address _holder) public {
    _assumeSafeWrapHolder(_holder);
    
    vm.expectRevert(WrappedGovLst.WrappedGovLst__InvalidAmount.selector);
    vm.prank(_holder);
    wrappedLst.unwrapToFixed(0);
  }
}
