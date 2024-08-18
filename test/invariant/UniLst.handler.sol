// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";
import {AddressSet, LibAddressSet} from "./AddressSet.sol";
import {UniLst} from "src/UniLst.sol";
import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

contract UniLstHandler is CommonBase, StdCheats, StdUtils {
  using LibAddressSet for AddressSet;

  // system setup
  UniLst public lst;
  IUniStaker public staker;
  IERC20 public stakeToken;
  IERC20 public rewardToken;
  address public admin;
  mapping(bytes32 => uint256) public calls;

  // actors, deposit state
  AddressSet holders;

  // ghost vars
  uint256 public ghost_stakeStaked;
  uint256 public ghost_stakeUnstaked;
  uint256 public ghost_rewardsClaimedAndDistributed;
  uint256 public ghost_rewardsNotified;

  modifier countCall(bytes32 key) {
    calls[key]++;
    _;
  }

  constructor(UniLst _uniLst) {
    lst = _uniLst;
    staker = _uniLst.STAKER();
    stakeToken = IERC20(address(staker.STAKE_TOKEN()));
    rewardToken = IERC20(address(staker.REWARD_TOKEN()));
    admin = staker.admin();
  }

  function _useActor(AddressSet storage _set, uint256 _randomActorSeed) internal view returns (address) {
    return _set.rand(_randomActorSeed);
  }

  function _mintStakeToken(address _to, uint256 _amount) internal {
    vm.assume(_to != address(0));
    deal(address(stakeToken), _to, _amount, true);
  }

  function _mintRewardToken(address _to, uint256 _amount) internal {
    vm.assume(_to != address(0));
    deal(address(rewardToken), _to, _amount, false);
  }

  // Public handler fns

  function stake(address _depositor, uint96 _amount) public countCall("stake") {
    vm.assume(_depositor != address(0));
    holders.add(_depositor);

    _amount = uint96(bound(_amount, 0, 100_000_000e18));

    // assume user has stake amount
    _mintStakeToken(_depositor, _amount);

    vm.startPrank(_depositor);
    stakeToken.approve(address(lst), _amount);
    lst.stake(_amount);
    vm.stopPrank();

    ghost_stakeStaked += _amount;
  }

  function unstake(uint256 _actorSeed, uint256 _amount) public countCall("unstake") {
    address _holder = _useActor(holders, _actorSeed);
    vm.assume(_holder != address(0));

    uint256 _holderBalance = lst.balanceOf(_holder);
    _amount = bound(_amount, 0, _holderBalance);

    vm.startPrank(_holder);
    uint256 _balanceBefore = stakeToken.balanceOf(_holder);
    lst.unstake(_amount);
    uint256 _unstakedActual = stakeToken.balanceOf(_holder) - _balanceBefore;
    vm.stopPrank();
    ghost_stakeUnstaked += _unstakedActual;
  }

  function notifyRewardAmount(uint256 _amount) public countCall("notifyRewardAmount") {
    _amount = bound(_amount, 0, 100_000_000e18);
    _mintRewardToken(admin, _amount);
    vm.startPrank(admin);
    rewardToken.transfer(address(staker), _amount);
    staker.notifyRewardAmount(_amount);
    vm.stopPrank();
    ghost_rewardsNotified += _amount;
  }

  function claimAndDistributeReward(address _actor, address _recipient, uint256 _minExpectedAmount)
    public
    countCall("claimAndDistributeReward")
  {
    vm.assume(_actor != address(0));
    vm.assume(_recipient != address(0));
    // in REWARD_TOKEN
    _minExpectedAmount = bound(_minExpectedAmount, 0, staker.unclaimedReward(address(lst)));
    uint256 _payoutAmount = lst.payoutAmount();
    _mintStakeToken(_actor, _payoutAmount);
    vm.startPrank(_actor);
    // we give STAKE_TOKEN to get REWARD_TOKEN
    stakeToken.approve(address(lst), _payoutAmount);
    lst.claimAndDistributeReward(_recipient, _minExpectedAmount);
    vm.stopPrank();
    ghost_rewardsClaimedAndDistributed += _payoutAmount;
  }

  function warpAhead(uint256 _seconds) public countCall("warpAhead") {
    _seconds = bound(_seconds, 0, lst.STAKER().REWARD_DURATION() * 2);
    skip(_seconds);
  }

  // Other convenience methods

  function reduceHolders(uint256 acc, function(uint256,address) external returns (uint256) func)
    public
    returns (uint256)
  {
    return holders.reduce(acc, func);
  }

  function forEachHolder(function(address) external func) external {
    holders.forEach(func);
  }

  function callSummary() external view {
    console.log("\nCall summary:");
    console.log("-------------------");
    console.log("stake", calls["stake"]);
    console.log("unstake", calls["unstake"]);
    console.log("claimAndDistributeReward", calls["claimAndDistributeReward"]);
    console.log("notifyRewardAmount", calls["notifyRewardAmount"]);
    console.log("warpAhead", calls["warpAhead"]);
    console.log("-------------------\n");
  }

  receive() external payable {}
}
