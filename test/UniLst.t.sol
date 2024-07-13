// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {UniLst, Ownable} from "src/UniLst.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {IUni} from "src/interfaces/IUni.sol";
import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {IWithdrawalGate} from "src/interfaces/IWithdrawalGate.sol";
import {UnitTestBase} from "test/UnitTestBase.sol";
import {TestHelpers} from "test/helpers/TestHelpers.sol";
import {PercentAssertions} from "test/helpers/PercentAssertions.sol";

contract UniLstTest is UnitTestBase, PercentAssertions, TestHelpers {
  IUniStaker staker;
  UniLst lst;
  address lstOwner;

  address defaultDelegatee = makeAddr("Default Delegatee");

  function setUp() public virtual override {
    super.setUp();
    lstOwner = makeAddr("LST Owner");

    // UniStaker contracts from bytecode to avoid compiler conflicts.
    staker = IUniStaker(deployCode("UniStaker.sol", abi.encode(rewardToken, stakeToken, stakerAdmin)));

    // We do the 0th deposit because the LST includes an assumption that deposit Id 0 is not held by it.
    vm.startPrank(stakeMinter);
    stakeToken.approve(address(staker), 1e18);
    staker.stake(1e18, stakeMinter);
    vm.stopPrank();

    // Finally, deploy the lst for tests
    lst = new UniLst(staker, defaultDelegatee, lstOwner);
  }

  function __dumpGlobalState() public view {
    console2.log("");
    console2.log("GLOBAL");
    console2.log("totalSupply");
    console2.log(lst.totalSupply());
    console2.log("totalShares");
    console2.log(lst.totalShares());
  }

  function __dumpHolderState(address _holder) public view {
    console2.log("");
    console2.log("HOLDER: ", _holder);
    console2.log("delegateeForHolder", lst.delegateeForHolder(_holder));
    console2.log("sharesOf");
    console2.log(lst.sharesOf(_holder));
    console2.log("balanceCheckpoint");
    console2.log(lst.balanceCheckpoint(_holder));
    console2.log("balanceOf");
    console2.log(lst.balanceOf(_holder));
    console2.log("getCurrentVotes(delegatee)");
    console2.log(stakeToken.getCurrentVotes(lst.delegateeForHolder(_holder)));
  }

  function _assumeSafeHolder(address _holder) internal view {
    // It's not safe to `deal` to an address that has already assigned a delegate, because deal overwrites the
    // balance directly without checkpointing vote weight, so subsequent transactions will cause the moving of
    // delegation weight to underflow.
    vm.assume(_holder != address(0) && _holder != stakeMinter && stakeToken.delegates(_holder) == address(0));
  }

  function _assumeSafeHolders(address _holder1, address _holder2) internal view {
    _assumeSafeHolder(_holder1);
    _assumeSafeHolder(_holder2);
    vm.assume(_holder1 != _holder2);
  }

  function _assumeSafeDelegatee(address _delegatee) internal view {
    vm.assume(_delegatee != address(0) && _delegatee != defaultDelegatee && _delegatee != stakeMinter);
  }

  function _assumeSafeDelegatees(address _delegatee1, address _delegatee2) internal view {
    _assumeSafeDelegatee(_delegatee1);
    _assumeSafeDelegatee(_delegatee2);
    vm.assume(_delegatee1 != _delegatee2);
  }

  function _boundToReasonableStakeTokenAmount(uint256 _amount) internal pure returns (uint256 _boundedAmount) {
    // Bound to within 1/10,000th of a UNI and 4 times the current total supply of UNI
    _boundedAmount = uint256(bound(_amount, 0.0001e18, 2_000_000_000e18));
  }

  function _mintStakeToken(address _to, uint256 _amount) internal {
    deal(address(stakeToken), _to, _amount);
  }

  function _updateDelegatee(address _holder, address _delegatee) internal {
    vm.prank(_holder);
    lst.updateDelegatee(_delegatee);
  }

  function _stake(address _holder, uint256 _amount) internal {
    vm.startPrank(_holder);
    stakeToken.approve(address(lst), _amount);
    lst.stake(_amount);
    vm.stopPrank();
  }

  function _mintAndStake(address _holder, uint256 _amount) internal {
    _mintStakeToken(_holder, _amount);
    _stake(_holder, _amount);
  }

  function _updateDelegateeAndStake(address _holder, uint256 _amount, address _delegatee) internal {
    _updateDelegatee(_holder, _delegatee);
    _stake(_holder, _amount);
  }

  function _mintUpdateDelegateeAndStake(address _holder, uint256 _amount, address _delegatee) internal {
    _mintStakeToken(_holder, _amount);
    _updateDelegateeAndStake(_holder, _amount, _delegatee);
  }

  function _distributeReward(uint256 _amount) internal {
    address _distributor = makeAddr("Distributor");
    _mintStakeToken(_distributor, _amount);

    vm.startPrank(_distributor);
    stakeToken.approve(address(lst), _amount);
    lst.temp_distributeRewards(_amount);
    vm.stopPrank();
  }
}

