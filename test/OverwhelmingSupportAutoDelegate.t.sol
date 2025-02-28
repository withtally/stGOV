// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {OverwhelmingSupportAutoDelegate, Ownable} from "../src/auto-delegates/OverwhelmingSupportAutoDelegate.sol";
import {GovernorBravoDelegateMock} from "./mocks/GovernorBravoDelegateMock.sol";
import {OpenZeppelinGovernorMock} from "./mocks/OpenZeppelinGovernorMock.sol";
import {OverwhelmingSupportAutoDelegateBravoGovernorBlockNumberModeMock} from
  "./mocks/OverwhelmingSupportAutoDelegateBravoGovernorBlockNumberModeMock.sol";
import {OverwhelmingSupportAutoDelegateBravoGovernorTimestampModeMock} from
  "./mocks/OverwhelmingSupportAutoDelegateBravoGovernorTimestampModeMock.sol";
import {OverwhelmingSupportAutoDelegateOZGovernorBlockNumberModeMock} from
  "./mocks/OverwhelmingSupportAutoDelegateOZGovernorBlockNumberModeMock.sol";
import {OverwhelmingSupportAutoDelegateOZGovernorTimestampModeMock} from
  "./mocks/OverwhelmingSupportAutoDelegateOZGovernorTimestampModeMock.sol";

abstract contract OverwhelmingSupportAutoDelegateTest is Test {
  OverwhelmingSupportAutoDelegate public autoDelegate;
  GovernorBravoDelegateMock public governor;
  address public owner = makeAddr("Owner");
  uint256 votingWindow = 1000; // Number of blocks
  uint256 votingWindowInSeconds = 7200; // 2 hours.
  uint256 subQuorumBips = 7500; // 75% of governor `QuorumVotes`
  uint256 supportThreshold = 7000; // 70%
  uint256 proposalDeadline = 20_000; // Arbitrary proposal deadline timepoint. (20,000 blocks or 20000 seconds).
  uint256 minSupportThreshold = 5000; // 50%
  uint256 maxSupportThreshold = 9500; // 95%
  bool isUsingTimestampMode = false;
  uint256 internal constant GOV_SUPPLY = 1_000_000_000e18;
  /// @notice BIP (Basis Points) constant where 100% equals 10,000 basis points (BIP)
  uint256 internal constant BIP = 10_000;

  function setUp() public virtual {
    autoDelegate = autoDelegateUsingBlockNumberOrTimestampMode();
    governor = new GovernorBravoDelegateMock();
    rollOrWarpToTimepoint(10_000); // Roll block to 10000;
  }

  function autoDelegateUsingBlockNumberOrTimestampMode() public virtual returns (OverwhelmingSupportAutoDelegate) {}

  function getTimepoint() public view returns (uint256) {
    if (isUsingTimestampMode) {
      return vm.getBlockTimestamp();
    } else {
      return vm.getBlockNumber();
    }
  }

  function rollOrWarpToTimepoint(uint256 _timepoint) public {
    if (isUsingTimestampMode) {
      vm.warp(_timepoint);
    } else {
      vm.roll(_timepoint);
    }
  }
}

abstract contract Constructor is OverwhelmingSupportAutoDelegateTest {
  function test_SetsCorrectOwner() public view {
    assertEq(autoDelegate.owner(), owner);
    assertEq(autoDelegate.votingWindow(), votingWindow);
    assertEq(autoDelegate.subQuorumBips(), subQuorumBips);
    assertEq(autoDelegate.supportThreshold(), supportThreshold);
  }
}

