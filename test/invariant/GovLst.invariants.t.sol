// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {GovLst} from "../../src/GovLst.sol";
import {GovLstHandler} from "./GovLst.handler.sol";
import {GovLstHarness} from "../harnesses/GovLstHarness.sol";
import {UnitTestBase} from "../UnitTestBase.sol";
import {MockFullEarningPowerCalculator} from "test/mocks/MockFullEarningPowerCalculator.sol";
import {FakeStaker} from "../fakes/FakeStaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Staker} from "staker/Staker.sol";
import {IERC20Staking} from "staker/interfaces/IERC20Staking.sol";

contract GovStakerInvariants is Test, UnitTestBase {
  GovLstHandler handler;
  MockFullEarningPowerCalculator earningPowerCalculator;
  Staker staker;
  address rewardsNotifier;
  GovLst lst;
  address lstOwner;
  uint80 initialPayoutAmount = 2500e18;
  uint256 maxTip = 1e18; // Higher values cause overflow issues

  // vars for reducers
  Staker.DepositIdentifier public currentId;

  address defaultDelegatee = makeAddr("Default Delegatee");
  address delegateeGuardian = makeAddr("Delegatee Guardian");

  function setUp() public override {
    // begin GovLst.t.sol setup
    super.setUp();

    lstOwner = makeAddr("LST Owner");

    // Staker contracts from bytecode to avoid compiler conflicts.
    earningPowerCalculator = new MockFullEarningPowerCalculator();

    staker = new FakeStaker(
      IERC20(address(rewardToken)),
      IERC20Staking(address(stakeToken)),
      earningPowerCalculator,
      1e18,
      stakerAdmin,
      "Gov staker"
    );

    // We do the 0th deposit because the LST includes an assumption that deposit Id 0 is not held by it.
    vm.startPrank(stakeMinter);
    stakeToken.approve(address(staker), 0);
    staker.stake(0, stakeMinter);
    vm.stopPrank();

    // The staker admin whitelists itself as a reward notifier so we can use it to distribute rewards in tests.
    vm.prank(stakerAdmin);
    staker.setRewardNotifier(stakerAdmin, true);

    // Finally, deploy the lst for tests.
    lst = new GovLstHarness(
      GovLst.ConstructorParams({
        fixedLstName: "Gov Lst",
        fixedLstSymbol: "stGov",
        rebasingLstName: "Rebased Gov Lst",
        rebasingLstSymbol: "rstGov",
        version: "2",
        staker: staker,
        initialDefaultDelegatee: defaultDelegatee,
        initialOwner: lstOwner,
        initialPayoutAmount: initialPayoutAmount,
        initialDelegateeGuardian: delegateeGuardian,
        stakeToBurn: 0,
        maxOverrideTip: maxTip,
        minQualifyingEarningPowerBips: 0
      })
    );

    // Set the withdrawal delay to a non-zero amount
    vm.startPrank(lstOwner);
    lst.WITHDRAW_GATE().setDelay(1 hours);
    vm.stopPrank();

    // end GovLst.t.sol setup

    handler = new GovLstHandler(lst);

    bytes4[] memory selectors = new bytes4[](8);
    selectors[0] = GovLstHandler.stake.selector;
    selectors[1] = GovLstHandler.unstake.selector;
    selectors[2] = GovLstHandler.validTransfer.selector;
    selectors[3] = GovLstHandler.fetchOrInitializeDepositForDelegatee.selector;
    selectors[4] = GovLstHandler.updateDeposit.selector;
    selectors[5] = GovLstHandler.claimAndDistributeReward.selector;
    selectors[6] = GovLstHandler.notifyRewardAmount.selector;
    selectors[7] = GovLstHandler.warpAhead.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

    targetContract(address(handler));
  }

  function _depositIdForHolder(address _holder) internal view returns (Staker.DepositIdentifier) {
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

  /// @notice A holder's delegated `balanceCheckpoint` is always less than or equal to their balance + 2 wei.
  /// @dev It is theoretically possible that the errors could accrue such that the difference is greater than 2 wei,
  /// however we have never observed it in practice. Either we're missing a reason why it's impossible, or it's
  /// unlikely to hit, or our invariants are constructed in such a way to accidentally never hit such a case. We leave
  /// this test in place to see if we will ever stumble upon such a case. The system is designed to be robust to such
  /// cases regardless.
  function invariant_eachHolderBalanceCheckpointLessThanOrEqualToBalance() public {
    handler.forEachHolder(this.assertHolderBalanceCheckpoint);
  }

  /// @notice The `balance` of a given Staker deposit (that is not the default deposit) is always greater than or
  /// equal to the sum of the `balanceCheckpoint`s of all users who chose that as their deposit Id.
  function invariant_eachStakerDepositBalanceGreaterOrEqualToSumOfUserBalanceCheckpoints() public {
    // for each deposit, if the depositor matches the depositId, add the user balance checkpoints
    // we know how to iterate through each deposit id...
    handler.forEachDepositId(
      // ... so this following arg function must look at depositId (which it does), and assert against the sum of user
      // balance checkpoints
      this.assertSumUserBalanceCheckpointsForDepositId
    );
  }

  /// @notice The Staker balance of the default deposit is always greater than or equal to the sum of the following
  /// two summations:
  /// - The sum of the `balanceOf`s of all holders who have set/left the default deposit
  /// - The sum of the undelegated balances of all holders who have set a custom delegate, where undelegated balance is
  /// defined as the `balanceOf` the holder minus the `balanceCheckpoint` of the holder
  function invariant_defaultDepositBalanceGreaterOrEqualToBalanceOfHoldersWithDefaultDepositPlusCustomDelegateUndelegatedBalance(
  ) public {
    // This is a hacky solution. We know it is possible for slight shortfalls to accrue, and we're ok with this as long
    // as they are always accruing to the default deposit. However, it's also important that we not miss a flagrant
    // error that causes dramatic shortfalls, as opposed to tiny shortfalls accruing due to truncation. The problem
    // with defining the assertion as "within some acceptable range" is that if the depth of the invariant tests are
    // increased, one would expect the "invariant" here to eventually be broken. For now, we leave this somewhat hacky
    // "invariant" in place to make sure we're avoiding an actual, unexpected bug.
    uint256 ACCEPTABLE_DEFAULT_DEPOSIT_SHORTFALL = 1000; // 1x10^-15 GOV

    // first, get the balance of the default deposit -- very easy!
    Staker.DepositIdentifier defaultDepositId = lst.depositForDelegatee(defaultDelegatee);
    (uint256 _defaultDepositBalance,,,,,,) = staker.deposits(defaultDepositId);

    // The following assignments use accumulators that read the depositId from the public state var `currentId`, so we
    // set the `currentId` to the default deposit id.
    currentId = defaultDepositId;
    uint256 _sumBalanceOfHoldersWithDefaultDeposit = handler.reduceHolders(0, this.accumulateBalanceForCurrentDepositId);

    uint256 _sumUndelegatedBalancesWithCustomDelegatee =
      handler.reduceDepositIds(0, this.sumUndelegatedBalanceForDepositId);

    assertGe(
      _defaultDepositBalance + ACCEPTABLE_DEFAULT_DEPOSIT_SHORTFALL,
      _sumBalanceOfHoldersWithDefaultDeposit + _sumUndelegatedBalancesWithCustomDelegatee
    );
  }

  /// @notice The LST contract never holds a stake token balance (assuming none are never transferred directly to it.
  /// @dev Note: adding this invariant ensures we haven't built a system that leaves spare wei sitting in the contract
  /// when doing `withdraw` and `stakeMore` calls to Staker.
  function invariant_lstBalanceNeverHoldsStakeTokenBalance() public view {
    assertEq(stakeToken.balanceOf(address(lst)), 0);
  }

  /// @notice When staking the user's balance should increase by less than or equal to the amount stake was called with.
  function invariant_stakeShouldNotIncreaseBalanceMoreThanStakeAmount() public view {
    assertFalse(handler.balanceInvariantBroken());
  }

  /// @notice When transferring, the sum of the balance changes across the sender & receiver should be less than or
  /// equal to 0 (i.e. the sender's balance should decrease by an amount greater than or equal to the receiver's balance
  /// increase).
  function invariant_transferShouldNotCauseANetBalanceDifferentialOfMoreThanOneWei() public view {
    assertFalse(handler.transferInvariantBroken());
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
    if (Staker.DepositIdentifier.unwrap(_depositIdForHolder(_holder)) == Staker.DepositIdentifier.unwrap(currentId)) {
      return _balance + lst.balanceOf(_holder);
    }
    return _balance;
  }

  function accumulateBalanceCheckpointsForCurrentDepositId(uint256 _balance, address _holder)
    external
    view
    returns (uint256)
  {
    if (Staker.DepositIdentifier.unwrap(_depositIdForHolder(_holder)) == Staker.DepositIdentifier.unwrap(currentId)) {
      return _balance + lst.balanceCheckpoint(_holder);
    }
    return _balance;
  }

  function accumulateUndelegatedBalanceForCurrentDepositId(uint256 _balance, address _holder)
    external
    view
    returns (uint256)
  {
    uint256 _currentId = Staker.DepositIdentifier.unwrap(currentId);
    if (
      Staker.DepositIdentifier.unwrap(_depositIdForHolder(_holder)) == _currentId
        && _currentId != Staker.DepositIdentifier.unwrap(lst.DEFAULT_DEPOSIT_ID())
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

  function sumUserBalancesForDepositId(uint256 _sum, Staker.DepositIdentifier id) external returns (uint256) {
    currentId = id;
    return _sum + handler.reduceHolders(0, this.accumulateBalanceForCurrentDepositId);
  }

  function sumUserBalanceCheckpointsForDepositId(uint256 _sum, Staker.DepositIdentifier id) external returns (uint256) {
    currentId = id;
    return _sum + handler.reduceHolders(0, this.accumulateBalanceCheckpointsForCurrentDepositId);
  }

  function sumUndelegatedBalanceForDepositId(uint256 _sum, Staker.DepositIdentifier id) external returns (uint256) {
    currentId = id;
    return _sum + handler.reduceHolders(0, this.accumulateUndelegatedBalanceForCurrentDepositId);
  }

  function assertSumUserBalanceCheckpointsForDepositId(Staker.DepositIdentifier id) external {
    // Ignore the default deposit, for which this assertion is not assumed to hold
    uint256 _defaultDepositId = Staker.DepositIdentifier.unwrap(handler.lst().DEFAULT_DEPOSIT_ID());
    if (Staker.DepositIdentifier.unwrap(id) == _defaultDepositId) {
      return;
    }
    // we only want holders that match the depositId
    currentId = id;
    // console2.log("Checking depositId: %s", Staker.DepositIdentifier.unwrap(id));
    uint256 _sumOfCheckpoints = handler.reduceHolders(0, this.accumulateBalanceCheckpointsForCurrentDepositId);
    (uint256 _stakerDepositBalance,,,,,,) = staker.deposits(id);
    assertGe(_stakerDepositBalance, _sumOfCheckpoints);
    // console2.log("staker deposit balance", _stakerDepositBalance, "sum of checkpoints", _sumOfCheckpoints);
  }

  function assertHolderBalanceCheckpoint(address holder) external view {
    assertLe(lst.balanceCheckpoint(holder), lst.balanceOf(holder) + 2);
  }
}
