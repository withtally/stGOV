// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasReport} from "test/gas-reports/GasReport.sol";
import {UniLst} from "src/UniLst.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {IUni} from "src/interfaces/IUni.sol";
import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {UnitTestBase} from "test/UnitTestBase.sol";
import {UniLstTest} from "test/UniLst.t.sol";

contract UniLstGasReport is UniLstTest, GasReport {
  function setUp() public override {
    super.setUp();
  }

  function REPORT_NAME() public pure override returns (string memory) {
    return "lst";
  }

  function touchSlots() public override {
    // Touch LST global variable slots by doing an initial deposit to the default delegatee.
    // This ensures all reported numbers, including the first one, are representative of what
    // a "real" use is likely to experience when interacting with the LST.
    // TODO: Investigate; why does moving this to setup change the results of the first scenario?
    _mintAndStake(makeAddr("Slot Warmer"), 100e18);
  }

  function runScenarios() public override {
    address _staker;
    address _delegatee;
    uint256 _stakeAmount;

    startScenario("First Stake to Default Delegate");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintStakeToken(_staker, _stakeAmount);
      vm.startPrank(_staker);
      stakeToken.approve(address(lst), _stakeAmount);
      lst.stake(_stakeAmount);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Second Stake To Default Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStake(_staker, _stakeAmount);
      _stakeAmount = 50e18;
      _mintStakeToken(_staker, _stakeAmount);
      vm.startPrank(_staker);
      stakeToken.approve(address(lst), _stakeAmount);
      lst.stake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("First Stake After Updating To A New Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _delegatee = makeScenarioAddr("Delegatee");
      _stakeAmount = 100e18;
      _mintStakeToken(_staker, _stakeAmount);
      vm.startPrank(_staker);
      lst.updateDelegatee(_delegatee);
      stakeToken.approve(address(lst), _stakeAmount);
      lst.stake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("First Stake After Updating To An Existing LST Delegatee");
    {
      _staker = makeScenarioAddr("Staker 1");
      _delegatee = makeScenarioAddr("Delegatee");
      _stakeAmount = 100e18;
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      _staker = makeScenarioAddr("Staker 2");
      _mintStakeToken(_staker, _stakeAmount);
      vm.startPrank(_staker);
      lst.updateDelegatee(_delegatee);
      stakeToken.approve(address(lst), _stakeAmount);
      lst.stake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Second Stake To A Custom Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _delegatee = makeScenarioAddr("Delegatee");
      _stakeAmount = 100e18;
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      _stakeAmount = 50e18;
      _mintStakeToken(_staker, _stakeAmount);
      vm.startPrank(_staker);
      lst.updateDelegatee(_delegatee);
      stakeToken.approve(address(lst), _stakeAmount);
      lst.stake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();
  }
}