contract Constructor is UniLstTest {
  function test_SetsConfigurationParameters() public view {
    assertEq(address(lst.STAKER()), address(staker));
    assertEq(address(lst.STAKE_TOKEN()), address(stakeToken));
    assertEq(address(lst.REWARD_TOKEN()), address(rewardToken));
    assertEq(lst.defaultDelegatee(), defaultDelegatee);
    assertEq(lst.owner(), lstOwner);
  }

  function test_MaxApprovesTheStakerContractToTransferStakeToken() public view {
    assertEq(stakeToken.allowance(address(lst), address(staker)), type(uint96).max);
  }

  function test_CreatesDepositForTheDefaultDelegatee() public view {
    assertTrue(IUniStaker.DepositIdentifier.unwrap(lst.depositForDelegatee(defaultDelegatee)) != 0);
  }

  function testFuzz_DeploysTheContractWithArbitraryValuesForParameters(
    address _staker,
    address _stakeToken,
    address _rewardToken,
    address _defaultDelegatee,
    address _lstOwner
  ) public {
    _assumeSafeMockAddress(_staker);
    _assumeSafeMockAddress(_stakeToken);
    vm.assume(_lstOwner != address(0));
    vm.mockCall(_staker, abi.encodeWithSelector(IUniStaker.STAKE_TOKEN.selector), abi.encode(_stakeToken));
    vm.mockCall(_staker, abi.encodeWithSelector(IUniStaker.REWARD_TOKEN.selector), abi.encode(_rewardToken));
    vm.mockCall(_stakeToken, abi.encodeWithSelector(IUni.approve.selector), abi.encode(true));
    // Because there are 2 functions named "stake" on UniStaker, `IUnistaker.stake.selector` does not resolve
    // so we precalculate the 2 arrity selector instead in order to mock it.
    bytes4 _stakeWithArrity2Selector = hex"98f2b576";
    vm.mockCall(_staker, abi.encodeWithSelector(_stakeWithArrity2Selector), abi.encode(1));

    UniLst _lst = new UniLst(IUniStaker(_staker), _defaultDelegatee, _lstOwner);
    assertEq(address(_lst.STAKER()), _staker);
    assertEq(address(_lst.STAKE_TOKEN()), _stakeToken);
    assertEq(address(_lst.REWARD_TOKEN()), _rewardToken);
    assertEq(_lst.defaultDelegatee(), _defaultDelegatee);
    assertEq(IUniStaker.DepositIdentifier.unwrap(_lst.depositForDelegatee(_defaultDelegatee)), 1);
    assertEq(_lst.owner(), _lstOwner);
  }

  function testFuzz_RevertIf_MaxApprovalOfTheStakerContractOnTheStakeTokenFails(
    address _staker,
    address _stakeToken,
    address _rewardToken,
    address _defaultDelegatee,
    address _lstOwner
  ) public {
    _assumeSafeMockAddress(_staker);
    _assumeSafeMockAddress(_stakeToken);
    vm.assume(_lstOwner != address(0));
    vm.mockCall(_staker, abi.encodeWithSelector(IUniStaker.STAKE_TOKEN.selector), abi.encode(_stakeToken));
    vm.mockCall(_staker, abi.encodeWithSelector(IUniStaker.REWARD_TOKEN.selector), abi.encode(_rewardToken));
    vm.mockCall(_stakeToken, abi.encodeWithSelector(IUni.approve.selector), abi.encode(false));

    vm.expectRevert(UniLst.UniLst__StakeTokenOperationFailed.selector);
    new UniLst(IUniStaker(_staker), _defaultDelegatee, _lstOwner);
  }
}

