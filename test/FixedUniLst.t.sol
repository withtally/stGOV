// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2, stdStorage, StdStorage, stdError} from "forge-std/Test.sol";
import {UniLstTest, UniLst} from "test/UniLst.t.sol";
import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {FixedUniLst, IUniStaker} from "src/FixedUniLst.sol";
import {FixedLstAddressAlias} from "src/FixedLstAddressAlias.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

using FixedLstAddressAlias for address;

contract FixedUniLstTest is UniLstTest {
  FixedUniLst fixedLst;

  function setUp() public virtual override {
    super.setUp();
    fixedLst = lst.FIXED_LST();
  }

  function _updateFixedDelegatee(address _holder, address _delegatee) internal {
    IUniStaker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

    vm.prank(_holder);
    fixedLst.updateDeposit(_depositId);
  }

  function _stakeFixed(address _holder, uint256 _amount) internal returns (uint256) {
    vm.startPrank(_holder);
    stakeToken.approve(address(fixedLst), _amount);
    uint256 _fixedTokens = fixedLst.stake(_amount);
    vm.stopPrank();
    return _fixedTokens;
  }

  function _mintAndStakeFixed(address _holder, uint256 _amount) internal returns (uint256) {
    _mintStakeToken(_holder, _amount);
    return _stakeFixed(_holder, _amount);
  }

  function _updateFixedDelegateeAndStakeFixed(address _holder, uint256 _amount, address _delegatee)
    internal
    returns (uint256)
  {
    _updateFixedDelegatee(_holder, _delegatee);
    return _stakeFixed(_holder, _amount);
  }

  function _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(address _holder, uint256 _amount, address _delegatee)
    internal
    returns (uint256)
  {
    _mintStakeToken(_holder, _amount);
    return _updateFixedDelegateeAndStakeFixed(_holder, _amount, _delegatee);
  }

  function _fix(address _holder, uint256 _amount) internal returns (uint256) {
    vm.startPrank(_holder);
    uint256 _fixedTokens = fixedLst.convertToFixed(_amount);
    vm.stopPrank();
    return _fixedTokens;
  }

  function _transferFixed(address _sender, address _receiver, uint256 _amount) internal {
    vm.startPrank(_sender);
    fixedLst.transfer(_receiver, _amount);
    vm.stopPrank();
  }

  function _unfix(address _holder, uint256 _amount) internal returns (uint256) {
    vm.startPrank(_holder);
    uint256 _lstTokens = fixedLst.convertToRebasing(_amount);
    vm.stopPrank();
    return _lstTokens;
  }

  function _unstakeFixed(address _holder, uint256 _amount) internal returns (uint256) {
    vm.startPrank(_holder);
    uint256 _stakeTokens = fixedLst.unstake(_amount);
    vm.stopPrank();
    return _stakeTokens;
  }

  // This simulates something we *don't* want users to do, namely send LST tokens directly to the alias address.
  function _sendLstTokensDirectlyToAlias(address _receiver, uint256 _amount) internal {
    address _sender = makeAddr("LST Sender");
    // Give the sender LST tokens
    _mintAndStake(_sender, _amount);
    // Send LST tokens to the receiver's *alias*
    vm.startPrank(_sender);
    lst.transfer(_receiver.fixedAlias(), lst.balanceOf(_sender));
    vm.stopPrank();
  }

  function __dumpFixedHolderState(address _holder) internal view {
    __dumpHolderState(_holder.fixedAlias());
    console2.log("FIXED HOLDER:");
    console2.log(_holder);
    console2.log("shareBalances");
    //console2.log(fixedLst.shareBalances(_holder));
    console2.log("balanceOf");
    console2.log(fixedLst.balanceOf(_holder));
  }
}

contract Constructor is FixedUniLstTest {
  function test_SetsConfigurationParameters() public view {
    assertEq(address(fixedLst.LST()), address(lst));
    assertEq(address(fixedLst.STAKE_TOKEN()), address(lst.STAKE_TOKEN()));
    assertEq(fixedLst.SHARE_SCALE_FACTOR(), lst.SHARE_SCALE_FACTOR());
    assertEq(fixedLst.name(), string.concat("Fixed ", lst.name()));
    assertEq(fixedLst.symbol(), string.concat("f", lst.symbol()));
  }
}

contract Approve is FixedUniLstTest {
  function testFuzz_CorrectlySetAllowance(address _caller, address _spender, uint256 _amount) public {
    vm.prank(_caller);
    bool approved = fixedLst.approve(_spender, _amount);
    assertEq(fixedLst.allowance(_caller, _spender), _amount);
    assertTrue(approved);
  }

  function testFuzz_SettingAllowanceEmitsApprovalEvent(address _caller, address _spender, uint256 _amount) public {
    vm.prank(_caller);
    vm.expectEmit();
    emit IERC20.Approval(_caller, _spender, _amount);
    fixedLst.approve(_spender, _amount);
  }
}

contract UpdateDeposit is FixedUniLstTest {
  function test_SetsTheDelegateeForTheHolderAliasOnTheLst(address _holder, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);

    _updateFixedDelegatee(_holder, _delegatee);

    address _aliasDelegatee = lst.delegateeForHolder(_holder.fixedAlias());
    assertEq(_aliasDelegatee, _delegatee);
  }
}

