// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import {Staker, IERC20} from "lib/staker/src/Staker.sol";
import {GovLst} from "src/GovLst.sol";

/// @title DeployBase
/// @author [ScopeLift](https://scopelift.co)
/// @notice The base contract for the GovLst modular deployment system. Any deployment script or extension should
/// inherit from this contract as it defines all of the necessary pieces for a GovLst system deployment. These pieces
/// are the gov lst contract, auto delegate and staker. Each of these components will have an implementation specific
/// extension that will be combined to create a concrete implementation of the deployment script. An example of what
/// this may look like can be found in test/fakes/FakeDeployBase.sol.
abstract contract DeployBase is Script {
  address internal _autoDelegate;
  GovLst public _rebasingLst;
  address public deployer;

  /// @notice Thrown if the deployer does not have sufficient stake to burn.
  error DeployBase__InsufficientStakeToBurn();

  /// @notice An interface method that fetches the auto delegate contract for the GovLst system.
  /// @dev Implementer can also deploy an auto delegate within the same transaction by inheriting
  /// DeployOverwhelmingSupportAutoDelegate.
  /// @return The address of the auto delegate contract.
  function _fetchOrDeployAutoDelegate() internal virtual returns (address);

  /// @notice An interface method that fetches the staker contract for the lst system.
  /// @dev Implementer can also deploy a staker within the same transaction by inheriting DeployLstStaker.
  /// @return The Staker contract for the lst system.
  function _fetchStaker() internal virtual returns (Staker);

  /// @notice An interface method that returns a set configuration for the lst system.
  /// @param _staker The Staker contract for the lst system.
  /// @param _autoDelegate The auto delegate contract for the lst system.
  /// @return The GovLst configuration for the lst system.
  function _govLstConfiguration(Staker _staker, address _autoDelegate)
    internal
    virtual
    returns (GovLst.ConstructorParams memory);

  /// @notice An interface method that deploys the GovLst contract for the lst system.
  /// @param _staker The Staker contract for the lst system.
  /// @param _autoDelegate The auto delegate contract for the lst system.
  /// @return _govLst The GovLst contract for the lst system.
  function _deployGovLst(Staker _staker, address _autoDelegate) internal virtual returns (GovLst _govLst);

  /// @notice The method that is executed when the script runs which deploys the entire lst system.
  /// @return The Staker contract, the GovLst contract, and the address of the auto delegate.
  function run() public virtual returns (Staker, GovLst, address) {
    uint256 deployerPrivateKey =
      vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
    deployer = vm.rememberKey(deployerPrivateKey);

    _autoDelegate = _fetchOrDeployAutoDelegate();

    Staker _staker = _fetchStaker();
    console2.log("Deployed Staker :", address(_staker));

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

    return (_staker, _rebasingLst, _autoDelegate);
  }
}
