// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console2} from "forge-std/Test.sol";
import {WithdrawGate} from "../src/WithdrawGate.sol";
import {GovLst} from "../src/GovLst.sol";
import {TestHelpers} from "./helpers/TestHelpers.sol";
import {MockERC20Token} from "./mocks/MockERC20Token.sol";
import {FakeERC1271Wallet} from "./fakes/FakeERC1271Wallet.sol";
import {Eip712Helper} from "./helpers/Eip712Helper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract WithdrawGateTest is TestHelpers {
  WithdrawGate withdrawGate;
  MockERC20Token stakeToken;
  address owner;
  address lst;
  uint256 initialDelay;

  function setUp() public virtual {
    owner = makeAddr("Owner");
    lst = makeAddr("LST");
    stakeToken = new MockERC20Token();
    initialDelay = 7 days;

    vm.mockCall(lst, abi.encodeWithSelector(GovLst(lst).STAKE_TOKEN.selector), abi.encode(address(stakeToken)));

    withdrawGate = new WithdrawGate(owner, lst, address(stakeToken), initialDelay);

    // Warp to a non-zero timestamp to avoid issues with zero timestamps
    vm.warp(1);
  }

  function _assumeSafeAddress(address _address) internal pure {
    vm.assume(_address != address(0));
    _assumeSafeMockAddress(_address);
  }

  function _assumeNotOwnerAddress(address _address) internal view {
    vm.assume(_address != owner);
  }

  function _boundToReasonableDelay(uint256 _delay) internal pure returns (uint256) {
    return bound(_delay, 0, 30 days);
  }

  function _boundToUnreasonableDelay(uint256 _delay) internal pure returns (uint256) {
    return bound(_delay, 30 days + 1, type(uint256).max);
  }

  function _boundToReasonableExtraTime(uint256 _extraTime) internal pure returns (uint256) {
    return bound(_extraTime, 1, 3650 days);
  }

  function _boundToOneHundredWithdrawals(uint256 _withdrawalCount) internal pure returns (uint256) {
    return bound(_withdrawalCount, 1, 100);
  }

  function _boundToReasonableDeadline(uint256 _deadline, uint256 _extraTime) internal view returns (uint256) {
    uint256 warpAmount = block.timestamp + initialDelay + _extraTime;
    return bound(_deadline, warpAmount, warpAmount + 3650 days);
  }

  function _boundToUnreasonableDeadline(uint256 _deadline, uint256 _extraTime) internal view returns (uint256) {
    uint256 warpAmount = block.timestamp + initialDelay + _extraTime;
    return bound(_deadline, 0, warpAmount - 1);
  }

  function _boundToValidPrivateKey(uint256 _privateKey) internal pure returns (uint256) {
    return bound(_privateKey, 1, SECP256K1_ORDER - 1);
  }
}

contract Constructor is WithdrawGateTest {
  function test_SetsConfigurationParameters() public view {
    assertEq(withdrawGate.owner(), owner);
    assertEq(withdrawGate.LST(), lst);
    assertEq(withdrawGate.WITHDRAWAL_TOKEN(), address(stakeToken));
    assertEq(withdrawGate.delay(), initialDelay);
  }

  function testFuzz_SetsConfigurationParametersToArbitraryValues(
    address _owner,
    address _lst,
    address _stakeToken,
    uint256 _initialDelay
  ) public {
    _assumeSafeAddress(_owner);
    _assumeSafeAddress(_lst);
    _initialDelay = _boundToReasonableDelay(_initialDelay);

    WithdrawGate _withdrawGate = new WithdrawGate(_owner, _lst, _stakeToken, _initialDelay);

    assertEq(_withdrawGate.owner(), _owner);
    assertEq(_withdrawGate.LST(), _lst);
    assertEq(_withdrawGate.WITHDRAWAL_TOKEN(), address(_stakeToken));
    assertEq(_withdrawGate.delay(), _initialDelay);
  }

  function testFuzz_RevertIf_LstAddressIsZero(address _owner, address _stakeToken, uint256 _initialDelay) public {
    _assumeSafeAddress(_owner);
    _initialDelay = _boundToReasonableDelay(_initialDelay);

    vm.expectRevert(WithdrawGate.WithdrawGate__InvalidLSTAddress.selector);
    new WithdrawGate(_owner, address(0), _stakeToken, _initialDelay);
  }

  function testFuzz_RevertIf_InitialDelayExceedsMaximum(
    address _owner,
    address _lst,
    address _stakeToken,
    uint256 _delay
  ) public {
    _assumeSafeAddress(_owner);
    _assumeSafeAddress(_lst);
    _delay = _boundToUnreasonableDelay(_delay);

    vm.mockCall(_lst, abi.encodeWithSelector(GovLst(lst).STAKE_TOKEN.selector), abi.encode(address(stakeToken)));

    vm.expectRevert(WithdrawGate.WithdrawGate__InvalidDelay.selector);
    new WithdrawGate(_owner, _lst, _stakeToken, _delay);
  }
}

