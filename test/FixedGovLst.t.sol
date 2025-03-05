// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console2, stdStorage, StdStorage, stdError, Vm} from "forge-std/Test.sol";
import {GovLstTest} from "./GovLst.t.sol";
import {FixedGovLst} from "../src/FixedGovLst.sol";
import {FixedGovLstHarness} from "./harnesses/FixedGovLstHarness.sol";
import {FixedLstAddressAlias} from "../src/FixedLstAddressAlias.sol";
import {Staker} from "staker/Staker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

using FixedLstAddressAlias for address;

contract FixedGovLstTest is GovLstTest {
  FixedGovLstHarness fixedLst;

  function setUp() public virtual override {
    super.setUp();
    fixedLst = FixedGovLstHarness(address(lst.FIXED_LST()));
  }

  function _stakeOnDelegateeFixedDeposit(Staker.DepositIdentifier _depositId, address _depositor) internal {
    _mintAndStakeFixed(_depositor, 1e18);
    vm.startPrank(_depositor);
    fixedLst.updateDeposit(_depositId);
    vm.stopPrank();
  }

  function _unstakeOnDelegateeFixedDeposit(address _depositor) internal {
    uint256 _time = block.timestamp;
    vm.startPrank(_depositor);
    uint256 _identifier = withdrawGate.getNextWithdrawalId();
    fixedLst.unstake(fixedLst.balanceOf(_depositor));
    if (withdrawGate.delay() != 0) {
      vm.warp(_time + withdrawGate.delay());
      withdrawGate.completeWithdrawal(_identifier);
      vm.warp(_time);
    }
    vm.stopPrank();
  }

  function _updateFixedDelegatee(address _holder, address _delegatee) internal {
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _assumeSafeDelegatee(_delegatee);
    _stakeOnDelegateeFixedDeposit(_depositId, delegateeFunder);

    vm.prank(_holder);
    fixedLst.updateDeposit(_depositId);

    _unstakeOnDelegateeFixedDeposit(delegateeFunder);
  }

  function _stakeFixed(address _holder, uint256 _amount) internal returns (uint256) {
    vm.startPrank(_holder);
    stakeToken.approve(address(fixedLst), _amount);
    uint256 _fixedTokens = fixedLst.stake(_amount);
    vm.stopPrank();
    return _fixedTokens;
  }

  function _fixedApprove(address _staker, address _caller, uint256 _amount) internal {
    vm.startPrank(_staker);
    fixedLst.approve(_caller, _amount);
    vm.stopPrank();
  }

  function _mintAndStakeFixed(address _holder, uint256 _amount) internal returns (uint256) {
    _mintStakeToken(_holder, _amount);
    return _stakeFixed(_holder, _amount);
  }

  function _updateFixedDelegateeAndStakeFixed(address _holder, uint256 _amount, address _delegatee)
    internal
    returns (uint256)
  {
    uint256 _initialStaked = _stakeFixed(_holder, _amount);
    _updateFixedDelegatee(_holder, _delegatee);
    return _initialStaked;
  }

  function _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(address _holder, uint256 _amount, address _delegatee)
    internal
    returns (uint256)
  {
    _mintStakeToken(_holder, _amount);
    return _updateFixedDelegateeAndStakeFixed(_holder, _amount, _delegatee);
  }

  function _convertToFixed(address _holder, uint256 _amount) internal returns (uint256) {
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

  function _convertToRebasing(address _holder, uint256 _amount) internal returns (uint256) {
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

  function _signFixedMessage(
    bytes32 _typehash,
    address _account,
    uint256 _amount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _signerPrivateKey
  ) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(abi.encode(_typehash, _account, _amount, _nonce, _expiry));
    bytes32 hash = _hashTypedDataV4(
      EIP712_DOMAIN_TYPEHASH, structHash, bytes(fixedLst.name()), bytes(fixedLst.version()), address(fixedLst)
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPrivateKey, hash);
    return abi.encodePacked(r, s, v);
  }

  function _signFixedMessage(
    bytes32 _typehash,
    address _account,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _signerPrivateKey
  ) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(abi.encode(_typehash, _account, _nonce, _expiry));
    bytes32 hash = _hashTypedDataV4(
      EIP712_DOMAIN_TYPEHASH, structHash, bytes(fixedLst.name()), bytes(fixedLst.version()), address(fixedLst)
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPrivateKey, hash);
    return abi.encodePacked(r, s, v);
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

contract Constructor is FixedGovLstTest {
  function test_SetsConfigurationParameters() public view {
    assertEq(address(fixedLst.LST()), address(lst));
    assertEq(address(fixedLst.STAKE_TOKEN()), address(lst.STAKE_TOKEN()));
    assertEq(fixedLst.SHARE_SCALE_FACTOR(), lst.SHARE_SCALE_FACTOR());
    assertEq(fixedLst.name(), tokenName);
    assertEq(fixedLst.symbol(), tokenSymbol);
  }
}

contract Approve is FixedGovLstTest {
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

contract UpdateDeposit is FixedGovLstTest {
  function testFuzz_SetsTheDelegateeForTheHolderAliasOnTheLst(address _holder, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);

    _updateFixedDelegatee(_holder, _delegatee);

    address _aliasDelegatee = lst.delegateeForHolder(_holder.fixedAlias());
    assertEq(_aliasDelegatee, _delegatee);
  }

  function test_EmitsEventWhenTheDelegateeForTheHolderAliasOnTheLstIsUpdated(address _holder, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeFixedDeposit(_newDepositId, delegateeFunder);

    Staker.DepositIdentifier _oldDepositId = lst.depositIdForHolder(_holder.fixedAlias());

    vm.expectEmit();
    emit FixedGovLst.DepositUpdated(_holder, _oldDepositId, _newDepositId);

    vm.prank(_holder);
    fixedLst.updateDeposit(_newDepositId);
  }
}

contract Stake is FixedGovLstTest {
  function testFuzz_MintsFixedTokensEqualToScaledDownShares(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintStakeToken(_holder, _amount);

    _stakeFixed(_holder, _amount);

    assertEq(lst.sharesOf(_holder.fixedAlias()) / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_holder));
  }

  function testFuzz_EmitsFixedEvent(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintStakeToken(_holder, _amount);
    vm.prank(_holder);
    stakeToken.approve(address(fixedLst), _amount);

    vm.expectEmit();
    emit FixedGovLst.Fixed(_holder, _amount);
    vm.prank(_holder);
    fixedLst.stake(_amount);
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

    assertEq(ERC20Votes(address(stakeToken)).getVotes(_delegatee), _amount);
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

contract Permit is FixedGovLstTest {
  function _buildPermitStructHash(address _owner, address _spender, uint256 _value, uint256 _nonce, uint256 _deadline)
    internal
    pure
    returns (bytes32)
  {
    return keccak256(abi.encode(PERMIT_TYPEHASH, _owner, _spender, _value, _nonce, _deadline));
  }

  function testFuzz_AllowsApprovalViaSignature(
    uint256 _ownerPrivateKey,
    address _spender,
    address _sender,
    uint256 _value,
    uint256 _deadline
  ) public {
    _ownerPrivateKey = _boundToValidPrivateKey(_ownerPrivateKey);
    address _owner = vm.addr(_ownerPrivateKey);
    _assumeSafeHolders(_owner, _spender);
    _assumeFutureExpiry(_deadline);
    _value = _boundToReasonableStakeTokenAmount(_value);

    uint256 _nonce = ERC20Permit(address(fixedLst)).nonces(_owner);
    bytes32 structHash = _buildPermitStructHash(_owner, _spender, _value, _nonce, _deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      _ownerPrivateKey,
      _hashTypedDataV4(
        EIP712_DOMAIN_TYPEHASH, structHash, bytes(fixedLst.name()), bytes(fixedLst.version()), address(fixedLst)
      )
    );

    assertEq(fixedLst.allowance(_owner, _spender), 0);

    vm.prank(_sender);
    fixedLst.permit(_owner, _spender, _value, _deadline, v, r, s);

    assertEq(fixedLst.allowance(_owner, _spender), _value);
    assertEq(ERC20Permit(address(fixedLst)).nonces(_owner), _nonce + 1);
  }

  function testFuzz_EmitsApprovalEvent(
    uint256 _ownerPrivateKey,
    address _spender,
    address _sender,
    uint256 _value,
    uint256 _deadline
  ) public {
    _ownerPrivateKey = _boundToValidPrivateKey(_ownerPrivateKey);
    address _owner = vm.addr(_ownerPrivateKey);
    _assumeSafeHolders(_owner, _spender);
    _assumeFutureExpiry(_deadline);
    _value = _boundToReasonableStakeTokenAmount(_value);

    uint256 _nonce = ERC20Permit(address(fixedLst)).nonces(_owner);
    bytes32 structHash = _buildPermitStructHash(_owner, _spender, _value, _nonce, _deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      _ownerPrivateKey,
      _hashTypedDataV4(
        EIP712_DOMAIN_TYPEHASH, structHash, bytes(fixedLst.name()), bytes(fixedLst.version()), address(fixedLst)
      )
    );

    vm.prank(_sender);
    vm.expectEmit();
    emit IERC20.Approval(_owner, _spender, _value);
    fixedLst.permit(_owner, _spender, _value, _deadline, v, r, s);
  }

  function testFuzz_RevertIf_DeadlineExpired(
    uint256 _ownerPrivateKey,
    address _spender,
    address _sender,
    uint256 _value,
    uint256 _deadline,
    uint256 _futureTimestamp
  ) public {
    _ownerPrivateKey = _boundToValidPrivateKey(_ownerPrivateKey);
    address _owner = vm.addr(_ownerPrivateKey);
    _assumeSafeHolders(_owner, _spender);
    _value = _boundToReasonableStakeTokenAmount(_value);

    // Bound _deadline to be in the past relative to _futureTimestamp
    _futureTimestamp = bound(_futureTimestamp, block.timestamp + 1, type(uint256).max);
    _deadline = bound(_deadline, 0, _futureTimestamp - 1);

    // Warp to the future timestamp
    vm.warp(_futureTimestamp);

    uint256 _nonce = ERC20Permit(address(fixedLst)).nonces(_owner);
    bytes32 structHash = _buildPermitStructHash(_owner, _spender, _value, _nonce, _deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      _ownerPrivateKey,
      _hashTypedDataV4(
        EIP712_DOMAIN_TYPEHASH, structHash, bytes(fixedLst.name()), bytes(fixedLst.version()), address(fixedLst)
      )
    );

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__SignatureExpired.selector);
    fixedLst.permit(_owner, _spender, _value, _deadline, v, r, s);
  }

  function testFuzz_RevertIf_SignatureInvalid(
    uint256 _ownerPrivateKey,
    uint256 _wrongPrivateKey,
    address _spender,
    address _sender,
    uint256 _value,
    uint256 _deadline
  ) public {
    _ownerPrivateKey = _boundToValidPrivateKey(_ownerPrivateKey);
    _wrongPrivateKey = _boundToValidPrivateKey(_wrongPrivateKey);
    vm.assume(_ownerPrivateKey != _wrongPrivateKey);
    address _owner = vm.addr(_ownerPrivateKey);
    _assumeSafeHolders(_owner, _spender);
    _assumeFutureExpiry(_deadline);
    _value = _boundToReasonableStakeTokenAmount(_value);

    uint256 _nonce = ERC20Permit(address(fixedLst)).nonces(_owner);
    bytes32 structHash = _buildPermitStructHash(_owner, _spender, _value, _nonce, _deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      _wrongPrivateKey,
      _hashTypedDataV4(
        EIP712_DOMAIN_TYPEHASH, structHash, bytes(fixedLst.name()), bytes(fixedLst.version()), address(fixedLst)
      )
    );

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__InvalidSignature.selector);
    fixedLst.permit(_owner, _spender, _value, _deadline, v, r, s);
  }

  function testFuzz_RevertIf_SignatureReused(
    uint256 _ownerPrivateKey,
    address _spender,
    address _sender,
    uint256 _value,
    uint256 _deadline
  ) public {
    _ownerPrivateKey = _boundToValidPrivateKey(_ownerPrivateKey);
    address _owner = vm.addr(_ownerPrivateKey);
    _assumeSafeHolders(_owner, _spender);
    _assumeFutureExpiry(_deadline);
    _value = _boundToReasonableStakeTokenAmount(_value);

    uint256 _nonce = ERC20Permit(address(fixedLst)).nonces(_owner);
    bytes32 structHash = _buildPermitStructHash(_owner, _spender, _value, _nonce, _deadline);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      _ownerPrivateKey,
      _hashTypedDataV4(
        EIP712_DOMAIN_TYPEHASH, structHash, bytes(fixedLst.name()), bytes(fixedLst.version()), address(fixedLst)
      )
    );

    vm.prank(_sender);
    fixedLst.permit(_owner, _spender, _value, _deadline, v, r, s);

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__InvalidSignature.selector);
    fixedLst.permit(_owner, _spender, _value, _deadline, v, r, s);
  }
}

