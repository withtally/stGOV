// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {DeployBase} from "./DeployBase.sol";

abstract contract DeployOverwhelmingSupportAutodelegate is DeployBase {
  struct AutoDelegateConfiguration {
    address owner;
    uint256 minVotingWindowTimepoints;
    uint256 maxVotingWindowTimepoints;
    uint256 initialVotingWindowTimepoints;
    uint256 subQuorumBips;
    uint256 supportThresholdBips;
  }

  function _overwhelmingSupportAutoDelegateConfiguration() public virtual returns (AutoDelegateConfiguration memory);
}
