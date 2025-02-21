// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GovLst} from "src/GovLst.sol";
import {GovLstOnBehalf} from "src/extensions/GovLstOnBehalf.sol";
import {GovLstPermitAndStake} from "src/extensions/GovLstPermitAndStake.sol";
import {FixedGovLst} from "src/FixedGovLst.sol";
import {Staker} from "staker/Staker.sol";
import {FixedGovLstHarness} from "test/harnesses/FixedGovLstHarness.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GovLstHarness is GovLst, GovLstOnBehalf, GovLstPermitAndStake {
  constructor(
    string memory _name,
    string memory _symbol,
    Staker _staker,
    address _initialDefaultDelegatee,
    address _initialOwner,
    uint80 _initialPayoutAmount,
    address _initialDelegateeGuardian,
    uint256 _stakeToBurn
  )
    GovLst(
      _name,
      _symbol,
      "2",
      _staker,
      _initialDefaultDelegatee,
      _initialOwner,
      _initialPayoutAmount,
      _initialDelegateeGuardian,
      _stakeToBurn
    )
  {}

  function _deployFixedGovLst(
    string memory _name,
    string memory _symbol,
    string memory _version,
    GovLst _lst,
    IERC20 _stakeToken,
    uint256 _shareScaleFactor
  ) internal virtual override returns (FixedGovLst _fixedLst) {
    return new FixedGovLstHarness(_name, _symbol, _version, _lst, _stakeToken, _shareScaleFactor);
  }
}
