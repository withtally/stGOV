// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {GovernorBravoDelegateMock} from "./mocks/GovernorBravoDelegateMock.sol";
import {IGovernorBravoDelegate} from "../src/interfaces/IGovernorBravoDelegate.sol";
import {AutoDelegateBravoGovernor} from "../src/auto-delegates/extensions/AutoDelegateBravoGovernor.sol";

contract InstanceOfAutoDelegateBravoGovernor is AutoDelegateBravoGovernor {
  function exposed_castVote(address _governor, uint256 _proposalId) external {
    _castVote(_governor, _proposalId);
  }

  function exposed_getProposalDetails(address _governor, uint256 _proposalId)
    external
    view
    returns (uint256 _proposalDeadline, uint256 _forVotes, uint256 _againstVotes, uint256 _quorumVotes)
  {
    return _getProposalDetails(_governor, _proposalId);
  }
}

contract AutoDelegateBravoGovernorTest is Test {
  InstanceOfAutoDelegateBravoGovernor public autoDelegate;
  GovernorBravoDelegateMock public governor;

  function setUp() public {
    autoDelegate = new InstanceOfAutoDelegateBravoGovernor();
    governor = new GovernorBravoDelegateMock();
  }
}

contract _CastVote is AutoDelegateBravoGovernorTest {
  function testFuzz_CastsSupportVote(uint256 _proposalId) public {
    autoDelegate.exposed_castVote(address(governor), _proposalId);
    assertEq(governor.mockProposalVotes(_proposalId), uint8(autoDelegate.FOR()));
  }
}

contract _GetProposalDetails is AutoDelegateBravoGovernorTest {
  function testFuzz_ReturnsCorrectProposalDetails(
    uint256 _proposalId,
    uint256 _proposalDeadline,
    uint256 _forVotes,
    uint256 _againstVotes
  ) public {
    governor.__setProposals(_proposalId, _proposalDeadline, _forVotes, _againstVotes);

    (
      uint256 _receivedProposalDeadline,
      uint256 _receivedForVotes,
      uint256 _receivedAgainstVotes,
      uint256 _receivedQuorumVotes
    ) = autoDelegate.exposed_getProposalDetails(address(governor), _proposalId);

    (,,,, uint256 _expectedProposalDeadline, uint256 _expectedForVotes, uint256 _expectedAgainstVotes,,,) =
      IGovernorBravoDelegate(address(governor)).proposals(_proposalId);
    uint256 _expectedQuorumVotes = IGovernorBravoDelegate(address(governor)).quorumVotes();

    assertEq(_receivedProposalDeadline, _expectedProposalDeadline);
    assertEq(_receivedForVotes, _expectedForVotes);
    assertEq(_receivedAgainstVotes, _expectedAgainstVotes);
    assertEq(_receivedQuorumVotes, _expectedQuorumVotes);
  }
}
