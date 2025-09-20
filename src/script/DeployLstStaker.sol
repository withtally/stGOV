// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.23;

import {Staker} from "lib/staker/src/Staker.sol";
import {DeployBase} from "./DeployBase.sol";
import {DeployStaker} from "lib/staker/src/script/DeployStaker.sol";

abstract contract DeployLstStaker is DeployBase {
  function _getStakerDeployScript() internal virtual returns (DeployStaker);

  function _fetchStaker() internal override returns (Staker) {
    DeployStaker deployScript = _getStakerDeployScript();
    (, Staker staker,) = deployScript.run();
    return staker;
  }
}