contract UpdateDepositOnBehalf is FixedGovLstTest {
  function testFuzz_SetsTheDelegateeForAnotherHolderAliasOnTheLstUsingSignatures(
    uint256 _nonce,
    uint256 _expiry,
    uint256 _holderPrivateKey,
    address _delegatee,
    address _sender
  ) public {
    _holderPrivateKey = _boundToValidPrivateKey(_holderPrivateKey);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);
    address _holder = vm.addr(_holderPrivateKey);

    // Sign the message
    _setNonce(address(fixedLst), _holder, _nonce);
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeFixedDeposit(_depositId, delegateeFunder);

    bytes memory _signature = _signFixedMessage(
      fixedLst.UPDATE_DEPOSIT_TYPEHASH(),
      _holder,
      Staker.DepositIdentifier.unwrap(_depositId),
      ERC20Permit(address(fixedLst)).nonces(_holder),
      _expiry,
      _holderPrivateKey
    );

    vm.prank(_sender);
    fixedLst.updateDepositOnBehalf(_holder, _depositId, _nonce, _expiry, _signature);

    address _aliasDelegatee = lst.delegateeForHolder(_holder.fixedAlias());
    assertEq(_aliasDelegatee, _delegatee);
  }

  function testFuzz_EmitsEventWhenTheDelegateeForTheHolderAliasOnTheLstIsUpdatedUsingSignatures(
    uint256 _nonce,
    uint256 _expiry,
    uint256 _holderPrivateKey,
    address _delegatee,
    address _sender
  ) public {
    _holderPrivateKey = _boundToValidPrivateKey(_holderPrivateKey);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);
    address _holder = vm.addr(_holderPrivateKey);

    // Sign the message
    _setNonce(address(fixedLst), _holder, _nonce);
    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeFixedDeposit(_newDepositId, delegateeFunder);

    Staker.DepositIdentifier _oldDepositId = lst.depositIdForHolder(_holder.fixedAlias());
    bytes memory _signature = _signFixedMessage(
      fixedLst.UPDATE_DEPOSIT_TYPEHASH(),
      _holder,
      Staker.DepositIdentifier.unwrap(_newDepositId),
      ERC20Permit(address(fixedLst)).nonces(_holder),
      _expiry,
      _holderPrivateKey
    );

    vm.expectEmit();
    emit FixedGovLst.DepositUpdated(_holder, _oldDepositId, _newDepositId);
    vm.prank(_sender);
    fixedLst.updateDepositOnBehalf(_holder, _newDepositId, _nonce, _expiry, _signature);
  }

  function testFuzz_RevertIf_InvalidSignature(
    address _holder,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _wrongPrivateKey,
    address _delegatee,
    address _sender
  ) public {
    _assumeSafeHolder(_holder);
    _wrongPrivateKey = _boundToValidPrivateKey(_wrongPrivateKey);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);

    // Sign the message
    _setNonce(address(fixedLst), _holder, _nonce);
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    bytes memory _signature = _signFixedMessage(
      fixedLst.UPDATE_DEPOSIT_TYPEHASH(),
      _holder,
      Staker.DepositIdentifier.unwrap(_depositId),
      ERC20Permit(address(fixedLst)).nonces(_holder),
      _expiry,
      _wrongPrivateKey
    );

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__InvalidSignature.selector);
    fixedLst.updateDepositOnBehalf(_holder, _depositId, _nonce, _expiry, _signature);
  }

  function testFuzz_RevertIf_ExpiredSignature(
    uint256 _nonce,
    uint256 _expiry,
    uint256 _holderPrivateKey,
    address _delegatee,
    address _sender
  ) public {
    _expiry = bound(_expiry, 0, block.timestamp - 1);
    _holderPrivateKey = _boundToValidPrivateKey(_holderPrivateKey);
    _assumeSafeDelegatee(_delegatee);
    address _holder = vm.addr(_holderPrivateKey);

    // Sign the message
    _setNonce(address(fixedLst), _holder, _nonce);
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    bytes memory _signature = _signFixedMessage(
      fixedLst.UPDATE_DEPOSIT_TYPEHASH(),
      _holder,
      Staker.DepositIdentifier.unwrap(_depositId),
      ERC20Permit(address(fixedLst)).nonces(_holder),
      _expiry,
      _holderPrivateKey
    );

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__SignatureExpired.selector);
    fixedLst.updateDepositOnBehalf(_holder, _depositId, _nonce, _expiry, _signature);
  }

  function testFuzz_RevertIf_InvalidNonce(
    uint256 _currentNonce,
    uint256 _suppliedNonce,
    uint256 _expiry,
    uint256 _holderPrivateKey,
    address _delegatee,
    address _sender
  ) public {
    vm.assume(_currentNonce != _suppliedNonce);
    _holderPrivateKey = _boundToValidPrivateKey(_holderPrivateKey);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);
    address _holder = vm.addr(_holderPrivateKey);

    // Sign the message
    _setNonce(address(fixedLst), _holder, _currentNonce);
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    bytes memory _signature = _signFixedMessage(
      fixedLst.UPDATE_DEPOSIT_TYPEHASH(),
      _holder,
      Staker.DepositIdentifier.unwrap(_depositId),
      _suppliedNonce,
      _expiry,
      _holderPrivateKey
    );

    vm.prank(_sender);
    bytes memory expectedRevertData =
      abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, _holder, _currentNonce);
    vm.expectRevert(expectedRevertData);
    fixedLst.updateDepositOnBehalf(_holder, _depositId, _suppliedNonce, _expiry, _signature);
  }

  function testFuzz_RevertIf_NonceReused(
    uint256 _nonce,
    uint256 _expiry,
    uint256 _holderPrivateKey,
    address _delegatee,
    address _sender
  ) public {
    _holderPrivateKey = _boundToValidPrivateKey(_holderPrivateKey);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);
    address _holder = vm.addr(_holderPrivateKey);

    // Sign the message
    _setNonce(address(fixedLst), _holder, _nonce);
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeFixedDeposit(_depositId, delegateeFunder);

    bytes memory _signature = _signFixedMessage(
      fixedLst.UPDATE_DEPOSIT_TYPEHASH(),
      _holder,
      Staker.DepositIdentifier.unwrap(_depositId),
      ERC20Permit(address(fixedLst)).nonces(_holder),
      _expiry,
      _holderPrivateKey
    );

    vm.prank(_sender);
    fixedLst.updateDepositOnBehalf(_holder, _depositId, _nonce, _expiry, _signature);

    vm.prank(_sender);
    bytes memory expectedRevertData = abi.encodeWithSelector(
      Nonces.InvalidAccountNonce.selector, _holder, ERC20Permit(address(fixedLst)).nonces(_holder)
    );
    vm.expectRevert(expectedRevertData);
    fixedLst.updateDepositOnBehalf(_holder, _depositId, _nonce, _expiry, _signature);
  }
}