contract Stake is FixedUniLstTest {
  function testFuzz_MintsFixedTokensEqualToScaledDownShares(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintStakeToken(_holder, _amount);

    _stakeFixed(_holder, _amount);

    assertEq(lst.sharesOf(_holder.fixedAlias()) / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_holder));
  }

  function testFuzz_MintsLstTokensToAliasOfHolder(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintStakeToken(_holder, _amount);

    _stakeFixed(_holder, _amount);

    assertEq(lst.balanceOf(_holder.fixedAlias()), _amount);
  }

  function testFuzz_ReturnsTheNumberOfTokensAddedToTheHoldersFixedLstBalance(
    address _holder,
    uint256 _amount1,
    uint256 _amount2
  ) public {
    _assumeSafeHolder(_holder);
    _amount1 = _boundToReasonableStakeTokenAmount(_amount1);
    _amount2 = _boundToReasonableStakeTokenAmount(_amount2);

    _mintStakeToken(_holder, _amount1 + _amount2);
    uint256 _returnValue1 = _stakeFixed(_holder, _amount1);
    uint256 _returnValue2 = _stakeFixed(_holder, _amount2);

    assertEq(_returnValue1, _amount1);
    assertEq(_returnValue2, _amount2);
  }

  function testFuzz_AddsMintedTokensToTheFixedLstTotalSupply(address _holder, uint256 _amount1, uint256 _amount2)
    public
  {
    _assumeSafeHolder(_holder);
    _amount1 = _boundToReasonableStakeTokenAmount(_amount1);
    _amount2 = _boundToReasonableStakeTokenAmount(_amount2);
    _mintStakeToken(_holder, _amount1 + _amount2);

    uint256 _returnValue1 = _stakeFixed(_holder, _amount1);
    assertEq(fixedLst.totalSupply(), _returnValue1);

    uint256 _returnValue2 = _stakeFixed(_holder, _amount2);
    assertEq(fixedLst.totalSupply(), _returnValue1 + _returnValue2);
  }

  function testFuzz_AddsVotingWeightToTheHoldersFixedLstDelegatee(address _holder, uint256 _amount, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintStakeToken(_holder, _amount);
    _updateFixedDelegatee(_holder, _delegatee);
    _stakeFixed(_holder, _amount);

    assertEq(stakeToken.getCurrentVotes(_delegatee), _amount);
  }

  function testFuzz_EmitsATransferEventFromAddressZero(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintStakeToken(_holder, _amount);

    vm.startPrank(_holder);
    stakeToken.approve(address(fixedLst), _amount);
    vm.expectEmit();
    // Because there have been no rewards we know shares will be 1:1 with amount staked.
    emit IERC20.Transfer(address(0), _holder, _amount);
    fixedLst.stake(_amount);
    vm.stopPrank();
  }
}

