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

  // vars for reducers
  IUniStaker.DepositIdentifier public currentId;

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
    lst = new UniLst("Uni Lst", "stUni", staker, defaultDelegatee, lstOwner, initialPayoutAmount);

    // Deploy and set the mock withdrawal gate.
    mockWithdrawalGate = new MockWithdrawalGate();
    vm.prank(lstOwner);
    lst.setWithdrawalGate(address(mockWithdrawalGate));

    // end UniLst.t.sol setup

    handler = new UniLstHandler(lst);

    bytes4[] memory selectors = new bytes4[](7);
    selectors[0] = UniLstHandler.stake.selector;
    selectors[1] = UniLstHandler.unstake.selector;
    selectors[2] = UniLstHandler.fetchOrInitializeDepositForDelegatee.selector;
    selectors[3] = UniLstHandler.updateDeposit.selector;
    selectors[4] = UniLstHandler.claimAndDistributeReward.selector;
    selectors[5] = UniLstHandler.notifyRewardAmount.selector;
    selectors[6] = UniLstHandler.warpAhead.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

    targetContract(address(handler));
  }

  function _depositIdForHolder(address _holder) internal view returns (IUniStaker.DepositIdentifier) {
    return lst.depositForDelegatee(lst.delegateeForHolder(_holder));
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
  function invariant_eachHolderBalanceCheckpointLessThanOrEqualToBalance() public {
    handler.forEachHolder(this.assertHolderBalanceCheckpoint);
  }

  /// @notice The `balance` of a given UniStaker deposit (that is not the default deposit) is always greater than or
  /// equal
  /// to the sum of the `balanceCheckpoint`s of all users who chose that as their deposit Id.
  function invariant_eachStakerDepositBalanceGreaterOrEqualToSumOfUserBalanceCheckpoints() public {
    // for each deposit, if the depositor matches the depositId, add the user balance checkpoints
    // we know how to iterate through each deposit id...
    handler.forEachDepositId(
      // ... so this following arg function must look at depositId (which it does), and assert against the sum of user
      // balance checkpoints
      this.assertSumUserBalanceCheckpointsForDepositId
    );
  }

  /// @notice The UniStaker balance of the default deposit is always greater than or equal to the sum of the following
  /// two summations:
  /// - The sum of the `balanceOf`s of all holders who have set/left the default deposit
  /// - The sum of the undelegated balances of all holders who have set a custom delegate, where undelegated balance is
  /// defined as the `balanceOf` the holder minus the `balanceCheckpoint` of the holder
  function invariant_defaultDepositBalanceGreaterOrEqualToBalanceOfHoldersWithDefaultDepositPlusCustomDelegateUndelegatedBalance(
  ) public {
    // first, get the balance of the default deposit -- very easy!
    IUniStaker.DepositIdentifier defaultDepositId = lst.depositForDelegatee(defaultDelegatee);
    (uint256 _defaultDepositBalance,,,) = staker.deposits(defaultDepositId);

    // The following assignments use accumulators that read the depositId from the public state var `currentId`, so we
    // set the `currentId` to the default deposit id.
    currentId = defaultDepositId;
    uint256 _sumBalanceOfHoldersWithDefaultDeposit = handler.reduceHolders(0, this.accumulateBalanceForCurrentDepositId);

    uint256 _sumUndelegatedBalancesWithCustomDelegatee =
      handler.reduceDepositIds(0, this.sumUndelegatedBalanceForDepositId);

    assertGe(
      _defaultDepositBalance, _sumBalanceOfHoldersWithDefaultDeposit + _sumUndelegatedBalancesWithCustomDelegatee
    );
  }

  /// @notice The LST contract never holds a stake token balance (assuming none are never transferred directly to it).
  /// @dev Note: adding this invariant ensures we haven't built a system that leaves spare wei sitting in the contract
  /// when doing `withdraw` and `stakeMore` calls to UniStaker.
  function invariant_lstBalanceNeverHoldsStakeTokenBalance() public view {
    assertEq(stakeToken.balanceOf(address(lst)), 0);
  }

  // Used to see distribution of non-reverting calls
  function invariant_callSummary() public view {
    handler.callSummary();
  }

  // Helpers
  function accumulateBalance(uint256 _balance, address _holder) external view returns (uint256) {
    return _balance + lst.balanceOf(_holder);
  }

  function accumulateBalanceForCurrentDepositId(uint256 _balance, address _holder) external view returns (uint256) {
    if (
      IUniStaker.DepositIdentifier.unwrap(_depositIdForHolder(_holder))
        == IUniStaker.DepositIdentifier.unwrap(currentId)
    ) {
      return _balance + lst.balanceOf(_holder);
    }
    return _balance;
  }

  function accumulateBalanceCheckpointsForCurrentDepositId(uint256 _balance, address _holder)
    external
    view
    returns (uint256)
  {
    if (
      IUniStaker.DepositIdentifier.unwrap(_depositIdForHolder(_holder))
        == IUniStaker.DepositIdentifier.unwrap(currentId)
    ) {
      return _balance + lst.balanceCheckpoint(_holder);
    }
    return _balance;
  }

  function accumulateUndelegatedBalanceForCurrentDepositId(uint256 _balance, address _holder)
    external
    view
    returns (uint256)
  {
    uint256 _currentId = IUniStaker.DepositIdentifier.unwrap(currentId);
    if (
      IUniStaker.DepositIdentifier.unwrap(_depositIdForHolder(_holder)) == _currentId
        && _currentId != IUniStaker.DepositIdentifier.unwrap(lst.DEFAULT_DEPOSIT_ID())
    ) {
      uint256 _undelegatedBalance;
      if (lst.balanceOf(_holder) >= lst.balanceCheckpoint(_holder)) {
        _undelegatedBalance = lst.balanceOf(_holder) - lst.balanceCheckpoint(_holder);
      } else {
        _undelegatedBalance = 0;
      }
      return _balance + _undelegatedBalance;
    }
    return _balance;
  }

  function sumUserBalancesForDepositId(uint256 _sum, IUniStaker.DepositIdentifier id) external returns (uint256) {
    currentId = id;
    return _sum + handler.reduceHolders(0, this.accumulateBalanceForCurrentDepositId);
  }

  function sumUserBalanceCheckpointsForDepositId(uint256 _sum, IUniStaker.DepositIdentifier id)
    external
    returns (uint256)
  {
    currentId = id;
    return _sum + handler.reduceHolders(0, this.accumulateBalanceCheckpointsForCurrentDepositId);
  }

  function sumUndelegatedBalanceForDepositId(uint256 _sum, IUniStaker.DepositIdentifier id) external returns (uint256) {
    currentId = id;
    return _sum + handler.reduceHolders(0, this.accumulateUndelegatedBalanceForCurrentDepositId);
  }

  function assertSumUserBalanceCheckpointsForDepositId(IUniStaker.DepositIdentifier id) external {
    // we only want holders that match the depositId
    currentId = id;
    // console2.log("Checking depositId: %s", IUniStaker.DepositIdentifier.unwrap(id));
    uint256 _sumOfCheckpoints = handler.reduceHolders(0, this.accumulateBalanceCheckpointsForCurrentDepositId);
    (uint256 _stakerDepositBalance,,,) = staker.deposits(id);
    assertGe(_stakerDepositBalance, _sumOfCheckpoints);
    // console2.log("staker deposit balance", _stakerDepositBalance, "sum of checkpoints", _sumOfCheckpoints);
  }

  function assertHolderBalanceCheckpoint(address holder) external view {
    assertLe(lst.balanceCheckpoint(holder), lst.balanceOf(holder) + 1);
  }
}