abstract contract CastVote is OverwhelmingSupportAutoDelegateTest {
  function testFuzz_CastsSupportVote(
    uint256 _proposalId,
    uint256 _blocksWithinVotingWindow,
    uint256 _proposalDeadline,
    uint256 _forVotesBIP,
    uint256 _forVotes
  ) public {
    _blocksWithinVotingWindow = bound(_blocksWithinVotingWindow, 0, uint48(votingWindow));
    _proposalDeadline = bound(_proposalDeadline, getTimepoint() + governor.votingPeriod(), type(uint48).max);
    _forVotesBIP = bound(_forVotesBIP, subQuorumBips, BIP);
    uint256 _forVotesLowerBound = governor.quorumVotes() * _forVotesBIP / BIP;
    _forVotes = bound(_forVotes, _forVotesLowerBound, GOV_SUPPLY);

    // Set the proposal end block to an arbitrary timepoint.
    governor.__setProposals(_proposalId, _proposalDeadline, _forVotes, /*Against*/ 0);
    rollOrWarpToTimepoint(_proposalDeadline - _blocksWithinVotingWindow);

    autoDelegate.castVote(address(governor), _proposalId);
    assertEq(governor.mockProposalVotes(_proposalId), 1);
  }

  function testFuzz_RevertIf_CurrentBlockIsOutsideVotingWindow(
    uint256 _proposalId,
    uint256 _blocksOutsideVotingWindow,
    uint256 _proposalDeadline
  ) public {
    _proposalDeadline = bound(_proposalDeadline, getTimepoint() + governor.votingPeriod(), type(uint48).max);
    _blocksOutsideVotingWindow = bound(_blocksOutsideVotingWindow, votingWindow + 1, _proposalDeadline);
    // Set the proposal end block to an arbitrary timepoint.
    governor.__setProposals(_proposalId, _proposalDeadline, /*For*/ 0, /*Against*/ 0);
    rollOrWarpToTimepoint(_proposalDeadline - _blocksOutsideVotingWindow);

    vm.expectRevert(
      abi.encodeWithSelector(
        OverwhelmingSupportAutoDelegate.OverwhelmingSupportAutoDelegate__OutsideVotingWindow.selector
      )
    );
    autoDelegate.castVote(address(governor), _proposalId);
  }

  function testFuzz_RevertIf_ProposalDoesNotHaveSufficientForVotes(
    uint256 _proposalId,
    uint256 _blocksWithinBuffer,
    uint256 _forVotesBIP
  ) public {
    _blocksWithinBuffer = bound(_blocksWithinBuffer, 0, votingWindow);
    _forVotesBIP = bound(_forVotesBIP, 0, autoDelegate.subQuorumBips() - 1);
    uint256 _forVotes = governor.quorumVotes() * _forVotesBIP / BIP;
    // Set the proposal end block to an arbitrary timepoint.
    governor.__setProposals(_proposalId, proposalDeadline, _forVotes, /*Against*/ 0);
    rollOrWarpToTimepoint(proposalDeadline - _blocksWithinBuffer);

    vm.expectRevert(OverwhelmingSupportAutoDelegate.OverwhelmingSupportAutoDelegate__InsufficientForVotes.selector);
    autoDelegate.castVote(address(governor), _proposalId);
  }

  function testFuzz_RevertIf_VoteRatioIsBelowSupportRatio(
    uint256 _proposalId,
    uint256 _blocksWithinBuffer,
    uint256 _totalVotes,
    uint256 _forVotes,
    uint256 _againstVotes
  ) public {
    _blocksWithinBuffer = bound(_blocksWithinBuffer, 0, votingWindow);
    uint256 _subQuorumVotes = (governor.quorumVotes() * subQuorumBips / BIP);
    _totalVotes = bound(_totalVotes, _subQuorumVotes * 2, GOV_SUPPLY);
    // Max is bound to 1 below votes required to meet supportThreshold.
    _forVotes = bound(_forVotes, _subQuorumVotes, _totalVotes * supportThreshold / BIP - 1);
    _againstVotes = _totalVotes - _forVotes;
    // Set the proposal end block to an arbitrary timepoint.
    governor.__setProposals(_proposalId, proposalDeadline, _forVotes, _againstVotes);
    rollOrWarpToTimepoint(proposalDeadline - _blocksWithinBuffer);

    vm.expectRevert(OverwhelmingSupportAutoDelegate.OverwhelmingSupportAutoDelegate__BelowSupportThreshold.selector);
    autoDelegate.castVote(address(governor), _proposalId);
  }
}

abstract contract SetVotingWindow is OverwhelmingSupportAutoDelegateTest {
  function boundVotingWindow(uint256 _votingWindow) public view returns (uint256) {
    return bound(_votingWindow, autoDelegate.MIN_VOTING_WINDOW(), autoDelegate.MAX_VOTING_WINDOW());
  }

  function testFuzz_SetsVotingWindow(uint256 _votingWindow) public {
    _votingWindow = boundVotingWindow(_votingWindow);
    vm.prank(owner);
    autoDelegate.setVotingWindow(_votingWindow);
    assertEq(autoDelegate.votingWindow(), _votingWindow);
  }

  function testFuzz_EmitsEventWhenVotingWindowIsSet(uint256 _votingWindow) public {
    _votingWindow = boundVotingWindow(_votingWindow);
    vm.expectEmit();
    emit OverwhelmingSupportAutoDelegate.VotingWindowSet(autoDelegate.votingWindow(), _votingWindow);
    vm.prank(owner);
    autoDelegate.setVotingWindow(_votingWindow);
  }

  function testFuzz_RevertIf_NotOwner(address _actor, uint256 _votingWindow) public {
    _votingWindow = boundVotingWindow(_votingWindow);
    vm.assume(_actor != owner);
    vm.prank(_actor);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _actor));
    autoDelegate.setVotingWindow(_votingWindow);
  }

  function testFuzz_RevertIf_VotingWindowIsBelowMinimum(uint256 _votingWindow) public {
    _votingWindow = bound(_votingWindow, 0, autoDelegate.MIN_VOTING_WINDOW() - 1);

    vm.prank(owner);
    vm.expectRevert(OverwhelmingSupportAutoDelegate.OverwhelmingSupportAutoDelegate__InvalidVotingWindow.selector);
    autoDelegate.setVotingWindow(_votingWindow);
  }

  function testFuzz_RevertIf_VotingWindowIsAboveMaximum(uint256 _votingWindow) public {
    _votingWindow = bound(_votingWindow, autoDelegate.MAX_VOTING_WINDOW() + 1, type(uint48).max);

    vm.prank(owner);
    vm.expectRevert(OverwhelmingSupportAutoDelegate.OverwhelmingSupportAutoDelegate__InvalidVotingWindow.selector);
    autoDelegate.setVotingWindow(_votingWindow);
  }
}