contract ConvertToFixed is FixedUniLstTest {
  function testFuzz_MintsFixedTokensEqualToScaledDownShares(address _holder, uint256 _lstAmount, uint256 _fixedAmount)
    public
  {
    _assumeSafeHolder(_holder);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    // Amount converted to fixed is less than or equal to the amount staked.
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);

    // User stakes in the rebasing lst contract.
    _mintAndStake(_holder, _lstAmount);
    // User converts some rebasing lst tokens to fixed lst tokens.
    _fix(_holder, _fixedAmount);

    assertEq(lst.sharesOf(_holder.fixedAlias()) / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_holder));
  }

  function testFuzz_MovesLstTokensToAliasOfHolder(address _holder, uint256 _lstAmount, uint256 _fixedAmount) public {
    _assumeSafeHolder(_holder);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    // Amount converted to fixed is less than or equal to the amount staked.
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);

    // User stakes in the rebasing lst contract.
    _mintAndStake(_holder, _lstAmount);
    // User converts some rebasing lst tokens to fixed lst tokens.
    _fix(_holder, _fixedAmount);

    // The holder's rebasing lst balance has decreased.
    assertEq(lst.balanceOf(_holder), _lstAmount - _fixedAmount);
    // The holder's alias holds the fixed tokens.
    assertEq(lst.balanceOf(_holder.fixedAlias()), _fixedAmount);
  }

  function testFuzz_ReturnsTheNumberOfTokensAddedToTheHoldersFixedLstBalance(
    address _holder,
    uint256 _lstAmount,
    uint256 _fixedAmount
  ) public {
    _assumeSafeHolder(_holder);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    // Amount converted to fixed is less than or equal to the amount staked.
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);

    // User stakes in the rebasing lst contract.
    _mintAndStake(_holder, 2 * _lstAmount);
    // User converts some rebasing lst tokens to fixed lst tokens.
    uint256 _returnValue1 = _fix(_holder, _fixedAmount / 3);
    uint256 _balance1 = fixedLst.balanceOf(_holder);
    // User converts some more rebasing lst tokens to fixed lst tokens.
    uint256 _returnValue2 = _fix(_holder, (2 * _fixedAmount) / 3);
    uint256 _balance2 = fixedLst.balanceOf(_holder);

    assertEq(_returnValue1, _balance1);
    assertEq(_returnValue2, _balance2 - _balance1);
  }

  function testFuzz_AddsMintedTokensToTheFixedLstTotalSupply(address _holder, uint256 _lstAmount, uint256 _fixedAmount)
    public
  {
    _assumeSafeHolder(_holder);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    // Amount converted to fixed is less than or equal to the amount staked.
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);
    // User stakes in the rebasing lst contract.
    _mintAndStake(_holder, 2 * _lstAmount);

    // User converts some rebasing lst tokens to fixed lst tokens.
    uint256 _returnValue1 = _fix(_holder, _fixedAmount / 3);
    assertEq(fixedLst.totalSupply(), _returnValue1);

    // User converts some more rebasing lst tokens to fixed lst tokens.
    uint256 _returnValue2 = _fix(_holder, (2 * _fixedAmount) / 3);
    assertEq(fixedLst.totalSupply(), _returnValue1 + _returnValue2);
  }

  function testFuzz_AddsVotingWeightToTheHoldersFixedLstDelegatee(
    address _holder,
    uint256 _lstAmount,
    uint256 _fixedAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _fixedAmount = _boundToReasonableStakeTokenAmount(_lstAmount);

    _mintAndStake(_holder, _lstAmount);
    _updateFixedDelegatee(_holder, _delegatee);
    _fix(_holder, _fixedAmount);

    // Fixed tokens are assigned to the fixed delegatee.
    assertEq(stakeToken.getCurrentVotes(_delegatee), _fixedAmount);
    // Rebasing tokens are still assigned to the default delegatee.
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), _lstAmount - _fixedAmount);
  }

  function testFuzz_EmitsATransferEventFromAddressZero(address _holder, uint256 _lstAmount, uint256 _fixedAmount)
    public
  {
    _assumeSafeHolder(_holder);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    // Amount converted to fixed is less than or equal to the amount staked.
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);
    // User stakes in the rebasing lst contract.
    _mintAndStake(_holder, _lstAmount);

    vm.expectEmit();
    emit IERC20.Transfer(address(0), _holder, _fixedAmount);
    _fix(_holder, _fixedAmount);
  }
}

