// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {WithdrawGate} from "src/WithdrawGate.sol";
import {IUni} from "src/interfaces/IUni.sol";
import {UniLst} from "src/UniLst.sol";
import {TestHelpers} from "test/helpers/TestHelpers.sol";

contract WithdrawGateTest is TestHelpers {
  WithdrawGate withdrawGate;
  address owner;
  address lst;
  address stakeToken;
  uint256 initialDelay;

  function setUp() public virtual {
    owner = makeAddr("Owner");
    lst = makeAddr("LST");
    stakeToken = makeAddr("StakeToken");
    initialDelay = 7 days;

    vm.mockCall(lst, abi.encodeWithSelector(UniLst(lst).STAKE_TOKEN.selector), abi.encode(address(stakeToken)));

    withdrawGate = new WithdrawGate(owner, lst, initialDelay);
  }

  function _assumeSafeAddress(address _address) internal pure {
    vm.assume(_address != address(0));
    _assumeSafeMockAddress(_address);
  }

  function _boundToReasonableDelay(uint256 _delay) internal pure returns (uint256) {
    return bound(_delay, 0, 30 days);
  }

  function _boundToUnreasonableDelay(uint256 _delay) internal pure returns (uint256) {
    return bound(_delay, 30 days + 1, type(uint256).max);
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
