// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {Staker, IEarningPowerCalculator} from "lib/staker/src/Staker.sol";
import {GovLst} from "src/GovLst.sol";
import {GovLstHarness} from "stGOV-test/harnesses/GovLstHarness.sol";
import {OverwhelmingSupportAutoDelegateOZGovernorTimestampModeMock} from
  "stGOV-test/mocks/OverwhelmingSupportAutoDelegateOZGovernorTimestampModeMock.sol";
import {DeployBase} from "src/script/DeployBase.sol";
import {DeployBaseFake} from "lib/staker/test/fakes/DeployBaseFake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/Test.sol";

contract FakeDeployBase is DeployBase {
  address public admin = makeAddr("Staker admin");
  IERC20 public rewardToken;
  IERC20 public stakeToken;
  uint256 public initialVotingWindowTimepoints = 14_400; // copied from Rari
  uint256 public subQuorumBips = 6600;
  uint256 public supportThresholdBips = 9000;

  constructor(IERC20 _rewardToken, IERC20 _stakeToken) {
    rewardToken = _rewardToken;
    stakeToken = _stakeToken;
  }

  function _fetchOrDeployAutoDelegate() internal virtual override returns (address) {
    vm.broadcast(deployer);
    OverwhelmingSupportAutoDelegateOZGovernorTimestampModeMock _autoDelegate = new OverwhelmingSupportAutoDelegateOZGovernorTimestampModeMock(
      admin, initialVotingWindowTimepoints, subQuorumBips, supportThresholdBips
    );
    console2.log("Deployed Auto Delegate:", address(_autoDelegate));

    return address(_autoDelegate);
  }

  function _fetchOrDeployStakerStakingSystem()
    internal
    virtual
    override
    returns (IEarningPowerCalculator _calculator, Staker _staker, address[] memory _notifiers)
  {
    DeployBaseFake _deployScript = new DeployBaseFake(rewardToken, stakeToken);
    (_calculator, _staker, _notifiers) = _deployScript.run();
  }

  function _govLstConfiguration(Staker _staker, address _delegatee)
    internal
    virtual
    override
    returns (GovLst.ConstructorParams memory)
  {
    return GovLst.ConstructorParams({
      fixedLstName: "Fixed LST",
      fixedLstSymbol: "fLST",
      rebasingLstName: "Rebasing LST",
      rebasingLstSymbol: "rLST",
      version: "1.0",
      staker: _staker,
      initialDefaultDelegatee: _delegatee,
      initialOwner: admin,
      initialPayoutAmount: 1000,
      initialDelegateeGuardian: address(0),
      stakeToBurn: 1e15,
      minQualifyingEarningPowerBips: 1000
    });
  }

  function _deployGovLst(Staker _staker, address _autoDelegate) internal virtual override returns (GovLst _govLst) {
    GovLst.ConstructorParams memory _config = _govLstConfiguration(_staker, _autoDelegate);

    vm.broadcast(deployer);
    _govLst = new GovLstHarness(_config);
    console2.log("Deployed rebalancing GovLst:", address(_govLst));
  }

  // Public wrapper for testing
  function fetchOrDeployAutoDelegate() public returns (address) {
    return _fetchOrDeployAutoDelegate();
  }
}
