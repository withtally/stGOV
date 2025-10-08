// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {FixedGovLst} from "../../src/FixedGovLst.sol";
import {AddressSet, LibAddressSet} from "./AddressSet.sol";

contract FixedGovLstHandler is CommonBase, StdCheats, StdUtils {
  using LibAddressSet for AddressSet;

  // system setup
  FixedGovLst public fixedGovLst;
  IERC20 public stakeToken;
  mapping(bytes32 => uint256) public calls;

  // actors, deposit state
  AddressSet holders;

  // ghost vars
  uint256 public ghost_stakeStaked;
  uint256 public ghost_stakeUnstaked;

  modifier countCall(bytes32 key) {
    calls[key]++;
    _;
  }

  constructor(FixedGovLst _fixedGovLst) {
    fixedGovLst = _fixedGovLst;
    stakeToken = fixedGovLst.STAKE_TOKEN();
  }

  function _useActor(AddressSet storage _set, uint256 _randomActorSeed) internal view returns (address) {
    return _set.rand(_randomActorSeed);
  }

  function _mintStakeToken(address _to, uint256 _amount) internal {
    vm.assume(_to != address(0));
    deal(address(stakeToken), _to, _amount, true);
  }

  function stake(address _depositor, uint96 _amount) public countCall("stake") {
    vm.assume(_depositor != address(0));
    holders.add(_depositor);

    _amount = uint96(_bound(_amount, 0.1e18, 100_000_000e18));

    // assume user has stake amount
    _mintStakeToken(_depositor, _amount);

    vm.startPrank(_depositor);
    stakeToken.approve(address(fixedGovLst), _amount);
    fixedGovLst.stake(_amount);
    vm.stopPrank();

    ghost_stakeStaked += _amount;
  }

  function unstake(uint256 _actorSeed, uint256 _amount) public countCall("unstake") {
    address _holder = _useActor(holders, _actorSeed);
    vm.assume(_holder != address(0));

    uint256 _holderBalance = fixedGovLst.balanceOf(_holder);
    _amount = _bound(_amount, 0, _holderBalance);

    vm.startPrank(_holder);
    uint256 _unstakeAmount = fixedGovLst.unstake(_amount);
    vm.stopPrank();
    ghost_stakeUnstaked += _unstakeAmount;
  }
}