contract DelegateeForHolder is UniLstTest {
  function testFuzz_ReturnsTheDefaultDelegateeBeforeADelegateeIsSet(address _holder) public view {
    _assumeSafeHolder(_holder);
    assertEq(lst.delegateeForHolder(_holder), defaultDelegatee);
  }

  function testFuzz_ReturnsTheValueSetViaUpdateDelegatee(address _holder, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _updateDelegatee(_holder, _delegatee);
    assertEq(lst.delegateeForHolder(_holder), _delegatee);
  }

  function testFuzz_ReturnsTheDefaultDelegateeIfTheDelegateeIsSetBackToTheZeroAddress(
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _updateDelegatee(_holder, _delegatee);
    _updateDelegatee(_holder, address(0));
    assertEq(lst.delegateeForHolder(_holder), defaultDelegatee);
  }
}

contract UpdateDelegatee is UniLstTest {
  function testFuzz_RecordsTheDelegateeWhenCalledByAHolderForTheFirstTime(address _holder, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);

    _updateDelegatee(_holder, _delegatee);

    assertEq(lst.delegateeForHolder(_holder), _delegatee);
  }

  function testFuzz_UpdatesTheDelegateeWhenCalledByAHolderASecondTime(
    address _holder,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee1);
    _assumeSafeDelegatee(_delegatee2);

    _updateDelegatee(_holder, _delegatee1);
    _updateDelegatee(_holder, _delegatee2);

    assertEq(lst.delegateeForHolder(_holder), _delegatee2);
  }

  function testFuzz_CreatesANewDepositForASingleNewLstDelegatee(address _holder, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);

    _updateDelegatee(_holder, _delegatee);

    assertTrue(IUniStaker.DepositIdentifier.unwrap(lst.depositForDelegatee(_delegatee)) != 0);
  }

  function testFuzz_MovesVotingWeightForAHolderWhoHasNotAccruedAnyRewards(
    uint256 _amount,
    address _holder,
    address _initialDelegatee,
    address _newDelegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_initialDelegatee);
    _assumeSafeDelegatee(_newDelegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintUpdateDelegateeAndStake(_holder, _amount, _initialDelegatee);
    _updateDelegatee(_holder, _newDelegatee);

    assertEq(stakeToken.getCurrentVotes(_newDelegatee), _amount);
  }

  function testFuzz_MovesAllVotingWeightForAHolderWhoHasAccruedRewards(
    uint256 _stakeAmount,
    address _holder,
    address _initialDelegatee,
    address _newDelegatee,
    uint256 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_initialDelegatee);
    _assumeSafeDelegatee(_newDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _initialDelegatee);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _distributeReward(_rewardAmount);

    // Interim assertions after setup phase:
    // The amount staked by the user goes to their designated delegatee
    assertEq(stakeToken.getCurrentVotes(_initialDelegatee), _stakeAmount);
    // The amount earned in rewards has been delegated to the default delegatee
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), _rewardAmount);

    _updateDelegatee(_holder, _newDelegatee);

    // After update:
    // New delegatee has both the stake voting weight and the rewards accumulated
    assertEq(stakeToken.getCurrentVotes(_newDelegatee), _stakeAmount + _rewardAmount);
    // Defualt delegatee has had reward voting weight removed
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), 0);
    assertEq(lst.balanceOf(_holder), _stakeAmount + _rewardAmount);
  }

  function testFuzz_MovesOnlyTheVotingWeightOfTheCallerWhenTwoUsersStake(
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    address _holder1,
    address _holder2,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    _stakeAmount2 = _boundToReasonableStakeTokenAmount(_stakeAmount2);

    // Two holders stake to the same delegatee
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee1);
    // One holder updates their delegatee
    _updateDelegatee(_holder1, _delegatee2);

    assertEq(stakeToken.getCurrentVotes(_delegatee1), _stakeAmount2);
    assertEq(stakeToken.getCurrentVotes(_delegatee2), _stakeAmount1);
  }

  function testFuzz_MovesOnlyTheVotingWeightOfTheCallerWhenTwoUsersStakeAfterARewardHasBeenDistributed(
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    address _holder1,
    address _holder2,
    uint256 _rewardAmount,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    _stakeAmount2 = _boundToReasonableStakeTokenAmount(_stakeAmount2);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);

    // Two users stake to the same delegatee
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee1);
    // A reward is distributed
    _distributeReward(_rewardAmount);
    // One holder updates their delegatee
    _updateDelegatee(_holder1, _delegatee2);

    // The new delegatee should have voting weight equal to the balance of the holder that updated
    assertEq(stakeToken.getCurrentVotes(_delegatee2), lst.balanceOf(_holder1));
    // The original delegatee should have voting weight equal to the balance of the other holder's staked amount
    assertEq(stakeToken.getCurrentVotes(_delegatee1), _stakeAmount2);
    // The default delegatee should have voting weight equal to the rewards distributed to the other holder
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), _stakeAmount1 + _rewardAmount - lst.balanceOf(_holder1));
  }
}

