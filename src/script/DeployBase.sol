// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import {Staker, IERC20} from "lib/staker/src/Staker.sol";
import {GovLst} from "src/GovLst.sol";
import {IEarningPowerCalculator} from "lib/staker/src/interfaces/IEarningPowerCalculator.sol";

abstract contract DeployBase is Script {
  address internal _autoDelegate;
  GovLst public _rebasingLst;
  address public deployer;

  error DeployBase__InsufficientStakeToBurn();

  function _fetchOrDeployAutoDelegate() internal virtual returns (address);

  function _fetchOrDeployStakerStakingSystem()
    internal
    virtual
    returns (IEarningPowerCalculator, Staker, address[] memory); /* _notifiers*/

  function _govLstConfiguration(Staker _staker, address _autoDelegate)
    internal
    virtual
    returns (GovLst.ConstructorParams memory);

  function _deployGovLst(Staker _staker, address _autoDelegate) internal virtual returns (GovLst _govLst);

  function run() public virtual returns (Staker, IEarningPowerCalculator, GovLst, address) {
    uint256 deployerPrivateKey =
      vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
    deployer = vm.rememberKey(deployerPrivateKey);

    _autoDelegate = _fetchOrDeployAutoDelegate();

    (IEarningPowerCalculator _calculator, Staker _staker, address[] memory _notifiers) =
      _fetchOrDeployStakerStakingSystem();
    console2.log("Deployed Staker :", address(_staker));
    console2.log("Deployed Earning Power Calculator :", address(_calculator));

    address _admin = _staker.admin();
    for (uint256 _i = 0; _i < _notifiers.length; _i++) {
      vm.broadcast(_admin);
      _staker.setRewardNotifier(_notifiers[_i], true);
      console2.log("Deployed and Configured Notifier", _notifiers[_i]);
    }

    GovLst.ConstructorParams memory _lstConfig = _govLstConfiguration(_staker, _autoDelegate);

    IERC20 stakeToken = _staker.STAKE_TOKEN();
    uint256 deployerStakeBalance = stakeToken.balanceOf(deployer);
    console2.log("Deployer's STAKE_TOKEN balance:", deployerStakeBalance);
    console2.log("Required stakeToBurn for LST:", _lstConfig.stakeToBurn);

    if (deployerStakeBalance < _lstConfig.stakeToBurn) {
      revert DeployBase__InsufficientStakeToBurn();
    }

    uint256 _deployerNonce = vm.getNonce(deployer);
    address _computedLstAddress = vm.computeCreateAddress(deployer, _deployerNonce + 1);

    vm.broadcast(deployer);
    stakeToken.approve(_computedLstAddress, _lstConfig.stakeToBurn);
    console2.log("Approved", _computedLstAddress, _lstConfig.stakeToBurn);

    _rebasingLst = _deployGovLst(_staker, _autoDelegate);
    console2.log("Deployed Rebasing GovLst:", address(_rebasingLst));
    console2.log("Deployed Fixed GovLst:", address(_rebasingLst.FIXED_LST()));

    return (_staker, _calculator, _rebasingLst, _autoDelegate);
  }
}
