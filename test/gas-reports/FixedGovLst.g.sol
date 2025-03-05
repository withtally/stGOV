// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {GasReport} from "./GasReport.sol";
import {Staker} from "staker/Staker.sol";
import {FixedLstAddressAlias} from "../../src/FixedLstAddressAlias.sol";
import {FixedGovLstTest} from "../FixedGovLst.t.sol";

contract FixedGovLstGasReport is FixedGovLstTest, GasReport {
  using FixedLstAddressAlias for address;

  function setUp() public override {
    super.setUp();
  }

  function REPORT_NAME() public pure override returns (string memory) {
    return "fixedLst";
  }

  function touchSlots() public override {
    // Touch LST global variable slots by doing an initial deposit to the default delegatee.
    // This ensures all reported numbers, including the first one, are representative of what
    // a "real" use is likely to experience when interacting with the LST.
    _mintAndStake(makeAddr("Slot Warmer"), 100e18);
    // Give the Withdraw Gate some tokens so it's balance slot is not empty for the first withdrawal.
    _mintStakeToken(address(withdrawGate), 100e18);
    _mintAndStakeFixed(makeAddr("Slot Warmer"), 100e18);
  }

  function runScenarios() public override {
    address _staker;
    address _delegatee;
    uint256 _stakeAmount;
    Staker.DepositIdentifier _depositId;
    uint80 _rewardAmount;

    ////-------------------------------------------------------------------------------------------//
    //// STAKING SCENARIOS
    ////-------------------------------------------------------------------------------------------//

    startScenario("First Stake to Default Delegate");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintStakeToken(_staker, _stakeAmount);
      vm.startPrank(_staker);
      stakeToken.approve(address(fixedLst), _stakeAmount);
      fixedLst.stake(_stakeAmount);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Second Stake To Default Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _stakeAmount = 50e18;
      _mintStakeToken(_staker, _stakeAmount);
      vm.startPrank(_staker);
      stakeToken.approve(address(fixedLst), _stakeAmount);
      fixedLst.stake(_stakeAmount);
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
      _updateFixedDelegatee(_staker, _delegatee);
      vm.startPrank(_staker);
      stakeToken.approve(address(fixedLst), _stakeAmount);
      fixedLst.stake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("First Stake After Updating To An Existing LST Delegatee");
    {
      _staker = makeScenarioAddr("Staker 1");
      _delegatee = makeScenarioAddr("Delegatee");
      _stakeAmount = 100e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _staker = makeScenarioAddr("Staker 2");
      _mintStakeToken(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      vm.startPrank(_staker);
      stakeToken.approve(address(fixedLst), _stakeAmount);
      fixedLst.stake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Second Stake To A Custom Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _delegatee = makeScenarioAddr("Delegatee");
      _stakeAmount = 100e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);
      _stakeAmount = 50e18;
      _mintStakeToken(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);
      vm.startPrank(_staker);
      stakeToken.approve(address(fixedLst), _stakeAmount);
      fixedLst.stake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    ////-------------------------------------------------------------------------------------------//
    //// TRANSFER SCENARIOS
    ////-------------------------------------------------------------------------------------------//

    address _receiver;

    startScenario("Sender With Default Delegatee Transfers Balance To New Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Default Delegatee Transfers Partial Balance To New Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Default Delegatee Transfers Balance To Existing Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);

      // Transfer the sender's full balance
      _stakeAmount = fixedLst.balanceOf(_staker);
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Default Delegatee Transfers Partial Balance To Existing Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);

      // Send only partial balance
      _stakeAmount = fixedLst.balanceOf(_staker) - 1e18;
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Balance To New Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Partial Balance To New Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Balance To Existing Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);

      // Transfer the sender's full balance
      _stakeAmount = fixedLst.balanceOf(_staker);
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Partial Balance To Existing Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);

      // Send only partial balance
      _stakeAmount = fixedLst.balanceOf(_staker) - 1e18;
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Balance To New Receiver With Same Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // The receiver has the same custom delegatee
      _updateFixedDelegatee(_staker, _delegatee);

      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Partial Balance To New Receiver With Same Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // The receiver has the same custom delegatee
      _updateFixedDelegatee(_staker, _delegatee);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Balance To Existing Receiver With Same Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // The receiver already has a balance & same custom delegatee
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);
      _updateFixedDelegatee(_receiver, _delegatee);

      // Transfer the sender's full balance
      _stakeAmount = fixedLst.balanceOf(_staker);
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Partial Balance To Existing Receiver With Same Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // The receiver already has a balance & same custom delegatee
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);
      _updateFixedDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = fixedLst.balanceOf(_staker) - 1e18;
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Balance To New Receiver With Custom Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // The receiver has a different custom delegatee
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _mintAndStakeFixed(_receiver, _stakeAmount);
      _updateFixedDelegatee(_receiver, _delegatee);

      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Partial Balance To New Receiver With Custom Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // The receiver has a different custom delegatee
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _mintAndStakeFixed(_receiver, _stakeAmount);
      _updateFixedDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Balance To Existing Receiver With Custom Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // The receiver already has a balance & different custom delegatee
      _stakeAmount = 55e18;
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _mintAndStakeFixed(_receiver, _stakeAmount);
      _updateFixedDelegatee(_receiver, _delegatee);

      // Transfer the sender's full balance
      _stakeAmount = fixedLst.balanceOf(_staker);
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Partial Balance To Existing Receiver With Custom Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // The receiver already has a balance & different custom delegatee
      _stakeAmount = 55e18;
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _mintAndStakeFixed(_receiver, _stakeAmount);
      _updateFixedDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = fixedLst.balanceOf(_staker) - 1e18;
      vm.startPrank(_staker);
      fixedLst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    ////-------------------------------------------------------------------------------------------//
    //// TRANSFER FROM SCENARIOS
    ////-------------------------------------------------------------------------------------------//

    address _caller;

    startScenario(
      "Sender With Default Delegatee Approves Caller To Transfer Balance To a New Receiver With Default Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _caller = makeScenarioAddr("Caller");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      _fixedApprove(_staker, _caller, _stakeAmount);

      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Default Delegatee Max Approves Caller To Transfer Balance To a New Receiver With Default Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _caller = makeScenarioAddr("Caller");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      _fixedApprove(_staker, _caller, _stakeAmount);

      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Default Delegatee Approves Caller To Transfer Partial Balance To New Receiver With Default Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _caller = makeScenarioAddr("Caller");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // Send only partial balance
      _stakeAmount = 125e18;

      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Default Delegatee Approves Caller To Transfer Balance To Existing Receiver With Default Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);

      // Transfer the sender's full balance
      _stakeAmount = lst.balanceOf(_staker);
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Default Delegatee Approves Caller To Transfer Partial Balance To Existing Receiver With Default Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);

      // Send only partial balance
      _stakeAmount = fixedLst.balanceOf(_staker) - 1e18;
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Balance To New Receiver With Default Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Partial Balance To New Receiver With Default Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Balance To Existing Receiver With Default Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);

      // Transfer the sender's full balance
      _stakeAmount = fixedLst.balanceOf(_staker);
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Partial Balance To Existing Receiver With Default Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);

      // Send only partial balance
      _stakeAmount = fixedLst.balanceOf(_staker) - 1e18;
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Balance To New Receiver With Same Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver has the same custom delegatee
      _updateFixedDelegatee(_receiver, _delegatee);

      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Partial Balance To New Receiver With Same Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver has the same custom delegatee
      _updateFixedDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Balance To Existing Receiver With Same Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver already has a balance & same custom delegatee
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);
      _updateFixedDelegatee(_receiver, _delegatee);

      // Transfer the sender's full balance
      _stakeAmount = fixedLst.balanceOf(_staker);
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Partial Balance To Existing Receiver With Same Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver already has a balance & same custom delegatee
      _stakeAmount = 55e18;
      _mintAndStakeFixed(_receiver, _stakeAmount);
      _updateFixedDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = fixedLst.balanceOf(_staker) - 1e18;
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Balance To New Receiver With Custom Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver has a different custom delegatee
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _updateFixedDelegatee(_receiver, _delegatee);

      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Partial Balance To New Receiver With Custom Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver has a different custom delegatee
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _updateFixedDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Balance To Existing Receiver With Custom Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver already has a balance & different custom delegatee
      _stakeAmount = 55e18;
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _mintAndStakeFixed(_receiver, _stakeAmount);
      _updateFixedDelegatee(_receiver, _delegatee);

      // Transfer the sender's full balance
      _stakeAmount = fixedLst.balanceOf(_staker);
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario(
      "Sender With Custom Delegatee Approves Caller To Transfer Partial Balance To Existing Receiver With Custom Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      _fixedApprove(_staker, _caller, _stakeAmount);

      // The receiver already has a balance & different custom delegatee
      _stakeAmount = 55e18;
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _mintAndStakeFixed(_receiver, _stakeAmount);
      _updateFixedDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = fixedLst.balanceOf(_staker) - 1e18;
      vm.startPrank(_caller);
      fixedLst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    ////-------------------------------------------------------------------------------------------//
    //// UNSTAKE SCENARIOS
    ////-------------------------------------------------------------------------------------------//

    startScenario("Unstake Full Balance From The Default Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      vm.startPrank(_staker);
      fixedLst.unstake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Partial Balance From The Default Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      vm.startPrank(_staker);
      fixedLst.unstake(_stakeAmount - 1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Full Balance From Unique Custom Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _delegatee = makeScenarioAddr("Delegatee");
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      vm.startPrank(_staker);
      fixedLst.unstake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Partial Balance From Unique Custom Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _delegatee = makeScenarioAddr("Delegatee");
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      vm.startPrank(_staker);
      fixedLst.unstake(_stakeAmount - 1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Full Balance From a Non-Unique Custom Delegatee");
    {
      _staker = makeScenarioAddr("Staker 1");
      _stakeAmount = 100e18;
      _delegatee = makeScenarioAddr("Delegatee");

      // Two stakers assign the same delegatee.
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);
      _staker = makeScenarioAddr("Staker 2");
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // One of them withdraws
      vm.startPrank(_staker);
      fixedLst.unstake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Partial Balance From a Non-Unique Custom Delegatee");
    {
      _staker = makeScenarioAddr("Staker 1");
      _stakeAmount = 100e18;
      _delegatee = makeScenarioAddr("Delegatee");

      // Two stakers assign the same delegatee.
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);
      _staker = makeScenarioAddr("Staker 2");
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      // One of them withdraws
      vm.startPrank(_staker);
      fixedLst.unstake(_stakeAmount - 1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Full Balance From The Default Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      fixedLst.unstake(fixedLst.balanceOf(_staker));
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Partial Balance From The Default Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      // We unstake almost all their balance, so it will have to pull from rewards & original stake.
      fixedLst.unstake(fixedLst.balanceOf(_staker) - 1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Full Balance From Unique Custom Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _delegatee = makeScenarioAddr("Delegatee");
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      fixedLst.unstake(fixedLst.balanceOf(_staker));
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Partial Balance From Unique Custom Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _delegatee = makeScenarioAddr("Delegatee");
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      fixedLst.unstake(fixedLst.balanceOf(_staker) - 1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Full Balance From a Non-Unique Custom Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker 1");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _delegatee = makeScenarioAddr("Delegatee");

      // Two stakers assign the same delegatee.
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);
      _staker = makeScenarioAddr("Staker 2");
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      // One of them withdraws
      vm.startPrank(_staker);
      fixedLst.unstake(fixedLst.balanceOf(_staker));
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Partial Balance From a Non-Unique Custom Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker 1");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _delegatee = makeScenarioAddr("Delegatee");

      // Two stakers assign the same delegatee.
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);
      _staker = makeScenarioAddr("Staker 2");
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);
      // Rewards are distributed

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      // One of them withdraws
      vm.startPrank(_staker);
      fixedLst.unstake(fixedLst.balanceOf(_staker) - 1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Earned Rewards Only From The Default Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      // We unstake a tiny amount, so it will have only have to pull from rewards.
      fixedLst.unstake(1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Earned Rewards Only From Unique Custom Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _delegatee = makeScenarioAddr("Delegatee");
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      fixedLst.unstake(1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    ////-------------------------------------------------------------------------------------------//
    //// UPDATE DEPOSIT SCENARIOS
    ////-------------------------------------------------------------------------------------------//

    startScenario("Updating from default deposit with nothing staked");
    {
      _delegatee = makeScenarioAddr("Delegatee");
      _staker = makeScenarioAddr("Staker");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
      vm.prank(_staker);
      fixedLst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Updating from custom deposit with nothing staked");
    {
      _delegatee = makeScenarioAddr("Initial Delegatee");
      _staker = makeScenarioAddr("Staker");
      _updateFixedDelegatee(_staker, _delegatee);
      _delegatee = makeScenarioAddr("Updated Delegatee");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

      vm.prank(_staker);
      fixedLst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Updating from default deposit after staking");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _delegatee = makeScenarioAddr("Delegatee");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

      vm.prank(_staker);
      fixedLst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Updating from custom deposit after staking");
    {
      _delegatee = makeScenarioAddr("Initial Delegatee");
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);
      _delegatee = makeScenarioAddr("Updated Delegatee");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

      vm.prank(_staker);
      fixedLst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Updating from default deposit after staking and earning rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _mintAndStakeFixed(_staker, _stakeAmount);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      _delegatee = makeScenarioAddr("Delegatee");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

      vm.prank(_staker);
      fixedLst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Updating from custom deposit after staking and earning rewards");
    {
      _delegatee = makeScenarioAddr("Initial Delegatee");
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      _delegatee = makeScenarioAddr("Updated Delegatee");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

      vm.prank(_staker);
      fixedLst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    ////-------------------------------------------------------------------------------------------//
    //// CONVERT TO FIXED Scenarios
    ////-------------------------------------------------------------------------------------------//

    startScenario("Convert rebasing to fixed with a default delegatee and the full amount");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStake(_staker, _stakeAmount);

      vm.prank(_staker);
      fixedLst.convertToFixed(_stakeAmount - 1);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Convert rebasing to fixed with a default delegatee and the partial amount");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStake(_staker, _stakeAmount);

      vm.prank(_staker);
      fixedLst.convertToFixed(_stakeAmount - 50e18);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Convert rebasing to fixed with a custom delegatee and the full amount");
    {
      _staker = makeScenarioAddr("Staker");
      _delegatee = makeScenarioAddr("Delegatee");
      _stakeAmount = 100e18;
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      vm.prank(_staker);
      fixedLst.convertToFixed(_stakeAmount - 1);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Convert rebasing to fixed with a custom delegatee and the partial amount");
    {
      _staker = makeScenarioAddr("Staker");
      _delegatee = makeScenarioAddr("Delegatee");
      _stakeAmount = 100e18;
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      vm.prank(_staker);
      fixedLst.convertToFixed(_stakeAmount - 50e18);
      recordScenarioGasResult();
    }
    stopScenario();
    ////-------------------------------------------------------------------------------------------//
    //// CONVERT TO REBASING Scenarios
    ////-------------------------------------------------------------------------------------------//
    startScenario("Convert fixed to rebasing with a default delegatee and the full amount");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      uint256 _fixedBalance = _mintAndStakeFixed(_staker, _stakeAmount);

      vm.prank(_staker);
      fixedLst.convertToRebasing(_fixedBalance);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Convert fixed to rebasing with a default delegatee and the partial amount");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      uint256 _fixedBalance = _mintAndStakeFixed(_staker, _stakeAmount);

      vm.prank(_staker);
      fixedLst.convertToRebasing(_fixedBalance / 2);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Convert fixed to rebasing with a custom delegatee and the full amount");
    {
      _staker = makeScenarioAddr("Staker");
      _delegatee = makeScenarioAddr("Delegatee");
      _stakeAmount = 100e18;
      uint256 _fixedBalance = _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      vm.prank(_staker);
      fixedLst.convertToRebasing(_fixedBalance);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Convert fixed to rebasing with a custom delegatee and the partial amount");
    {
      _staker = makeScenarioAddr("Staker");
      _delegatee = makeScenarioAddr("Delegatee");
      _stakeAmount = 100e18;
      uint256 _fixedBalance = _mintAndStakeFixed(_staker, _stakeAmount);
      _updateFixedDelegatee(_staker, _delegatee);

      vm.prank(_staker);
      fixedLst.convertToRebasing(_fixedBalance / 2);
      recordScenarioGasResult();
    }
    stopScenario();

    ////-------------------------------------------------------------------------------------------//
    //// Rescue Scenarios
    ////-------------------------------------------------------------------------------------------//
    startScenario("Rescue funds sent to alias address");
    {
      _staker = makeScenarioAddr("Staker");
      _delegatee = makeScenarioAddr("Delegatee");
      _stakeAmount = 100e18;
      _mintAndStake(_staker.fixedAlias(), _stakeAmount);

      vm.prank(_staker);
      fixedLst.rescue();
      recordScenarioGasResult();
    }
    stopScenario();
  }
}
