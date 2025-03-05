// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";
import {AddressSet, LibAddressSet} from "./AddressSet.sol";
import {DepositIdSet, LibDepositIdSet} from "./DepositIdSet.sol";
import {GovLst} from "../../src/GovLst.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Staker} from "staker/Staker.sol";

contract GovLstHandler is CommonBase, StdCheats, StdUtils {
  using LibAddressSet for AddressSet;
  using LibDepositIdSet for DepositIdSet;

  // system setup
  GovLst public lst;
  Staker public staker;
  IERC20 public stakeToken;
  IERC20 public rewardToken;
  address public admin;
  mapping(bytes32 => uint256) public calls;

  // actors, deposit state
  AddressSet holders;
  DepositIdSet depositIds;

  // ghost vars
  uint256 public ghost_stakeStaked;
  uint256 public ghost_stakeUnstaked;
  uint256 public ghost_rewardsClaimedAndDistributed;
  uint256 public ghost_rewardsNotified;

  // invariant markers
  bool public balanceInvariantBroken;
  bool public transferInvariantBroken;

  modifier countCall(bytes32 key) {
    calls[key]++;
    _;
  }

  constructor(GovLst _govLst) {
    lst = _govLst;
    staker = _govLst.STAKER();
    stakeToken = staker.STAKE_TOKEN();
    rewardToken = IERC20(address(staker.REWARD_TOKEN()));
    admin = staker.admin();
    depositIds.add(lst.DEFAULT_DEPOSIT_ID());
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
    vm.assume(_depositor != address(lst.WITHDRAW_GATE()));
    holders.add(_depositor);

    _amount = uint96(_bound(_amount, 0.1e18, 100_000_000e18));

    // assume user has stake amount
    _mintStakeToken(_depositor, _amount);

    uint256 _depositorBalanceBefore = lst.balanceOf(_depositor);

    vm.startPrank(_depositor);
    stakeToken.approve(address(lst), _amount);
    lst.stake(_amount);
    vm.stopPrank();

    uint256 _depositorBalanceAfter = lst.balanceOf(_depositor);
    if (_depositorBalanceAfter - _depositorBalanceBefore > _amount) {
      balanceInvariantBroken = true;
    }

    ghost_stakeStaked += _amount;
  }

  function unstake(uint256 _actorSeed, uint256 _amount) public countCall("unstake") {
    address _holder = _useActor(holders, _actorSeed);
    vm.assume(_holder != address(0));

    uint256 _holderBalance = lst.balanceOf(_holder);
    _amount = _bound(_amount, 0, _holderBalance);

    vm.startPrank(_holder);
    uint256 _balanceBefore = stakeToken.balanceOf(address(lst.WITHDRAW_GATE()));
    lst.unstake(_amount);
    uint256 _unstakedActual = stakeToken.balanceOf(address(lst.WITHDRAW_GATE())) - _balanceBefore;
    vm.stopPrank();
    ghost_stakeUnstaked += _unstakedActual;
  }

  function validTransfer(uint256 _holderSeed, address _to, uint256 _amount) public countCall("validTransfer") {
    address _holder = _useActor(holders, _holderSeed);
    vm.assume(_holder != address(0));
    vm.assume(_to != address(0));

    uint256 _holderBalance = lst.balanceOf(_holder);
    uint256 _toBalance = lst.balanceOf(_to);
    _amount = _bound(_amount, 0, _holderBalance);

    vm.startPrank(_holder);
    lst.transfer(_to, _amount);
    vm.stopPrank();

    // Calculate the difference between the amount the receiver's balance increased and the
    // sender's balance decreased. If not for truncation, this would be zero, because the
    // receiver's balance would increase by exactly as much as the sender's decreased. Because of
    // truncation, we know the difference may be up to 1 wei, assuming the total shares are greater
    // than the total supply.
    uint256 _holderBalanceDecrease = _holderBalance - lst.balanceOf(_holder);
    uint256 _toBalanceIncrease = lst.balanceOf(_to) - _toBalance;
    uint256 _balanceChangeDiff;
    if (_holderBalanceDecrease > _toBalanceIncrease) {
      _balanceChangeDiff = _holderBalanceDecrease - _toBalanceIncrease;
    } else {
      _balanceChangeDiff = _toBalanceIncrease - _holderBalanceDecrease;
    }

    // The difference between the sender's decrease and the receiver's increase should not be more than 1 wei
    if (_balanceChangeDiff > 1) {
      transferInvariantBroken = true;
    }

    holders.add(_to);
  }

  function fetchOrInitializeDepositForDelegatee(address _actor, address _delegatee)
    public
    countCall("fetchOrInitializeDepositForDeleg")
  {
    vm.assume(_actor != address(0));
    vm.assume(_delegatee != address(0));

    vm.startPrank(_actor);
    Staker.DepositIdentifier _id = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    vm.stopPrank();

    depositIds.add(_id);
  }

  function updateDeposit(uint256 _actorSeed, uint256 _depositSeed) public countCall("updateDeposit") {
    address _holder = _useActor(holders, _actorSeed);
    Staker.DepositIdentifier _id = depositIds.rand(_depositSeed);

    vm.startPrank(_holder);
    lst.updateDeposit(_id);
    vm.stopPrank();
  }

  function notifyRewardAmount(uint256 _amount) public countCall("notifyRewardAmount") {
    _amount = _bound(_amount, 0, 100_000_000e18);
    _mintRewardToken(admin, _amount);
    vm.startPrank(admin);
    rewardToken.transfer(address(staker), _amount);
    staker.notifyRewardAmount(_amount);
    vm.stopPrank();
    ghost_rewardsNotified += _amount;
  }

  function claimAndDistributeReward(
    address _actor,
    address _recipient,
    uint256 _minExpectedAmount,
    Staker.DepositIdentifier _depositId
  ) public countCall("claimAndDistributeReward") {
    vm.assume(_actor != address(0));
    vm.assume(_recipient != address(0));

    Staker.DepositIdentifier[] memory _deposits = new Staker.DepositIdentifier[](1);
    _deposits[0] = _depositId;

    // in REWARD_TOKEN
    _minExpectedAmount = _bound(_minExpectedAmount, 0, staker.unclaimedReward(_depositId));
    uint256 _payoutAmount = lst.payoutAmount();
    _mintStakeToken(_actor, _payoutAmount);
    vm.startPrank(_actor);
    // we give STAKE_TOKEN to get REWARD_TOKEN
    stakeToken.approve(address(lst), _payoutAmount);
    lst.claimAndDistributeReward(_recipient, _minExpectedAmount, _deposits);
    vm.stopPrank();

    // If distributing this reward would result in the raw total supply being greater than the raw
    // total shares, then we don't allow it. Because the total shares has a scale factor applied,
    // this scenario can only occur in extreme circumstances that are unlikely in the real world.
    // For example, if only a fraction of a stake token is stake, while billions of reward tokens
    // are distributed as rewards, raw supply may exceed raw shares. However, when this assumption
    // holds, we can make stricter assumptions about the nature of rounding errors. In particular,
    // we can be mathematically certain that errors introduced by truncation will be 1 wei or less.
    // Given this, we apply this constraint here to make the rest of our invariant tests stricter.
    // It might be worth considering if a different set of invariants, that don't apply this
    // constraint, should also be developed.
    vm.assume(lst.totalShares() > lst.totalSupply());

    ghost_rewardsClaimedAndDistributed += _payoutAmount;
  }

  function warpAhead(uint256 _seconds) public countCall("warpAhead") {
    _seconds = _bound(_seconds, 0, lst.STAKER().REWARD_DURATION() * 2);
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

  function reduceDepositIds(uint256 acc, function(uint256,Staker.DepositIdentifier) external returns (uint256) func)
    public
    returns (uint256)
  {
    return depositIds.reduce(acc, func);
  }

  function forEachDepositId(function(Staker.DepositIdentifier) external func) external {
    depositIds.forEach(func);
  }

  function callSummary() external view {
    console.log("\nCall summary:");
    console.log("-------------------");
    console.log("stake", calls["stake"]);
    console.log("unstake", calls["unstake"]);
    console.log("validTransfer", calls["validTransfer"]);
    console.log("fetchOrInitializeDepositForDelegatee", calls["fetchOrInitializeDepositForDeleg"]);
    console.log("updateDeposit", calls["updateDeposit"]);
    console.log("claimAndDistributeReward", calls["claimAndDistributeReward"]);
    console.log("notifyRewardAmount", calls["notifyRewardAmount"]);
    console.log("warpAhead", calls["warpAhead"]);
    console.log("-------------------\n");
  }

  receive() external payable {}
}