contract StakeOnBehalf is FixedGovLstTest {
  function testFuzz_StakesTokensOnBehalfOfAnotherUser(
    uint256 _amount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    _assumeFutureExpiry(_expiry);

    // Mint and approve tokens to the staker
    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(fixedLst), _amount);
    vm.stopPrank();

    // Sign the message
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.STAKE_TYPEHASH(),
      _staker,
      _amount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    // Perform the stake on behalf
    vm.prank(_sender);
    fixedLst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);

    // Check balances
    assertEq(lst.balanceOf(_staker.fixedAlias()), _amount);
    assertEq(lst.sharesOf(_staker.fixedAlias()) / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_staker));
  }

  function testFuzz_EmitsAStakedEvent(
    uint256 _amount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    _assumeFutureExpiry(_expiry);

    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(fixedLst), _amount);
    vm.stopPrank();

    // Sign the message
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.STAKE_TYPEHASH(),
      _staker,
      _amount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    // Perform the stake on behalf
    vm.prank(_sender);
    vm.expectEmit();
    emit FixedGovLst.Fixed(_staker, _amount);
    fixedLst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidSignature(
    uint256 _amount,
    address _staker,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _wrongPrivateKey,
    address _sender
  ) public {
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _wrongPrivateKey = _boundToValidPrivateKey(_wrongPrivateKey);

    // Mint and approve tokens to the sender (signer)
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(fixedLst), _amount);
    vm.stopPrank();

    // Sign the message with an invalid key
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory invalidSignature =
      _signFixedMessage(fixedLst.STAKE_TYPEHASH(), _staker, _amount, _nonce, _expiry, _wrongPrivateKey);

    // Attempt to perform the stake on behalf with an invalid signature
    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__InvalidSignature.selector);
    fixedLst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, invalidSignature);
  }

  function testFuzz_RevertIf_ExpiredSignature(
    uint256 _amount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _expiry = bound(_expiry, 0, block.timestamp - 1);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    // Mint and approve tokens to the staker
    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(fixedLst), _amount);
    vm.stopPrank();

    // Sign the message with an expired expiry
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.STAKE_TYPEHASH(),
      _staker,
      _amount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    // Attempt to perform the stake on behalf with an expired signature
    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__SignatureExpired.selector);
    fixedLst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidNonce(
    uint256 _amount,
    uint256 _currentNonce,
    uint256 _suppliedNonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    vm.assume(_currentNonce != _suppliedNonce);
    _assumeFutureExpiry(_expiry);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    // Mint and approve tokens to the sender (staker)
    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(fixedLst), _amount);
    vm.stopPrank();

    // Sign the message with an invalid nonce
    _setNonce(address(fixedLst), _staker, _currentNonce); // expected nonce
    bytes memory signature =
      _signFixedMessage(fixedLst.STAKE_TYPEHASH(), _staker, _amount, _suppliedNonce, _expiry, _stakerPrivateKey);

    // Attempt to perform the stake on behalf with an invalid nonce
    vm.prank(_sender);
    bytes memory expectedRevertData =
      abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, _staker, _currentNonce);
    vm.expectRevert(expectedRevertData);
    fixedLst.stakeOnBehalf(_staker, _amount, _suppliedNonce, _expiry, signature);
  }

  function testFuzz_RevertIf_NonceReused(
    uint256 _amount,
    uint256 _expiry,
    uint256 _nonce,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);

    // Mint and approve tokens to the sender (staker)
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(fixedLst), _amount);
    vm.stopPrank();

    // Sign the message with a valid nonce
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.STAKE_TYPEHASH(),
      _staker,
      _amount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    // Perform the stake on behalf with a valid nonce
    vm.prank(_sender);
    fixedLst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);

    vm.prank(_sender);
    bytes memory expectedRevertData = abi.encodeWithSelector(
      Nonces.InvalidAccountNonce.selector, _staker, ERC20Permit(address(fixedLst)).nonces(_staker)
    );
    vm.expectRevert(expectedRevertData);
    fixedLst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);
  }
}

