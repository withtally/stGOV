// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {FixedGovLst} from "../../src/FixedGovLst.sol";
import {FixedGovLstOnBehalf} from "../../src/extensions/FixedGovLstOnBehalf.sol";
import {FixedGovLstPermitAndStake} from "../../src/extensions/FixedGovLstPermitAndStake.sol";
import {GovLst} from "../../src/GovLst.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FixedGovLstHarness is FixedGovLstOnBehalf, FixedGovLstPermitAndStake {
  constructor(
    string memory _name,
    string memory _symbol,
    string memory _version,
    GovLst _lst,
    IERC20 _stakeToken,
    uint256 _shareScaleFactor
  ) FixedGovLst(_name, _symbol, _version, _lst, _stakeToken, _shareScaleFactor) {}
}