abstract contract Clock is OverwhelmingSupportAutoDelegateTest {
  function test_ReturnsCorrectClockValue() public view {
    assertEq(autoDelegate.clock(), getTimepoint());
  }
}

abstract contract Clock_Mode is OverwhelmingSupportAutoDelegateTest {
  function test_ReturnsCorrectClockMode() public view {
    if (isUsingTimestampMode) {
      assertEq(autoDelegate.CLOCK_MODE(), "mode=timestamp");
    } else {
      assertEq(autoDelegate.CLOCK_MODE(), "mode=blocknumber&from=default");
    }
  }
}

abstract contract SetSubQuorumBips is OverwhelmingSupportAutoDelegateTest {
  function testFuzz_SetsSubQuorumBips(uint256 _subQuorumBips) public {
    _subQuorumBips = bound(_subQuorumBips, autoDelegate.MIN_SUB_QUORUM_BIPS(), autoDelegate.MAX_SUB_QUORUM_BIPS());
    vm.prank(owner);
    autoDelegate.setSubQuorumBips(_subQuorumBips);
    assertEq(autoDelegate.subQuorumBips(), _subQuorumBips);
  }

  function testFuzz_EmitsEventWhenSubQuorumBipsIsSet(uint256 _subQuorumBips) public {
    _subQuorumBips = bound(_subQuorumBips, autoDelegate.MIN_SUB_QUORUM_BIPS(), autoDelegate.MAX_SUB_QUORUM_BIPS());
    vm.expectEmit();
    emit OverwhelmingSupportAutoDelegate.SubQuorumBipsSet(autoDelegate.subQuorumBips(), _subQuorumBips);
    vm.prank(owner);
    autoDelegate.setSubQuorumBips(_subQuorumBips);
  }

  function testFuzz_RevertIf_NotOwner(address _actor, uint256 _subQuorumBips) public {
    _subQuorumBips = bound(_subQuorumBips, autoDelegate.MIN_SUB_QUORUM_BIPS(), autoDelegate.MAX_SUB_QUORUM_BIPS());
    vm.assume(_actor != owner);
    vm.prank(_actor);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _actor));
    autoDelegate.setSubQuorumBips(_subQuorumBips);
  }

  function testFuzz_RevertIf_SubQuorumBipsIsBelowMinimum(uint256 _subQuorumBips) public {
    _subQuorumBips = bound(_subQuorumBips, 0, autoDelegate.MIN_SUB_QUORUM_BIPS() - 1);
    vm.prank(owner);
    vm.expectRevert(OverwhelmingSupportAutoDelegate.OverwhelmingSupportAutoDelegate__InvalidSubQuorumBips.selector);
    autoDelegate.setSubQuorumBips(_subQuorumBips);
  }

  function testFuzz_RevertIf_SubQuorumBipsIsAboveMaximum(uint256 _subQuorumBips) public {
    _subQuorumBips = bound(_subQuorumBips, autoDelegate.MAX_SUB_QUORUM_BIPS() + 1, type(uint256).max);
    vm.prank(owner);
    vm.expectRevert(OverwhelmingSupportAutoDelegate.OverwhelmingSupportAutoDelegate__InvalidSubQuorumBips.selector);
    autoDelegate.setSubQuorumBips(_subQuorumBips);
  }
}