contract SetDelay is WithdrawGateTest {
  function testFuzz_SetsTheDelayWhenCalledByTheOwnerWithAValidValue(uint256 _newDelay) public {
    _newDelay = _boundToReasonableDelay(_newDelay);
    vm.prank(owner);
    withdrawGate.setDelay(_newDelay);
    assertEq(withdrawGate.delay(), _newDelay);
  }

  function test_RevertIf_SetDelayCalledByNonOwner(address _owner, uint256 _newDelay) public {
    _assumeNotOwnerAddress(_owner);
    _newDelay = _boundToReasonableDelay(_newDelay);
    vm.startPrank(_owner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _owner));
    withdrawGate.setDelay(_newDelay);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_SetDelayExceedsMaximum(uint256 _newDelay) public {
    _newDelay = _boundToUnreasonableDelay(_newDelay);
    vm.prank(owner);
    vm.expectRevert(WithdrawGate.WithdrawGate__InvalidDelay.selector);
    withdrawGate.setDelay(_newDelay);
  }

  function testFuzz_EmitsSetDelayEventWhenCalledByTheOwnerWithAValidValue(uint256 _newDelay) public {
    _newDelay = _boundToReasonableDelay(_newDelay);
    vm.prank(owner);
    vm.expectEmit();
    emit WithdrawGate.DelaySet(initialDelay, _newDelay);
    withdrawGate.setDelay(_newDelay);
  }
}

contract InitiateWithdrawal is WithdrawGateTest {
  function testFuzz_InitiatesWithdrawalWhenCalledByLst(uint96 _amount, address _receiver) public {
    _assumeSafeAddress(_receiver);
    vm.prank(lst);
    uint256 identifier = withdrawGate.initiateWithdrawal(_amount, _receiver);

    (address receiver, uint96 amount, uint256 eligibleTimestamp) = withdrawGate.withdrawals(identifier);
    assertEq(receiver, _receiver);
    assertEq(amount, _amount);
    assertEq(eligibleTimestamp, block.timestamp + initialDelay);
    assertEq(identifier, 1); // First withdrawal should have ID 1
  }

  function testFuzz_EmitsWithdrawalInitiatedEvent(uint96 _amount, address _receiver) public {
    _assumeSafeAddress(_receiver);
    vm.prank(lst);

    uint256 expectedIdentifier = 1; // First withdrawal should have ID 1

    vm.expectEmit();
    emit WithdrawGate.WithdrawalInitiated(_amount, _receiver, block.timestamp + initialDelay, expectedIdentifier);

    withdrawGate.initiateWithdrawal(_amount, _receiver);
  }

  function test_IncrementsWithdrawIdAfterEachInitiateWithdrawal() public {
    vm.startPrank(lst);

    // Inputs the first withdrawal initiation call
    uint96 _amount = 100;
    address _receiver = makeAddr("Receiver");

    for (uint256 i = 1; i <= 100; i++) {
      _assumeSafeAddress(_receiver);
      uint256 identifier = withdrawGate.initiateWithdrawal(_amount, _receiver);
      assertEq(identifier, i);

      // Assign new inputs for the next withdrawal initiation by hashing the last inputs.
      _receiver = address(uint160(uint256(keccak256(abi.encode(_receiver)))));
      _amount = uint96(uint256(keccak256(abi.encode(_amount))));
    }
    vm.stopPrank();
  }

  function testFuzz_RevertIf_CalledByNonLst(address _caller, uint96 _amount, address _receiver) public {
    vm.assume(_caller != lst);
    _assumeSafeAddress(_receiver);
    vm.prank(_caller);
    vm.expectRevert(WithdrawGate.WithdrawGate__CallerNotLST.selector);
    withdrawGate.initiateWithdrawal(_amount, _receiver);
  }

  function testFuzz_RevertIf_ReceiverIsZero(uint96 _amount) public {
    vm.prank(lst);
    vm.expectRevert(WithdrawGate.WithdrawGate__CallerNotReceiver.selector);
    withdrawGate.initiateWithdrawal(_amount, address(0));
  }
}

