// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {WrappedGovLst} from "../../src/WrappedGovLst.sol";
import {GovLst} from "../../src/GovLst.sol";
import {FixedGovLst} from "../../src/FixedGovLst.sol";

import {AddressSet, LibAddressSet} from "./AddressSet.sol";

contract WrappedGovLstHandler is CommonBase, StdCheats, StdUtils, StdAssertions {
  using LibAddressSet for AddressSet;

  // system setup
  WrappedGovLst public wrappedGovLst;
  GovLst public lst;
  IERC20 public stakeToken;
  FixedGovLst public fixedGovLst;
  mapping(bytes32 => uint256) public calls;
  bool public reverted = false;

  // actors, deposit state
  AddressSet holders;

  // ghost vars
  uint256 public ghost_fixedWrapped;
  uint256 public ghost_fixedUnwrapped;

  modifier countCall(bytes32 key) {
    calls[key]++;
    _;
  }

  constructor(WrappedGovLst _wrappedGovLst) {
    wrappedGovLst = _wrappedGovLst;
    lst = wrappedGovLst.LST();
    stakeToken = lst.STAKE_TOKEN();
    fixedGovLst = lst.FIXED_LST();
  }

  function _useActor(AddressSet storage _set, uint256 _randomActorSeed) internal view returns (address) {
    return _set.rand(_randomActorSeed);
  }

  function _mintStakeToken(address _to, uint256 _amount) internal {
    vm.assume(_to != address(0));
    deal(address(stakeToken), _to, _amount, true);
  }

  function wrapRebasing(address _depositor, uint96 _amount) public countCall("wrapRebasing") {
    vm.assume(_depositor != address(0));
    holders.add(_depositor);

    _amount = uint96(_bound(_amount, 0.1e18, 100_000_000e18));
    _mintStakeToken(_depositor, _amount);

    vm.startPrank(_depositor);
    stakeToken.approve(address(lst), _amount);
    lst.stake(_amount);

    uint256 _previewWrap = wrappedGovLst.previewWrapRebasing(_amount);
    uint256 _fixedBalanceBefore = fixedGovLst.balanceOf(address(wrappedGovLst));
    uint256 _wrappedBalanceBefore = wrappedGovLst.balanceOf(address(_depositor));

    lst.approve(address(wrappedGovLst), _amount);
    wrappedGovLst.wrapRebasing(_amount);
    vm.stopPrank();
    uint256 _fixedBalanceAfter = fixedGovLst.balanceOf(address(wrappedGovLst));
    uint256 _wrappedBalanceAfter = wrappedGovLst.balanceOf(address(_depositor));
    vm.assertLe(_previewWrap, _wrappedBalanceAfter - _wrappedBalanceBefore);

    // We should track underlying fixed tokens
    ghost_fixedWrapped += _fixedBalanceAfter - _fixedBalanceBefore;
  }

  function wrapUnderlying(address _depositor, uint96 _amount) public countCall("wrapUnderlying") {
    vm.assume(_depositor != address(0));
    holders.add(_depositor);

    _amount = uint96(_bound(_amount, 0.1e18, 100_000_000e18));
    _mintStakeToken(_depositor, _amount);

    uint256 _previewWrap = wrappedGovLst.previewWrapUnderlying(_amount);
    vm.startPrank(_depositor);
    uint256 _fixedBalanceBefore = fixedGovLst.balanceOf(address(wrappedGovLst));
    uint256 _wrappedBalanceBefore = wrappedGovLst.balanceOf(address(_depositor));
    stakeToken.approve(address(wrappedGovLst), _amount);
    wrappedGovLst.wrapUnderlying(_amount);
    vm.stopPrank();
    uint256 _fixedBalanceAfter = fixedGovLst.balanceOf(address(wrappedGovLst));
    uint256 _wrappedBalanceAfter = wrappedGovLst.balanceOf(address(_depositor));
    vm.assertLe(_previewWrap, _wrappedBalanceAfter - _wrappedBalanceBefore);

    // We should track underlying fixed tokens
    ghost_fixedWrapped += _fixedBalanceAfter - _fixedBalanceBefore;
  }

  function wrapFixed(address _depositor, uint96 _amount) public countCall("wrapFixed") {
    vm.assume(_depositor != address(0));
    holders.add(_depositor);

    _amount = uint96(_bound(_amount, 0.1e18, 100_000_000e18));
    _mintStakeToken(_depositor, _amount);

    vm.startPrank(_depositor);
    stakeToken.approve(address(fixedGovLst), _amount);
    uint256 _fixedAmount = fixedGovLst.stake(_amount);

    uint256 _fixedBalanceBefore = fixedGovLst.balanceOf(address(wrappedGovLst));
    uint256 _previewWrap = wrappedGovLst.previewWrapFixed(_amount);
    fixedGovLst.approve(address(wrappedGovLst), _fixedAmount);
    wrappedGovLst.wrapFixed(_fixedAmount);
    vm.stopPrank();

    uint256 _fixedBalanceAfter = fixedGovLst.balanceOf(address(wrappedGovLst));
    vm.assertLe(_previewWrap, _fixedBalanceAfter - _fixedBalanceBefore);

    // We should track underlying fixed tokens
    ghost_fixedWrapped += _fixedBalanceAfter - _fixedBalanceBefore;
  }

  function unwrapToRebasing(uint256 _actorSeed, uint256 _wrappedAmount) public countCall("unwrapToRebase") {
    address _holder = _useActor(holders, _actorSeed);
    vm.assume(_holder != address(0));

    uint256 _holderBalance = wrappedGovLst.balanceOf(_holder);
    uint256 _initialHolderRebasingBalance = lst.balanceOf(_holder);
    uint256 _amount = _bound(_wrappedAmount, 0, _holderBalance);
    uint256 _previewUnwrap = wrappedGovLst.previewUnwrapToRebasing(_amount);

    vm.startPrank(_holder);
    wrappedGovLst.unwrapToRebasing(_amount);
    vm.stopPrank();

    uint256 _finalHolderRebasingBalanceA = lst.balanceOf(_holder);
    assertLe(_previewUnwrap, _finalHolderRebasingBalanceA - _initialHolderRebasingBalance);

    ghost_fixedUnwrapped += _amount;
  }

  function unwrapToFixed(uint256 _actorSeed, uint256 _wrappedAmount) public countCall("unwrapToFixed") {
    address _holder = _useActor(holders, _actorSeed);
    vm.assume(_holder != address(0));

    uint256 _holderBalance = wrappedGovLst.balanceOf(_holder);
    uint256 _amount = _bound(_wrappedAmount, 0, _holderBalance);
    uint256 _initialHolderFixedBalance = fixedGovLst.balanceOf(_holder);
    uint256 _previewUnwrap = wrappedGovLst.previewUnwrapToFixed(_amount);

    vm.startPrank(_holder);
    wrappedGovLst.unwrapToFixed(_amount);
    vm.stopPrank();

    uint256 _finalHolderFixedBalance = fixedGovLst.balanceOf(_holder);
    assertLe(_previewUnwrap, _finalHolderFixedBalance - _initialHolderFixedBalance);
    ghost_fixedUnwrapped += _amount;
  }

  function reduceHolders(uint256 acc, function(uint256,address) external returns (uint256) func)
    public
    returns (uint256)
  {
    return holders.reduce(acc, func);
  }
}
