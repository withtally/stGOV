// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {GovLst, Staker} from "src/GovLst.sol";

/// @title InitDelegateeDeposits
/// @author [ScopeLift](https://scopelift.co)
/// @notice A script to initialize deposits for delegatee addresses in the GovLst contract.
/// @dev This script reads delegatee addresses from a JSON file, checks if they already have deposits, and initializes
/// deposits for those that don't have one yet using multicall batching for efficiency.
/// To use this script, inherit from it and implement the required methods: `getGovLst()`, `multicallBatchSize()`, and
/// the `filePath()` method that returns the path to your JSON file. Be sure to add fs_permissions for read access to
/// your JSON file in foundry.toml (e.g., fs_permissions = [{ access = "read", path = "./src/script/addresses.json"}]).
abstract contract InitDelegateeDeposits is Script {
  /// @notice Reference to the GovLst contract.
  GovLst govLst;

  /// @notice Whether to show summary output when the script is run.
  bool showSummaryOutput;

  /// @notice The default deposit ID value used to identify uninitialized deposits.
  uint256 public DEFAULT_DEPOSIT_ID;

  /// @notice The number of operations to include in each multicall batch.
  uint256 public BATCH_SIZE;

  /// @notice Storage array used to build multicall batches.
  bytes[] private batchData;

  function setUp() public virtual {
    govLst = getGovLst();
    showSummaryOutput = true;
    BATCH_SIZE = multicallBatchSize();
    DEFAULT_DEPOSIT_ID = Staker.DepositIdentifier.unwrap(govLst.DEFAULT_DEPOSIT_ID());
  }

  /// @notice Main entry point for the script.
  /// @dev Reads addresses from file, filters those needing initialization, and processes them in batches.
  function run() public virtual {
    address[] memory _delegateeAddresses = readDelegateeAddressesFromFile();
    uint256[] memory _depositIds = getDepositIdsForDelegateeAddresses(_delegateeAddresses);
    (address[] memory _addressesToInit, uint256 _numOfAddressesToInit) =
      filterDelegateeAddresses(_delegateeAddresses, _depositIds);
    uint256 _batchCount = callFetchOrInitializeDepositForDelegatee(_addressesToInit, _numOfAddressesToInit);

    if (showSummaryOutput) {
      console2.log("\n========== INITIALIZATION SUMMARY ==========");
      console2.log("Total delegatee addresses processed:", _delegateeAddresses.length);
      console2.log("Addresses filtered (already have deposits):", _delegateeAddresses.length - _numOfAddressesToInit);
      console2.log("Addresses included for initialization:", _numOfAddressesToInit);
      console2.log("Multicall batch size:", BATCH_SIZE);
      console2.log("Number of multicall batches submitted:", _batchCount);
      console2.log("===========================================");
    }
  }

  /// @notice Returns the address of the GovLst contract.
  /// @return The address of the GovLst contract.
  function getGovLst() public virtual returns (GovLst);

  /// @notice Returns the batch size for multicall operations.
  /// @return The number of operations to include in each batch.
  function multicallBatchSize() public pure virtual returns (uint256);

  /// @notice Returns the path to the JSON file containing delegatee addresses.
  /// @return The path to the JSON file containing delegatee addresses.
  /// @dev The path should be composed relative to the project root, e.g.:
  ///      return string.concat(vm.projectRoot(), "/src/script/addresses.json")
  ///      Note that Foundry requires explicit read permissions in foundry.toml:
  ///      [profile.default]
  ///      fs_permissions = [{ access = "read", path = "./src/script/addresses.json" }]
  ///      The JSON file should contain a top-level array of addresses as strings, e.g.:
  ///      ["0x1234...", "0xabcd...", "0x5678..."]
  function filePath() public view virtual returns (string memory);

  /// @notice Reads delegatee addresses from a JSON file.
  /// @return An array of delegatee addresses.
  function readDelegateeAddressesFromFile() public view virtual returns (address[] memory) {
    string memory _json = vm.readFile(filePath());
    address[] memory _delegateeAddresses = stdJson.readAddressArray(_json, "");
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
      _data[i] = abi.encodeWithSelector(GovLst.depositForDelegatee.selector, _delegateeAddresses[i]);
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
  /// @return _batchCount The number of batches processed.
  function callFetchOrInitializeDepositForDelegatee(address[] memory _addressesToInit, uint256 _numOfAddressesToInit)
    public
    virtual
    returns (uint256)
  {
    uint256 _batchCount = 0;

    // Iterate over all addresses building multicall batches and broadcasting them when the batch
    // size is reached.
    for (uint256 i = 0; i < _numOfAddressesToInit; i++) {
      batchData.push(abi.encodeWithSelector(GovLst.fetchOrInitializeDepositForDelegatee.selector, _addressesToInit[i]));

      if (batchData.length == BATCH_SIZE) {
        _broadcastAndClearBatch();
        _batchCount += 1;
      }
    }

    // If the number of addresses does not divide evenly into the batch size, this will broadcast
    // the leftovers.
    if (batchData.length > 0) {
      _broadcastAndClearBatch();
      _batchCount += 1;
    }

    return _batchCount;
  }

  /// @notice Internal helper that broadcasts the batch and clears the current batch array.
  function _broadcastAndClearBatch() internal virtual {
    vm.broadcast();
    govLst.multicall(batchData);

    delete batchData;
  }
}
