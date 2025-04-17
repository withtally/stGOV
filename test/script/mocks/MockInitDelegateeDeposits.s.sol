// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {InitDelegateeDeposits} from "../../../src/script/InitDelegateeDeposits.s.sol";
import {GovLst} from "../../../src/GovLst.sol";

contract MockInitDelegateeDeposits is InitDelegateeDeposits {
  constructor() {
    showSummaryOutput = false;
  }

  function getGovLst() public pure override returns (GovLst) {
    return GovLst(0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9); // local deployment address.
  }

  function multicallBatchSize() public pure override returns (uint256) {
    return 2;
  }

  function filePath() public view override returns (string memory) {
    string memory _root = vm.projectRoot();
    string memory _path = string.concat(_root, "/test/script/fixtures/addresses.json");
    return _path;
  }
}