contract Transfer is FixedUniLstTest {
  function testFuzz_MovesLstTokensFromSenderAliasToReceiverAlias(
    address _sender,
    address _receiver,
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _senderDelegatee,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_sender, _stakeAmount, _senderDelegatee);
    _updateFixedDelegatee(_receiver, _receiverDelegatee);
    _transferFixed(_sender, _receiver, _sendAmount);

    assertEq(lst.balanceOf(_sender.fixedAlias()), _stakeAmount - _sendAmount);
    assertEq(lst.balanceOf(_receiver.fixedAlias()), _sendAmount);
  }

  function testFuzz_MovesFixedLstTokensFromSenderToReceiverAfterARewardIsDistributed(
    address _sender,
    address _receiver,
    uint80 _rewardAmount,
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _senderDelegatee,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    // A user stakes directly in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_sender, _stakeAmount, _senderDelegatee);
    uint256 _senderInitialBalance = fixedLst.balanceOf(_sender);
    // A reward is distributed.
    _distributeReward(_rewardAmount);
    // The user transfers some of their fixed LST tokens.
    _sendAmount = bound(_sendAmount, 0, _senderInitialBalance);
    _transferFixed(_sender, _receiver, _sendAmount);
    // The receiver updates their fixed delegatee.
    _updateFixedDelegatee(_receiver, _receiverDelegatee);

    assertApproxEqAbs(fixedLst.balanceOf(_sender), _senderInitialBalance - _sendAmount, 1);
    assertEq(fixedLst.balanceOf(_sender), lst.sharesOf(_sender.fixedAlias()) / SHARE_SCALE_FACTOR);
    assertApproxEqAbs(fixedLst.balanceOf(_receiver), _sendAmount, 1);
    assertEq(fixedLst.balanceOf(_receiver), lst.sharesOf(_receiver.fixedAlias()) / SHARE_SCALE_FACTOR);
  }

  function testFuzz_MaintainsUnderlyingLstBalanceAcrossSenderAndReceiverAliasesAfterRewardIsDistributed(
    address _sender,
    address _receiver,
    uint80 _rewardAmount,
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _senderDelegatee,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    // A user stakes directly in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_sender, _stakeAmount, _senderDelegatee);
    // A reward is distributed.
    _distributeReward(_rewardAmount);
    // The user transfers some of their fixed LST tokens.
    _sendAmount = bound(_sendAmount, 0, fixedLst.balanceOf(_sender));
    _transferFixed(_sender, _receiver, _sendAmount);
    // The receiver updates their fixed delegatee.
    _updateFixedDelegatee(_receiver, _receiverDelegatee);

    // Calculate the sum of the balances of the sender and the receiver aliases in the rebasing lst.
    uint256 _lstBalanceSum = lst.balanceOf(_sender.fixedAlias()) + lst.balanceOf(_receiver.fixedAlias());
    // This should be equal to the amount staked plus the reward distributed, within 1 wei.
    assertApproxEqAbs(_lstBalanceSum, _stakeAmount + _rewardAmount, 1);
    assertLe(_lstBalanceSum, _stakeAmount + _rewardAmount);
  }

  function testFuzz_MovesVotingWeightBetweenSenderAndReceiverDelegatees(
    address _sender,
    address _receiver,
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _senderDelegatee,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_sender, _stakeAmount, _senderDelegatee);
    _updateFixedDelegatee(_receiver, _receiverDelegatee);
    _transferFixed(_sender, _receiver, _sendAmount);

    assertEq(stakeToken.getCurrentVotes(_senderDelegatee), _stakeAmount - _sendAmount);
    assertEq((stakeToken.getCurrentVotes(_receiverDelegatee)), _sendAmount);
  }

  function testFuzz_EmitsATransferEvent(
    address _sender,
    address _receiver,
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _senderDelegatee,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_sender, _stakeAmount, _senderDelegatee);
    _updateFixedDelegatee(_receiver, _receiverDelegatee);
    vm.expectEmit();
    emit IERC20.Transfer(_sender, _receiver, _sendAmount);
    _transferFixed(_sender, _receiver, _sendAmount);
  }

  function testFuzz_RevertIf_HolderTransfersMoreThanBalance(
    address _sender,
    address _receiver,
    uint256 _stakeAmount,
    uint256 _sendAmount
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    uint256 _fixedBalance = _mintAndStakeFixed(_sender, _stakeAmount);
    _sendAmount = bound(_sendAmount, _fixedBalance + 1, type(uint256).max);

    vm.startPrank(_sender);
    vm.expectRevert(FixedUniLst.FixedUniLst__InsufficientBalance.selector);
    fixedLst.transfer(_receiver, _sendAmount);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_HolderTriesToTransferLstTokensThatWereSentToItsAlias(
    address _sender,
    address _receiver,
    uint256 _stakeAmount,
    uint256 _amountSentToAlias,
    uint256 _sendAmount
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _amountSentToAlias = _boundToReasonableStakeTokenAmount(_amountSentToAlias);

    // Sender stakes in fixed lst.
    uint256 _fixedBalance = _mintAndStakeFixed(_sender, _stakeAmount);
    // Someone mistakenly sends lst tokens directly to the sender alias.
    _sendLstTokensDirectlyToAlias(_sender, _amountSentToAlias);
    // The alias now has more shares than represented by the sender's fixed lst balance.
    uint256 _aliasShares = lst.sharesOf(_sender.fixedAlias());
    assertGt(_aliasShares / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_sender));
    // The sender will try to send an amount more than his balance to access the excess shares.
    _sendAmount = bound(_sendAmount, _fixedBalance + 1, _aliasShares / SHARE_SCALE_FACTOR);

    vm.startPrank(_sender);
    vm.expectRevert(FixedUniLst.FixedUniLst__InsufficientBalance.selector);
    fixedLst.transfer(_receiver, _sendAmount);
    vm.stopPrank();
  }
}

contract TransferFrom is FixedUniLstTest {
  function testFuzz_MovesFullBalanceToAReceiver(uint256 _amount, address _caller, address _sender, address _receiver)
    public
  {
    _assumeSafeHolders(_sender, _receiver);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _amount = _mintAndStakeFixed(_sender, _amount);

    vm.prank(_sender);
    fixedLst.approve(_caller, _amount);

    vm.prank(_caller);
    fixedLst.transferFrom(_sender, _receiver, _amount);

    assertEq(fixedLst.balanceOf(_sender), 0);
    assertEq(fixedLst.balanceOf(_receiver), _amount);
  }

  function testFuzz_MovesPartialBalanceToAReceiver(
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _caller,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _stakeAmount = _mintAndStakeFixed(_sender, _stakeAmount);
    // Amount to send should be less than or equal to the full amount
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    vm.prank(_sender);
    fixedLst.approve(_caller, _sendAmount);

    vm.prank(_caller);
    fixedLst.transferFrom(_sender, _receiver, _sendAmount);

    assertEq(fixedLst.balanceOf(_sender), _stakeAmount - _sendAmount);
    assertEq(fixedLst.balanceOf(_receiver), _sendAmount);
  }

  function testFuzz_CorrectlyDecrementsAllowance(
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _caller,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _stakeAmount = _mintAndStakeFixed(_sender, _stakeAmount);
    // Amount to send should be less than or equal to the full amount
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    vm.prank(_sender);
    fixedLst.approve(_caller, _stakeAmount);

    vm.prank(_caller);
    fixedLst.transferFrom(_sender, _receiver, _sendAmount);

    assertEq(fixedLst.allowance(_sender, _caller), _stakeAmount - _sendAmount);
  }

  function testFuzz_DoesNotDecrementAllowanceIfMaxUint(
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _caller,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    _stakeAmount = _mintAndStakeFixed(_sender, _stakeAmount);
    // Amount to send should be less than or equal to the full amount
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    vm.prank(_sender);
    fixedLst.approve(_caller, type(uint256).max);

    vm.prank(_caller);
    fixedLst.transferFrom(_sender, _receiver, _sendAmount);

    assertEq(fixedLst.allowance(_sender, _caller), type(uint256).max);
  }

  function testFuzz_RevertIf_NotEnoughAllowanceGiven(
    uint256 _amount,
    uint256 _allowanceAmount,
    address _caller,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _amount = _mintAndStakeFixed(_sender, _amount);
    // Amount to send should be less than or equal to the full stake amount
    _allowanceAmount = bound(_allowanceAmount, 0, _amount - 1);

    vm.prank(_sender);
    fixedLst.approve(_caller, _allowanceAmount);

    vm.prank(_caller);
    vm.expectRevert(stdError.arithmeticError);
    fixedLst.transferFrom(_sender, _receiver, _amount);
  }
}

