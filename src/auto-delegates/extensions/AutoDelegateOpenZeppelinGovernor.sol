// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OverwhelmingSupportAutoDelegate} from "../OverwhelmingSupportAutoDelegate.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IGovernorCountingExtensions} from "../interfaces/IGovernorCountingExtensions.sol";

/// @title AutoDelegateOpenZeppelinGovernor
/// @author [ScopeLift](https://scopelift.co)
/// @notice Extension for the OverwhelmingSupportAutoDelegate that integrates with OpenZeppelin Governor contracts.
/// @dev This contract provides implementations for the abstract functions in OverwhelmingSupportAutoDelegate
/// that are specific to OpenZeppelin Governor contracts.
abstract contract AutoDelegateOpenZeppelinGovernor {
  /// @notice The constant value representing a "For" vote.
  /// @dev Aligns with FOR value in Governor's VoteType enum.
  uint8 public constant FOR = 1;

  /// @notice Clock used for flagging checkpoints. Can be overridden to implement timestamp based checkpoints (and
  /// voting).
  /// @dev This function needs to be overridden by the implementing contract.
  function clock() public view virtual returns (uint48);

  /// @notice Casts a vote on a proposal in an OpenZeppelin Governor contract.
  /// @dev Always votes in favor of the proposal.
  /// @param _governor The address of the governor contract.
  /// @param _proposalId The ID of the proposal to vote on.
  function _castVote(address _governor, uint256 _proposalId) internal virtual {
    IGovernor(_governor).castVote(_proposalId, FOR);
  }

  /// @notice Retrieves details about a proposal from an OpenZeppelin Governor contract.
  /// @dev Gets the proposal deadline, vote counts, and quorum requirement.
  /// @param _governor The address of the governor contract.
  /// @param _proposalId The ID of the proposal to get details for.
  /// @return _proposalDeadline The block number or timestamp when voting on the proposal ends.
  /// @return _forVotes The number of votes in favor of the proposal.
  /// @return _againstVotes The number of votes against the proposal.
  /// @return _quorumVotes The number of votes required to reach quorum.
  function _getProposalDetails(address _governor, uint256 _proposalId)
    internal
    view
    virtual
    returns (uint256 _proposalDeadline, uint256 _forVotes, uint256 _againstVotes, uint256 _quorumVotes)
  {
    _proposalDeadline = IGovernor(_governor).proposalDeadline(_proposalId);
    (_againstVotes, _forVotes,) = IGovernorCountingExtensions(_governor).proposalVotes(_proposalId);
    _quorumVotes = IGovernor(_governor).quorum(clock());
  }
}