contract ConvertToFixedOnBehalf is FixedGovLstTest {
  function testFuzz_ConvertsToFixedTokensOnBehalfOfAnotherUser(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _lstAmount = _boundToReasonableStakeTokenAmount(_fixedAmount);
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    _assumeFutureExpiry(_expiry);

    address _staker = vm.addr(_stakerPrivateKey);
    _mintAndStake(_staker, _lstAmount);

    // Sign the message
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.CONVERT_TO_FIXED_TYPEHASH(),
      _staker,
      _fixedAmount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    vm.prank(_sender);
    fixedLst.convertToFixedOnBehalf(_staker, _fixedAmount, _nonce, _expiry, signature);

    // Check balances
    assertEq(lst.sharesOf(_staker.fixedAlias()) / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_staker));
  }

  function testFuzz_EmitsAFixedEvent(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    _assumeFutureExpiry(_expiry);

    address _staker = vm.addr(_stakerPrivateKey);
    _mintAndStake(_staker, _lstAmount);

    // Sign the message
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.CONVERT_TO_FIXED_TYPEHASH(),
      _staker,
      _fixedAmount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    vm.prank(_sender);
    vm.expectEmit();
    emit FixedGovLst.Fixed(_staker, _fixedAmount);
    fixedLst.convertToFixedOnBehalf(_staker, _fixedAmount, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidSignature(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    address _staker,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _wrongPrivateKey,
    address _sender
  ) public {
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);
    _wrongPrivateKey = _boundToValidPrivateKey(_wrongPrivateKey);

    _mintAndStake(_staker, _lstAmount);

    // Sign the message with an invalid key
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory invalidSignature =
      _signFixedMessage(fixedLst.CONVERT_TO_FIXED_TYPEHASH(), _staker, _fixedAmount, _nonce, _expiry, _wrongPrivateKey);

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__InvalidSignature.selector);
    fixedLst.convertToFixedOnBehalf(_staker, _fixedAmount, _nonce, _expiry, invalidSignature);
  }

  function testFuzz_RevertIf_ExpiredSignature(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _expiry = bound(_expiry, 0, block.timestamp - 1);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    address _staker = vm.addr(_stakerPrivateKey);
    _mintAndStake(_staker, _lstAmount);

    // Sign the message with an expired expiry
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.CONVERT_TO_FIXED_TYPEHASH(),
      _staker,
      _fixedAmount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__SignatureExpired.selector);
    fixedLst.convertToFixedOnBehalf(_staker, _fixedAmount, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidNonce(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    uint256 _currentNonce,
    uint256 _suppliedNonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    vm.assume(_currentNonce != _suppliedNonce);
    _assumeFutureExpiry(_expiry);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    address _staker = vm.addr(_stakerPrivateKey);
    _mintAndStake(_staker, _lstAmount);

    // Sign the message with an invalid nonce
    _setNonce(address(fixedLst), _staker, _currentNonce); // expected nonce
    bytes memory signature = _signFixedMessage(
      fixedLst.CONVERT_TO_FIXED_TYPEHASH(), _staker, _fixedAmount, _suppliedNonce, _expiry, _stakerPrivateKey
    );

    vm.prank(_sender);
    bytes memory expectedRevertData =
      abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, _staker, _currentNonce);
    vm.expectRevert(expectedRevertData);
    fixedLst.convertToFixedOnBehalf(_staker, _fixedAmount, _suppliedNonce, _expiry, signature);
  }

  function testFuzz_RevertIf_NonceReused(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    uint256 _expiry,
    uint256 _nonce,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);

    // Mint and approve tokens to the sender (staker)
    _mintAndStake(_staker, _lstAmount);

    // Sign the message with a valid nonce
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.CONVERT_TO_FIXED_TYPEHASH(),
      _staker,
      _fixedAmount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    vm.prank(_sender);
    fixedLst.convertToFixedOnBehalf(_staker, _fixedAmount, _nonce, _expiry, signature);

    vm.prank(_sender);
    bytes memory expectedRevertData = abi.encodeWithSelector(
      Nonces.InvalidAccountNonce.selector, _staker, ERC20Permit(address(fixedLst)).nonces(_staker)
    );
    vm.expectRevert(expectedRevertData);
    fixedLst.convertToFixedOnBehalf(_staker, _fixedAmount, _nonce, _expiry, signature);
  }
}

