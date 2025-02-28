// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

abstract contract OverwhelmingSupportAutoDelegate is Ownable, IERC6372 {
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

  /// @notice Error thrown when an invalid voting window is provided.
  /// @dev This error is thrown when attempting to set a voting window outside the valid range of 300 to 50_400 blocks.
  error OverwhelmingSupportAutoDelegate__InvalidVotingWindow();

  /// @notice Error thrown when an invalid sub-quorum basis points is provided.
  /// @dev This error is thrown when attempting to set a sub-quorum BIPs outside the valid range of 1000 to 10_000.
  error OverwhelmingSupportAutoDelegate__InvalidSubQuorumBips();

  /// @notice Emitted when the voting window is changed.
  /// @param oldVotingWindow The previous voting window, in timepoint units.
  /// @param newVotingWindow The new voting window, in timepoint units.
  event VotingWindowSet(uint256 oldVotingWindow, uint256 newVotingWindow);

  /// @notice Emitted when the sub-quorum basis points threshold is changed.
  /// @param oldSubQuorumBips The previous sub-quorum percentage in basis points.
  /// @param newSubQuorumBips The new sub-quorum percentage in basis points.
  event SubQuorumBipsSet(uint256 oldSubQuorumBips, uint256 newSubQuorumBips);

  /// @notice Emitted when the support threshold is changed.
  /// @param oldSupportThreshold The previous support threshold in basis points.
  /// @param newSupportThreshold The new support threshold in basis points.
  event SupportThresholdSet(uint256 oldSupportThreshold, uint256 newSupportThreshold);

  /// @notice BIP (Basis Points) constant where 100% equals 10,000 basis points (BIP)
  uint256 private constant BIP = 10_000;

  /// @notice The minimum support threshold required for proposals, set to 5000 basis points (50%).
  uint256 public constant MIN_SUPPORT_THRESHOLD = 5000;

  /// @notice The maximum support threshold allowed for proposals, set to 9500 basis points (95%).
  uint256 public constant MAX_SUPPORT_THRESHOLD = 9500;

  /// @notice The minimum sub-quorum basis points allowed for proposals, set to 1000 basis points (10%).
  uint256 public constant MIN_SUB_QUORUM_BIPS = 1000;

  /// @notice The maximum sub-quorum basis points allowed for proposals, set to 10_000 basis points (100%).
  uint256 public constant MAX_SUB_QUORUM_BIPS = 10_000;

  /// @notice The minimum allowable voting window to be set.
  uint256 public immutable MIN_VOTING_WINDOW;

  /// @notice The maximum allowable voting window to be set.
  uint256 public immutable MAX_VOTING_WINDOW;

  /// @notice Timepoint before a proposal's voting deadline at which this Auto Delegate can begin casting votes.
  /// @dev Earliest timepoint that this delegate can vote would be proposalDeadline - votingWindow.
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
  /// @param _votingWindow The initial voting window value, in timepoint units.
  /// @param _subQuorumBips The initial sub-quorum votes percentage in basis points.
  /// @param _supportThreshold The initial support threshold in basis points.
  /// @notice The number of FOR votes required for a proposal.
  /// @dev If a proposal receives at least this many for votes, this delegate will be able to vote in favor of it.
  constructor(
    address _initialOwner,
    uint256 _minVotingWindow,
    uint256 _maxVotingWindow,
    uint256 _votingWindow,
    uint256 _subQuorumBips,
    uint256 _supportThreshold
  ) Ownable(_initialOwner) {
    MIN_VOTING_WINDOW = _minVotingWindow;
    MAX_VOTING_WINDOW = _maxVotingWindow;
    _setVotingWindow(_votingWindow);
    _setSubQuorumBips(_subQuorumBips);
    _setSupportThreshold(_supportThreshold);
  }

  /// @notice Casts a "For" vote on a given proposal in the specified governor contract.
  /// @param _governor The Governor contract where the proposal lives and the vote takes place.
  /// @param _proposalId The ID of the proposal to vote on.
  /// @dev Always votes in favor (1) of the proposal.
  function castVote(address _governor, uint256 _proposalId) public virtual {
    checkVoteRequirements(_governor, _proposalId);
    _castVote(_governor, _proposalId);
  }

  /// @notice Sets the voting window.
  /// @param _votingWindow The new voting window value, in timepoint units.
  /// @dev Can only be called by the contract owner.
  function setVotingWindow(uint256 _votingWindow) external virtual {
    _checkOwner();
    _setVotingWindow(_votingWindow);
  }

  /// @inheritdoc IERC6372
  function clock() public view virtual returns (uint48);

  /// @inheritdoc IERC6372
  function CLOCK_MODE() public view virtual returns (string memory);

  /// @notice Sets the sub-quorum votes percentage in basis points.
  /// @param _subQuorumBips The percentage of the live quorum (in basis points) that must be FOR votes before this
  /// auto delegate can vote on a proposal.
  /// @dev For example, 10,000 basis points (BIP) represent 100%. 5000 BIP represents 50%.
  function setSubQuorumBips(uint256 _subQuorumBips) external virtual {
    _checkOwner();
    _setSubQuorumBips(_subQuorumBips);
  }

  /// @notice Sets the support percentage required for proposals.
  /// @param _supportThreshold The percentage (in basis points) of FOR votes relative to the sum of FOR and AGAINST
  /// votes required for proposal approval. For example, 7500 represents 75%.
  /// @dev Can only be called by the contract owner. Value is expressed in basis points (BIP) where 10,000 represents
  /// 100%.
  function setSupportThreshold(uint256 _supportThreshold) external virtual {
    _checkOwner();
    _setSupportThreshold(_supportThreshold);
  }

  /// @notice Checks if all requirements are met for casting a vote on a proposal.
  /// @dev Requirements include:
  /// 1. The governor must be an authorized governor.
  /// 2. Current timepoint must be within voting window (proposalDeadline - votingWindow).
  /// 3. FOR votes must meet sub-quorum threshold (percentage of quorum in basis points).
  /// 4. Support ratio (FOR/(FOR+AGAINST)) must exceed supportThreshold.
  /// @param _governor The Governor contract containing the proposal.
  /// @param _proposalId The ID of the proposal to check
  /// @dev This function reverts if any voting requirement is not met.
  function checkVoteRequirements(address _governor, uint256 _proposalId) public view virtual {
    // Fetch proposal data once
    (uint256 _proposalDeadline, uint256 _forVotes, uint256 _againstVotes, uint256 _quorumVotes) =
      _getProposalDetails(_governor, _proposalId);

    if (!_isWithinVotingWindow(_proposalDeadline)) {
      revert OverwhelmingSupportAutoDelegate__OutsideVotingWindow();
    }
    if (!_hasReachedSubQuorum(_forVotes, _quorumVotes)) {
      revert OverwhelmingSupportAutoDelegate__InsufficientForVotes();
    }
    if (!_isAboveSupportThreshold(_forVotes, _againstVotes)) {
      revert OverwhelmingSupportAutoDelegate__BelowSupportThreshold();
    }
  }

  /// @notice Gets the details of a proposal from the governor contract.
  /// @param _governor The address of the Governor contract.
  /// @param _proposalId The ID of the proposal for which to get details.
  /// @return _proposalDeadline The deadline (in blocks or timestamp) for voting on the proposal.
  /// @return _forVotes The number of votes in favor of the proposal.
  /// @return _againstVotes The number of votes against the proposal.
  /// @return _quorumVotes The number of votes required to reach quorum.
  /// @dev This internal function should be overridden to implement fetching proposal different governor interfaces.
  function _getProposalDetails(address _governor, uint256 _proposalId)
    internal
    view
    virtual
    returns (uint256 _proposalDeadline, uint256 _forVotes, uint256 _againstVotes, uint256 _quorumVotes);

  /// @notice Casts a "For" vote on a given proposal in the specified governor contract.
  /// @param _governor The Governor contract where the proposal lives and the vote takes place.
  /// @param _proposalId The ID of the proposal to vote on.
  /// @dev Always votes in favor (1) of the proposal.
  /// @dev This is an internal virtual function that should be overridden by child contracts to implement
  /// the specific voting logic for different governor interfaces.
  function _castVote(address _governor, uint256 _proposalId) internal virtual;

  /// @notice Checks if the current timepoint is within the voting window of a proposal's deadline.
  /// @param _proposalDeadline The proposal's deadline.
  /// @return bool Returns true if within the voting window, false otherwise.
  function _isWithinVotingWindow(uint256 _proposalDeadline) internal view virtual returns (bool) {
    return clock() >= (_proposalDeadline - votingWindow);
  }

  /// @notice Checks if a proposal has enough FOR votes to meet the subQuorumBips threshold.
  /// @param _forVotes The number of FOR votes.
  /// @param _quorumVotes The number of quorum votes.
  /// @return bool Returns true if the proposal has received enough "For" votes to meet the subQuorumBips threshold,
  /// false otherwise.
  function _hasReachedSubQuorum(uint256 _forVotes, uint256 _quorumVotes) internal view virtual returns (bool) {
    return _forVotes >= ((_quorumVotes * subQuorumBips) / BIP);
  }

  /// @notice Checks if a proposal has received sufficient support based on the minimum support percentage threshold.
  /// @param _forVotes The number of FOR votes.
  /// @param _againstVotes The number of AGAINST votes.
  /// @return bool Returns true if the percentage of "For" votes to for + against votes meets or exceeds
  /// supportThreshold, and false otherwise.
  /// @dev The percentage is calculated as (_forVotes / (_forVotes + _againstVotes)) * BIP, where BIP = 10,000
  /// represents 100%. This calculation determines if the percentage of "For" votes meets the required threshold.
  function _isAboveSupportThreshold(uint256 _forVotes, uint256 _againstVotes) internal view virtual returns (bool) {
    return _forVotes * BIP >= supportThreshold * (_forVotes + _againstVotes);
  }

  /// @notice Internal function to set the voting window.
  /// @param _votingWindow The new voting window value, in timepoint units.
  function _setVotingWindow(uint256 _votingWindow) internal virtual {
    if (_votingWindow < MIN_VOTING_WINDOW || _votingWindow > MAX_VOTING_WINDOW) {
      revert OverwhelmingSupportAutoDelegate__InvalidVotingWindow();
    }
    emit VotingWindowSet(votingWindow, _votingWindow);
    votingWindow = _votingWindow;
  }

  /// @notice Internal function to set the sub-quorum votes percentage.
  /// @param _subQuorumBips The new percentage of the live quorum that's required to be FOR votes.
  function _setSubQuorumBips(uint256 _subQuorumBips) internal virtual {
    if (_subQuorumBips < MIN_SUB_QUORUM_BIPS || _subQuorumBips > MAX_SUB_QUORUM_BIPS) {
      revert OverwhelmingSupportAutoDelegate__InvalidSubQuorumBips();
    }
    emit SubQuorumBipsSet(subQuorumBips, _subQuorumBips);
    subQuorumBips = _subQuorumBips;
  }

  /// @notice Internal function to set the minimum support percentage required for proposals.
  /// @param _supportThreshold The new minimum percentage of "For" votes in for + against votes required for a
  /// proposal to pass.
  /// @dev Value is expressed in basis points (BIP) where 10,000 represents 100%.
  function _setSupportThreshold(uint256 _supportThreshold) internal virtual {
    if (_supportThreshold < MIN_SUPPORT_THRESHOLD || _supportThreshold > MAX_SUPPORT_THRESHOLD) {
      revert OverwhelmingSupportAutoDelegate__InvalidSupportThreshold();
    }
    emit SupportThresholdSet(supportThreshold, _supportThreshold);
    supportThreshold = _supportThreshold;
  }
}
