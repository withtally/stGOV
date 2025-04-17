// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {InitDelegateeDeposits} from "../../src/script/InitDelegateeDeposits.s.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {GovLst, Staker} from "../../src/GovLst.sol";
import {MockInitDelegateeDeposits} from "./mocks/MockInitDelegateeDeposits.s.sol";
import {GovLstTest} from "../GovLst.t.sol";

contract InitDelegateeDepositsTest is GovLstTest {
  MockInitDelegateeDeposits public initDelegateeDeposits;
  uint256 public FORK_BLOCK = 8_120_588;
  uint256 public BATCH_SIZE = 2; // Should match production or mock script.
  string jsonObj; // Test json object.
  address[] delegateeAddresses;

  function setUp() public override {
    super.setUp();
    initDelegateeDeposits = new MockInitDelegateeDeposits();
    jsonObj =
      '["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", "0x90F79bf6EB2c4f870365E785982E1f101E93b906", "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"]'; // Anvil
    delegateeAddresses = stdJson.readAddressArray(jsonObj, "");
  }

  function _unwrapDepositId(Staker.DepositIdentifier _depositId) internal pure returns (uint256) {
    return Staker.DepositIdentifier.unwrap(_depositId);
  }
}

contract GetGovLst is InitDelegateeDepositsTest {
  function test_ReturnsCorrectAddress() public view {
    assertEq(address(initDelegateeDeposits.getGovLst()), address(lst));
  }
}

contract MulticallBatchSize is InitDelegateeDepositsTest {
  function test_ReturnsCorrectBatchSize() public view {
    assertEq(initDelegateeDeposits.multicallBatchSize(), BATCH_SIZE);
  }
}

contract GetDepositIdsForDelegateeAddresses is InitDelegateeDepositsTest {
  function testFuzz_ReturnsCorrectDepositIds(uint256 _mockDepositId) public {
    vm.mockCall(
      address(lst),
      abi.encodeWithSelector(GovLst.depositForDelegatee.selector, delegateeAddresses[0]),
      abi.encode(_mockDepositId)
    );

    uint256[] memory depositIds = initDelegateeDeposits.getDepositIdsForDelegateeAddresses(delegateeAddresses);
    assertEq(depositIds.length, delegateeAddresses.length);
    assertEq(depositIds[0], _mockDepositId);
    assertEq(depositIds[1], _unwrapDepositId(lst.depositForDelegatee(delegateeAddresses[1])));
    assertEq(depositIds[2], _unwrapDepositId(lst.depositForDelegatee(delegateeAddresses[2])));
    assertEq(depositIds[3], _unwrapDepositId(lst.depositForDelegatee(delegateeAddresses[3])));
    assertEq(depositIds[4], _unwrapDepositId(lst.depositForDelegatee(delegateeAddresses[4])));
  }
}

contract FilterDelegateeAddresses is InitDelegateeDepositsTest {
  function testFuzz_ReturnsCorrectFilteredAddresses(uint256 _mockDepositId) public {
    vm.assume(_mockDepositId != 0 && _mockDepositId != initDelegateeDeposits.DEFAULT_DEPOSIT_ID());
    vm.mockCall(
      address(lst),
      abi.encodeWithSelector(GovLst.depositForDelegatee.selector, delegateeAddresses[0]),
      abi.encode(_mockDepositId)
    );

    uint256[] memory depositIds = initDelegateeDeposits.getDepositIdsForDelegateeAddresses(delegateeAddresses);
    (address[] memory _addressesToInit, uint256 _numOfAddressesToInit) =
      initDelegateeDeposits.filterDelegateeAddresses(delegateeAddresses, depositIds);

    assertEq(_addressesToInit[_addressesToInit.length - 1], address(0));
    assertEq(_numOfAddressesToInit, 4);
    assertEq(_addressesToInit[0], delegateeAddresses[1]);
  }
}

contract CallFetchOrInitializeDepositForDelegatee is InitDelegateeDepositsTest {
  function test_ReturnsCorrectResults() public {
    uint256 _delegateeAddressesLength = delegateeAddresses.length;

    uint256 _batchCount =
      initDelegateeDeposits.callFetchOrInitializeDepositForDelegatee(delegateeAddresses, _delegateeAddressesLength);

    assertEq(_batchCount, (_delegateeAddressesLength + BATCH_SIZE - 1) / BATCH_SIZE);
    for (uint256 i; i < _delegateeAddressesLength; i++) {
      Staker.DepositIdentifier _depositId = lst.depositForDelegatee(delegateeAddresses[i]);
      assertTrue(
        _unwrapDepositId(_depositId) != 0 && _unwrapDepositId(_depositId) != initDelegateeDeposits.DEFAULT_DEPOSIT_ID()
      );
    }
  }
}

contract Run is InitDelegateeDepositsTest {
  function test_AllDepositsInitialized() public {
    address[] memory _delegateeAddresses = initDelegateeDeposits.readDelegateeAddressesFromFile();
    uint256 _delegateeAddressesLength = _delegateeAddresses.length;

    initDelegateeDeposits.run();

    for (uint256 i; i < _delegateeAddressesLength; i++) {
      uint256 _depositId = Staker.DepositIdentifier.unwrap(lst.depositForDelegatee(_delegateeAddresses[i]));
      assertTrue(_depositId != 0 && _depositId != initDelegateeDeposits.DEFAULT_DEPOSIT_ID());
    }
  }
}