contract ConvertToRebasingOnBehalf is FixedGovLstTest {
  function testFuzz_ConvertsToRebasingTokensOnBehalfOfAnotherUser(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _lstAmount = _boundToReasonableStakeTokenAmount(_fixedAmount);
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    _assumeFutureExpiry(_expiry);

    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _lstAmount, _delegatee);

    // Sign the message
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.CONVERT_TO_REBASING_TYPEHASH(),
      _staker,
      _fixedAmount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );
    uint256 _initialBalance = fixedLst.balanceOf(_staker);

    vm.prank(_sender);
    fixedLst.convertToRebasingOnBehalf(_staker, _fixedAmount, _nonce, _expiry, signature);

    // Check balances
    assertEq(fixedLst.balanceOf(_staker), _initialBalance - _fixedAmount);
  }

  function testFuzz_EmitsAUnfixedEvent(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    _assumeFutureExpiry(_expiry);

    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _lstAmount, _delegatee);

    // Sign the message
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.CONVERT_TO_REBASING_TYPEHASH(),
      _staker,
      _fixedAmount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    vm.prank(_sender);
    vm.expectEmit();
    emit FixedGovLst.Unfixed(_staker, _fixedAmount);
    fixedLst.convertToRebasingOnBehalf(_staker, _fixedAmount, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidSignature(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    address _staker,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _wrongPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);
    _wrongPrivateKey = _boundToValidPrivateKey(_wrongPrivateKey);

    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _lstAmount, _delegatee);

    // Sign the message with an invalid key
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory invalidSignature = _signFixedMessage(
      fixedLst.CONVERT_TO_REBASING_TYPEHASH(), _staker, _fixedAmount, _nonce, _expiry, _wrongPrivateKey
    );

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__InvalidSignature.selector);
    fixedLst.convertToRebasingOnBehalf(_staker, _fixedAmount, _nonce, _expiry, invalidSignature);
  }

  function testFuzz_RevertIf_ExpiredSignature(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _expiry = bound(_expiry, 0, block.timestamp - 1);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _lstAmount, _delegatee);

    // Sign the message with an expired expiry
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.CONVERT_TO_REBASING_TYPEHASH(),
      _staker,
      _fixedAmount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__SignatureExpired.selector);
    fixedLst.convertToRebasingOnBehalf(_staker, _fixedAmount, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidNonce(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    uint256 _currentNonce,
    uint256 _suppliedNonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    vm.assume(_currentNonce != _suppliedNonce);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _lstAmount, _delegatee);

    // Sign the message with an invalid nonce
    _setNonce(address(fixedLst), _staker, _currentNonce); // expected nonce
    bytes memory signature = _signFixedMessage(
      fixedLst.CONVERT_TO_REBASING_TYPEHASH(), _staker, _fixedAmount, _suppliedNonce, _expiry, _stakerPrivateKey
    );

    vm.prank(_sender);
    bytes memory expectedRevertData =
      abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, _staker, _currentNonce);
    vm.expectRevert(expectedRevertData);
    fixedLst.convertToRebasingOnBehalf(_staker, _fixedAmount, _suppliedNonce, _expiry, signature);
  }

  function testFuzz_RevertIf_NonceReused(
    uint256 _lstAmount,
    uint256 _fixedAmount,
    uint256 _expiry,
    uint256 _nonce,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);

    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _lstAmount, _delegatee);

    // Sign the message with a valid nonce
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.CONVERT_TO_REBASING_TYPEHASH(),
      _staker,
      _fixedAmount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    vm.prank(_sender);
    fixedLst.convertToRebasingOnBehalf(_staker, _fixedAmount, _nonce, _expiry, signature);

    vm.prank(_sender);
    bytes memory expectedRevertData = abi.encodeWithSelector(
      Nonces.InvalidAccountNonce.selector, _staker, ERC20Permit(address(fixedLst)).nonces(_staker)
    );
    vm.expectRevert(expectedRevertData);
    fixedLst.convertToRebasingOnBehalf(_staker, _fixedAmount, _nonce, _expiry, signature);
  }
}

contract RescueOnBehalf is FixedGovLstTest {
  function testFuzz_RescueTokensOnBehalfOfAnotherUser(
    uint256 _initialStakeAmount,
    uint256 _rescueAmount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    _assumeFutureExpiry(_expiry);

    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _initialStakeAmount, _delegatee);
    _sendLstTokensDirectlyToAlias(_staker, _rescueAmount);

    // Sign the message
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.RESCUE_TYPEHASH(), _staker, ERC20Permit(address(fixedLst)).nonces(_staker), _expiry, _stakerPrivateKey
    );

    vm.prank(_sender);
    fixedLst.rescueOnBehalf(_staker, _nonce, _expiry, signature);
    uint256 _expectedBalance = lst.sharesForStake(_initialStakeAmount + _rescueAmount) / SHARE_SCALE_FACTOR;
    assertEq(fixedLst.balanceOf(_staker), _expectedBalance);
  }

  function testFuzz_EmitsARescuedEvent(
    uint256 _initialStakeAmount,
    uint256 _rescueAmount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    _assumeFutureExpiry(_expiry);

    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _initialStakeAmount, _delegatee);
    _sendLstTokensDirectlyToAlias(_staker, _rescueAmount);

    // Sign the message
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.RESCUE_TYPEHASH(), _staker, ERC20Permit(address(fixedLst)).nonces(_staker), _expiry, _stakerPrivateKey
    );

    vm.prank(_sender);
    vm.expectEmit();
    emit FixedGovLst.Rescued(_staker, _rescueAmount);
    fixedLst.rescueOnBehalf(_staker, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidSignature(
    uint256 _initialStakeAmount,
    uint256 _rescueAmount,
    address _staker,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _wrongPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);
    _wrongPrivateKey = _boundToValidPrivateKey(_wrongPrivateKey);

    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _initialStakeAmount, _delegatee);
    _sendLstTokensDirectlyToAlias(_staker, _rescueAmount);

    // Sign the message with an invalid key
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory invalidSignature =
      _signFixedMessage(fixedLst.RESCUE_TYPEHASH(), _staker, _nonce, _expiry, _wrongPrivateKey);

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__InvalidSignature.selector);
    fixedLst.rescueOnBehalf(_staker, _nonce, _expiry, invalidSignature);
  }

  function testFuzz_RevertIf_ExpiredSignature(
    uint256 _initialStakeAmount,
    uint256 _rescueAmount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _expiry = bound(_expiry, 0, block.timestamp - 1);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _initialStakeAmount, _delegatee);
    _sendLstTokensDirectlyToAlias(_staker, _rescueAmount);

    // Sign the message with an expired expiry
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.RESCUE_TYPEHASH(), _staker, ERC20Permit(address(fixedLst)).nonces(_staker), _expiry, _stakerPrivateKey
    );

    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__SignatureExpired.selector);
    fixedLst.rescueOnBehalf(_staker, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidNonce(
    uint256 _initialStakeAmount,
    uint256 _rescueAmount,
    uint256 _currentNonce,
    uint256 _suppliedNonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    vm.assume(_currentNonce != _suppliedNonce);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _initialStakeAmount, _delegatee);
    _sendLstTokensDirectlyToAlias(_staker, _rescueAmount);

    // Sign the message with an invalid nonce
    _setNonce(address(fixedLst), _staker, _currentNonce); // expected nonce
    bytes memory signature =
      _signFixedMessage(fixedLst.RESCUE_TYPEHASH(), _staker, _suppliedNonce, _expiry, _stakerPrivateKey);

    vm.prank(_sender);
    bytes memory expectedRevertData =
      abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, _staker, _currentNonce);
    vm.expectRevert(expectedRevertData);
    fixedLst.rescueOnBehalf(_staker, _suppliedNonce, _expiry, signature);
  }

  function testFuzz_RevertIf_NonceReused(
    uint256 _initialStakeAmount,
    uint256 _rescueAmount,
    uint256 _expiry,
    uint256 _nonce,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _initialStakeAmount = _boundToReasonableStakeTokenAmount(_initialStakeAmount);
    _rescueAmount = _boundToReasonableStakeTokenAmount(_rescueAmount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);

    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _initialStakeAmount, _delegatee);
    _sendLstTokensDirectlyToAlias(_staker, _rescueAmount);

    // Sign the message with a valid nonce
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.RESCUE_TYPEHASH(), _staker, ERC20Permit(address(fixedLst)).nonces(_staker), _expiry, _stakerPrivateKey
    );

    vm.prank(_sender);
    fixedLst.rescueOnBehalf(_staker, _nonce, _expiry, signature);

    vm.prank(_sender);
    bytes memory expectedRevertData = abi.encodeWithSelector(
      Nonces.InvalidAccountNonce.selector, _staker, ERC20Permit(address(fixedLst)).nonces(_staker)
    );
    vm.expectRevert(expectedRevertData);
    fixedLst.rescueOnBehalf(_staker, _nonce, _expiry, signature);
  }
}