contract Stake is UniLstTest {
  function testFuzz_RecordsTheDepositIdAssociatedWithTheDelegatee(uint256 _amount, address _holder, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintStakeToken(_holder, _amount);

    _updateDelegateeAndStake(_holder, _amount, _delegatee);

    assertTrue(IUniStaker.DepositIdentifier.unwrap(lst.depositForDelegatee(_delegatee)) != 0);
  }

  function testFuzz_AddsEachStakedAmountToTheTotalSupply(
    uint256 _amount1,
    address _holder1,
    uint256 _amount2,
    address _holder2,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    _amount1 = _boundToReasonableStakeTokenAmount(_amount1);
    _amount2 = _boundToReasonableStakeTokenAmount(_amount2);

    _mintUpdateDelegateeAndStake(_holder1, _amount1, _delegatee1);
    assertEq(lst.totalSupply(), _amount1);

    _mintUpdateDelegateeAndStake(_holder2, _amount2, _delegatee2);
    assertEq(lst.totalSupply(), _amount1 + _amount2);
  }

  function testFuzz_IncreasesANewHoldersBalanceByTheAmountStaked(uint256 _amount, address _holder, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);

    assertEq(lst.balanceOf(_holder), _amount);
  }

  function testFuzz_DelegatesToTheDefaultDelegateeIfTheHolderHasNotSetADelegate(uint256 _amount, address _holder)
    public
  {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_holder, _amount);

    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), _amount);
  }

  function testFuzz_DelegatesToTheDelegateeTheHolderHasPreviouslySet(
    uint256 _amount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);

    assertEq(stakeToken.getCurrentVotes(_delegatee), _amount);
  }

  function testFuzz_RecordsTheBalanceCheckpointForFirstTimeStaker(uint256 _amount, address _holder, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);

    assertEq(lst.balanceCheckpoint(_holder), _amount);
  }

  function testFuzz_IncrementsTheBalanceCheckPointForAHolderAddingToTheirStake(
    uint256 _amount1,
    uint256 _amount2,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount1 = _boundToReasonableStakeTokenAmount(_amount1);
    _amount2 = _boundToReasonableStakeTokenAmount(_amount2);

    _mintUpdateDelegateeAndStake(_holder, _amount1, _delegatee);
    _mintAndStake(_holder, _amount2);

    assertEq(lst.balanceCheckpoint(_holder), _amount1 + _amount2);
  }

  function testFuzz_IncrementsTheBalanceCheckpointForAHolderAddingToTheirStakeWhoHasPreviouslyEarnedAReward(
    uint256 _amount1,
    uint256 _amount2,
    uint256 _rewardAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount1 = _boundToReasonableStakeTokenAmount(_amount1);
    _amount2 = _boundToReasonableStakeTokenAmount(_amount2);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _amount1, _delegatee);
    _distributeReward(_rewardAmount);
    _mintAndStake(_holder, _amount2);

    assertEq(lst.balanceCheckpoint(_holder), _amount1 + _amount2);
  }

  function testFuzz_RevertIf_TheTransferFromTheStakeTokenFails(uint256 _amount, address _holder, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    vm.startPrank(_holder);
    lst.updateDelegatee(_delegatee);
    stakeToken.approve(address(lst), _amount);
    vm.mockCall(address(stakeToken), abi.encodeWithSelector(IUni.transferFrom.selector), abi.encode(false));
    vm.expectRevert(UniLst.UniLst__StakeTokenOperationFailed.selector);
    lst.stake(_amount);
    vm.stopPrank();
  }
}