contract CompleteWithdrawal is WithdrawGateTest {
  function testFuzz_CompletesWithdrawalWhenEligible(uint96 _amount, address _receiver, uint256 _extraTime) public {
    _assumeSafeAddress(_receiver);
    _extraTime = _boundToReasonableExtraTime(_extraTime);

    // Initiate withdrawal
    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, _receiver);

    // Warp time and complete withdrawal
    vm.warp(block.timestamp + initialDelay + _extraTime);
    vm.prank(_receiver);
    withdrawGate.completeWithdrawal(withdrawalId);

    (address receiver, uint96 amount, uint256 eligibleTimestamp) = withdrawGate.withdrawals(withdrawalId);

    assertEq(receiver, _receiver);
    assertEq(amount, _amount);
    assertEq(eligibleTimestamp, 0); // Timestamp should be zeroed out after completion

    // External call to stakeToken.transfer should have been made
    assertEq(stakeToken.lastParam__transfer_to(), _receiver);
    assertEq(stakeToken.lastParam__transfer_amount(), _amount);
  }

  function testFuzz_EmitsWithdrawalCompletedEvent(uint96 _amount, address _receiver, uint256 _extraTime) public {
    _assumeSafeAddress(_receiver);
    _extraTime = _boundToReasonableExtraTime(_extraTime);

    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, _receiver);

    vm.mockCall(
      address(stakeToken), abi.encodeWithSelector(IERC20.transfer.selector, _receiver, _amount), abi.encode(true)
    );

    vm.warp(block.timestamp + initialDelay + _extraTime);
    vm.prank(_receiver);
    vm.expectEmit();
    emit WithdrawGate.WithdrawalCompleted(withdrawalId, _receiver, _amount);
    withdrawGate.completeWithdrawal(withdrawalId);
  }

  function testFuzz_RevertIf_CallerNotReceiver(uint96 _amount, address _receiver, address _caller) public {
    _assumeSafeAddress(_receiver);
    vm.assume(_caller != _receiver);
    uint256 warpTime = block.timestamp + initialDelay + 1;

    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, _receiver);

    vm.warp(warpTime);

    vm.prank(_caller);
    vm.expectRevert(WithdrawGate.WithdrawGate__CallerNotReceiver.selector);
    withdrawGate.completeWithdrawal(withdrawalId);
  }

  function testFuzz_RevertIf_WithdrawalNotEligible(uint96 _amount, address _receiver, uint256 _earlyTime) public {
    _assumeSafeAddress(_receiver);
    _earlyTime = bound(_earlyTime, 0, initialDelay - 1);

    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, _receiver);

    vm.warp(block.timestamp + _earlyTime);
    vm.prank(_receiver);
    vm.expectRevert(WithdrawGate.WithdrawGate__WithdrawalNotEligible.selector);
    withdrawGate.completeWithdrawal(withdrawalId);
  }

  function testFuzz_RevertIf_WithdrawalNotFound(uint256 _nonExistentId, uint96 _amount, address _receiver) public {
    _nonExistentId = bound(_nonExistentId, 2, type(uint256).max); // 2 since initial withdrawal once
    _assumeSafeAddress(_receiver);

    // Perform one withdrawal
    vm.prank(lst);
    withdrawGate.initiateWithdrawal(_amount, _receiver);

    vm.expectRevert(WithdrawGate.WithdrawGate__WithdrawalNotFound.selector);
    withdrawGate.completeWithdrawal(_nonExistentId);
  }

  function testFuzz_RevertIf_WithdrawalAlreadyCompleted(uint256 _amount, address _receiver, uint256 _extraTime) public {
    _assumeSafeAddress(_receiver);
    _extraTime = _boundToReasonableExtraTime(_extraTime);

    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(uint96(_amount), _receiver);

    vm.mockCall(
      address(stakeToken), abi.encodeWithSelector(IERC20.transfer.selector, _receiver, _amount), abi.encode(true)
    );

    vm.warp(block.timestamp + initialDelay + _extraTime);
    vm.startPrank(_receiver);
    withdrawGate.completeWithdrawal(withdrawalId);
    vm.expectRevert(WithdrawGate.WithdrawGate__WithdrawalNotEligible.selector);
    withdrawGate.completeWithdrawal(withdrawalId);
    vm.stopPrank();
  }
}