contract PermitAndStake is FixedGovLstTest {
  using stdStorage for StdStorage;

  function testFuzz_PerformsTheApprovalByCallingPermitThenPerformsStake(
    uint256 _depositorPrivateKey,
    uint256 _stakeAmount,
    uint256 _deadline,
    uint256 _currentNonce
  ) public {
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _depositorPrivateKey = bound(_depositorPrivateKey, 1, 100e18);
    address _depositor = vm.addr(_depositorPrivateKey);
    _mintStakeToken(_depositor, _stakeAmount);

    _setNonce(address(stakeToken), _depositor, _currentNonce);
    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        _depositor,
        address(fixedLst),
        _stakeAmount,
        ERC20Permit(address(stakeToken)).nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash = _hashTypedDataV4(
      EIP712_DOMAIN_TYPEHASH, _message, bytes(ERC20Votes(address(stakeToken)).name()), "1", address(stakeToken)
    );
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    fixedLst.permitAndStake(_stakeAmount, _deadline, _v, _r, _s);

    assertEq(lst.balanceOf(_depositor.fixedAlias()), _stakeAmount);
    assertEq(lst.sharesOf(_depositor.fixedAlias()) / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_depositor));
  }

  function testFuzz_SuccessfullyStakeWhenApprovalExistsAndPermitSignatureIsInvalid(
    uint256 _depositorPrivateKey,
    uint256 _stakeAmount,
    uint256 _approvalAmount,
    uint256 _deadline,
    uint256 _currentNonce
  ) public {
    _depositorPrivateKey = _boundToValidPrivateKey(_depositorPrivateKey);
    address _depositor = vm.addr(_depositorPrivateKey);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _approvalAmount = bound(_approvalAmount, _stakeAmount, type(uint96).max);
    _deadline = bound(_deadline, 0, block.timestamp);
    _mintStakeToken(_depositor, _stakeAmount);
    vm.startPrank(_depositor);
    stakeToken.approve(address(fixedLst), _approvalAmount);
    vm.stopPrank();

    _setNonce(address(stakeToken), _depositor, _currentNonce);
    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        _depositor,
        address(fixedLst),
        _stakeAmount,
        ERC20Votes(address(stakeToken)).nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash = _hashTypedDataV4(
      EIP712_DOMAIN_TYPEHASH, _message, bytes(ERC20Votes(address(stakeToken)).name()), "1", address(stakeToken)
    );
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    fixedLst.permitAndStake(_stakeAmount, _deadline, _v, _r, _s);

    assertEq(lst.balanceOf(_depositor.fixedAlias()), _stakeAmount);
    assertEq(lst.sharesOf(_depositor.fixedAlias()) / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_depositor));
  }

  function testFuzz_RevertIf_ThePermitSignatureIsInvalidAndTheApprovalIsInsufficient(
    address _notDepositor,
    uint256 _depositorPrivateKey,
    uint256 _stakeAmount,
    uint256 _approvalAmount,
    uint256 _deadline,
    uint256 _currentNonce
  ) public {
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _depositorPrivateKey = _boundToValidPrivateKey(_depositorPrivateKey);
    address _depositor = vm.addr(_depositorPrivateKey);
    vm.assume(_notDepositor != _depositor);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _approvalAmount = bound(_approvalAmount, 0, _stakeAmount - 1);
    _mintStakeToken(_depositor, _stakeAmount);
    vm.startPrank(_depositor);
    stakeToken.approve(address(fixedLst), _approvalAmount);
    vm.stopPrank();

    _setNonce(address(stakeToken), _notDepositor, _currentNonce);
    bytes32 _message = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        _notDepositor,
        address(fixedLst),
        _stakeAmount,
        ERC20Votes(address(stakeToken)).nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash = _hashTypedDataV4(
      EIP712_DOMAIN_TYPEHASH, _message, bytes(ERC20Votes(address(stakeToken)).name()), "1", address(stakeToken)
    );
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector,
        address(fixedLst),
        lst.allowance(_depositor, address(fixedLst)),
        _stakeAmount
      )
    );
    fixedLst.permitAndStake(_stakeAmount, _deadline, _v, _r, _s);
  }
}

