// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IGovernorBravoDelegate {
  function castVote(uint256 proposalId, uint8 support) external;
  function proposals(uint256)
    external
    view
    returns (
      uint256 id,
      address proposer,
      uint256 eta,
      uint256 startBlock,
      uint256 endBlock,
      uint256 forVotes,
      uint256 againstVotes,
      uint256 abstainVotes,
      bool canceled,
      bool executed
    );
  function quorumVotes() external view returns (uint256);
  function votingPeriod() external view returns (uint256);
}