contract GetNextWithdrawalId is WithdrawGateTest {
  function test_ReturnsNextWithdrawalIdCorrectlyAfterInitiateWithdrawal() public {
    vm.startPrank(lst);

    // Inputs the first withdrawal initiation call
    uint96 _amount = 100;
    address _receiver = makeAddr("Receiver");

    for (uint256 i = 1; i <= 100; i++) {
      _assumeSafeAddress(_receiver);
      withdrawGate.initiateWithdrawal(_amount, _receiver);
      assertEq(withdrawGate.getNextWithdrawalId(), i + 1);

      // Assign new inputs for the next withdrawal initiation by hashing the last inputs.
      _receiver = address(uint160(uint256(keccak256(abi.encode(_receiver)))));
      _amount = uint96(uint256(keccak256(abi.encode(_amount))));
    }

    vm.stopPrank();
  }
}

contract CompleteWithdrawalOnBehalf is WithdrawGateTest, Eip712Helper {
  using ECDSA for bytes32;

  // EIP-712 constants
  bytes32 private DOMAIN_SEPARATOR;

  function setUp() public override {
    super.setUp();

    // Compute the domain separator
    DOMAIN_SEPARATOR = _domainSeperator(EIP712_DOMAIN_TYPEHASH, "WithdrawGate", "1", address(withdrawGate));
  }

  function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
    return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
  }

  function _signWithdrawalMessage(uint256 _withdrawalId, uint256 _deadline, uint256 _signerPrivateKey)
    internal
    view
    returns (bytes memory)
  {
    bytes32 structHash = keccak256(abi.encode(withdrawGate.COMPLETE_WITHDRAWAL_TYPEHASH(), _withdrawalId, _deadline));
    bytes32 hash = _hashTypedDataV4(structHash);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPrivateKey, hash);
    return abi.encodePacked(r, s, v);
  }

  function testFuzz_CompletesWithdrawalOnBehalfWithEoaSignature(
    uint96 _amount,
    uint256 _extraTime,
    uint256 _deadline,
    uint256 _alicePk
  ) public {
    _extraTime = _boundToReasonableExtraTime(_extraTime);
    _deadline = _boundToReasonableDeadline(_deadline, _extraTime);
    _alicePk = _boundToValidPrivateKey(_alicePk);
    address alice = vm.addr(_alicePk);

    // Initiate withdrawal
    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, alice);

    // Warp time
    vm.warp(block.timestamp + initialDelay + _extraTime);

    // Sign the withdrawal message
    bytes memory signature = _signWithdrawalMessage(withdrawalId, _deadline, _alicePk);

    // Complete withdrawal on behalf
    withdrawGate.completeWithdrawalOnBehalf(withdrawalId, _deadline, signature);

    // Assert withdrawal is completed (eligibleTimestamp should be 0)
    (,, uint256 eligibleTimestamp) = withdrawGate.withdrawals(withdrawalId);
    assertEq(eligibleTimestamp, 0);

    // Assert transfer occurred
    assertEq(stakeToken.lastParam__transfer_to(), alice);
    assertEq(stakeToken.lastParam__transfer_amount(), _amount);
  }

  function testFuzz_CompletesWithdrawalOnBehalfWithErc1271Signature(
    uint96 _amount,
    uint256 _deadline,
    uint256 _extraTime,
    uint256 _alicePk
  ) public {
    _extraTime = _boundToReasonableExtraTime(_extraTime);
    _deadline = _boundToReasonableDeadline(_deadline, _extraTime);
    _alicePk = _boundToValidPrivateKey(_alicePk);
    address alice = vm.addr(_alicePk);
    FakeERC1271Wallet fakeWallet = new FakeERC1271Wallet(alice);

    // Initiate withdrawal
    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, address(fakeWallet));

    // Warp time
    vm.warp(block.timestamp + initialDelay + _extraTime);

    // Sign the withdrawal message (mock wallet uses ALICE's key)
    bytes memory signature = _signWithdrawalMessage(withdrawalId, _deadline, _alicePk);

    // Complete withdrawal on behalf
    withdrawGate.completeWithdrawalOnBehalf(withdrawalId, _deadline, signature);

    // Assert withdrawal is completed (eligibleTimestamp should be 0)
    (,, uint256 eligibleTimestamp) = withdrawGate.withdrawals(withdrawalId);
    assertEq(eligibleTimestamp, 0);

    // Assert transfer occurred
    assertEq(stakeToken.lastParam__transfer_to(), address(fakeWallet));
    assertEq(stakeToken.lastParam__transfer_amount(), _amount);
  }

  function testFuzz_RevertIf_InvalidSignatureForWithdraw(
    uint96 _amount,
    uint256 _deadline,
    uint256 _extraTime,
    uint256 _fakeKey,
    uint256 _alicePk
  ) public {
    _extraTime = _boundToReasonableExtraTime(_extraTime);
    _deadline = _boundToReasonableDeadline(_deadline, _extraTime);
    _alicePk = _boundToValidPrivateKey(_alicePk);
    _fakeKey = _boundToValidPrivateKey(_fakeKey);
    vm.assume(_alicePk != _fakeKey);
    address alice = vm.addr(_alicePk);

    // Initiate withdrawal
    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, alice);

    // Warp time
    vm.warp(block.timestamp + initialDelay + _extraTime);

    // Sign with incorrect key
    bytes memory invalidSignature = _signWithdrawalMessage(withdrawalId, _deadline, _fakeKey);

    // Attempt to complete withdrawal
    vm.expectRevert(WithdrawGate.WithdrawGate__InvalidSignature.selector);
    withdrawGate.completeWithdrawalOnBehalf(withdrawalId, _deadline, invalidSignature);
  }

  function testFuzz_RevertIf_WithdrawalNotFound(uint256 _fakeId, uint256 _alicePk, uint256 _deadline) public {
    _fakeId = bound(_fakeId, 2, type(uint256).max); // 2 since initial withdrawal once
    _alicePk = _boundToValidPrivateKey(_alicePk);
    bytes memory signature = _signWithdrawalMessage(_fakeId, _deadline, _alicePk);

    vm.expectRevert(WithdrawGate.WithdrawGate__WithdrawalNotFound.selector);
    withdrawGate.completeWithdrawalOnBehalf(_fakeId, _deadline, signature);
  }

  function testFuzz_RevertIf_WithdrawalNotEligible(
    uint96 _amount,
    uint256 _deadline,
    uint256 _earlyTime,
    uint256 _alicePk
  ) public {
    _earlyTime = bound(_earlyTime, 0, initialDelay - 1);
    _deadline = bound(_deadline, block.timestamp + initialDelay + _earlyTime, type(uint256).max);
    _alicePk = _boundToValidPrivateKey(_alicePk);
    address alice = vm.addr(_alicePk);

    // Initiate withdrawal
    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, alice);

    // Warp time (but not enough)
    vm.warp(block.timestamp + _earlyTime);

    // Sign the withdrawal message
    bytes memory signature = _signWithdrawalMessage(withdrawalId, _deadline, _alicePk);

    // Attempt to complete withdrawal
    vm.expectRevert(WithdrawGate.WithdrawGate__WithdrawalNotEligible.selector);
    withdrawGate.completeWithdrawalOnBehalf(withdrawalId, _deadline, signature);
  }

  function testFuzz_RevertIf_ExpiredSignatureDeadline(
    uint96 _amount,
    uint256 _deadline,
    uint256 _extraTime,
    uint256 _alicePk
  ) public {
    _extraTime = _boundToReasonableExtraTime(_extraTime);
    _deadline = _boundToUnreasonableDeadline(_deadline, _extraTime);
    _alicePk = _boundToValidPrivateKey(_alicePk);
    address alice = vm.addr(_alicePk);

    // Initiate withdrawal
    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, alice);

    // Warp time
    vm.warp(block.timestamp + initialDelay + _extraTime);

    // Sign the withdrawal message
    bytes memory signature = _signWithdrawalMessage(withdrawalId, _deadline, _alicePk);

    // Attempt to complete withdrawal
    vm.expectRevert(WithdrawGate.WithdrawGate__ExpiredDeadline.selector);
    withdrawGate.completeWithdrawalOnBehalf(withdrawalId, _deadline, signature);
  }
}