contract Multicall is FixedGovLstTest {
  function testFuzz_CallsMultipleFunctionsInOneTransaction(
    address _actor,
    uint256 _stakeAmount,
    address _delegatee,
    address _receiver,
    uint256 _transferAmount
  ) public {
    _assumeSafeHolders(_actor, _receiver);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintStakeToken(_actor, _stakeAmount);
    _transferAmount = bound(_transferAmount, 0, _stakeAmount);

    vm.prank(_actor);
    stakeToken.approve(address(fixedLst), _stakeAmount);

    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    bytes[] memory _calls = new bytes[](3);
    _calls[0] = abi.encodeWithSelector(fixedLst.stake.selector, _stakeAmount);
    _calls[1] = abi.encodeWithSelector(fixedLst.updateDeposit.selector, Staker.DepositIdentifier.unwrap(_depositId));
    _calls[2] = abi.encodeWithSelector(fixedLst.transfer.selector, _receiver, _transferAmount);

    vm.prank(_actor);
    fixedLst.multicall(_calls);

    assertApproxEqAbs(lst.balanceOf(_actor.fixedAlias()), _stakeAmount - _transferAmount, 1);
    assertLe(lst.balanceOf(_actor.fixedAlias()), _stakeAmount - _transferAmount);
    assertApproxEqAbs(lst.balanceOf(_receiver.fixedAlias()), _transferAmount, 1);
    assertLe(lst.balanceOf(_receiver.fixedAlias()), _transferAmount);
    assertApproxEqAbs(lst.balanceOf(_actor.fixedAlias()), ERC20Votes(address(stakeToken)).getVotes(_delegatee), 1);
    assertLe(lst.balanceOf(_actor.fixedAlias()), ERC20Votes(address(stakeToken)).getVotes(_delegatee));
    assertEq(lst.sharesOf(_actor.fixedAlias()) / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_actor));
  }

  function testFuzz_RevertIf_AFunctionCallFails(address _actor, address _receiver) public {
    _assumeSafeHolder(_actor);
    uint256 _stakeAmount = 1000e18;
    _mintStakeToken(_actor, _stakeAmount);

    vm.prank(_actor);
    stakeToken.approve(address(fixedLst), _stakeAmount + 1);

    bytes[] memory _calls = new bytes[](2);
    _calls[0] = abi.encodeWithSelector(fixedLst.stake.selector, _stakeAmount);
    _calls[1] = abi.encodeWithSelector(fixedLst.transfer.selector, _receiver, _stakeAmount + 1);

    vm.expectRevert(FixedGovLst.FixedGovLst__InsufficientBalance.selector);
    vm.prank(_actor);
    fixedLst.multicall(_calls);
  }
}

contract UnstakeOnBehalf is FixedGovLstTest {
  function testFuzz_UnstakesTokensOnBehalfOfAnotherUser(
    uint256 _amount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);

    // Mint and stake tokens for the holder
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _amount, _delegatee);

    // Sign the message
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.UNSTAKE_TYPEHASH(),
      _staker,
      _amount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    uint256 _initialBalance = fixedLst.balanceOf(_staker);

    // Perform the unstake on behalf
    vm.prank(_sender);
    fixedLst.unstakeOnBehalf(_staker, _amount, ERC20Permit(address(fixedLst)).nonces(_staker), _expiry, signature);

    // Check balances
    assertEq(stakeToken.balanceOf(_staker), 0);
    // The holder still has the remaining fixed tokens.
    assertEq(fixedLst.balanceOf(_staker), _initialBalance - _amount);
  }

  function testFuzz_EmitsAnUnstakedEvent(
    uint256 _amount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeHolder(_sender);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);

    // Mint and stake tokens for the holder
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _amount, _delegatee);

    // Sign the message
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature = _signFixedMessage(
      fixedLst.UNSTAKE_TYPEHASH(),
      _staker,
      _amount,
      ERC20Permit(address(fixedLst)).nonces(_staker),
      _expiry,
      _stakerPrivateKey
    );

    // Perform the unstake on behalf
    vm.prank(_sender);
    vm.expectEmit();
    emit FixedGovLst.Unfixed(_staker, _amount);
    fixedLst.unstakeOnBehalf(_staker, _amount, ERC20Permit(address(fixedLst)).nonces(_staker), _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidSignature(
    uint256 _amount,
    address _holder,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _wrongPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeHolder(_sender);
    _assumeSafeDelegatee(_delegatee);
    _assumeSafeHolder(_holder);
    _assumeFutureExpiry(_expiry);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _wrongPrivateKey = _boundToValidPrivateKey(_wrongPrivateKey);

    // Mint and stake tokens for the holder
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _amount, _delegatee);

    // Sign the message with an invalid key
    _setNonce(address(fixedLst), _holder, _nonce);
    bytes memory invalidSignature =
      _signFixedMessage(fixedLst.UNSTAKE_TYPEHASH(), _holder, _amount, _nonce, _expiry, _wrongPrivateKey);

    // Attempt to perform the unstake on behalf with an invalid signature
    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__InvalidSignature.selector);
    fixedLst.unstakeOnBehalf(_holder, _amount, _nonce, _expiry, invalidSignature);
  }

  function testFuzz_RevertIf_ExpiredSignature(
    uint256 _amount,
    address _holder,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeHolder(_sender);
    _assumeSafeDelegatee(_delegatee);
    _assumeSafeHolder(_holder);
    _expiry = bound(_expiry, 0, block.timestamp - 1);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    // Mint and stake tokens for the holder
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _amount, _delegatee);

    // Sign the message with an expired expiry
    _setNonce(address(fixedLst), _holder, _nonce);
    bytes memory signature =
      _signFixedMessage(fixedLst.UNSTAKE_TYPEHASH(), _holder, _amount, _nonce, _expiry, _stakerPrivateKey);

    // Attempt to perform the unstake on behalf with an expired signature
    vm.prank(_sender);
    vm.expectRevert(FixedGovLst.FixedGovLst__SignatureExpired.selector);
    fixedLst.unstakeOnBehalf(_holder, _amount, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidNonce(
    uint256 _amount,
    address _holder,
    uint256 _currentNonce,
    uint256 _suppliedNonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    vm.assume(_currentNonce != _suppliedNonce);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    // Mint and stake tokens for the holder
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _amount, _delegatee);

    // Sign the message with an invalid nonce
    _setNonce(address(fixedLst), _holder, _currentNonce);
    bytes memory signature =
      _signMessage(fixedLst.UNSTAKE_TYPEHASH(), _holder, _amount, _suppliedNonce, _expiry, _stakerPrivateKey);

    // Attempt to perform the unstake on behalf with an invalid nonce
    vm.prank(_sender);
    bytes memory expectedRevertData = abi.encodeWithSelector(
      Nonces.InvalidAccountNonce.selector, _holder, ERC20Permit(address(fixedLst)).nonces(_holder)
    );
    vm.expectRevert(expectedRevertData);
    fixedLst.unstakeOnBehalf(_holder, _amount, _suppliedNonce, _expiry, signature);
  }

  function testFuzz_RevertIf_NonceReused(
    uint256 _amount,
    uint256 _expiry,
    uint256 _nonce,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);

    // Mint and stake tokens for the holder
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_staker, _amount, _delegatee);

    // Sign the message with a valid nonce
    _setNonce(address(fixedLst), _staker, _nonce);
    bytes memory signature =
      _signFixedMessage(fixedLst.UNSTAKE_TYPEHASH(), _staker, _amount, _nonce, _expiry, _stakerPrivateKey);

    // Perform the unstake on behalf with a valid nonce
    fixedLst.unstakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);

    vm.prank(_sender);
    bytes memory expectedRevertData = abi.encodeWithSelector(
      Nonces.InvalidAccountNonce.selector, _staker, ERC20Permit(address(fixedLst)).nonces(_staker)
    );
    vm.expectRevert(expectedRevertData);
    fixedLst.unstakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);
  }
}

