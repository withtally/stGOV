// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IGovLst, Staker} from "../interfaces/IGovLst.sol";

/// @title InitDelegateeDeposits
/// @author [ScopeLift](https://scopelift.co)
/// @notice A script to initialize deposits for delegatee addresses in the GovLst contract.
/// @dev This script reads delegatee addresses from a JSON file, checks if they already have deposits,
/// and initializes deposits for those that don't have one yet using multicall batching for efficiency.
abstract contract InitDelegateeDeposits is Script {
  /// @notice Reference to the GovLst contract.
  IGovLst govLst = IGovLst(getGovLstAddress());

  /// @notice The default deposit ID value used to identify uninitialized deposits.
  uint256 public immutable DEFAULT_DEPOSIT_ID = Staker.DepositIdentifier.unwrap(govLst.DEFAULT_DEPOSIT_ID());

  /// @notice The number of operations to include in each multicall batch.
  uint256 public immutable BATCH_SIZE = multicallBatchSize();

  /// @notice Main entry point for the script.
  /// @dev Reads addresses from file, filters those needing initialization, and processes them in batches.
  function run() public virtual {
    vm.startBroadcast();

    address[] memory _delegateeAddresses = readDelegateeAddressesFromFile();
    uint256[] memory _depositIds = getDepositIdsForDelegateeAddresses(_delegateeAddresses);
    (address[] memory _addressesToInit, uint256 _numOfAddressesToInit) =
      filterDelegateeAddresses(_delegateeAddresses, _depositIds);
    (, uint256 _batchCount) = callFetchOrInitializeDepositForDelegatee(_addressesToInit, _numOfAddressesToInit);

    console2.log("\n========== INITIALIZATION SUMMARY ==========");
    console2.log("Total delegatee addresses processed:", _delegateeAddresses.length);
    console2.log("Addresses filtered (already have deposits):", _delegateeAddresses.length - _numOfAddressesToInit);
    console2.log("Addresses included for initialization:", _numOfAddressesToInit);
    console2.log("Multicall batch size:", BATCH_SIZE);
    console2.log("Number of multicall batches submitted:", _batchCount);
    console2.log("===========================================");

    vm.stopBroadcast();
  }

  /// @notice Returns the address of the GovLst contract.
  /// @return The address of the GovLst contract.
  function getGovLstAddress() public virtual returns (address);

  /// @notice Returns the batch size for multicall operations.
  /// @return The number of operations to include in each batch.
  function multicallBatchSize() public pure virtual returns (uint256);

  /// @notice Reads delegatee addresses from a JSON file.
  /// @return An array of delegatee addresses.
  function readDelegateeAddressesFromFile() public view virtual returns (address[] memory) {
    string memory _root = vm.projectRoot();
    string memory _path = string.concat(_root, "/src/script/addresses.json");
    string memory _json = vm.readFile(_path);

    address[] memory _delegateeAddresses = stdJson.readAddressArray(_json, ".addresses");
    return _delegateeAddresses;
  }

  /// @notice Retrieves deposit IDs for a list of delegatee addresses.
  /// @param _delegateeAddresses Array of delegatee addresses to check.
  /// @return An array of deposit IDs corresponding to each delegatee address.
  function getDepositIdsForDelegateeAddresses(address[] memory _delegateeAddresses)
    public
    virtual
    returns (uint256[] memory)
  {
    uint256 _delegateeAddressesLength = _delegateeAddresses.length;
    uint256[] memory _depositIds = new uint256[](_delegateeAddressesLength);

    bytes[] memory _data = new bytes[](_delegateeAddressesLength);
    for (uint256 i = 0; i < _delegateeAddressesLength; i++) {
      _data[i] = abi.encodeWithSelector(IGovLst.depositForDelegatee.selector, _delegateeAddresses[i]);
    }

    bytes[] memory _results = govLst.multicall(_data);
    for (uint256 i = 0; i < _delegateeAddressesLength; i++) {
      _depositIds[i] = abi.decode(_results[i], (uint256));
    }
    return _depositIds;
  }

  /// @notice Filters delegatee addresses to identify those needing deposit initialization.
  /// @param _delegateeAddresses Array of all delegatee addresses.
  /// @param _depositIds Array of deposit IDs corresponding to each delegatee address.
  /// @return _addressesToInit An array of addresses that need initialization.
  /// @return _numOfAddressesToInit The count of addresses that need initialization.
  function filterDelegateeAddresses(address[] memory _delegateeAddresses, uint256[] memory _depositIds)
    public
    view
    virtual
    returns (address[] memory, uint256)
  {
    address[] memory _addressesToInit = new address[](_delegateeAddresses.length);
    uint256 _numOfAddressesToInit = 0;

    for (uint256 i = 0; i < _delegateeAddresses.length; i++) {
      if (_depositIds[i] == 0 || _depositIds[i] == DEFAULT_DEPOSIT_ID) {
        _addressesToInit[_numOfAddressesToInit] = _delegateeAddresses[i];
        _numOfAddressesToInit++;
      }
    }
    return (_addressesToInit, _numOfAddressesToInit);
  }

  /// @notice Initializes deposits for delegatee addresses in batches using multicall.
  /// @param _addressesToInit Array of delegatee addresses that need initialization.
  /// @param _numOfAddressesToInit Number of addresses to initialize.
  /// @return _allResults An array of results from the initialization calls.
  /// @return _batchCount The number of batches processed.
  function callFetchOrInitializeDepositForDelegatee(address[] memory _addressesToInit, uint256 _numOfAddressesToInit)
    public
    virtual
    returns (bytes[] memory, uint256)
  {
    uint256 _totalAddresses = _numOfAddressesToInit;
    uint256 _batchCount = (_totalAddresses + BATCH_SIZE - 1) / BATCH_SIZE;

    bytes[] memory _allResults = new bytes[](_totalAddresses);

    for (uint256 _batchIndex = 0; _batchIndex < _batchCount; _batchIndex++) {
      uint256 _startIndex = _batchIndex * BATCH_SIZE;
      uint256 _endIndex = _startIndex + BATCH_SIZE;
      if (_endIndex > _totalAddresses) {
        _endIndex = _totalAddresses;
      }

      uint256 _currentBatchSize = _endIndex - _startIndex;
      bytes[] memory _batchData = new bytes[](_currentBatchSize);

      for (uint256 i = 0; i < _currentBatchSize; i++) {
        _batchData[i] = abi.encodeWithSelector(
          IGovLst.fetchOrInitializeDepositForDelegatee.selector, _addressesToInit[_startIndex + i]
        );
      }

      bytes[] memory _batchResults = govLst.multicall(_batchData);

      for (uint256 i = 0; i < _currentBatchSize; i++) {
        _allResults[_startIndex + i] = _batchResults[i];
      }
    }

    return (_allResults, _batchCount);
  }
}
