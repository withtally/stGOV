// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IGovernorCountingExtensions {
  function proposalVotes(uint256 proposalId)
    external
    view
    returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes);
}
