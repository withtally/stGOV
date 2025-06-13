// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {DeployBase} from "./DeployBase.sol";

/// @title DeployOverwhelmingSupportAutodelegate
/// @author [ScopeLift](https://scopelift.co)
/// @notice An abstract contract that has the interface and logic necessary to deploy an
/// OverwhelmingSupportAutoDelegate contract. This contract is part of our modular deployment
/// system and can be combined with other script contracts in order to deploy an entire GovLst
/// system.
abstract contract DeployOverwhelmingSupportAutodelegate is DeployBase {
  /// @notice The configuration for the overwhelming support auto delegate.
  /// @param owner The address that will be set as the initial owner of the contract.
  /// @param initialVotingWindowTimepoints The initial voting window timepoints.
  /// @param subQuorumBips The sub-quorum threshold in basis points.
  /// @param supportThresholdBips The support threshold in basis points.
  struct AutoDelegateConfiguration {
    address owner;
    uint256 initialVotingWindowTimepoints;
    uint256 subQuorumBips;
    uint256 supportThresholdBips;
  }

  /// @notice An interface method that returns the configuration for the overwhelming support
  /// auto delegate.
  /// @return The configuration for the overwhelming support auto delegate.
  function _overwhelmingSupportAutoDelegateConfiguration() public virtual returns (AutoDelegateConfiguration memory);
}
