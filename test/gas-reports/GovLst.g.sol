// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {GasReport} from "./GasReport.sol";
import {GovLst} from "../../src/GovLst.sol";
import {WithdrawGate} from "../../src/WithdrawGate.sol";
import {Staker} from "staker/Staker.sol";
import {GovLstTest} from "../GovLst.t.sol";

contract GovLstGasReport is GovLstTest, GasReport {
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
    _mintAndStake(makeAddr("Slot Warmer"), 100e18);
    // Give the Withdraw Gate some tokens so it's balance slot is not empty for the first withdrawal.
    _mintStakeToken(address(withdrawGate), 100e18);
  }

  function runScenarios() public override {
    address _staker;
    address _delegatee;
    uint256 _stakeAmount;
    Staker.DepositIdentifier _depositId;
    uint80 _rewardAmount;

    //-------------------------------------------------------------------------------------------//
    // INITIALIZE SCENARIOS
    //-------------------------------------------------------------------------------------------//

    startScenario("Initialize a brand new delegate");
    {
      _delegatee = makeScenarioAddr("Delegatee");
      _staker = makeScenarioAddr("Initializer");
      vm.prank(_staker);
      lst.fetchOrInitializeDepositForDelegatee(_delegatee);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Initialize a delegate that exists on staker");
    {
      _delegatee = makeScenarioAddr("Delegatee");
      _staker = makeScenarioAddr("Initializer");
      _mintStakeToken(_staker, _stakeAmount);

      vm.startPrank(_staker);
      // First stake directly on Staker to initialize the underlying DelegationSurrogate
      staker.stake(0, _delegatee);
      // Now initialize a deposit for the delegatee on the LST.
      lst.fetchOrInitializeDepositForDelegatee(_delegatee);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    //-------------------------------------------------------------------------------------------//
    // STAKING SCENARIOS
    //-------------------------------------------------------------------------------------------//

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
      _updateDelegatee(_staker, _delegatee);
      vm.startPrank(_staker);
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
      _updateDelegatee(_staker, _delegatee);
      vm.startPrank(_staker);
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
      _updateDelegatee(_staker, _delegatee);
      vm.startPrank(_staker);
      stakeToken.approve(address(lst), _stakeAmount);
      lst.stake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    //-------------------------------------------------------------------------------------------//
    // TRANSFER SCENARIOS
    //-------------------------------------------------------------------------------------------//

    address _receiver;

    startScenario("Sender With Default Delegatee Transfers Balance To New Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStake(_staker, _stakeAmount);

      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Default Delegatee Transfers Partial Balance To New Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStake(_staker, _stakeAmount);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Default Delegatee Transfers Balance To Existing Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStake(_staker, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStake(_receiver, _stakeAmount);

      // Transfer the sender's full balance
      _stakeAmount = lst.balanceOf(_staker);
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Default Delegatee Transfers Partial Balance To Existing Receiver With Default Delegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintAndStake(_staker, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStake(_receiver, _stakeAmount);

      // Send only partial balance
      _stakeAmount = lst.balanceOf(_staker) - 1e18;
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStake(_receiver, _stakeAmount);

      // Transfer the sender's full balance
      _stakeAmount = lst.balanceOf(_staker);
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStake(_receiver, _stakeAmount);

      // Send only partial balance
      _stakeAmount = lst.balanceOf(_staker) - 1e18;
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // The receiver has the same custom delegatee
      _updateDelegatee(_receiver, _delegatee);

      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // The receiver has the same custom delegatee
      _updateDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // The receiver already has a balance & same custom delegatee
      _stakeAmount = 55e18;
      _mintUpdateDelegateeAndStake(_receiver, _stakeAmount, _delegatee);

      // Transfer the sender's full balance
      _stakeAmount = lst.balanceOf(_staker);
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // The receiver already has a balance & same custom delegatee
      _stakeAmount = 55e18;
      _mintUpdateDelegateeAndStake(_receiver, _stakeAmount, _delegatee);

      // Send only partial balance
      _stakeAmount = lst.balanceOf(_staker) - 1e18;
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // The receiver has a different custom delegatee
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _updateDelegatee(_receiver, _delegatee);

      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // The receiver has a different custom delegatee
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _updateDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // The receiver already has a balance & different custom delegatee
      _stakeAmount = 55e18;
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _mintUpdateDelegateeAndStake(_receiver, _stakeAmount, _delegatee);

      // Transfer the sender's full balance
      _stakeAmount = lst.balanceOf(_staker);
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Sender With Custom Delegatee Transfers Partial Balance To Existing Receiver With CustomDelegatee");
    {
      _staker = makeScenarioAddr("Sender");
      _delegatee = makeScenarioAddr("Sender Delegatee");
      _receiver = makeScenarioAddr("Receiver");
      _stakeAmount = 135e18;
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // The receiver already has a balance & different custom delegatee
      _stakeAmount = 55e18;
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _mintUpdateDelegateeAndStake(_receiver, _stakeAmount, _delegatee);

      // Send only partial balance
      _stakeAmount = lst.balanceOf(_staker) - 1e18;
      vm.startPrank(_staker);
      lst.transfer(_receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    //-------------------------------------------------------------------------------------------//
    // TRANSFER FROM SCENARIOS
    //-------------------------------------------------------------------------------------------//

    address _caller;

    startScenario(
      "Sender With Default Delegatee Approves Caller To Transfer Balance To a New Receiver With Default Delegatee"
    );
    {
      _staker = makeScenarioAddr("Sender");
      _receiver = makeScenarioAddr("Receiver");
      _caller = makeScenarioAddr("Caller");
      _stakeAmount = 135e18;
      _mintAndStake(_staker, _stakeAmount);

      _approve(_staker, _caller, _stakeAmount);

      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintAndStake(_staker, _stakeAmount);

      _approve(_staker, _caller, type(uint256).max);

      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintAndStake(_staker, _stakeAmount);

      _approve(_staker, _caller, _stakeAmount);

      // Send only partial balance
      _stakeAmount = 125e18;

      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintAndStake(_staker, _stakeAmount);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStake(_receiver, _stakeAmount);

      // Transfer the sender's full balance
      _stakeAmount = lst.balanceOf(_staker);
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintAndStake(_staker, _stakeAmount);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStake(_receiver, _stakeAmount);

      // Send only partial balance
      _stakeAmount = lst.balanceOf(_staker) - 1e18;
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStake(_receiver, _stakeAmount);

      // Transfer the sender's full balance
      _stakeAmount = lst.balanceOf(_staker);
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver already has a balance
      _stakeAmount = 55e18;
      _mintAndStake(_receiver, _stakeAmount);

      // Send only partial balance
      _stakeAmount = lst.balanceOf(_staker) - 1e18;
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver has the same custom delegatee
      _updateDelegatee(_receiver, _delegatee);

      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver has the same custom delegatee
      _updateDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver already has a balance & same custom delegatee
      _stakeAmount = 55e18;
      _mintUpdateDelegateeAndStake(_receiver, _stakeAmount, _delegatee);

      // Transfer the sender's full balance
      _stakeAmount = lst.balanceOf(_staker);
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver already has a balance & same custom delegatee
      _stakeAmount = 55e18;
      _mintUpdateDelegateeAndStake(_receiver, _stakeAmount, _delegatee);

      // Send only partial balance
      _stakeAmount = lst.balanceOf(_staker) - 1e18;
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver has a different custom delegatee
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _updateDelegatee(_receiver, _delegatee);

      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver has a different custom delegatee
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _updateDelegatee(_receiver, _delegatee);

      // Send only partial balance
      _stakeAmount = 125e18;
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver already has a balance & different custom delegatee
      _stakeAmount = 55e18;
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _mintUpdateDelegateeAndStake(_receiver, _stakeAmount, _delegatee);

      // Transfer the sender's full balance
      _stakeAmount = lst.balanceOf(_staker);
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      _approve(_staker, _caller, _stakeAmount);

      // The receiver already has a balance & different custom delegatee
      _stakeAmount = 55e18;
      _delegatee = makeScenarioAddr("Receiver Delegatee");
      _mintUpdateDelegateeAndStake(_receiver, _stakeAmount, _delegatee);

      // Send only partial balance
      _stakeAmount = lst.balanceOf(_staker) - 1e18;
      vm.startPrank(_caller);
      lst.transferFrom(_staker, _receiver, _stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    //-------------------------------------------------------------------------------------------//
    // UNSTAKE SCENARIOS
    //-------------------------------------------------------------------------------------------//

    startScenario("Unstake Full Balance From The Default Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStake(_staker, _stakeAmount);

      vm.startPrank(_staker);
      lst.unstake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Partial Balance From The Default Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStake(_staker, _stakeAmount);

      vm.startPrank(_staker);
      lst.unstake(_stakeAmount - 1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Full Balance From Unique Custom Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _delegatee = makeScenarioAddr("Delegatee");
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      vm.startPrank(_staker);
      lst.unstake(_stakeAmount);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Partial Balance From Unique Custom Delegatee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _delegatee = makeScenarioAddr("Delegatee");
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      vm.startPrank(_staker);
      lst.unstake(_stakeAmount - 1);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      _staker = makeScenarioAddr("Staker 2");
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // One of them withdraws
      vm.startPrank(_staker);
      lst.unstake(_stakeAmount);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      _staker = makeScenarioAddr("Staker 2");
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);

      // One of them withdraws
      vm.startPrank(_staker);
      lst.unstake(_stakeAmount - 1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Full Balance From The Default Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _mintAndStake(_staker, _stakeAmount);
      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      lst.unstake(lst.balanceOf(_staker));
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Partial Balance From The Default Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _mintAndStake(_staker, _stakeAmount);
      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      // We unstake almost all their balance, so it will have to pull from rewards & original stake.
      lst.unstake(lst.balanceOf(_staker) - 1);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      lst.unstake(lst.balanceOf(_staker));
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      lst.unstake(lst.balanceOf(_staker) - 1);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      _staker = makeScenarioAddr("Staker 2");
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      // Rewards are distributed
      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      // One of them withdraws
      vm.startPrank(_staker);
      lst.unstake(lst.balanceOf(_staker));
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      _staker = makeScenarioAddr("Staker 2");
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      // Rewards are distributed
      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      // One of them withdraws
      vm.startPrank(_staker);
      lst.unstake(lst.balanceOf(_staker) - 1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Unstake Earned Rewards Only From The Default Delegatee After Rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _mintAndStake(_staker, _stakeAmount);
      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      // We unstake a tiny amount, so it will have only have to pull from rewards.
      lst.unstake(1);
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
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));

      vm.startPrank(_staker);
      lst.unstake(1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    //-------------------------------------------------------------------------------------------//
    // CLAIM REWARD SCENARIOS
    //-------------------------------------------------------------------------------------------//

    // Claiming rewards is not part of a normal user flow, but instead will be carried out by searchers racing
    // to arbitrage the opportunity in what is essentially an MEV Dutch auction. That said, the lower the gas fees paid
    // by the searchers, the more of the rewards go to LST holders, so we should seek to optimize it to some
    // extent. We can assume the searchers will take all relevant external steps to minimize the fees they pay, such as
    // ensuring the receiver already has a balance of the reward token. We include two scenarios here to monitor the
    // impact of changes & optimization efforts on the gas of the core claim method. One scenario includes fee payment
    // while the other does not.
    startScenario("Claim and distribute a reward");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      uint256 _payoutAmount = lst.payoutAmount();
      address _claimer = makeScenarioAddr("Claimer");
      address _recipient = makeScenarioAddr("Recipient");
      _mintStakeToken(_claimer, _payoutAmount);
      // Give the receiver a reward token balance so we're not writing to an empty slot
      _mintRewardToken(_recipient, 1e18);
      // Staker deposits to the default delegatee so it is also not an empty slot.
      _mintAndStake(_staker, _stakeAmount);
      _distributeStakerReward(_rewardAmount);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      Staker.DepositIdentifier[] memory _depositsLocal = new Staker.DepositIdentifier[](1);
      _depositsLocal[0] = _depositIdLocal;

      vm.startPrank(_claimer);
      stakeToken.approve(address(lst), _payoutAmount);
      lst.claimAndDistributeReward(
        _recipient, _percentOf(_rewardAmount, _toPercentage(_balance, staker.totalStaked())), _depositsLocal
      );
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    startScenario("Claim and distribute a reward that includes a fee");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      uint256 _payoutAmount = lst.payoutAmount();
      uint16 _feeBips = 1e3;
      address _claimer = makeScenarioAddr("Claimer");
      address _recipient = makeScenarioAddr("Recipient");
      address _feeCollector = makeScenarioAddr("Fee Collector");
      _mintStakeToken(_claimer, _payoutAmount);
      // Give the receiver a reward token balance so we're not writing to an empty slot
      _mintRewardToken(_recipient, 1e18);
      // Staker deposits to the default delegatee so it is also not an empty slot.
      _mintAndStake(_staker, _stakeAmount);
      _distributeStakerReward(_rewardAmount);
      // Give the fee collector a balance as well, again, to avoid writing empty slots.
      _mintAndStake(_feeCollector, _stakeAmount);
      // Configure the fee parameters.
      _setRewardParameters(_rewardAmount, _feeBips, _feeCollector);

      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_feeCollector);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      Staker.DepositIdentifier[] memory _depositsLocal = new Staker.DepositIdentifier[](1);
      _depositsLocal[0] = _depositIdLocal;

      vm.startPrank(_claimer);
      stakeToken.approve(address(lst), _payoutAmount);
      lst.claimAndDistributeReward(
        _recipient, _percentOf(_rewardAmount, _toPercentage(_balance, staker.totalStaked())), _depositsLocal
      );
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();

    //-------------------------------------------------------------------------------------------//
    // UPDATE DEPOSIT SCENARIOS
    //-------------------------------------------------------------------------------------------//

    startScenario("Updating from default deposit with nothing staked");
    {
      _delegatee = makeScenarioAddr("Delegatee");
      _staker = makeScenarioAddr("Staker");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
      vm.prank(_staker);
      lst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Updating from custom deposit with nothing staked");
    {
      _delegatee = makeScenarioAddr("Initial Delegatee");
      _staker = makeScenarioAddr("Staker");
      _updateDelegatee(_staker, _delegatee);
      _delegatee = makeScenarioAddr("Updated Delegatee");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

      vm.prank(_staker);
      lst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Updating from default deposit after staking");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintAndStake(_staker, _stakeAmount);
      _delegatee = makeScenarioAddr("Delegatee");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

      vm.prank(_staker);
      lst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Updating from custom deposit after staking");
    {
      _delegatee = makeScenarioAddr("Initial Delegatee");
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      _delegatee = makeScenarioAddr("Updated Delegatee");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

      vm.prank(_staker);
      lst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Updating from default deposit after staking and earning rewards");
    {
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _mintAndStake(_staker, _stakeAmount);
      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));
      _delegatee = makeScenarioAddr("Delegatee");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

      vm.prank(_staker);
      lst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();

    startScenario("Updating from custom deposit after staking and earning rewards");
    {
      _delegatee = makeScenarioAddr("Initial Delegatee");
      _staker = makeScenarioAddr("Staker");
      _stakeAmount = 100e18;
      _rewardAmount = 5000e18;
      _mintUpdateDelegateeAndStake(_staker, _stakeAmount, _delegatee);
      Staker.DepositIdentifier _depositIdLocal = lst.depositIdForHolder(_staker);
      (uint96 _balance,,,,,,) = staker.deposits(_depositIdLocal);
      _distributeReward(_rewardAmount, _depositIdLocal, _toPercentage(_balance, staker.totalStaked()));
      _delegatee = makeScenarioAddr("Updated Delegatee");
      _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
      vm.prank(_staker);
      lst.updateDeposit(_depositId);
      recordScenarioGasResult();
    }
    stopScenario();
  }
}