contract ConvertToRebasing is FixedUniLstTest {
  function testFuzz_RemovesFixedLstTokensFromBalanceOfHolder(address _holder, uint256 _stakeAmount, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    uint256 _initialBalance = fixedLst.balanceOf(_holder);
    // Unfix one third of the tokens staked.
    uint256 _unfixAmount = _initialBalance / 3;
    _unfix(_holder, _unfixAmount);

    assertEq(fixedLst.balanceOf(_holder), _initialBalance - _unfixAmount);
  }

  function testFuzz_MovesLstTokensFromHolderAliasToHolderAddress(
    address _holder,
    uint256 _stakeAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    // Unfix one third of the tokens staked.
    uint256 _unfixAmount = fixedLst.balanceOf(_holder) / 3;
    _unfix(_holder, _unfixAmount);

    assertApproxEqAbs(lst.balanceOf(_holder.fixedAlias()), (2 * _stakeAmount) / 3, 1);
    assertApproxEqAbs(lst.balanceOf(_holder), _stakeAmount / 3, 1);
  }

  function testFuzz_MovesLstTokensFromHolderAliasToHolderAddressAfterReward(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    // A reward is distributed.
    _distributeReward(_rewardAmount);

    // Because fixed lst token holders can only operate on scaled down shares, they lose up to the value of the
    // scale factor in stake tokens. We calculate this for use in the assertions.
    uint256 _maxPrecisionLoss = lst.stakeForShares(SHARE_SCALE_FACTOR) + 2;

    // Unfix one third of the tokens staked.
    uint256 _unfixAmount = fixedLst.balanceOf(_holder) / 3;
    _unfix(_holder, _unfixAmount);
    // The total number of stake tokens in the system.
    uint256 _totalAmount = _stakeAmount + _rewardAmount;

    uint256 _expectedAliasBalance = (2 * _totalAmount) / 3;
    uint256 _actualAliasBalance = lst.balanceOf(_holder.fixedAlias());
    uint256 _expectedHolderBalance = _totalAmount / 3;
    uint256 _actualHolderBalance = lst.balanceOf(_holder);

    assertApproxEqAbs(_actualAliasBalance, _expectedAliasBalance, _maxPrecisionLoss);
    assertGe(_actualAliasBalance, _expectedAliasBalance);
    assertApproxEqAbs(_actualHolderBalance, _expectedHolderBalance, _maxPrecisionLoss);
    assertLe(_actualHolderBalance, _expectedHolderBalance);
  }

  function testFuzz_ReturnsTheNumberOfLstTokensThatAreUnfixed(address _holder, uint256 _stakeAmount, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    // Unfix one third of the tokens staked.
    uint256 _unfixAmount = fixedLst.balanceOf(_holder) / 3;
    uint256 _returnValue = _unfix(_holder, _unfixAmount);

    assertEq(_returnValue, _stakeAmount / 3);
  }

  function testFuzz_RemovesTokensFromTheFixedLstTotalSupply(address _holder, uint256 _stakeAmount, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Stake tokens in the fixed LST.
    uint256 _initialStaked = _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    // Unfix one third of the tokens staked.
    uint256 _unfixAmount = fixedLst.balanceOf(_holder) / 3;
    _unfix(_holder, _unfixAmount);

    assertEq(fixedLst.totalSupply(), _initialStaked - _unfixAmount);
  }

  function testFuzz_RemovesVotingWeightFromTheFixedDelegateeOfTheHolder(
    address _holder,
    uint256 _stakeAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    // Unfix one third of the tokens staked.
    uint256 _unfixAmount = fixedLst.balanceOf(_holder) / 3;
    _unfix(_holder, _unfixAmount);

    assertApproxEqAbs(stakeToken.getCurrentVotes(_delegatee), (2 * _stakeAmount) / 3, 1);
    assertApproxEqAbs(stakeToken.getCurrentVotes(defaultDelegatee), _stakeAmount / 3, 1);
  }

  function testFuzz_EmitsATransferEventToTheZeroAddress(address _holder, uint256 _stakeAmount, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    uint256 _initialBalance = fixedLst.balanceOf(_holder);
    // Unfix one third of the tokens staked.
    uint256 _unfixAmount = _initialBalance / 3;

    vm.expectEmit();
    emit IERC20.Transfer(_holder, address(0), _unfixAmount);
    _unfix(_holder, _unfixAmount);
  }

  function testFuzz_RevertIf_HolderUnfixesMoreThanBalance(address _holder, uint256 _stakeAmount, uint256 _unfixAmount)
    public
  {
    _assumeSafeHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    uint256 _fixedBalance = _mintAndStakeFixed(_holder, _stakeAmount);
    _unfixAmount = bound(_unfixAmount, _fixedBalance + 1, type(uint256).max);

    vm.startPrank(_holder);
    vm.expectRevert(stdError.arithmeticError);
    fixedLst.convertToRebasing(_unfixAmount);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_HolderTriesToUnfixLstTokensSentDirectlyToTheAlias(
    address _holder,
    uint256 _stakeAmount,
    uint256 _amountSentToAlias,
    uint256 _unfixAmount
  ) public {
    _assumeSafeHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _amountSentToAlias = _boundToReasonableStakeTokenAmount(_amountSentToAlias);

    // Holder stakes in fixed lst.
    uint256 _fixedBalance = _mintAndStakeFixed(_holder, _stakeAmount);
    // Someone mistakenly sends lst tokens directly to the holder alias.
    _sendLstTokensDirectlyToAlias(_holder, _amountSentToAlias);
    // The alias now has more shares than represented by the holder's fixed lst balance.
    uint256 _aliasShares = lst.sharesOf(_holder.fixedAlias());
    assertGt(_aliasShares / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_holder));
    // The holder will try to unfix an amount more than his balance to access the excess shares.
    _unfixAmount = bound(_unfixAmount, _fixedBalance + 1, _aliasShares / SHARE_SCALE_FACTOR);

    vm.startPrank(_holder);
    vm.expectRevert(stdError.arithmeticError);
    fixedLst.convertToRebasing(_unfixAmount);
    vm.stopPrank();
  }
}

