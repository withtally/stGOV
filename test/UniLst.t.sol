// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {UniLst} from "src/UniLst.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {IUni} from "src/interfaces/IUni.sol";
import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {UnitTestBase} from "test/UnitTestBase.sol";

contract UniLstTest is Test, UnitTestBase {
  IUniStaker staker;

  UniLst lst;

  function setUp() public override {
    super.setUp();

    // UniStaker contracts from bytecode to avoid compiler conflicts.
    staker = IUniStaker(deployCode("UniStaker.sol", abi.encode(rewardToken, stakeToken, stakerAdmin)));

    lst = new UniLst(staker);
  }
}

contract Constructor is UniLstTest {
  function test_SetsConfigurationParameters() public view {
    assertEq(address(lst.STAKER()), address(staker));
    assertEq(address(lst.STAKE_TOKEN()), address(stakeToken));
    assertEq(address(lst.REWARD_TOKEN()), address(rewardToken));
  }

  function test_DeploysTheContractWithArbitraryValuesForParameters(
    address _staker,
    address _stakeToken,
    address _rewardToken
  ) public {
    vm.mockCall(_staker, abi.encodeWithSelector(IUniStaker.STAKE_TOKEN.selector), abi.encode(_stakeToken));
    vm.mockCall(_staker, abi.encodeWithSelector(IUniStaker.REWARD_TOKEN.selector), abi.encode(_rewardToken));

    UniLst _lst = new UniLst(IUniStaker(_staker));
    assertEq(address(_lst.STAKER()), _staker);
    assertEq(address(_lst.STAKE_TOKEN()), _stakeToken);
    assertEq(address(_lst.REWARD_TOKEN()), _rewardToken);
  }
}
