// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {OverwhelmingSupportAutoDelegate} from "../OverwhelmingSupportAutoDelegate.sol";
import {IGovernorBravoDelegate} from "../../interfaces/IGovernorBravoDelegate.sol";

/// @title AutoDelegateBravoGovernor
/// @author [ScopeLift](https://scopelift.co)
/// @notice Extension for the OverwhelmingSupportAutoDelegate that integrates with Compound's Governor Bravo contracts.
/// @dev This contract provides implementations for the abstract functions in OverwhelmingSupportAutoDelegate
/// that are specific to Governor Bravo contracts.
abstract contract AutoDelegateBravoGovernor {
  /// @notice The constant value representing a "For" vote.
  /// @dev Aligns with FOR value in Governor's VoteType enum.
  uint8 public constant FOR = 1;

  /// @notice Casts a vote on a proposal in a Governor Bravo contract.
  /// @dev Always votes in favor of the proposal.
  /// @param _governor The address of the governor contract.
  /// @param _proposalId The ID of the proposal to vote on.
  function _castVote(address _governor, uint256 _proposalId) internal virtual {
    IGovernorBravoDelegate(_governor).castVote(_proposalId, FOR);
  }

  /// @notice Retrieves details about a proposal from a Governor Bravo contract.
  /// @dev Gets the proposal deadline, vote counts, and quorum requirement.
  /// @param _governor The address of the governor contract.
  /// @param _proposalId The ID of the proposal to get details for.
  /// @return _proposalDeadline The block number when voting on the proposal ends.
  /// @return _forVotes The number of votes in favor of the proposal.
  /// @return _againstVotes The number of votes against the proposal.
  /// @return _quorumVotes The number of votes required to reach quorum.
  function _getProposalDetails(address _governor, uint256 _proposalId)
    internal
    view
    virtual
    returns (uint256 _proposalDeadline, uint256 _forVotes, uint256 _againstVotes, uint256 _quorumVotes)
  {
    (,,,, _proposalDeadline, _forVotes, _againstVotes,,,) = IGovernorBravoDelegate(_governor).proposals(_proposalId);
    _quorumVotes = IGovernorBravoDelegate(_governor).quorumVotes();
  }
}
