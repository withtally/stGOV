// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {UniLst} from "src/UniLst.sol";
import {UniLstHandler} from "./UniLst.handler.sol";
import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {MockWithdrawalGate} from "test/mocks/MockWithdrawalGate.sol";
import {UnitTestBase} from "test/UnitTestBase.sol";

contract UniStakerInvariants is Test, UnitTestBase {
  UniLstHandler handler;
  IUniStaker staker;
  address rewardsNotifier;
  UniLst lst;
  address lstOwner;
  MockWithdrawalGate mockWithdrawalGate;
  uint256 initialPayoutAmount = 2500e18;

  address defaultDelegatee = makeAddr("Default Delegatee");

  function setUp() public override {
    // begin UniLst.t.sol setup
    super.setUp();

    lstOwner = makeAddr("LST Owner");

    // UniStaker contracts from bytecode to avoid compiler conflicts.
    staker = IUniStaker(deployCode("UniStaker.sol", abi.encode(rewardToken, stakeToken, stakerAdmin)));

    // We do the 0th deposit because the LST includes an assumption that deposit Id 0 is not held by it.
    vm.startPrank(stakeMinter);
    stakeToken.approve(address(staker), 0);
    staker.stake(0, stakeMinter);
    vm.stopPrank();

    // The staker admin whitelists itself as a reward notifier so we can use it to distribute rewards in tests.
    vm.prank(stakerAdmin);
    staker.setRewardNotifier(stakerAdmin, true);

    // Finally, deploy the lst for tests.
    lst = new UniLst(staker, defaultDelegatee, lstOwner, initialPayoutAmount);

    // Deploy and set the mock withdrawal gate.
    mockWithdrawalGate = new MockWithdrawalGate();
    vm.prank(lstOwner);
    lst.setWithdrawalGate(address(mockWithdrawalGate));

    // end UniLst.t.sol setup

    handler = new UniLstHandler(lst);

    bytes4[] memory selectors = new bytes4[](5);
    selectors[0] = UniLstHandler.stake.selector;
    selectors[1] = UniLstHandler.unstake.selector;
    selectors[2] = UniLstHandler.warpAhead.selector;
    selectors[3] = UniLstHandler.claimAndDistributeReward.selector;
    selectors[4] = UniLstHandler.notifyRewardAmount.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

    targetContract(address(handler));
  }

  // Invariants

  /// @notice  The totalSupply is always greater than or equal to the sum of all holder `balanceOf`s
  function invariant_sumOfBalancesLessThanOrEqualToTotalSupply() public {
    uint256 _totalSupply = lst.totalSupply();
    uint256 _sumOfBalances = handler.reduceHolders(0, this.accumulateBalance);
    assertLe(_sumOfBalances, _totalSupply);
  }

  /// @notice The `totalSupply` is always exactly equal to the total staked plus the total distributed as rewards minus
  /// the total unstaked (as measured by what is actually withdrawn when unstake is called)
  function invariant_totalSupplyEqualToTotalStakedPlusTotalRewardsMinusUnstaked() public view {
    uint256 _totalSupply = lst.totalSupply();
    uint256 _totalStaked = handler.ghost_stakeStaked();
    uint256 _totalRewardsDistributed = handler.ghost_rewardsClaimedAndDistributed();
    uint256 _totalUnstaked = handler.ghost_stakeUnstaked();

    assertEq(_totalSupply, _totalStaked + _totalRewardsDistributed - _totalUnstaked);
  }

  /// @notice A holder's delegated `balanceCheckpoint` is always less than or equal to their balance + 1 wei.
  /// @dev It seems theoretically possible that the errors could accrue such that the difference is greater than 1 wei,
  /// however we have never observed it in practice. Either we're missing a reason why it's impossible, or it's
  /// unlikely to hit, or our invariants are constructed in such a way to accidentally never hit such a case. We leave
  /// this test in place to see if we will ever stumble upon such a case. The system is designed to be robust to such
  /// case regardless.
  function invariant_holderBalanceCheckpointLessThanOrEqualToBalance() public {
    handler.forEachHolder(this.assertHolderBalanceCheckpoint);
  }

  // Used to see distribution of non-reverting calls
  function invariant_callSummary() public view {
    handler.callSummary();
  }

  // Helpers

  function accumulateBalance(uint256 balance, address holder) external view returns (uint256) {
    return balance + lst.balanceOf(holder);
  }

  function assertHolderBalanceCheckpoint(address holder) external view {
    assertLe(lst.balanceCheckpoint(holder), lst.balanceOf(holder) + 1);
  }
}
