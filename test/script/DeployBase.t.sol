// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {GovLst} from "src/GovLst.sol";
import {Staker} from "staker/Staker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEarningPowerCalculator} from "staker/interfaces/IEarningPowerCalculator.sol";
import {DeployBase} from "src/script/DeployBase.sol";
import {ERC20VotesMock} from "lib/staker/test/mocks/MockERC20Votes.sol";
import {FakeDeployBase} from "../fakes/FakeDeployBase.sol";
import {MockERC20Token} from "../mocks/MockERC20Token.sol";

contract DeployBaseTest is Test {
  MockERC20Token public rewardToken;
  ERC20VotesMock public stakeToken;
  address public autoDelegate;
  address public deployer;
  uint256 public stakeToBurn;

  function setUp() public {
    rewardToken = new MockERC20Token();
    vm.label(address(rewardToken), "Reward Token");

    stakeToken = new ERC20VotesMock();
    vm.label(address(stakeToken), "Stake Token");

    autoDelegate = makeAddr("AutoDelegate");

    uint256 deployerPrivateKey =
      vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
    deployer = vm.rememberKey(deployerPrivateKey);

    stakeToBurn = 1e15;
  }
}

contract Run is DeployBaseTest {
  function test_GovLstSystemDeploy() public {
    stakeToken.mint(deployer, stakeToBurn);

    FakeDeployBase deployScript = new FakeDeployBase(IERC20(address(rewardToken)), IERC20(address(stakeToken)));

    (Staker staker, IEarningPowerCalculator calculator, GovLst govLst, address deployedAutoDelegate) =
      deployScript.run();

    // Verify staker params
    assertEq(address(staker.REWARD_TOKEN()), address(rewardToken));
    assertEq(address(staker.STAKE_TOKEN()), address(stakeToken));
    assertEq(address(staker.earningPowerCalculator()), address(calculator));
    assertEq(staker.admin(), deployScript.admin());

    // Verify GovLst deployment
    assertEq(address(govLst), address(deployScript._rebasingLst()));
    assertEq(address(govLst.defaultDelegatee()), deployedAutoDelegate);
    assertEq(address(govLst.STAKER()), address(staker));
    assertEq(govLst.name(), "Rebasing LST");
    assertEq(govLst.symbol(), "rLST");
    assertEq(govLst.owner(), deployScript.admin());
    assertEq(address(govLst.FIXED_LST().LST().STAKER()), address(staker));
    assertEq(address(govLst.FIXED_LST().STAKE_TOKEN()), address(stakeToken));
  }

  function test_RevertIf_InsufficientStakeToBurn(uint256 _insufficientBalance) public {
    _insufficientBalance = bound(_insufficientBalance, 0, stakeToBurn - 1);
    stakeToken.mint(deployer, _insufficientBalance);

    FakeDeployBase deployScript = new FakeDeployBase(IERC20(address(rewardToken)), IERC20(address(stakeToken)));

    vm.expectRevert(DeployBase.DeployBase__InsufficientStakeToBurn.selector);
    deployScript.run();
  }
}