abstract contract SetSupportThreshold is OverwhelmingSupportAutoDelegateTest {
  function testFuzz_SetsSupportRatio(uint256 _supportThreshold) public {
    _supportThreshold = bound(_supportThreshold, minSupportThreshold, maxSupportThreshold);
    vm.prank(owner);
    autoDelegate.setSupportThreshold(_supportThreshold);
    assertEq(autoDelegate.supportThreshold(), _supportThreshold);
  }

  function testFuzz_EmitsEventWhenSupportThresholdIsSet(uint256 _supportThreshold) public {
    _supportThreshold = bound(_supportThreshold, minSupportThreshold, maxSupportThreshold);
    vm.expectEmit();
    emit OverwhelmingSupportAutoDelegate.SupportThresholdSet(autoDelegate.supportThreshold(), _supportThreshold);
    vm.prank(owner);
    autoDelegate.setSupportThreshold(_supportThreshold);
  }

  function testFuzz_RevertIf_NotOwner(address _actor, uint256 _supportThreshold) public {
    vm.assume(_actor != owner);
    vm.prank(_actor);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _actor));
    autoDelegate.setSupportThreshold(_supportThreshold);
  }

  function testFuzz_RevertIf_SetsInvalidSupportRatio(uint256 _supportThreshold, uint256 _randomSeed) public {
    if (_randomSeed % 1 == 0) {
      _supportThreshold = bound(_supportThreshold, 0, minSupportThreshold - 1);
    } else {
      _supportThreshold = bound(_supportThreshold, maxSupportThreshold + 1, BIP);
    }
    vm.prank(owner);
    vm.expectRevert(OverwhelmingSupportAutoDelegate.OverwhelmingSupportAutoDelegate__InvalidSupportThreshold.selector);
    autoDelegate.setSupportThreshold(_supportThreshold);
  }
}

contract OZGovernorBlockNumberModeConstructor is OverwhelmingSupportAutoDelegateTest, Constructor {
  function autoDelegateUsingBlockNumberOrTimestampMode() public override returns (OverwhelmingSupportAutoDelegate) {
    return new OverwhelmingSupportAutoDelegateOZGovernorBlockNumberModeMock(
      owner, votingWindow, subQuorumBips, supportThreshold
    );
  }
}

contract OZGovernorBlockNumberModeCastVote is OverwhelmingSupportAutoDelegateTest, CastVote {
  function setUp() public override {
    super.setUp();
    governor = GovernorBravoDelegateMock(address(new OpenZeppelinGovernorMock()));
  }

  function autoDelegateUsingBlockNumberOrTimestampMode() public override returns (OverwhelmingSupportAutoDelegate) {
    return new OverwhelmingSupportAutoDelegateOZGovernorBlockNumberModeMock(
      owner, votingWindow, subQuorumBips, supportThreshold
    );
  }
}

contract OZGovernorBlockNumberModeSetVotingWindow is OverwhelmingSupportAutoDelegateTest, SetVotingWindow {
  function autoDelegateUsingBlockNumberOrTimestampMode() public override returns (OverwhelmingSupportAutoDelegate) {
    return new OverwhelmingSupportAutoDelegateOZGovernorBlockNumberModeMock(
      owner, votingWindow, subQuorumBips, supportThreshold
    );
  }
}

contract OZGovernorBlockNumberModeClock is OverwhelmingSupportAutoDelegateTest, Clock {
  function autoDelegateUsingBlockNumberOrTimestampMode() public override returns (OverwhelmingSupportAutoDelegate) {
    return new OverwhelmingSupportAutoDelegateOZGovernorBlockNumberModeMock(
      owner, votingWindow, subQuorumBips, supportThreshold
    );
  }
}

contract OZGovernorBlockNumberModeClockMode is OverwhelmingSupportAutoDelegateTest, Clock_Mode {
  function autoDelegateUsingBlockNumberOrTimestampMode() public override returns (OverwhelmingSupportAutoDelegate) {
    return new OverwhelmingSupportAutoDelegateOZGovernorBlockNumberModeMock(
      owner, votingWindow, subQuorumBips, supportThreshold
    );
  }
}

contract OZGovernorBlockNumberModeSetSubQuorumBips is OverwhelmingSupportAutoDelegateTest, SetSubQuorumBips {
  function autoDelegateUsingBlockNumberOrTimestampMode() public override returns (OverwhelmingSupportAutoDelegate) {
    return new OverwhelmingSupportAutoDelegateOZGovernorBlockNumberModeMock(
      owner, votingWindow, subQuorumBips, supportThreshold
    );
  }
}

contract OZGovernorBlockNumberModeSetSupportThreshold is OverwhelmingSupportAutoDelegateTest, SetSupportThreshold {
  function autoDelegateUsingBlockNumberOrTimestampMode() public override returns (OverwhelmingSupportAutoDelegate) {
    return new OverwhelmingSupportAutoDelegateOZGovernorBlockNumberModeMock(
      owner, votingWindow, subQuorumBips, supportThreshold
    );
  }
}
