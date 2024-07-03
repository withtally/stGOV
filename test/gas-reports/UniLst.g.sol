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

    // TODO: When the real withdrawal gate is completed, deploy it and update it on the lst here instead of using the
    // mock version, which is appropriate for unit tests, but will not produce accurate gas estimates.
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

    startScenario("Sender With Custom Delegatee Transfers Partial Balance To Existing Receiver With Custom Delegatee");
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

    uint256 _rewardAmount;

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
      _distributeReward(_rewardAmount);

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
      _distributeReward(_rewardAmount);

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
      _distributeReward(_rewardAmount);

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
      _distributeReward(_rewardAmount);

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
      _distributeReward(_rewardAmount);

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
      _distributeReward(_rewardAmount);

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
      _distributeReward(_rewardAmount);

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
      _distributeReward(_rewardAmount);

      vm.startPrank(_staker);
      lst.unstake(1);
      recordScenarioGasResult();
      vm.stopPrank();
    }
    stopScenario();
  }
}
