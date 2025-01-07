// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IGovernorBravoDelegate} from "src/interfaces/IGovernorBravoDelegate.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

contract OverwhelmingSupportAutoDelegate is Ownable, IERC6372 {
  /// @notice Error thrown when attempting to cast a vote outside the permitted voting window.
  /// @dev This error is thrown when trying to vote too early, before the voting window period has started.
  error OverwhelmingSupportAutoDelegate__OutsideVotingWindow();

  /// @notice Error thrown when a proposal does not have the required FOR votes.
  /// @dev This error is thrown when a proposal has not received enough "For" votes to meet the subQuorumBips
  /// threshold.
  error OverwhelmingSupportAutoDelegate__InsufficientForVotes();

  /// @notice Error thrown when a proposal's percentage of for votes is below the minimum required threshold.
  /// @dev This error is thrown when the percentage of "For" votes in for + against votes (For + Against) is less than
  /// supportThreshold.
  error OverwhelmingSupportAutoDelegate__BelowSupportThreshold();

  /// @notice Error thrown when an invalid support threshold is provided.
  /// @dev This error is thrown when attempting to set a support threshold outside the valid range of 50% (5000 BIP) to
  /// 95% (9500 BIP).
  error OverwhelmingSupportAutoDelegate__InvalidSupportThreshold();

  /// @notice Emitted when the voting window is changed.
  /// @param oldVotingWindow The previous voting window in blocks.
  /// @param newVotingWindow The new voting window in blocks.
  event VotingWindowSet(uint256 oldVotingWindow, uint256 newVotingWindow);

  /// @notice Emitted when the sub-quorum basis points threshold is changed.
  /// @param oldSubQuorumBips The previous sub-quorum percentage in basis points.
  /// @param newSubQuorumBips The new sub-quorum percentage in basis points.
  event SubQuorumBipsSet(uint256 oldSubQuorumBips, uint256 newSubQuorumBips);

  /// @notice Emitted when the support threshold is changed.
  /// @param oldSupportThreshold The previous support threshold in basis points.
  /// @param newSupportThreshold The new support threshold in basis points.
  event SupportThresholdSet(uint256 oldSupportThreshold, uint256 newSupportThreshold);

  /// @notice The constant value representing a "For" vote.
  /// @dev Aligns with FOR value in Governor's VoteType enum.
  uint8 private constant FOR = 1;

  /// @notice BIP (Basis Points) constant where 100% equals 10,000 basis points (BIP)
  uint256 private constant BIP = 10_000;

  /// @notice The minimum support threshold required for proposals, set to 5000 basis points (50%).
  uint256 private constant MIN_SUPPORT_THRESHOLD = 5000;

  /// @notice The maximum support threshold allowed for proposals, set to 9500 basis points (95%).
  uint256 private constant MAX_SUPPORT_THRESHOLD = 9500;

  /// @notice The number of blocks before a proposal's voting endBlock at which this Auto Delegate can begin casting
  /// votes.
  /// @dev Earliest block number that this delegate can vote would be endBlock - votingWindow.
  uint256 public votingWindow;

  /// @notice The percentage of FOR votes that a proposal must meet relative to the live quorum.
  /// @dev The quorum calculation follows Uniswap's governance model, where only FOR votes are counted.
  /// @dev If a proposal's FOR votes meet or exceed the specified percentage of the current quorum, this auto delegate
  /// can vote. For example, if set to 5000, the proposal needs FOR votes >= 50% of the live quorum to be eligible.
  uint256 public subQuorumBips;

  /// @notice The minimum required percentage of "For" votes in for + against votes for a proposal to pass.
  /// @dev Expressed in basis points (BIP) where 10,000 represents 100%. For example, 7,500 represents 75%.
  uint256 public supportThreshold;

  /// @notice Initializes the contract with an owner and voting window.
  /// @param _initialOwner The address that will be set as the initial owner of the contract.
  /// @param _votingWindow The initial voting window value in blocks.
  /// @param _subQuorumBips The initial sub-quorum votes percentage in basis points.
  /// @param _supportThreshold The initial support threshold in basis points.
  /// @notice The number of FOR votes required for a proposal.
  /// @dev If a proposal receives at least this many for votes, this delegate will be able to vote in favor of it.
  constructor(address _initialOwner, uint256 _votingWindow, uint256 _subQuorumBips, uint256 _supportThreshold)
    Ownable(_initialOwner)
  {
    _setVotingWindow(_votingWindow);
    _setSubQuorumBips(_subQuorumBips);
    _setSupportThreshold(_supportThreshold);
  }

  /// @notice Casts a "For" vote on a given proposal in the specified governor contract.
  /// @param _governor The Governor contract containing the proposal to vote on.
  /// @param _proposalId The ID of the proposal to vote on.
  /// @dev Always votes in favor (1) of the proposal.
  function castVote(IGovernorBravoDelegate _governor, uint256 _proposalId) public {
    if (!_isWithinVotingWindow(_governor, _proposalId)) {
      revert OverwhelmingSupportAutoDelegate__OutsideVotingWindow();
    }
    if (!_hasReachedSubQuorum(_governor, _proposalId)) {
      revert OverwhelmingSupportAutoDelegate__InsufficientForVotes();
    }
    if (!_isAboveSupportThreshold(_governor, _proposalId)) {
      revert OverwhelmingSupportAutoDelegate__BelowSupportThreshold();
    }
    _governor.castVote(_proposalId, FOR);
  }

  /// @notice Sets the voting window.
  /// @param _votingWindow The new voting window value in blocks.
  /// @dev Can only be called by the contract owner.
  function setVotingWindow(uint256 _votingWindow) external {
    _checkOwner();
    _setVotingWindow(_votingWindow);
  }

  /// @notice Returns the current clock value as a uint48.
  /// @return uint48 The current block number cast to uint48.
  function clock() external view returns (uint48) {
    return SafeCast.toUint48(block.number);
  }

  /// @notice Returns a string representing the clock mode used by the contract.
  /// @dev Indicates that the contract uses block numbers as its time tracking mechanism.
  /// @return string A machine-readable string describing the clock mode.
  function CLOCK_MODE() external pure returns (string memory) {
    return "mode=blocknumber&from=default";
  }

  /// @notice Sets the sub-quorum votes percentage in basis points.
  /// @param _subQuorumBips The percentage of the live quorum (in basis points) that must be FOR votes before this
  /// auto delegate can vote on a proposal.
  /// @dev For example, 10,000 basis points (BIP) represent 100%. 5000 BIP represents 50%.
  function setSubQuorumBips(uint256 _subQuorumBips) external {
    _checkOwner();
    _setSubQuorumBips(_subQuorumBips);
  }

  /// @notice Sets the support percentage required for proposals.
  /// @param _supportThreshold The percentage (in basis points) of FOR votes relative to the sum of FOR and AGAINST
  /// votes required for proposal approval. For example, 7500 represents 75%.
  /// @dev Can only be called by the contract owner. Value is expressed in basis points (BIP) where 10,000 represents
  /// 100%.
  function setSupportThreshold(uint256 _supportThreshold) external {
    _checkOwner();
    _setSupportThreshold(_supportThreshold);
  }

  /// @notice Checks if the current block is within the voting window of a proposal's endBlock.
  /// @param _governor The Governor contract to check the proposal in.
  /// @param _proposalId The ID of the proposal to check the voting window for.
  /// @return bool Returns true if within the voting window, false otherwise.
  function _isWithinVotingWindow(IGovernorBravoDelegate _governor, uint256 _proposalId) internal view returns (bool) {
    (,,,, uint256 endBlock,,,,,) = _governor.proposals(_proposalId);
    return block.number >= (endBlock - votingWindow);
  }

  /// @notice Checks if a proposal has enough FOR votes to meet the subQuorumBips threshold.
  /// @param _governor The Governor contract.
  /// @param _proposalId The ID of the proposal to check.
  /// @return bool Returns true if the proposal has received enough "For" votes to meet the subQuorumBips threshold,
  /// false otherwise.
  function _hasReachedSubQuorum(IGovernorBravoDelegate _governor, uint256 _proposalId) internal view returns (bool) {
    (,,,,, uint256 _forVotes,,,,) = _governor.proposals(_proposalId);
    return _forVotes >= ((_governor.quorumVotes() * subQuorumBips) / BIP);
  }

  /// @notice Checks if a proposal has received sufficient support based on the minimum support percentage threshold.
  /// @param _governor The address of the Governor contract.
  /// @param _proposalId The ID of the proposal to check.
  /// @return bool Returns true if the percentage of "For" votes to for + against votes meets or exceeds
  /// supportThreshold, and false otherwise.
  /// @dev The percentage is calculated as (_forVotes / (_forVotes + _againstVotes)) * BIP, where BIP = 10,000
  /// represents 100%. This calculation determines if the percentage of "For" votes meets the required threshold.
  function _isAboveSupportThreshold(IGovernorBravoDelegate _governor, uint256 _proposalId) internal view returns (bool) {
    (,,,,, uint256 _forVotes, uint256 _againstVotes,,,) = _governor.proposals(_proposalId);
    return ((_forVotes * BIP) / (_forVotes + _againstVotes)) >= supportThreshold;
  }

  /// @notice Internal function to set the voting window.
  /// @param _votingWindow The new voting window value in blocks.
  function _setVotingWindow(uint256 _votingWindow) internal {
    emit VotingWindowSet(votingWindow, _votingWindow);
    votingWindow = _votingWindow;
  }

  /// @notice Internal function to set the sub-quorum votes percentage.
  /// @param _subQuorumBips The new percentage of the live quorum that's required to be FOR votes.
  function _setSubQuorumBips(uint256 _subQuorumBips) internal {
    emit SubQuorumBipsSet(subQuorumBips, _subQuorumBips);
    subQuorumBips = _subQuorumBips;
  }

  /// @notice Internal function to set the minimum support percentage required for proposals.
  /// @param _supportThreshold The new minimum percentage of "For" votes in for + against votes required for a
  /// proposal to pass.
  /// @dev Value is expressed in basis points (BIP) where 10,000 represents 100%.
  function _setSupportThreshold(uint256 _supportThreshold) internal {
    if (_supportThreshold < MIN_SUPPORT_THRESHOLD || _supportThreshold > MAX_SUPPORT_THRESHOLD) {
      revert OverwhelmingSupportAutoDelegate__InvalidSupportThreshold();
    }
    emit SupportThresholdSet(supportThreshold, _supportThreshold);
    supportThreshold = _supportThreshold;
  }
}