contract BalanceOf is UniLstTest {
  function testFuzz_CalculatesTheCorrectBalanceWhenASingleHolderMakesASingleDeposit(
    uint256 _amount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);

    assertEq(lst.balanceOf(_holder), _amount);
  }

  function testFuzz_CalculatesTheCorrectBalanceWhenASingleHolderMakesTwoDeposits(
    uint256 _amount1,
    uint256 _amount2,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount1 = _boundToReasonableStakeTokenAmount(_amount1);
    _amount2 = _boundToReasonableStakeTokenAmount(_amount2);

    _mintUpdateDelegateeAndStake(_holder, _amount1, _delegatee);
    assertEq(lst.balanceOf(_holder), _amount1);

    _mintUpdateDelegateeAndStake(_holder, _amount2, _delegatee);
    assertEq(lst.balanceOf(_holder), _amount1 + _amount2);
  }

  function testFuzz_CalculatesTheCorrectBalanceWhenASingleHolderMadeASingleDepositAndARewardIsDistributed(
    uint256 _stakeAmount,
    address _holder,
    address _delegatee,
    uint256 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _distributeReward(_rewardAmount);

    // Since there is only one LST holder, they should own the whole balance of the LST, both the tokens they staked
    // and the tokens distributed as rewards.
    assertEq(lst.balanceOf(_holder), _stakeAmount + _rewardAmount);
  }

  function testFuzz_CalculatesTheCorrectBalanceWhenTwoUsersStakeBeforeARewardIsDistributed(
    uint256 _stakeAmount1,
    address _holder1,
    address _holder2,
    uint256 _rewardAmount,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    // The second user will stake 150% of the first user
    uint256 _stakeAmount2 = _percentOf(_stakeAmount1, 150);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);

    // Both users stake
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee2);
    // A reward is distributed
    _distributeReward(_rewardAmount);

    // Because the first user staked 40% of the UNI, they should have earned 40% of rewards
    assertWithinOneBip(lst.balanceOf(_holder1), _stakeAmount1 + _percentOf(_rewardAmount, 40));
    // Because the second user staked 60% of the UNI, they should have earned 60% of rewards
    assertWithinOneBip(lst.balanceOf(_holder2), _stakeAmount2 + _percentOf(_rewardAmount, 60));
    // Invariant: Sum of balanceOf should always be less than or equal to total stake + rewards
    assertLteWithinOneBip(
      lst.balanceOf(_holder1) + lst.balanceOf(_holder2), _stakeAmount1 + _stakeAmount2 + _rewardAmount
    );
  }

  function testFuzz_CalculatesTheCorrectBalanceWhenASecondUserStakesAfterARewardIsDistributed(
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    address _holder1,
    address _holder2,
    uint256 _rewardAmount,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);

    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    _stakeAmount2 = _boundToReasonableStakeTokenAmount(_stakeAmount2);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);

    // The first user stakes
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    // A reward is distributed
    _distributeReward(_rewardAmount);
    // The second user stakes
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee2);

    // The first user was the only staker before the reward, so their balance should be their stake + the full reward
    assertWithinOneBip(lst.balanceOf(_holder1), _stakeAmount1 + _rewardAmount);
    // The second user staked after the only reward, so their balance should equal their stake
    assertWithinOneBip(lst.balanceOf(_holder2), _stakeAmount2);
    // Invariant: Sum of balanceOf should always be less than or equal to total stake + rewards
    assertLteWithinOneBip(
      lst.balanceOf(_holder1) + lst.balanceOf(_holder2), _stakeAmount1 + _stakeAmount2 + _rewardAmount
    );
  }

  function testFuzz_CalculatesTheCorrectBalanceWhenAUserStakesThenARewardIsDistributedThenAnotherUserStakesAndAnotherRewardIsDistributed(
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    address _holder1,
    address _holder2,
    uint256 _rewardAmount1,
    uint256 _rewardAmount2,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    // second user will stake 250% of first user
    _stakeAmount2 = _percentOf(_stakeAmount1, 250);
    // the first reward will be 25 percent of the first holders stake amount
    _rewardAmount1 = _percentOf(_stakeAmount1, 25);
    _rewardAmount2 = bound(_rewardAmount2, _percentOf(_stakeAmount1, 5), _percentOf(_stakeAmount1, 150));

    // The first user stakes
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    // A reward is distributed
    _distributeReward(_rewardAmount1);
    // The second user stakes
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee2);
    // Another reward is distributed
    _distributeReward(_rewardAmount2);

    // The first holder received all of the first reward and ~33% of the second reward
    uint256 _holder1ExpectedBalance = _stakeAmount1 + _rewardAmount1 + _percentOf(_rewardAmount2, 33);
    // The second holder received ~67% of the second reward
    uint256 _holder2ExpectedBalance = _stakeAmount2 + _percentOf(_rewardAmount2, 67);

    assertWithinOnePercent(lst.balanceOf(_holder1), _holder1ExpectedBalance);
    assertWithinOnePercent(lst.balanceOf(_holder2), _holder2ExpectedBalance);

    // Invariant: Sum of balanceOf should always be less than or equal to total stake + rewards
    assertLteWithinOneBip(
      lst.balanceOf(_holder1) + lst.balanceOf(_holder2), _stakeAmount1 + _stakeAmount2 + _rewardAmount1 + _rewardAmount2
    );
  }
}