contract Unstake is FixedUniLstTest {
  function testFuzz_MovesStakeTokensIntoTheWalletOfTheHolderWhenThereIsNoWithdrawDelay(
    address _holder,
    uint256 _stakeAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // There is no delay on the withdraw gate, so tokens go straight to the holder on unstake.
    vm.prank(lstOwner);
    withdrawGate.setDelay(0);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    uint256 _initialBalance = fixedLst.balanceOf(_holder);
    // Unstake one quarter of the tokens staked.
    uint256 _unstakeAmount = fixedLst.balanceOf(_holder) / 4;
    _unstakeFixed(_holder, _unstakeAmount);

    // One quarter of the stake tokens are back in the holder's balance.
    assertEq(stakeToken.balanceOf(_holder), _stakeAmount / 4);
    // The holder still has the remaining fixed tokens.
    assertEq(fixedLst.balanceOf(_holder), _initialBalance - _unstakeAmount);
  }

  function testFuzz_MovesStakeTokensIntoTheWithdrawGateWhenThereIsAWithdrawDelay(
    address _holder,
    uint256 _stakeAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    uint256 _initialBalance = fixedLst.balanceOf(_holder);
    // Unstake one quarter of the tokens staked.
    uint256 _unstakeAmount = fixedLst.balanceOf(_holder) / 4;
    _unstakeFixed(_holder, _unstakeAmount);

    // One quarter of the stake tokens are back in the holder's balance.
    assertEq(stakeToken.balanceOf(address(withdrawGate)), _stakeAmount / 4);
    // The holder still has the remaining fixed tokens.
    assertEq(fixedLst.balanceOf(_holder), _initialBalance - _unstakeAmount);
  }

  function testFuzz_RemovesVotingWeightFromTheFixedDelegateeOfTheHolder(
    address _holder,
    uint256 _stakeAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    fixedLst.balanceOf(_holder);
    // Unstake one quarter of the tokens staked.
    uint256 _unstakeAmount = fixedLst.balanceOf(_holder) / 4;
    _unstakeFixed(_holder, _unstakeAmount);

    assertApproxEqAbs(stakeToken.getCurrentVotes(_delegatee), (3 * _stakeAmount) / 4, 1);
  }

  function testFuzz_ReturnsTheNumberOfStakeTokensUnstaked(address _holder, uint256 _stakeAmount, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // There is no delay on the withdraw gate, so tokens go straight to the holder on unstake.
    vm.prank(lstOwner);
    withdrawGate.setDelay(0);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    fixedLst.balanceOf(_holder);
    // Unstake one quarter of the tokens staked.
    uint256 _unstakeAmount = fixedLst.balanceOf(_holder) / 4;
    uint256 _returnValue = _unstakeFixed(_holder, _unstakeAmount);

    assertEq(_returnValue, stakeToken.balanceOf(_holder));
  }

  function testFuzz_RemovesLstTokensFromBalanceOfHolderAlias(address _holder, uint256 _stakeAmount, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // There is no delay on the withdraw gate, so tokens go straight to the holder on unstake.
    vm.prank(lstOwner);
    withdrawGate.setDelay(0);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    fixedLst.balanceOf(_holder);
    // Unstake one quarter of the tokens staked.
    uint256 _unstakeAmount = fixedLst.balanceOf(_holder) / 4;
    _unstakeFixed(_holder, _unstakeAmount);

    assertApproxEqAbs(lst.balanceOf(_holder.fixedAlias()), (3 * _stakeAmount) / 4, 1);
    assertEq(lst.sharesOf(_holder.fixedAlias()) / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_holder));
  }

  function testFuzz_RemovesLstTokensFromBalanceOfHolderAliasAfterReward(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    // There is no delay on the withdraw gate, so tokens go straight to the holder on unstake.
    vm.prank(lstOwner);
    withdrawGate.setDelay(0);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    // A reward is distributed.
    _distributeReward(_rewardAmount);

    // Because fixed lst token holders can only operate on scaled down shares, they lose up to the value of the
    // scale factor in stake tokens. We calculate this for use in the assertions.
    uint256 _maxPrecisionLoss = lst.stakeForShares(SHARE_SCALE_FACTOR) + 2;

    // Unstake one fourth of the tokens staked.
    uint256 _unstakeAmount = fixedLst.balanceOf(_holder) / 4;
    _unstakeFixed(_holder, _unstakeAmount);
    // The total number of stake tokens in the system.
    uint256 _totalAmount = _stakeAmount + _rewardAmount;

    uint256 _expectedAliasBalance = (3 * _totalAmount) / 4;
    uint256 _actualAliasBalance = lst.balanceOf(_holder.fixedAlias());
    uint256 _expectedHolderBalance = _totalAmount / 4;
    uint256 _actualHolderBalance = stakeToken.balanceOf(_holder);

    assertApproxEqAbs(_actualAliasBalance, _expectedAliasBalance, _maxPrecisionLoss);
    assertGe(_actualAliasBalance, _expectedAliasBalance);
    assertApproxEqAbs(_actualHolderBalance, _expectedHolderBalance, _maxPrecisionLoss);
    assertLe(_actualHolderBalance, _expectedHolderBalance);
  }

  function testFuzz_RemovesFromFixedLstTotalSupplyAfterReward(
    address _holder,
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    // There is no delay on the withdraw gate, so tokens go straight to the holder on unstake.
    vm.prank(lstOwner);
    withdrawGate.setDelay(0);

    // Stake tokens in the fixed LST.
    uint256 _initialStaked = _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    // A reward is distributed.
    _distributeReward(_rewardAmount);

    // Unstake one fourth of the tokens staked.
    uint256 _unstakeAmount = fixedLst.balanceOf(_holder) / 4;
    _unstakeFixed(_holder, _unstakeAmount);

    assertEq(fixedLst.totalSupply(), _initialStaked - _unstakeAmount);
  }

  function testFuzz_EmitsATransferEventToTheZeroAddress(address _holder, uint256 _stakeAmount, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // There is no delay on the withdraw gate, so tokens go straight to the holder on unstake.
    vm.prank(lstOwner);
    withdrawGate.setDelay(0);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    fixedLst.balanceOf(_holder);
    // Unstake one quarter of the tokens staked.
    uint256 _unstakeAmount = fixedLst.balanceOf(_holder) / 4;

    vm.expectEmit();
    emit IERC20.Transfer(_holder, address(0), _unstakeAmount);
    _unstakeFixed(_holder, _unstakeAmount);
  }

  function testFuzz_RevertIf_HolderUnstakesMoreThanBalance(
    address _holder,
    uint256 _stakeAmount,
    uint256 _unstakeAmount
  ) public {
    _assumeSafeHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    uint256 _fixedBalance = _mintAndStakeFixed(_holder, _stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, _fixedBalance + 1, type(uint256).max);

    vm.startPrank(_holder);
    vm.expectRevert(stdError.arithmeticError);
    fixedLst.unstake(_unstakeAmount);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_HolderTriesToUnstakeLstTokensSentDirectlyToTheAlias(
    address _holder,
    uint256 _stakeAmount,
    uint256 _amountSentToAlias,
    uint256 _unstakeAmount
  ) public {
    _assumeSafeHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _amountSentToAlias = _boundToReasonableStakeTokenAmount(_amountSentToAlias);

    // Holder stakes in fixed lst.
    uint256 _fixedBalance = _mintAndStakeFixed(_holder, _stakeAmount);
    // Someone mistakenly sends lst tokens directly to the holder alias.
    _sendLstTokensDirectlyToAlias(_holder, _amountSentToAlias);
    // The alias now has more shares than represented by the holder's fixed lst balance.
    uint256 _aliasShares = lst.sharesOf(_holder.fixedAlias());
    assertGt(_aliasShares / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_holder));
    // The holder will try to unstake an amount more than his balance to access the excess shares.
    _unstakeAmount = bound(_unstakeAmount, _fixedBalance + 1, _aliasShares / SHARE_SCALE_FACTOR);

    vm.startPrank(_holder);
    vm.expectRevert(stdError.arithmeticError);
    fixedLst.unstake(_unstakeAmount);
    vm.stopPrank();
  }
}