contract ConvertToFixed is FixedGovLstTest {
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
    _convertToFixed(_holder, _fixedAmount);

    assertEq(lst.sharesOf(_holder.fixedAlias()) / SHARE_SCALE_FACTOR, fixedLst.balanceOf(_holder));
  }

  function testFuzz_EmitsFixedEvent(address _holder, uint256 _lstAmount, uint256 _fixedAmount) public {
    _assumeSafeHolder(_holder);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    // Amount converted to fixed is less than or equal to the amount staked.
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);

    // User stakes in the rebasing lst contract.
    _mintAndStake(_holder, _lstAmount);

    vm.expectEmit();
    emit FixedGovLst.Fixed(_holder, _lstAmount);
    vm.prank(_holder);
    fixedLst.convertToFixed(_lstAmount);
  }

  function testFuzz_MovesLstTokensToAliasOfHolder(address _holder, uint256 _lstAmount, uint256 _fixedAmount) public {
    _assumeSafeHolder(_holder);
    _lstAmount = _boundToReasonableStakeTokenAmount(_lstAmount);
    // Amount converted to fixed is less than or equal to the amount staked.
    _fixedAmount = bound(_fixedAmount, 0, _lstAmount);

    // User stakes in the rebasing lst contract.
    _mintAndStake(_holder, _lstAmount);
    // User converts some rebasing lst tokens to fixed lst tokens.
    _convertToFixed(_holder, _fixedAmount);

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
    uint256 _returnValue1 = _convertToFixed(_holder, _fixedAmount / 3);
    uint256 _balance1 = fixedLst.balanceOf(_holder);
    // User converts some more rebasing lst tokens to fixed lst tokens.
    uint256 _returnValue2 = _convertToFixed(_holder, (2 * _fixedAmount) / 3);
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
    uint256 _returnValue1 = _convertToFixed(_holder, _fixedAmount / 3);
    assertEq(fixedLst.totalSupply(), _returnValue1);

    // User converts some more rebasing lst tokens to fixed lst tokens.
    uint256 _returnValue2 = _convertToFixed(_holder, (2 * _fixedAmount) / 3);
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
    _convertToFixed(_holder, _fixedAmount);

    // Fixed tokens are assigned to the fixed delegatee.
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_delegatee), _fixedAmount);
    // Rebasing tokens are still assigned to the default delegatee.
    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _lstAmount - _fixedAmount);
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
    _convertToFixed(_holder, _fixedAmount);
  }
}

contract Transfer is FixedGovLstTest {
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
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender.fixedAlias()));
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
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender.fixedAlias()));
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

    assertEq(ERC20Votes(address(stakeToken)).getVotes(_senderDelegatee), _stakeAmount - _sendAmount);
    assertEq((ERC20Votes(address(stakeToken)).getVotes(_receiverDelegatee)), _sendAmount);
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
    vm.expectRevert(FixedGovLst.FixedGovLst__InsufficientBalance.selector);
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
    vm.expectRevert(FixedGovLst.FixedGovLst__InsufficientBalance.selector);
    fixedLst.transfer(_receiver, _sendAmount);
    vm.stopPrank();
  }
}

contract TransferFrom is FixedGovLstTest {
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

contract ConvertToRebasing is FixedGovLstTest {
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
    _convertToRebasing(_holder, _unfixAmount);

    assertEq(fixedLst.balanceOf(_holder), _initialBalance - _unfixAmount);
  }

  function testFuzz_EmitsUnfixedEvent(address _holder, uint256 _stakeAmount, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    uint256 _initialBalance = fixedLst.balanceOf(_holder);
    // Unfix one third of the tokens staked.
    uint256 _unfixAmount = _initialBalance / 3;
    vm.recordLogs();
    vm.prank(_holder);
    uint256 _lstTokens = fixedLst.convertToRebasing(_unfixAmount);

    Vm.Log[] memory _entries = vm.getRecordedLogs();
    uint256 _index = _entries.length - 1;
    assertEq(_entries[_index].topics[0], keccak256("Unfixed(address,uint256)"));
    assertEq(_entries[_index].topics[1], bytes32(uint256(uint160(_holder))));
    assertEq(abi.decode(_entries[_index].data, (uint256)), _lstTokens);
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
    _convertToRebasing(_holder, _unfixAmount);

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
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder.fixedAlias()));

    // Because fixed lst token holders can only operate on scaled down shares, they lose up to the value of the
    // scale factor in stake tokens. We calculate this for use in the assertions.
    uint256 _maxPrecisionLoss = lst.stakeForShares(SHARE_SCALE_FACTOR) + 2;

    // Unfix one third of the tokens staked.
    uint256 _unfixAmount = fixedLst.balanceOf(_holder) / 3;
    _convertToRebasing(_holder, _unfixAmount);
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
    uint256 _returnValue = _convertToRebasing(_holder, _unfixAmount);

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
    _convertToRebasing(_holder, _unfixAmount);

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
    _convertToRebasing(_holder, _unfixAmount);

    assertApproxEqAbs(ERC20Votes(address(stakeToken)).getVotes(_delegatee), (2 * _stakeAmount) / 3, 1);
    assertApproxEqAbs(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _stakeAmount / 3, 1);
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
    _convertToRebasing(_holder, _unfixAmount);
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

contract Unstake is FixedGovLstTest {
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

  function testFuzz_EmitsUnfixedEvent(address _holder, uint256 _stakeAmount, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // There is no delay on the withdraw gate, so tokens go straight to the holder on unstake.
    vm.prank(lstOwner);
    withdrawGate.setDelay(0);

    // Stake tokens in the fixed LST.
    _mintStakeTokenUpdateFixedDelegateeAndStakeFixed(_holder, _stakeAmount, _delegatee);
    // Unstake one quarter of the tokens staked.
    uint256 _unstakeAmount = fixedLst.balanceOf(_holder) / 4;

    vm.recordLogs();
    vm.prank(_holder);
    uint256 _stakeTokens = fixedLst.unstake(_unstakeAmount);

    Vm.Log[] memory _entries = vm.getRecordedLogs();
    uint256 _index = _entries.length - 1;
    assertEq(_entries[_index].topics[0], keccak256("Unfixed(address,uint256)"));
    assertEq(_entries[_index].topics[1], bytes32(uint256(uint160(_holder))));
    assertEq(abi.decode(_entries[_index].data, (uint256)), _stakeTokens);
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

    assertApproxEqAbs(ERC20Votes(address(stakeToken)).getVotes(_delegatee), (3 * _stakeAmount) / 4, 1);
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
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder.fixedAlias()));

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
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder.fixedAlias()));

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

contract Delegate is FixedGovLstTest {
  function testFuzz_UpdatesCallersDepositToExistingDelegatee(address _holder, address _delegatee, uint256 _amount)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    lst.fetchOrInitializeDepositForDelegatee(_delegatee);

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

contract Rescue is FixedGovLstTest {
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

  function testFuzz_EmitsRescuedEvent(
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
    uint256 _expectedAmount = lst.sharesForStake(_rescueAmount) / SHARE_SCALE_FACTOR;

    vm.expectEmit();
    emit FixedGovLst.Rescued(_holder, _expectedAmount);
    vm.prank(_holder);
    fixedLst.rescue();
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
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder.fixedAlias()));
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