contract Transfer is UniLstTest {
  function testFuzz_MovesFullBalanceToAReceiver(uint256 _amount, address _sender, address _receiver) public {
    _assumeSafeHolders(_sender, _receiver);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_sender, _amount);
    vm.prank(_sender);
    lst.transfer(_receiver, _amount);

    assertEq(lst.balanceOf(_sender), 0);
    assertEq(lst.balanceOf(_receiver), _amount);
  }

  function testFuzz_MovesPartialBalanceToAReceiver(
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    // Amount to send should be less than or equal to the full stake amount
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    _mintAndStake(_sender, _stakeAmount);
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    assertEq(lst.balanceOf(_sender), _stakeAmount - _sendAmount);
    assertEq(lst.balanceOf(_receiver), _sendAmount);
  }

  function testFuzz_MovesFullBalanceToAReceiverWhenBalanceIncludesEarnedRewards(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);

    _mintAndStake(_sender, _stakeAmount);
    _distributeReward(_rewardAmount);
    // As the only staker, the sender's balance should be the stake and rewards
    vm.prank(_sender);
    lst.transfer(_receiver, _stakeAmount + _rewardAmount);

    assertEq(lst.balanceOf(_sender), 0);
    assertEq(lst.balanceOf(_receiver), _stakeAmount + _rewardAmount);
  }

  function testFuzz_MovesPartialBalanceToAReceiverWhenBalanceIncludesEarnedRewards(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount + _rewardAmount);

    _mintAndStake(_sender, _stakeAmount);
    _distributeReward(_rewardAmount);
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // The sender should have the full balance of his stake and the reward, minus what was sent.
    uint256 _expectedSenderBalance = _stakeAmount + _rewardAmount - _sendAmount;

    // TODO: It's a bit concerning that you can transfer N tokens to the receiver but they end up receiving N-1 because
    // of the rounding with shares. Do STETH or ATokens handle this in some way, or accept it as a tradeoff?
    assertWithinOneUnit(lst.balanceOf(_sender), _expectedSenderBalance);
    assertWithinOneUnit(lst.balanceOf(_receiver), _sendAmount);
  }

  function testFuzz_MovesVotingWeightToTheReceiversDelegatee(
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _updateDelegatee(_receiver, _receiverDelegatee);

    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    assertEq(lst.balanceOf(_sender), _stakeAmount - _sendAmount);
    assertEq(stakeToken.getCurrentVotes(_senderDelegatee), _stakeAmount - _sendAmount);
    assertEq(lst.balanceOf(_receiver), _sendAmount);
    assertEq(stakeToken.getCurrentVotes(_receiverDelegatee), _sendAmount);
  }

  function testFuzz_MovesFullVotingWeightToTheReceiversDelegateeWhenBalanceIncludesEarnedRewards(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _updateDelegatee(_receiver, _receiverDelegatee);
    _distributeReward(_rewardAmount);
    vm.prank(_sender);
    lst.transfer(_receiver, _stakeAmount + _rewardAmount); // As the only staker, sender has all rewards

    assertEq(lst.balanceOf(_sender), 0);
    assertEq(stakeToken.getCurrentVotes(_senderDelegatee), 0);
    assertEq(lst.balanceOf(_receiver), _stakeAmount + _rewardAmount);
    assertEq(stakeToken.getCurrentVotes(_receiverDelegatee), _stakeAmount + _rewardAmount);
  }

  function testFuzz_MovesPartialVotingWeightToTheReceiversDelegateeAndConsolidatesSendersVotingWeightWhenBalanceIncludesRewards(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _updateDelegatee(_receiver, _receiverDelegatee);
    _distributeReward(_rewardAmount);
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    uint256 _expectedSenderBalance = _stakeAmount + _rewardAmount - _sendAmount;

    assertWithinOneUnit(lst.balanceOf(_sender), _expectedSenderBalance);
    assertWithinOneUnit(lst.balanceOf(_receiver), _sendAmount);

    // It's important the balances are less than the votes, since the votes represent the "real" underlying tokens,
    // and balances being below the real tokens available means the rounding favors the protocol, which is desired.
    assertLteWithinOneUnit(lst.balanceOf(_sender), stakeToken.getCurrentVotes(_senderDelegatee));
    assertLteWithinOneUnit(lst.balanceOf(_receiver), stakeToken.getCurrentVotes(_receiverDelegatee));
  }

  function testFuzz_UpdatesTheBalanceCheckpointOfTheSenderToReflectConsolidatedVotingWeight(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _updateDelegatee(_receiver, _receiverDelegatee);
    _distributeReward(_rewardAmount);
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // The sender's voting weight has been consolidated, so his checkpoint should equal his current balance.
    assertEq(lst.balanceCheckpoint(_sender), lst.balanceOf(_sender));
  }

  function testFuzz_AddsToTheBalanceCheckpointOfTheReceiverToAdditionalVotingWeight(
    uint256 _stakeAmount1,
    uint256 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _receiver,
    address _senderDelegatee,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    // The second user will stake 150% of the first user
    uint256 _stakeAmount2 = _percentOf(_stakeAmount1, 150);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);

    // Both users stake
    _mintUpdateDelegateeAndStake(_sender, _stakeAmount1, _senderDelegatee);
    _mintUpdateDelegateeAndStake(_receiver, _stakeAmount2, _receiverDelegatee);
    // A reward is distributed
    _distributeReward(_rewardAmount);

    // The send amount must be less than the sender's balance after the reward distribution
    _sendAmount = bound(_sendAmount, 0, lst.balanceOf(_sender));

    // The sender transfers to the receiver
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // The sender's full remaining balance is consolidated to their designated delegatee
    assertEq(lst.balanceOf(_sender), stakeToken.getCurrentVotes(_senderDelegatee), "SENDER DELEGATEE IS WRONG");
    // The rewards earned by the receiver are still assigned to the default delegatee
    assertWithinOneBip(stakeToken.getCurrentVotes(defaultDelegatee), _percentOf(_rewardAmount, 60));
    // The receiver's original stake and the tokens sent to him are staked to his designated delegatee
    assertWithinOneBip(stakeToken.getCurrentVotes(_receiverDelegatee), _stakeAmount2 + _sendAmount);

    // Invariant: Sum of balanceOf should always be less than or equal to total stake + rewards
    assertLteWithinOneBip(
      lst.balanceOf(_sender) + lst.balanceOf(_receiver), _stakeAmount1 + _stakeAmount2 + _rewardAmount
    );

    // Invariant: Total voting weight across delegatees equals the total tokens in the system
    assertEq(
      stakeToken.getCurrentVotes(_senderDelegatee) + stakeToken.getCurrentVotes(_receiverDelegatee)
        + stakeToken.getCurrentVotes(defaultDelegatee),
      _stakeAmount1 + _stakeAmount2 + _rewardAmount
    );
  }

  function testFuzz_MovesPartialVotingWeightToTheReceiversDelegateeAndConsolidatesSendersVotingWeightWhenBothBalancesIncludeRewards(
    uint256 _stakeAmount1,
    uint256 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _receiver,
    address _senderDelegatee,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    // The second user will stake 150% of the first user
    uint256 _stakeAmount2 = _percentOf(_stakeAmount1, 150);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);

    // Both users stake
    _mintUpdateDelegateeAndStake(_sender, _stakeAmount1, _senderDelegatee);
    _mintUpdateDelegateeAndStake(_receiver, _stakeAmount2, _receiverDelegatee);
    // A reward is distributed
    _distributeReward(_rewardAmount);

    // The send amount must be less than the sender's balance after the reward distribution
    _sendAmount = bound(_sendAmount, 0, lst.balanceOf(_sender));

    // The sender transfers to the receiver
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // The sender's checkpoint should be incremented by the send amount to reflect
    assertEq(lst.balanceCheckpoint(_receiver), _stakeAmount2 + _sendAmount);
  }

  function testFuzz_TransfersTheBalanceAndMovesTheVotingWeightBetweenMultipleHoldersWhoHaveStakedAndReceivedRewards(
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    uint256 _rewardAmount,
    uint256 _sendAmount1,
    uint256 _sendAmount2,
    address _sender1,
    address _sender2,
    address _receiver,
    address _sender1Delegatee,
    address _sender2Delegatee
  ) public {
    _assumeSafeHolders(_sender1, _sender2);
    _assumeSafeHolder(_receiver);
    vm.assume(_sender1 != _receiver && _sender2 != _receiver);
    _assumeSafeDelegatees(_sender1Delegatee, _sender2Delegatee);
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    _stakeAmount2 = _boundToReasonableStakeTokenAmount(_stakeAmount2);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _sendAmount1 = bound(_sendAmount1, 0.0001e18, _stakeAmount1);
    _sendAmount2 = bound(_sendAmount2, 0.0001e18, _stakeAmount2 + _sendAmount1);

    // Two users stake
    _mintUpdateDelegateeAndStake(_sender1, _stakeAmount1, _sender1Delegatee);
    _mintUpdateDelegateeAndStake(_sender2, _stakeAmount2, _sender2Delegatee);
    // A reward is distributed
    _distributeReward(_rewardAmount);
    // Remember the the sender balances after they receive their reward
    uint256 _balance1AfterReward = lst.balanceOf(_sender1);
    uint256 _balance2AfterReward = lst.balanceOf(_sender2);

    // First sender transfers to the second sender
    vm.prank(_sender1);
    lst.transfer(_sender2, _sendAmount1);
    // Second sender transfers to the receiver
    vm.prank(_sender2);
    lst.transfer(_receiver, _sendAmount2);

    // Balances have been updated correctly after the transfers
    assertWithinOneUnit(lst.balanceOf(_sender1), _balance1AfterReward - _sendAmount1);
    assertWithinOneUnit(lst.balanceOf(_sender2), _balance2AfterReward + _sendAmount1 - _sendAmount2);
    assertWithinOneUnit(lst.balanceOf(_receiver), _sendAmount2);

    // The sender balances should match their delegatee's voting weights because their voting weight has been
    // consolidated by doing the send.
    // TODO: These assertions show the balance of can be more than the current votes, which means the balance is more
    // than the "real" underlying. We have to understand this better and it is probably needed to make sure the
    // rounding favors the protocol.
    assertWithinOneUnit(lst.balanceOf(_sender1), stakeToken.getCurrentVotes(_sender1Delegatee));
    assertWithinOneUnit(lst.balanceOf(_sender2), stakeToken.getCurrentVotes(_sender2Delegatee));
    // Because the two transfer errors could have stacked, the error can be more than 1 unit
    assertWithinOneBip(lst.balanceOf(_receiver), stakeToken.getCurrentVotes(defaultDelegatee));
  }

  function testFuzz_EmitsATransferEvent(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _distributeReward(_rewardAmount);

    vm.expectEmit();
    emit UniLst.Transfer(_sender, _receiver, _sendAmount);
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);
  }

  function testFuzz_RevertIf_TheHolderTriesToTransferMoreThanTheirBalance(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatee(_senderDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    uint256 _totalAmount = _rewardAmount + _stakeAmount;
    // Send amount will be some value more than the sender's balance, up to 2x as much
    _sendAmount = bound(_sendAmount, _totalAmount + 1, 2 * _totalAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _distributeReward(_rewardAmount);

    vm.prank(_sender);
    vm.expectRevert(); // TODO: can we specifically expect an overflow?
    lst.transfer(_receiver, _sendAmount);
  }
}

contract SetWithdrawalGate is UniLstTest {
  function testFuzz_UpdatesTheWithdrawalGateWhenCalledByTheOwner(address _newWithdrawalGate) public {
    vm.prank(lstOwner);
    lst.setWithdrawalGate(IWithdrawalGate(_newWithdrawalGate));
    assertEq(address(lst.withdrawalGate()), _newWithdrawalGate);
  }

  function testFuzz_EmitsWithdrawalGateSetEvent(address _newWithdrawalGate) public {
    vm.prank(lstOwner);
    vm.expectEmit();
    emit UniLst.WithdrawalGateSet(address(0), _newWithdrawalGate);
    lst.setWithdrawalGate(IWithdrawalGate(_newWithdrawalGate));
  }

  function testFuzz_UpdatesTheWithdrawalGateAndEmitsEventWhenCalledASecondTime(
    address _firstNewWithdrawalGate,
    address _secondNewWithdrawalGate
  ) public {
    // A non-zero withdrawal gate is already set
    vm.prank(lstOwner);
    lst.setWithdrawalGate(IWithdrawalGate(_firstNewWithdrawalGate));

    vm.prank(lstOwner);
    vm.expectEmit();
    emit UniLst.WithdrawalGateSet(_firstNewWithdrawalGate, _secondNewWithdrawalGate);
    lst.setWithdrawalGate(IWithdrawalGate(_secondNewWithdrawalGate));
    assertEq(address(lst.withdrawalGate()), _secondNewWithdrawalGate);
  }

  function testFuzz_RevertIf_CalledByNonOwnerAccount(address _notLstOwner) public {
    vm.assume(_notLstOwner != lstOwner);

    vm.prank(_notLstOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notLstOwner));
    lst.setWithdrawalGate(IWithdrawalGate(_notLstOwner));
  }
}
