// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {WithdrawGate} from "src/WithdrawGate.sol";
import {IUni} from "src/interfaces/IUni.sol";
import {UniLst} from "src/UniLst.sol";
import {TestHelpers} from "test/helpers/TestHelpers.sol";
import {MockERC20Token} from "test/mocks/MockERC20Token.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

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

    vm.mockCall(lst, abi.encodeWithSelector(UniLst(lst).STAKE_TOKEN.selector), abi.encode(address(stakeToken)));

    withdrawGate = new WithdrawGate(owner, lst, initialDelay);

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
}

contract Constructor is WithdrawGateTest {
  function test_SetsConfigurationParameters() public view {
    assertEq(withdrawGate.owner(), owner);
    assertEq(withdrawGate.LST(), lst);
    assertEq(withdrawGate.WITHDRAWAL_TOKEN(), address(stakeToken));
    assertEq(withdrawGate.delay(), initialDelay);
  }

  function testFuzz_SetsConfigurationParametersToArbitraryValues(address _owner, address _lst, uint256 _initialDelay)
    public
  {
    _assumeSafeAddress(_owner);
    _assumeSafeAddress(_lst);
    _initialDelay = _boundToReasonableDelay(_initialDelay);

    vm.mockCall(_lst, abi.encodeWithSelector(UniLst(lst).STAKE_TOKEN.selector), abi.encode(address(stakeToken)));

    WithdrawGate _withdrawGate = new WithdrawGate(_owner, _lst, _initialDelay);

    assertEq(_withdrawGate.owner(), _owner);
    assertEq(_withdrawGate.LST(), _lst);
    assertEq(_withdrawGate.WITHDRAWAL_TOKEN(), address(stakeToken));
    assertEq(_withdrawGate.delay(), _initialDelay);
  }

  function testFuzz_RevertIf_LstAddressIsZero(address _owner, uint256 _initialDelay) public {
    _assumeSafeAddress(_owner);
    _initialDelay = _boundToReasonableDelay(_initialDelay);

    vm.expectRevert(WithdrawGate.WithdrawGate__InvalidLSTAddress.selector);
    new WithdrawGate(_owner, address(0), _initialDelay);
  }

  function testFuzz_RevertIf_InitialDelayExceedsMaximum(address _owner, address _lst, uint256 _delay) public {
    _assumeSafeAddress(_owner);
    _assumeSafeAddress(_lst);
    _delay = _boundToUnreasonableDelay(_delay);

    vm.mockCall(_lst, abi.encodeWithSelector(UniLst(lst).STAKE_TOKEN.selector), abi.encode(address(stakeToken)));

    vm.expectRevert(WithdrawGate.WithdrawGate__InvalidDelay.selector);
    new WithdrawGate(_owner, _lst, _delay);
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
  function testFuzz_InitiatesWithdrawalWhenCalledByLst(uint256 _amount, address _receiver) public {
    _assumeSafeAddress(_receiver);
    vm.prank(lst);
    uint256 identifier = withdrawGate.initiateWithdrawal(_amount, _receiver);

    (address receiver, uint256 amount, uint256 eligibleTimestamp, bool completed) = withdrawGate.withdrawals(identifier);
    assertEq(receiver, _receiver);
    assertEq(amount, _amount);
    assertEq(eligibleTimestamp, block.timestamp + initialDelay);
    assertFalse(completed);
    assertEq(identifier, 1); // First withdrawal should have ID 1
  }

  function testFuzz_EmitsWithdrawalInitiatedEvent(uint256 _amount, address _receiver) public {
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
    uint256 _amount = 100;
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

  function testFuzz_RevertIf_CalledByNonLst(address _caller, uint256 _amount, address _receiver) public {
    vm.assume(_caller != lst);
    _assumeSafeAddress(_receiver);
    vm.prank(_caller);
    vm.expectRevert(WithdrawGate.WithdrawGate__CallerNotLST.selector);
    withdrawGate.initiateWithdrawal(_amount, _receiver);
  }

  function testFuzz_RevertIf_ReceiverIsZero(uint256 _amount) public {
    vm.prank(lst);
    vm.expectRevert(WithdrawGate.WithdrawGate__InvalidReceiver.selector);
    withdrawGate.initiateWithdrawal(_amount, address(0));
  }
}

contract CompleteWithdrawal is WithdrawGateTest {
  function testFuzz_CompletesWithdrawalWhenEligible(uint256 _amount, address _receiver, uint256 _extraTime) public {
    _assumeSafeAddress(_receiver);
    _extraTime = _boundToReasonableExtraTime(_extraTime);

    // Initiate withdrawal
    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, _receiver);

    // Checkpoint the block timestamp before warping time
    uint256 _checkpointTimestamp = block.timestamp;

    // Warp time and complete withdrawal
    vm.warp(block.timestamp + initialDelay + _extraTime);
    vm.prank(_receiver);
    withdrawGate.completeWithdrawal(withdrawalId);

    (address receiver, uint256 amount, uint256 eligibleTimestamp, bool completed) =
      withdrawGate.withdrawals(withdrawalId);

    assertEq(receiver, _receiver);
    assertEq(amount, _amount);
    assertEq(eligibleTimestamp, _checkpointTimestamp + initialDelay);
    assertTrue(completed);

    // External call to stakeToken.transfer should have been made
    assertEq(stakeToken.lastParam__transfer_to(), _receiver);
    assertEq(stakeToken.lastParam__transfer_amount(), _amount);
  }

  function testFuzz_EmitsWithdrawalCompletedEvent(uint256 _amount, address _receiver, uint256 _extraTime) public {
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

  function testFuzz_RevertIf_WithdrawalNotFound(uint256 _fakeId, address _receiver) public {
    _assumeSafeAddress(_receiver);
    _fakeId = bound(_fakeId, 2, type(uint256).max); // 2 since initial withdrawal once
    vm.prank(_receiver);
    vm.expectRevert(WithdrawGate.WithdrawGate__WithdrawalNotFound.selector);
    withdrawGate.completeWithdrawal(_fakeId);
  }

  function testFuzz_RevertIf_CallerNotReceiver(uint256 _amount, address _receiver, address _caller) public {
    _assumeSafeAddress(_receiver);
    vm.assume(_caller != _receiver);

    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, _receiver);

    vm.warp(block.timestamp + initialDelay + 1);
    vm.prank(_caller);
    vm.expectRevert(WithdrawGate.WithdrawGate__CallerNotReceiver.selector);
    withdrawGate.completeWithdrawal(withdrawalId);
  }

  function testFuzz_RevertIf_WithdrawalNotEligible(uint256 _amount, address _receiver, uint256 _earlyTime) public {
    _assumeSafeAddress(_receiver);
    _earlyTime = bound(_earlyTime, 0, initialDelay - 1);

    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, _receiver);

    vm.warp(block.timestamp + _earlyTime);
    vm.prank(_receiver);
    vm.expectRevert(WithdrawGate.WithdrawGate__WithdrawalNotEligible.selector);
    withdrawGate.completeWithdrawal(withdrawalId);
  }

  function testFuzz_RevertIf_WithdrawalAlreadyCompleted(uint256 _amount, address _receiver, uint256 _extraTime) public {
    _assumeSafeAddress(_receiver);
    _extraTime = _boundToReasonableExtraTime(_extraTime);

    vm.prank(lst);
    uint256 withdrawalId = withdrawGate.initiateWithdrawal(_amount, _receiver);

    vm.mockCall(
      address(stakeToken), abi.encodeWithSelector(IERC20.transfer.selector, _receiver, _amount), abi.encode(true)
    );

    vm.warp(block.timestamp + initialDelay + _extraTime);
    vm.startPrank(_receiver);
    withdrawGate.completeWithdrawal(withdrawalId);
    vm.expectRevert(WithdrawGate.WithdrawGate__WithdrawalNotFound.selector);
    withdrawGate.completeWithdrawal(withdrawalId);
    vm.stopPrank();
  }
}

contract GetNextWithdrawalId is WithdrawGateTest {
  function test_ReturnsNextWithdrawalIdCorrectlyAfterInitiateWithdrawal() public {
    vm.startPrank(lst);

    // Inputs the first withdrawal initiation call
    uint256 _amount = 100;
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