contract Delegate is FixedUniLstTest {
  function testFuzz_UpdatesCallersDepositToExistingDelegatee(address _holder, address _delegatee, uint256 _amount)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    IUniStaker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintStakeToken(_holder, _amount);
    _stakeFixed(_holder, _amount);

    vm.prank(_holder);
    fixedLst.delegate(_delegatee);

    assertEq(fixedLst.delegates(_holder), _delegatee);
  }

  function testFuzz_UpdatesCallersDepositToANewDelegatee(address _holder, address _delegatee, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);

    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintStakeToken(_holder, _amount);
    _stakeFixed(_holder, _amount);

    vm.prank(_holder);
    fixedLst.delegate(_delegatee);

    assertEq(fixedLst.delegates(_holder), _delegatee);
  }
}

contract Rescue is FixedUniLstTest {
  function testFuzz_AddsLstTokensMistakenlySentToTheAliasAddressOfAHolderToFixedLstBalance(
    address _holder,
    uint256 _initialStakeAmount,
    uint256 _rescueAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);

    // Holder stakes in fixed lst.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _initialStakeAmount, _delegatee);
    // Someone mistakenly sends lst tokens directly to the holder alias.
    _sendLstTokensDirectlyToAlias(_holder, _rescueAmount);

    vm.prank(_holder);
    fixedLst.rescue();

    uint256 _expectedBalance = lst.sharesForStake(_initialStakeAmount + _rescueAmount) / SHARE_SCALE_FACTOR;
    assertEq(fixedLst.balanceOf(_holder), _expectedBalance);
  }

  function testFuzz_AddsLstTokensMistakenlySentToTheAliasAddressOfAHolderToFixedLstTotalSupply(
    address _holder,
    uint256 _initialStakeAmount,
    uint256 _rescueAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);

    // Holder stakes in fixed lst.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _initialStakeAmount, _delegatee);
    // Someone mistakenly sends lst tokens directly to the holder alias.
    _sendLstTokensDirectlyToAlias(_holder, _rescueAmount);

    vm.prank(_holder);
    fixedLst.rescue();

    uint256 _expectedTotalSupply = lst.sharesForStake(_initialStakeAmount + _rescueAmount) / SHARE_SCALE_FACTOR;
    assertEq(fixedLst.totalSupply(), _expectedTotalSupply);
  }

  function testFuzz_ReturnsTheNumberOfFixedLstTokensAddedToTheBalanceOfTheHolder(
    address _holder,
    uint256 _initialStakeAmount,
    uint256 _rescueAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);

    // Holder stakes in fixed lst.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _initialStakeAmount, _delegatee);
    // Someone mistakenly sends lst tokens directly to the holder alias.
    _sendLstTokensDirectlyToAlias(_holder, _rescueAmount);

    vm.prank(_holder);
    uint256 _returnValue = fixedLst.rescue();

    uint256 _expectedReturnValue = lst.sharesForStake(_rescueAmount) / SHARE_SCALE_FACTOR;
    assertEq(_returnValue, _expectedReturnValue);
  }

  function testFuzz_EmitsATransferEventFromTheZeroAddress(
    address _holder,
    uint256 _initialStakeAmount,
    uint256 _rescueAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);

    // Holder stakes in fixed lst.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _initialStakeAmount, _delegatee);
    // Someone mistakenly sends lst tokens directly to the holder alias.
    _sendLstTokensDirectlyToAlias(_holder, _rescueAmount);

    uint256 _expectedRescue = lst.sharesForStake(_rescueAmount) / SHARE_SCALE_FACTOR;

    vm.startPrank(_holder);
    vm.expectEmit();
    emit IERC20.Transfer(address(0), _holder, _expectedRescue);
    fixedLst.rescue();
    vm.stopPrank();
  }

  function testFuzz_DoesNothingIfThereAreNoLstTokensToRescue(
    address _holder,
    uint256 _initialStakeAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);

    // Holder stakes in fixed lst.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _initialStakeAmount, _delegatee);

    vm.startPrank(_holder);
    uint256 _rescueReturnValue = fixedLst.rescue();

    assertEq(_rescueReturnValue, 0);
    assertEq(fixedLst.balanceOf(_holder), lst.sharesForStake(_initialStakeAmount) / SHARE_SCALE_FACTOR);
  }

  function testFuzz_AddsLstTokensMistakenlySentToTheAliasAddressOfAHolderToFixedLstBalanceAfterAReward(
    address _holder,
    uint256 _initialStakeAmount,
    uint80 _rewardAmount,
    uint256 _rescueAmount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    // Holder stakes in fixed lst.
    uint256 _initialFixedAmount =
      _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _initialStakeAmount, _delegatee);
    // A reward is distributed.
    _distributeReward(_rewardAmount);
    // Someone mistakenly sends lst tokens directly to the holder alias.
    _sendLstTokensDirectlyToAlias(_holder, _rescueAmount);

    vm.prank(_holder);
    fixedLst.rescue();

    uint256 _expectedBalance = _initialFixedAmount + (lst.sharesForStake(_rescueAmount) / SHARE_SCALE_FACTOR);
    // Because `sharesForStake` rounds up we may have up to 1 wei less than calculated expected balance.
    assertApproxEqAbs(fixedLst.balanceOf(_holder), _expectedBalance, 1);
    assertLe(fixedLst.balanceOf(_holder), _expectedBalance);
  }
}
