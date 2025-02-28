// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {OpenZeppelinGovernorMock} from "./mocks/OpenZeppelinGovernorMock.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IGovernorCountingExtensions} from "../src/auto-delegates/interfaces/IGovernorCountingExtensions.sol";
import {FakeAutoDelegateOpenZeppelinGovernor} from "./fakes/FakeAutoDelegateOpenZeppelinGovernor.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract AutoDelegateOpenZeppelinGovernorTest is Test {
  FakeAutoDelegateOpenZeppelinGovernor public autoDelegate;
  OpenZeppelinGovernorMock public governor;

  function setUp() public {
    autoDelegate = new FakeAutoDelegateOpenZeppelinGovernor();
    governor = new OpenZeppelinGovernorMock();
  }
}

contract Clock is AutoDelegateOpenZeppelinGovernorTest {
  function testFuzz_ReturnsCurrentClock(uint256 _randomBlockNumber) public {
    _randomBlockNumber = bound(_randomBlockNumber, 0, type(uint48).max);
    vm.roll(_randomBlockNumber);
    assertEq(autoDelegate.clock(), SafeCast.toUint48(_randomBlockNumber));
  }
}

contract _CastVote is AutoDelegateOpenZeppelinGovernorTest {
  function testFuzz_CastsSupportVote(uint256 _proposalId) public {
    autoDelegate.exposed_castVote(address(governor), _proposalId);
    assertEq(governor.mockProposalVotes(_proposalId), uint8(autoDelegate.FOR()));
  }
}

contract _GetProposalDetails is AutoDelegateOpenZeppelinGovernorTest {
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

    uint256 _expectedProposalDeadline = IGovernor(address(governor)).proposalDeadline(_proposalId);
    (uint256 _expectedAgainstVotes, uint256 _expectedForVotes,) =
      IGovernorCountingExtensions(address(governor)).proposalVotes(_proposalId);
    uint256 _expectedQuorumVotes = IGovernor(address(governor)).quorum(autoDelegate.clock());

    assertEq(_receivedProposalDeadline, _expectedProposalDeadline);
    assertEq(_receivedForVotes, _expectedForVotes);
    assertEq(_receivedAgainstVotes, _expectedAgainstVotes);
    assertEq(_receivedQuorumVotes, _expectedQuorumVotes);
  }
}
