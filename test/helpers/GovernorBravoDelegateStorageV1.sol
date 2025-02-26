// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// @notice This library has been modified to make it simpler for mock testing purposes.
library GovernorBravoDelegateStorageV1 {
  /// @notice Following struct has been modified to make it simpler for mock testing purposes.
  struct Proposal {
    /// @notice Unique id for looking up a proposal
    uint256 id;
    /// @notice Creator of the proposal
    address proposer;
    /// @notice The timestamp that the proposal will be available for execution, set once the vote succeeds
    uint256 eta;
    /// @notice the ordered list of target addresses for calls to be made
    // address[] targets;
    // /// @notice The ordered list of values (i.e. msg.value) to be passed to the calls to be made
    // uint256[] values;
    // /// @notice The ordered list of function signatures to be called
    // string[] signatures;
    // /// @notice The ordered list of calldata to be passed to each call
    // bytes[] calldatas;
    /// @notice The block at which voting begins: holders must delegate their votes prior to this block
    uint256 startBlock;
    /// @notice The block at which voting ends: votes must be cast prior to this block
    uint256 endBlock;
    /// @notice Current number of votes in favor of this proposal
    uint256 forVotes;
    /// @notice Current number of votes in opposition to this proposal
    uint256 againstVotes;
    /// @notice Current number of votes for abstaining for this proposal
    uint256 abstainVotes;
    /// @notice Flag marking whether the proposal has been canceled
    bool canceled;
    /// @notice Flag marking whether the proposal has been executed
    bool executed;
  }
  /// @notice Mapping below is part of the Proposal struct. It's commented out for mock simplicity.
  /// @notice Receipts of ballots for the entire set of voters
  // mapping(address => Receipt) receipts;
}
