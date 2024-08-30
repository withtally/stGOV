// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2, stdStorage, StdStorage, stdError} from "forge-std/Test.sol";
import {UniLst, Ownable} from "src/UniLst.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {IUni} from "src/interfaces/IUni.sol";
import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {IWithdrawalGate} from "src/interfaces/IWithdrawalGate.sol";
import {MockWithdrawalGate} from "test/mocks/MockWithdrawalGate.sol";
import {UnitTestBase} from "test/UnitTestBase.sol";
import {TestHelpers} from "test/helpers/TestHelpers.sol";
import {Eip712Helper} from "test/helpers/Eip712Helper.sol";
import {PercentAssertions} from "test/helpers/PercentAssertions.sol";
import {Nonces} from "openzeppelin/utils/Nonces.sol";
import {Vm} from "forge-std/Vm.sol";

contract UniLstTest is UnitTestBase, PercentAssertions, TestHelpers, Eip712Helper {
  using stdStorage for StdStorage;

  IUniStaker staker;
  UniLst lst;
  address lstOwner;
  MockWithdrawalGate mockWithdrawalGate;
  uint256 initialPayoutAmount = 2500e18;

  address defaultDelegatee = makeAddr("Default Delegatee");
  string tokenName = "Staked Uni";
  string tokenSymbol = "stUni";

  // The error tolerance caused by rounding acceptable in certain test cases, i.e. 1x10^-13 UNI,
  // or 10 quadrillionths of a UNI.
  uint256 constant ACCEPTABLE_DELTA = 0.00000000000001e18;

  function setUp() public virtual override {
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
    lst = new UniLst(tokenName, tokenSymbol, staker, defaultDelegatee, lstOwner, initialPayoutAmount);

    // Deploy and set the mock withdrawal gate.
    mockWithdrawalGate = new MockWithdrawalGate();
    vm.prank(lstOwner);
    lst.setWithdrawalGate(address(mockWithdrawalGate));
  }

  function __dumpGlobalState() public view {
    console2.log("");
    console2.log("GLOBAL");
    console2.log("totalSupply");
    console2.log(lst.totalSupply());
    console2.log("totalShares");
    console2.log(lst.totalShares());
    (uint96 _defaultDepositBalance,,,) = staker.deposits(lst.DEFAULT_DEPOSIT_ID());
    console2.log("defaultDepositBalance", _defaultDepositBalance);
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

  function _assumeFutureExpiry(uint256 _expiry) internal view {
    vm.assume(_expiry > block.timestamp + 2);
  }

  function _boundToReasonableRewardTokenAmount(uint256 _amount) internal pure returns (uint256 _boundedAmount) {
    // Bound to within 1/1,000,000th of an ETH and >2 times the current total supply
    _boundedAmount = bound(_amount, 0.000001e18, 250_000_000e18);
  }

  function _boundToReasonableStakeTokenAmount(uint256 _amount) internal pure returns (uint256 _boundedAmount) {
    // Bound to within 1/10,000th of a UNI and 4 times the current total supply of UNI
    _boundedAmount = uint256(bound(_amount, 0.0001e18, 2_000_000_000e18));
  }

  function _boundToValidPrivateKey(uint256 _privateKey) internal pure returns (uint256) {
    return bound(_privateKey, 1, SECP256K1_ORDER - 1);
  }

  function _mintStakeToken(address _to, uint256 _amount) internal {
    deal(address(stakeToken), _to, _amount);
  }

  function _mintRewardToken(address _to, uint256 _amount) internal {
    // give the address ETH
    deal(_to, _amount);
    // deposit to get WETH
    vm.prank(_to);
    rewardToken.deposit{value: _amount}();
  }

  function _updateDeposit(address _holder, IUniStaker.DepositIdentifier _depositId) internal {
    vm.prank(_holder);
    lst.updateDeposit(_depositId);
  }

  function _updateDelegatee(address _holder, address _delegatee) internal {
    IUniStaker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

    vm.prank(_holder);
    lst.updateDeposit(_depositId);
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

  function _unstake(address _holder, uint256 _amount) internal {
    vm.prank(_holder);
    lst.unstake(_amount);
  }

  function _setWithdrawalGate(address _newWithdrawalGate) internal {
    vm.prank(lstOwner);
    lst.setWithdrawalGate(_newWithdrawalGate);
  }

  function _setPayoutAmount(uint256 _payoutAmount) internal {
    vm.prank(lstOwner);
    lst.setPayoutAmount(_payoutAmount);
  }

  function _setFeeParameters(uint256 _feeAmount, address _feeCollector) internal {
    vm.prank(lstOwner);
    lst.setFeeParameters(_feeAmount, _feeCollector);
  }

  function _distributeStakerReward(uint256 _amount) internal {
    _mintRewardToken(stakerAdmin, _amount);
    // As the reward notifier, send tokens to the staker then notify it.
    vm.startPrank(stakerAdmin);
    rewardToken.transfer(address(staker), _amount);
    staker.notifyRewardAmount(_amount);
    vm.stopPrank();
    // Fast forward to the point that all staker rewards are distributed
    vm.warp(block.timestamp + staker.REWARD_DURATION() + 1);
  }

  function _approveLstAndClaimAndDistributeReward(
    address _claimer,
    uint256 _rewardTokenAmount,
    address _rewardTokenRecipient
  ) internal {
    // Puts reward token in the staker.
    _distributeStakerReward(_rewardTokenAmount);
    // Approve the LST and claim the reward.
    vm.startPrank(_claimer);
    stakeToken.approve(address(lst), lst.payoutAmount());
    // Min expected rewards parameter is one less than reward amount due to truncation.
    lst.claimAndDistributeReward(_rewardTokenRecipient, _rewardTokenAmount - 1);
    vm.stopPrank();
  }

  function _distributeReward(uint256 _amount) internal {
    _setPayoutAmount(_amount);
    address _claimer = makeAddr("Claimer");
    uint256 _rewardTokenAmount = 10e18; // arbitrary amount of reward token
    _mintStakeToken(_claimer, _amount);
    _approveLstAndClaimAndDistributeReward(_claimer, _rewardTokenAmount, _claimer);
  }

  function _approve(address _staker, address _caller, uint256 _amount) internal {
    vm.startPrank(_staker);
    lst.approve(_caller, _amount);
    vm.stopPrank();
  }

  function _hashTypedDataV4(
    bytes32 _typeHash,
    bytes32 _structHash,
    bytes memory _name,
    bytes memory _version,
    address _verifyingContract
  ) internal view returns (bytes32) {
    bytes32 _seperator = _domainSeperator(_typeHash, _name, _version, _verifyingContract);
    return keccak256(abi.encodePacked("\x19\x01", _seperator, _structHash));
  }

  function _signMessage(
    bytes32 _typehash,
    address _account,
    uint256 _amount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _signerPrivateKey
  ) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(abi.encode(_typehash, _account, _amount, _nonce, _expiry));
    bytes32 hash = _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, "UniLst", "1", address(lst));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPrivateKey, hash);
    return abi.encodePacked(r, s, v);
  }

  function _setNonce(address _target, address _account, uint256 _currentNonce) internal {
    stdstore.target(_target).sig("nonces(address)").with_key(_account).checked_write(_currentNonce);
  }
}

contract Constructor is UniLstTest {
  function test_SetsConfigurationParameters() public view {
    assertEq(address(lst.STAKER()), address(staker));
    assertEq(address(lst.STAKE_TOKEN()), address(stakeToken));
    assertEq(address(lst.REWARD_TOKEN()), address(rewardToken));
    assertEq(lst.defaultDelegatee(), defaultDelegatee);
    assertEq(lst.payoutAmount(), initialPayoutAmount);
    assertEq(lst.owner(), lstOwner);
    assertEq(lst.name(), tokenName);
    assertEq(lst.symbol(), tokenSymbol);
    assertEq(lst.decimals(), 18);
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
    uint256 _payoutAmount,
    address _lstOwner,
    string memory _tokenName,
    string memory _tokenSymbol
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

    UniLst _lst = new UniLst(_tokenName, _tokenSymbol, IUniStaker(_staker), _defaultDelegatee, _lstOwner, _payoutAmount);
    assertEq(address(_lst.STAKER()), _staker);
    assertEq(address(_lst.STAKE_TOKEN()), _stakeToken);
    assertEq(address(_lst.REWARD_TOKEN()), _rewardToken);
    assertEq(_lst.defaultDelegatee(), _defaultDelegatee);
    assertEq(IUniStaker.DepositIdentifier.unwrap(_lst.depositForDelegatee(_defaultDelegatee)), 1);
    assertEq(_lst.payoutAmount(), _payoutAmount);
    assertEq(_lst.owner(), _lstOwner);
  }

  function testFuzz_RevertIf_MaxApprovalOfTheStakerContractOnTheStakeTokenFails(
    address _staker,
    address _stakeToken,
    address _rewardToken,
    address _defaultDelegatee,
    uint256 _payoutAmount,
    address _lstOwner,
    string memory _tokenName,
    string memory _tokenSymbol
  ) public {
    _assumeSafeMockAddress(_staker);
    _assumeSafeMockAddress(_stakeToken);
    vm.assume(_lstOwner != address(0));
    vm.mockCall(_staker, abi.encodeWithSelector(IUniStaker.STAKE_TOKEN.selector), abi.encode(_stakeToken));
    vm.mockCall(_staker, abi.encodeWithSelector(IUniStaker.REWARD_TOKEN.selector), abi.encode(_rewardToken));
    vm.mockCall(_stakeToken, abi.encodeWithSelector(IUni.approve.selector), abi.encode(false));

    vm.expectRevert(UniLst.UniLst__StakeTokenOperationFailed.selector);
    new UniLst(_tokenName, _tokenSymbol, IUniStaker(_staker), _defaultDelegatee, _lstOwner, _payoutAmount);
  }
}

contract DelegateeForHolder is UniLstTest {
  function testFuzz_ReturnsTheDefaultDelegateeBeforeADepositIsSet(address _holder) public view {
    _assumeSafeHolder(_holder);
    assertEq(lst.delegateeForHolder(_holder), defaultDelegatee);
  }

  function testFuzz_ReturnsTheValueSetViaUpdateDeposit(address _holder, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _updateDelegatee(_holder, _delegatee);
    assertEq(lst.delegateeForHolder(_holder), _delegatee);
  }
}

contract DepositForDelegatee is UniLstTest {
  function test_ReturnsTheDefaultDepositIdForTheZeroAddress() public view {
    IUniStaker.DepositIdentifier _depositId = lst.depositForDelegatee(address(0));
    assertEq(_depositId, lst.DEFAULT_DEPOSIT_ID());
  }

  function test_ReturnsTheDefaultDepositIdForTheDefaultDelegatee() public view {
    IUniStaker.DepositIdentifier _depositId = lst.depositForDelegatee(defaultDelegatee);
    assertEq(_depositId, lst.DEFAULT_DEPOSIT_ID());
  }

  function testFuzz_ReturnsZeroAddressForAnUninitializedDelegatee(address _delegatee) public view {
    _assumeSafeDelegatee(_delegatee);
    IUniStaker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    assertEq(_depositId, IUniStaker.DepositIdentifier.wrap(0));
  }

  function testFuzz_ReturnsTheStoredDepositIdForAnInitializedDelegatee(address _delegatee) public {
    _assumeSafeDelegatee(_delegatee);
    IUniStaker.DepositIdentifier _initializedDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    IUniStaker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    assertEq(_depositId, _initializedDepositId);
  }
}

contract FetchOrInitializeDepositForDelegatee is UniLstTest {
  function testFuzz_CreatesANewDepositForAnUninitializedDelegatee(address _delegatee) public {
    _assumeSafeDelegatee(_delegatee);
    IUniStaker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    (,, address _depositDelegatee,) = staker.deposits(_depositId);
    assertEq(_depositDelegatee, _delegatee);
  }

  function testFuzz_ReturnsTheExistingDepositIdForAPreviouslyInitializedDelegatee(address _delegatee) public {
    _assumeSafeDelegatee(_delegatee);
    IUniStaker.DepositIdentifier _depositIdFirstCall = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    IUniStaker.DepositIdentifier _depositIdSecondCall = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    assertEq(_depositIdFirstCall, _depositIdSecondCall);
  }

  function test_ReturnsTheDefaultDepositIdForTheZeroAddress() public {
    IUniStaker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(address(0));
    assertEq(_depositId, lst.DEFAULT_DEPOSIT_ID());
  }

  function test_ReturnsTheDefaultDepositIdForTheDefaultDelegatee() public {
    IUniStaker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(defaultDelegatee);
    assertEq(_depositId, lst.DEFAULT_DEPOSIT_ID());
  }

  function testFuzz_EmitsADepositInitializedEventWhenANewDepositIsCreated(address _delegatee1, address _delegatee2)
    public
  {
    _assumeSafeDelegatees(_delegatee1, _delegatee2);

    vm.expectEmit();
    // We did the 0th deposit in setUp() and the 1st deposit for the default deposit, so the next should be the 2nd
    emit UniLst.DepositInitialized(_delegatee1, IUniStaker.DepositIdentifier.wrap(2));
    lst.fetchOrInitializeDepositForDelegatee(_delegatee1);

    vm.expectEmit();
    // Initialize another deposit to make sure the identifier in the event increments to track the deposit identifier
    emit UniLst.DepositInitialized(_delegatee2, IUniStaker.DepositIdentifier.wrap(3));
    lst.fetchOrInitializeDepositForDelegatee(_delegatee2);
  }
}

contract UpdateDeposit is UniLstTest {
  function testFuzz_SetsTheHoldersDepositToOneAssociatedWithAGivenInitializedDelegatee(
    address _holder,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    IUniStaker.DepositIdentifier _depositId1 = lst.fetchOrInitializeDepositForDelegatee(_delegatee1);
    IUniStaker.DepositIdentifier _depositId2 = lst.fetchOrInitializeDepositForDelegatee(_delegatee2);

    _updateDeposit(_holder, _depositId1);
    assertEq(lst.delegateeForHolder(_holder), _delegatee1);

    _updateDeposit(_holder, _depositId2);
    assertEq(lst.delegateeForHolder(_holder), _delegatee2);
  }

  function testFuzz_EmitsDepositUpdatedEvent(address _holder, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    IUniStaker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

    vm.expectEmit();
    emit UniLst.DepositUpdated(_holder, IUniStaker.DepositIdentifier.wrap(1), _depositId);
    _updateDeposit(_holder, _depositId);
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
    IUniStaker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);

    // The user is first staking to a particular delegate.
    _mintUpdateDelegateeAndStake(_holder, _amount, _initialDelegatee);
    // The user updates their deposit identifier.
    _updateDeposit(_holder, _newDepositId);

    // The voting weight should have moved to the new delegatee.
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
    IUniStaker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);

    // Interim assertions after setup phase:
    // The amount staked by the user goes to their designated delegatee
    assertEq(stakeToken.getCurrentVotes(_initialDelegatee), _stakeAmount);
    // The amount earned in rewards has been delegated to the default delegatee
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), _rewardAmount);

    _updateDeposit(_holder, _newDepositId);

    // After update:
    // New delegatee has both the stake voting weight and the rewards accumulated
    assertEq(stakeToken.getCurrentVotes(_newDelegatee), _stakeAmount + _rewardAmount);
    // Default delegatee has had reward voting weight removed
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), 0);
    assertEq(lst.balanceOf(_holder), _stakeAmount + _rewardAmount);
  }

  function testFuzz_MovesAllVotingWeightForAHolderWhoHasAccruedRewardsAndWasPreviouslyDelegatedToDefault(
    uint256 _stakeAmount,
    address _holder,
    address _newDelegatee,
    uint256 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_newDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _distributeReward(_rewardAmount);
    IUniStaker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);

    // Interim assertions after setup phase:
    // The amount staked by the user plus the rewards all go to the default delegatee
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), _stakeAmount + _rewardAmount);

    _updateDeposit(_holder, _newDepositId);

    // After update:
    // New delegatee has both the stake voting weight and the rewards accumulated
    assertEq(stakeToken.getCurrentVotes(_newDelegatee), _stakeAmount + _rewardAmount);
    // Default delegatee has had reward voting weight removed
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), 0);
    assertEq(lst.balanceOf(_holder), _stakeAmount + _rewardAmount);
  }

  function testFuzz_MovesAllVotingWeightForAHolderWhoHasAccruedRewardsAndUpdatesToTheDefaultDelegatee(
    uint256 _stakeAmount,
    address _holder,
    address _initialDelegatee,
    uint256 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_initialDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _initialDelegatee);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _distributeReward(_rewardAmount);
    // Returns the default deposit ID.
    IUniStaker.DepositIdentifier _newDepositId = lst.depositForDelegatee(address(0));

    // Interim assertions after setup phase:
    // The amount staked by the user goes to their designated delegatee
    assertEq(stakeToken.getCurrentVotes(_initialDelegatee), _stakeAmount);
    // The amount earned in rewards has been delegated to the default delegatee
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), _rewardAmount);

    _updateDeposit(_holder, _newDepositId);

    // After update:
    // Default delegatee has both the stake voting weight and the rewards accumulated
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), _stakeAmount + _rewardAmount);
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
    IUniStaker.DepositIdentifier _depositId2 = lst.fetchOrInitializeDepositForDelegatee(_delegatee2);

    // Two holders stake to the same delegatee
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee1);

    // One holder updates their deposit
    _updateDeposit(_holder1, _depositId2);

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
    IUniStaker.DepositIdentifier _depositId2 = lst.fetchOrInitializeDepositForDelegatee(_delegatee2);

    // Two users stake to the same delegatee
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee1);
    // A reward is distributed
    _distributeReward(_rewardAmount);
    // One holder updates their deposit
    _updateDeposit(_holder1, _depositId2);

    // The new delegatee should have voting weight equal to the balance of the holder that updated
    assertEq(stakeToken.getCurrentVotes(_delegatee2), lst.balanceOf(_holder1));
    // The original delegatee should have voting weight equal to the balance of the other holder's staked amount
    assertEq(stakeToken.getCurrentVotes(_delegatee1), _stakeAmount2);
    // The default delegatee should have voting weight equal to the rewards distributed to the other holder
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), _stakeAmount1 + _rewardAmount - lst.balanceOf(_holder1));
  }

  function testFuzz_RevertIf_TheDepositIdProvidedDoesNotBelongToTheLstContract(address _holder) public {
    _assumeSafeHolder(_holder);

    vm.expectRevert(
      abi.encodeWithSelector(IUniStaker.UniStaker__Unauthorized.selector, bytes32("not owner"), address(lst))
    );
    _updateDeposit(_holder, IUniStaker.DepositIdentifier.wrap(0));
  }

  function testFuzz_UsesTheLiveBalanceForAUserIfTheirBalanceBecomesLowerThanTheirBalanceCheckpointDueToTruncation(
    address _holder1,
    address _holder2,
    address _delegatee1,
    address _delegatee2,
    address _delegatee3
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    _assumeSafeDelegatee(_delegatee3);
    vm.assume(_delegatee1 != _delegatee3 && _delegatee2 != _delegatee3);
    // These specific values were discovered via fuzzing, and are tuned to represent a specific case that can occur
    // where one user's live balance drops below their last delegated balance checkpoint due to the actions of
    // another user.
    uint256 _firstStakeAmount = 100_000_001;
    uint256 _rewardAmount = 100_000_003;
    uint256 _secondStakeAmount = 100_000_002;
    uint256 _firstUnstakeAmount = 138_542_415;

    // A holder stakes some tokens.
    _mintUpdateDelegateeAndStake(_holder1, _firstStakeAmount, _delegatee1);
    // A reward is distributed.
    _distributeReward(_rewardAmount);
    // Another user stakes some tokens, creating a delegated balance checkpoint.
    _mintUpdateDelegateeAndStake(_holder2, _secondStakeAmount, _delegatee2);
    // The first user unstakes, causing the second user's balance to drop slightly due to truncation.
    _unstake(_holder1, _firstUnstakeAmount);
    // The second user's live balance is now below the balance checkpoint that was created when they staked. We
    // validate this with a require statement rather than an assert, because it's an assumption of the specific test
    // values we've chosen, not a property of the system we are asserting.
    require(
      lst.balanceOf(_holder2) < lst.balanceCheckpoint(_holder2),
      "The assumption of this test is that the numbers chosen produce a case where the user's"
      "balance decreases below their checkpoint and this has been violated."
    );
    // Now the second user, whose balance is below their delegated balance checkpoint, updates their deposit.
    IUniStaker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee3);
    _updateDeposit(_holder2, _newDepositId);

    // The second user's first delegatee should still have one stray wei. This indicates the extra
    // wei has been left in their balance, as we intend.
    assertEq(stakeToken.getCurrentVotes(_delegatee2), 1);
    // Meanwhile, the second user's new delegatee is equal to their current balance, which dropped due to truncation.
    assertEq(stakeToken.getCurrentVotes(_delegatee3), lst.balanceOf(_holder2));
    assertEq(lst.balanceOf(_holder2), _secondStakeAmount - 1);
    // Finally, we ensure the second user's new balance checkpoint, created when they unstaked, matches their updated
    // live balance.
    assertEq(lst.balanceOf(_holder2), lst.balanceCheckpoint(_holder2));
  }
}

contract UpdateDepositOnBehalf is UniLstTest {
  function testFuzz_UpdatesDepositWhenCalledWithValidSignature(
    uint256 _amount,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);

    IUniStaker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    uint256 _nonce = lst.nonces(_staker);

    bytes memory signature = _signMessage(
      lst.UPDATE_DEPOSIT_TYPEHASH(),
      _staker,
      IUniStaker.DepositIdentifier.unwrap(_newDepositId),
      _nonce,
      _expiry,
      _stakerPrivateKey
    );

    vm.prank(_sender);
    lst.updateDepositOnBehalf(_staker, _newDepositId, _nonce, _expiry, signature);

    assertEq(lst.delegateeForHolder(_staker), _delegatee);
  }

  function testFuzz_EmitsDepositUpdatedEventWhenCalledWithValidSignature(
    uint256 _amount,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);

    IUniStaker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    uint256 _nonce = lst.nonces(_staker);

    bytes memory signature = _signMessage(
      lst.UPDATE_DEPOSIT_TYPEHASH(),
      _staker,
      IUniStaker.DepositIdentifier.unwrap(_newDepositId),
      _nonce,
      _expiry,
      _stakerPrivateKey
    );

    vm.expectEmit();
    emit UniLst.DepositUpdated(_staker, IUniStaker.DepositIdentifier.wrap(1), _newDepositId);

    vm.prank(_sender);
    lst.updateDepositOnBehalf(_staker, _newDepositId, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_SignatureIsInvalid(
    uint256 _amount,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);

    IUniStaker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    uint256 _nonce = lst.nonces(_staker);

    bytes memory _invalidSignature = new bytes(65);

    vm.prank(_sender);
    vm.expectRevert(UniLst.UniLst__InvalidSignature.selector);
    lst.updateDepositOnBehalf(_staker, _newDepositId, _nonce, _expiry, _invalidSignature);
  }

  function testFuzz_RevertIf_DeadlineHasExpired(
    uint256 _amount,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeSafeDelegatee(_delegatee);

    // Set expiry to a past timestamp
    _expiry = bound(_expiry, 0, block.timestamp - 1);

    IUniStaker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    uint256 _nonce = lst.nonces(_staker);

    bytes memory signature = _signMessage(
      lst.UPDATE_DEPOSIT_TYPEHASH(),
      _staker,
      IUniStaker.DepositIdentifier.unwrap(_newDepositId),
      _nonce,
      _expiry,
      _stakerPrivateKey
    );

    vm.prank(_sender);
    vm.expectRevert(UniLst.UniLst__SignatureExpired.selector);
    lst.updateDepositOnBehalf(_staker, _newDepositId, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_NonceIsInvalid(
    uint256 _amount,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender,
    address _delegatee
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeSafeDelegatee(_delegatee);
    _assumeFutureExpiry(_expiry);

    IUniStaker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    uint256 _nonce = lst.nonces(_staker);

    bytes memory signature = _signMessage(
      lst.UPDATE_DEPOSIT_TYPEHASH(),
      _staker,
      IUniStaker.DepositIdentifier.unwrap(_newDepositId),
      _nonce,
      _expiry,
      _stakerPrivateKey
    );

    // Use the signature once to invalidate the nonce
    vm.prank(_sender);
    lst.updateDepositOnBehalf(_staker, _newDepositId, _nonce, _expiry, signature);

    // Attempt to use the same nonce again
    vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, _staker, _nonce + 1));
    lst.updateDepositOnBehalf(_staker, _newDepositId, _nonce, _expiry, signature);
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

    assertLteWithinOneUnit(lst.balanceCheckpoint(_holder), _amount1 + _amount2);
  }

  function testFuzz_RevertIf_TheTransferFromTheStakeTokenFails(uint256 _amount, address _holder, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _updateDelegatee(_holder, _delegatee);

    vm.startPrank(_holder);
    stakeToken.approve(address(lst), _amount);
    vm.mockCall(address(stakeToken), abi.encodeWithSelector(IUni.transferFrom.selector), abi.encode(false));
    vm.expectRevert(UniLst.UniLst__StakeTokenOperationFailed.selector);
    lst.stake(_amount);
    vm.stopPrank();
  }

  function testFuzz_EmitsStakedEvent(uint256 _amount, address _holder) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintStakeToken(_holder, _amount);

    vm.startPrank(_holder);
    stakeToken.approve(address(lst), _amount);

    vm.expectEmit();
    emit UniLst.Staked(_holder, _amount);

    lst.stake(_amount);
    vm.stopPrank();
  }
}

contract Unstake is UniLstTest {
  function testFuzz_TransfersToAValidWithdrawalGate(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _unstake(_holder, _unstakeAmount);

    assertEq(stakeToken.balanceOf(address(mockWithdrawalGate)), _unstakeAmount);
  }

  function testFuzz_InitiatesWithdrawalOnTheWithdrawalGate(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _unstake(_holder, _unstakeAmount);

    assertEq(mockWithdrawalGate.lastParam__initiateWithdrawal_amount(), _unstakeAmount);
    assertEq(mockWithdrawalGate.lastParam__initiateWithdrawal_receiver(), _holder);
  }

  function testFuzz_TransfersDirectlyToHolderIfTheWithdrawalGateIsAddressZero(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    _setWithdrawalGate(address(0));
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _unstake(_holder, _unstakeAmount);

    assertEq(stakeToken.balanceOf(_holder), _unstakeAmount);
  }

  function testFuzz_TransfersToHolderIfWithdrawGateIsSetToANonContractAddress(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee,
    address _withdrawalGate
  ) public {
    _assumeSafeHolders(_holder, _withdrawalGate);
    vm.assume(_withdrawalGate.code.length == 0); // make sure fuzzer has not picked a contract address
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    _setWithdrawalGate(_withdrawalGate); // withdrawal gate is set to an EOA
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _unstake(_holder, _unstakeAmount);

    assertEq(stakeToken.balanceOf(_holder), _unstakeAmount);
  }

  function testFuzz_TransfersDirectlyToHolderIfCallToTheWithdrawalGateFails(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    mockWithdrawalGate.__setShouldRevertOnNextCall(true);
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _unstake(_holder, _unstakeAmount);

    assertEq(stakeToken.balanceOf(_holder), _unstakeAmount);
  }

  function testFuzz_TransfersDirectlyToHolderIfTheWithdrawalGateDoesNotImplementTheSelector(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    // We set the withdrawal gate to the stake token to act as an arbitrary contract that does not implement the
    // `initiateWithdrawal` selector
    _setWithdrawalGate(address(stakeToken));
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _unstake(_holder, _unstakeAmount);

    assertEq(stakeToken.balanceOf(_holder), _unstakeAmount);
  }

  function testFuzz_AllowsAHolderToWithdrawBalanceThatIncludesEarnedRewards(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    // One holder stakes and earns the full reward amount
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount);
    _unstake(_holder, _unstakeAmount);

    // The amount unstaked is less than or equal to the amount requested, within some acceptable truncation tolerance
    assertApproxEqAbs(stakeToken.balanceOf(address(mockWithdrawalGate)), _unstakeAmount, ACCEPTABLE_DELTA);
    assertLe(stakeToken.balanceOf(address(mockWithdrawalGate)), _unstakeAmount);
  }

  function testFuzz_WithdrawsFromUndelegatedBalanceIfItCoversTheAmount(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    // The unstake amount is _less_ than the reward amount.
    _unstakeAmount = bound(_unstakeAmount, 0, _rewardAmount);

    // One holder stakes and earns the full reward amount
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount);
    _unstake(_holder, _unstakeAmount);

    // Default delegatee has lost the unstake amount, within some acceptable delta to account for truncation.
    assertApproxEqAbs(stakeToken.getCurrentVotes(defaultDelegatee), _rewardAmount - _unstakeAmount, ACCEPTABLE_DELTA);
    assertGe(stakeToken.getCurrentVotes(defaultDelegatee), _rewardAmount - _unstakeAmount);
    // Delegatee balance is untouched and therefore still exactly the original amount
    assertEq(stakeToken.getCurrentVotes(_delegatee), _stakeAmount);
    // The amount actually unstaked is less than or equal to the amount requested, within some acceptable amount due to
    // truncation.
    assertApproxEqAbs(stakeToken.balanceOf(address(mockWithdrawalGate)), _unstakeAmount, ACCEPTABLE_DELTA);
    assertLe(stakeToken.balanceOf(address(mockWithdrawalGate)), _unstakeAmount);
  }

  function testFuzz_WithdrawsFromDelegatedBalanceAfterExhaustingUndelegatedBalance(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    // The unstake amount is _more_ than the reward amount.
    _unstakeAmount = bound(_unstakeAmount, _rewardAmount, _stakeAmount + _rewardAmount);

    // One holder stakes and earns the full reward amount
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount);
    _unstake(_holder, _unstakeAmount);

    assertApproxEqAbs(stakeToken.getCurrentVotes(defaultDelegatee), 0, ACCEPTABLE_DELTA);
    assertApproxEqAbs(
      stakeToken.getCurrentVotes(_delegatee), _stakeAmount + _rewardAmount - _unstakeAmount, ACCEPTABLE_DELTA
    );
    assertGe(stakeToken.getCurrentVotes(_delegatee), _stakeAmount + _rewardAmount - _unstakeAmount);
    assertApproxEqAbs(stakeToken.balanceOf(address(mockWithdrawalGate)), _unstakeAmount, ACCEPTABLE_DELTA);
    assertLe(stakeToken.balanceOf(address(mockWithdrawalGate)), _unstakeAmount);
  }

  function testFuzz_RemovesUnstakedAmountFromHoldersBalance(
    uint256 _stakeAmount,
    address _holder,
    address _delegatee,
    uint256 _unstakeAmount,
    uint256 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount);
    _unstake(_holder, _unstakeAmount);

    // The holder's lst balance decreases by the amount unstaked, within some tolerance to allow for truncation.
    assertApproxEqAbs(lst.balanceOf(_holder), _stakeAmount + _rewardAmount - _unstakeAmount, ACCEPTABLE_DELTA);
    assertGe(lst.balanceOf(_holder), _stakeAmount + _rewardAmount - _unstakeAmount);
  }

  function testFuzz_SubtractsFromTheHoldersDelegatedBalanceCheckpointIfUndelegatedBalanceIsUnstaked(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    // The unstake amount is _more_ than the reward amount.
    _unstakeAmount = bound(_unstakeAmount, _rewardAmount, _stakeAmount + _rewardAmount);

    // One holder stakes and earns the full reward amount
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount);
    _unstake(_holder, _unstakeAmount);

    // Because the full undelegated balance was unstaked, whatever balance the holder has left must be reflected in
    // their delegated balance checkpoint. However, it's also possible that, because global shares are destroyed
    // after the user's shares are destroyed, truncation may cause the user's balance to go up slightly from the
    // calculated balance checkpoint. This is fine, as long as the system is remaining solvent, that is, the extra
    // wei are actually being left in the default deposit as they should be. We also assert this here to ensure it
    // is the case.
    assertApproxEqAbs(lst.balanceCheckpoint(_holder), lst.balanceOf(_holder), ACCEPTABLE_DELTA);
    assertLe(lst.balanceCheckpoint(_holder), lst.balanceOf(_holder));
    (uint96 _defaultDepositBalance,,,) = staker.deposits(lst.DEFAULT_DEPOSIT_ID());
    assertEq(_defaultDepositBalance, lst.balanceOf(_holder) - lst.balanceCheckpoint(_holder));
  }

  function testFuzz_SubtractsTheRealAmountUnstakedFromTheTotalSupply(
    uint256 _stakeAmount,
    address _holder,
    address _delegatee,
    uint256 _unstakeAmount,
    uint256 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount);

    // Record the holder's balance and the total supply before unstaking
    uint256 _initialBalance = lst.balanceOf(_holder);
    uint256 _initialTotalSupply = lst.totalSupply();
    // Perform the unstaking
    _unstake(_holder, _unstakeAmount);

    uint256 _balanceDiff = _initialBalance - lst.balanceOf(_holder);
    uint256 _totalSupplyDiff = _initialTotalSupply - lst.totalSupply();

    assertEq(_totalSupplyDiff, _balanceDiff);
  }

  function testFuzz_SubtractsTheEquivalentSharesForTheAmountFromTheTotalShares(
    uint256 _stakeAmount,
    address _holder,
    address _delegatee,
    uint256 _unstakeAmount,
    uint256 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount);

    // Record the holders shares and the total shares before unstaking
    uint256 _initialShares = lst.sharesOf(_holder);
    uint256 _initialTotalShares = lst.totalShares();
    // Perform the unstaking
    _unstake(_holder, _unstakeAmount);

    uint256 _sharesDiff = _initialShares - lst.sharesOf(_holder);
    uint256 _totalSharesDiff = _initialTotalShares - lst.totalShares();

    assertEq(_totalSharesDiff, _sharesDiff);
  }

  function testFuzz_RevertIf_UnstakeAmountExceedsBalance(
    uint256 _stakeAmount,
    address _holder1,
    address _holder2,
    address _delegatee
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);

    // Two holders stake with the same delegatee, ensuring their funds will be mixed in the same staker deposit
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount, _delegatee);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount, _delegatee);
    // One of the holders tries to withdraw more than their balance

    vm.prank(_holder1);
    vm.expectRevert(UniLst.UniLst__InsufficientBalance.selector);
    lst.unstake(_stakeAmount + 1);
  }

  function testFuzz_UsesTheLiveBalanceForAUserIfTheirBalanceBecomesLowerThanTheirBalanceCheckpointDueToTruncation(
    address _holder1,
    address _holder2,
    address _delegatee1,
    address _delegatee2,
    uint256 _secondUnstakeAmount
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    // These specific values were discovered via fuzzing, and are tuned to represent a specific case that can occur
    // where one user's live balance drops below their last delegated balance checkpoint due to the actions of
    // another user.
    uint256 _firstStakeAmount = 100_000_001;
    uint256 _rewardAmount = 100_000_003;
    uint256 _secondStakeAmount = 100_000_002;
    uint256 _firstUnstakeAmount = 138_542_415;
    _secondUnstakeAmount = bound(_secondUnstakeAmount, 2, _secondStakeAmount - 1);

    // A holder stakes some tokens.
    _mintUpdateDelegateeAndStake(_holder1, _firstStakeAmount, _delegatee1);
    // A reward is distributed.
    _distributeReward(_rewardAmount);
    // Another user stakes some tokens, creating a delegated balance checkpoint.
    _mintUpdateDelegateeAndStake(_holder2, _secondStakeAmount, _delegatee2);
    // The first user unstakes, causing the second user's balance to drop slightly due to truncation.
    _unstake(_holder1, _firstUnstakeAmount);
    uint256 _interimGateBalance = stakeToken.balanceOf(address(mockWithdrawalGate));
    // The second user's live balance is now below the balance checkpoint that was created when they staked. We
    // validate this with a require statement rather than an assert, because it's an assumption of the specific test
    // values we've chosen, not a property of the system we are asserting.
    require(
      lst.balanceOf(_holder2) < lst.balanceCheckpoint(_holder2),
      "The assumption of this test is that the numbers chosen produce a case where the user's"
      "balance decreases below their checkpoint and this has been violated."
    );
    // Now the second user, whose balance is below their delegated balance checkpoint, unstakes.
    _unstake(_holder2, _secondUnstakeAmount);
    uint256 _finalGateBalance = stakeToken.balanceOf(address(mockWithdrawalGate));
    // Tha actual amount unstaked by the second user (as opposed to the amount they requested) is calculated as the
    // change in the withdrawal gate's balance.
    uint256 _amountUnstaked = _finalGateBalance - _interimGateBalance;

    // The second user's delegatee should still have all that user's remaining vote weight. This indicates the extra
    // wei has been left in their balance, as we intend.
    assertEq(stakeToken.getCurrentVotes(_delegatee2), _secondStakeAmount - _amountUnstaked);
    // Meanwhile, the second user's balance has dropped one wei lower than the actual tokens in the balance in their
    // actual deposit.
    assertEq(lst.balanceOf(_holder2), _secondStakeAmount - _amountUnstaked - 1);
    // Finally, we ensure the second user's new balance checkpoint, created when they unstaked, matches their updated
    // live balance.
    assertEq(lst.balanceOf(_holder2), lst.balanceCheckpoint(_holder2));
  }

  function testFuzz_EmitsUnstakedEvent(uint256 _stakeAmount, uint256 _unstakeAmount, address _holder) public {
    _assumeSafeHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    _mintAndStake(_holder, _stakeAmount);

    // Expect the event to be emitted
    vm.expectEmit();
    emit UniLst.Unstaked(_holder, _unstakeAmount);

    vm.prank(_holder);
    lst.unstake(_unstakeAmount);
  }
}

contract PermitAndStake is UniLstTest {
  using stdStorage for StdStorage;

  function testFuzz_PerformsTheApprovalByCallingPermitThenPerformsStake(
    uint256 _depositorPrivateKey,
    uint256 _stakeAmount,
    uint256 _deadline,
    uint256 _currentNonce
  ) public {
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _depositorPrivateKey = bound(_depositorPrivateKey, 1, 100e18);
    address _depositor = vm.addr(_depositorPrivateKey);
    _mintStakeToken(_depositor, _stakeAmount);

    _setNonce(address(stakeToken), _depositor, _currentNonce);
    bytes32 _message = keccak256(
      abi.encode(
        stakeToken.PERMIT_TYPEHASH(), _depositor, address(lst), _stakeAmount, stakeToken.nonces(_depositor), _deadline
      )
    );

    bytes32 _messageHash =
      _hashTypedDataV4(DOMAIN_TYPEHASH, _message, bytes(stakeToken.name()), "1", address(stakeToken));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    lst.permitAndStake(_stakeAmount, _deadline, _v, _r, _s);

    assertEq(lst.balanceOf(_depositor), _stakeAmount);
  }

  function testFuzz_SuccessfullyStakeWhenApprovalExistsAndPermitSignatureIsInvalid(
    uint256 _depositorPrivateKey,
    uint256 _stakeAmount,
    uint256 _approvalAmount,
    uint256 _deadline,
    uint256 _currentNonce
  ) public {
    _depositorPrivateKey = _boundToValidPrivateKey(_depositorPrivateKey);
    address _depositor = vm.addr(_depositorPrivateKey);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _approvalAmount = bound(_approvalAmount, _stakeAmount, type(uint96).max);
    _mintStakeToken(_depositor, _stakeAmount);
    vm.startPrank(_depositor);
    stakeToken.approve(address(lst), _approvalAmount);
    vm.stopPrank();

    _setNonce(address(stakeToken), _depositor, _currentNonce);
    bytes32 _message = keccak256(
      abi.encode(
        stakeToken.PERMIT_TYPEHASH(), _depositor, address(lst), _stakeAmount, stakeToken.nonces(_depositor), _deadline
      )
    );

    bytes32 _messageHash =
      _hashTypedDataV4(DOMAIN_TYPEHASH, _message, bytes(stakeToken.name()), "1", address(stakeToken));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    lst.permitAndStake(_stakeAmount, _deadline, _v, _r, _s);

    assertEq(lst.balanceOf(_depositor), _stakeAmount);
  }

  function testFuzz_RevertIf_ThePermitSignatureIsInvalidAndTheApprovalIsInsufficient(
    address _notDepositor,
    uint256 _depositorPrivateKey,
    uint256 _stakeAmount,
    uint256 _approvalAmount,
    uint256 _deadline,
    uint256 _currentNonce
  ) public {
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _depositorPrivateKey = _boundToValidPrivateKey(_depositorPrivateKey);
    address _depositor = vm.addr(_depositorPrivateKey);
    vm.assume(_notDepositor != _depositor);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _approvalAmount = bound(_approvalAmount, 0, _stakeAmount - 1);
    _mintStakeToken(_depositor, _stakeAmount);
    vm.startPrank(_depositor);
    stakeToken.approve(address(lst), _approvalAmount);
    vm.stopPrank();

    _setNonce(address(stakeToken), _notDepositor, _currentNonce);
    bytes32 _message = keccak256(
      abi.encode(
        stakeToken.PERMIT_TYPEHASH(),
        _notDepositor,
        address(lst),
        _stakeAmount,
        stakeToken.nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash =
      _hashTypedDataV4(DOMAIN_TYPEHASH, _message, bytes(stakeToken.name()), "1", address(stakeToken));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    vm.expectRevert("Uni::transferFrom: transfer amount exceeds spender allowance");
    lst.permitAndStake(_stakeAmount, _deadline, _v, _r, _s);
  }
}

contract StakeOnBehalf is UniLstTest {
  function testFuzz_StakesTokensOnBehalfOfAnotherUser(
    uint256 _amount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    _assumeFutureExpiry(_expiry);

    // Mint and approve tokens to the staker
    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(lst), _amount);
    vm.stopPrank();

    // Sign the message
    _setNonce(address(lst), _staker, _nonce);
    bytes memory signature =
      _signMessage(lst.STAKE_TYPEHASH(), _staker, _amount, lst.nonces(_staker), _expiry, _stakerPrivateKey);

    // Perform the stake on behalf
    vm.prank(_sender);
    lst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);

    // Check balances
    assertEq(lst.balanceOf(_staker), _amount);
  }

  function testFuzz_RevertIf_InvalidSignature(
    uint256 _amount,
    address _staker,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _wrongPrivateKey,
    address _sender
  ) public {
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _wrongPrivateKey = _boundToValidPrivateKey(_wrongPrivateKey);

    // Mint and approve tokens to the sender (signer)
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(lst), _amount);
    vm.stopPrank();

    // Sign the message with an invalid key
    _setNonce(address(lst), _staker, _nonce);
    bytes memory invalidSignature =
      _signMessage(lst.STAKE_TYPEHASH(), _staker, _amount, _nonce, _expiry, _wrongPrivateKey);

    // Attempt to perform the stake on behalf with an invalid signature
    vm.prank(_sender);
    vm.expectRevert(UniLst.UniLst__InvalidSignature.selector);
    lst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, invalidSignature);
  }

  function testFuzz_RevertIf_ExpiredSignature(
    uint256 _amount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _expiry = bound(_expiry, 0, block.timestamp - 1);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    // Mint and approve tokens to the staker
    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(lst), _amount);
    vm.stopPrank();

    // Sign the message with an expired expiry
    _setNonce(address(lst), _staker, _nonce);
    bytes memory signature =
      _signMessage(lst.STAKE_TYPEHASH(), _staker, _amount, lst.nonces(_staker), _expiry, _stakerPrivateKey);

    // Attempt to perform the stake on behalf with an expired signature
    vm.prank(_sender);
    vm.expectRevert(UniLst.UniLst__SignatureExpired.selector);
    lst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidNonce(
    uint256 _amount,
    uint256 _currentNonce,
    uint256 _suppliedNonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    vm.assume(_currentNonce != _suppliedNonce);
    _assumeFutureExpiry(_expiry);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    // Mint and approve tokens to the sender (staker)
    address _staker = vm.addr(_stakerPrivateKey);
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(lst), _amount);
    vm.stopPrank();

    // Sign the message with an invalid nonce
    _setNonce(address(lst), _staker, _currentNonce); // expected nonce
    bytes memory signature =
      _signMessage(lst.STAKE_TYPEHASH(), _staker, _amount, _suppliedNonce, _expiry, _stakerPrivateKey);

    // Attempt to perform the stake on behalf with an invalid nonce
    vm.prank(_sender);
    bytes memory expectedRevertData =
      abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, _staker, _currentNonce);
    vm.expectRevert(expectedRevertData);
    lst.stakeOnBehalf(_staker, _amount, _suppliedNonce, _expiry, signature);
  }

  function testFuzz_RevertIf_NonceReused(
    uint256 _amount,
    uint256 _expiry,
    uint256 _nonce,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);

    // Mint and approve tokens to the sender (staker)
    _mintStakeToken(_staker, _amount);
    vm.startPrank(_staker);
    stakeToken.approve(address(lst), _amount);
    vm.stopPrank();

    // Sign the message with a valid nonce
    _setNonce(address(lst), _staker, _nonce);
    bytes memory signature =
      _signMessage(lst.STAKE_TYPEHASH(), _staker, _amount, lst.nonces(_staker), _expiry, _stakerPrivateKey);

    // Perform the stake on behalf with a valid nonce
    vm.prank(_sender);
    lst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);

    // Attempt to perform the stake on behalf with the same nonce
    _expiry = block.timestamp + 1;

    vm.prank(_sender);
    bytes memory expectedRevertData =
      abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, _staker, lst.nonces(_staker));
    vm.expectRevert(expectedRevertData);
    lst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);
  }
}

contract UnstakeOnBehalf is UniLstTest {
  function testFuzz_UnstakesTokensOnBehalfOfAnotherUser(
    uint256 _amount,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _assumeFutureExpiry(_expiry);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);

    // Mint and stake tokens for the holder
    _mintStakeToken(_staker, _amount);
    _stake(_staker, _amount);

    // Sign the message
    _setNonce(address(lst), _staker, _nonce);
    bytes memory signature =
      _signMessage(lst.UNSTAKE_TYPEHASH(), _staker, _amount, lst.nonces(_staker), _expiry, _stakerPrivateKey);

    // Perform the unstake on behalf
    vm.prank(_sender);
    lst.unstakeOnBehalf(_staker, _amount, lst.nonces(_staker), _expiry, signature);

    // Check balances
    assertEq(lst.balanceOf(_staker), 0);
    assertEq(stakeToken.balanceOf(address(mockWithdrawalGate)), _amount);
  }

  function testFuzz_RevertIf_InvalidSignature(
    uint256 _amount,
    address _holder,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _wrongPrivateKey,
    address _sender
  ) public {
    _assumeSafeHolder(_holder);
    _assumeFutureExpiry(_expiry);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _wrongPrivateKey = _boundToValidPrivateKey(_wrongPrivateKey);

    // Mint and stake tokens for the holder
    _mintStakeToken(_holder, _amount);
    _stake(_holder, _amount);

    // Sign the message with an invalid key
    _setNonce(address(lst), _holder, _nonce);
    bytes memory invalidSignature =
      _signMessage(lst.UNSTAKE_TYPEHASH(), _holder, _amount, _nonce, _expiry, _wrongPrivateKey);

    // Attempt to perform the unstake on behalf with an invalid signature
    vm.prank(_sender);
    vm.expectRevert(UniLst.UniLst__InvalidSignature.selector);
    lst.unstakeOnBehalf(_holder, _amount, _nonce, _expiry, invalidSignature);
  }

  function testFuzz_RevertIf_ExpiredSignature(
    uint256 _amount,
    address _holder,
    uint256 _nonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _assumeSafeHolder(_holder);
    _expiry = bound(_expiry, 0, block.timestamp - 1);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    // Mint and stake tokens for the holder
    _mintStakeToken(_holder, _amount);
    _stake(_holder, _amount);

    // Sign the message with an expired expiry
    _setNonce(address(lst), _holder, _nonce);
    bytes memory signature = _signMessage(lst.UNSTAKE_TYPEHASH(), _holder, _amount, _nonce, _expiry, _stakerPrivateKey);

    // Attempt to perform the unstake on behalf with an expired signature
    vm.prank(_sender);
    vm.expectRevert(UniLst.UniLst__SignatureExpired.selector);
    lst.unstakeOnBehalf(_holder, _amount, _nonce, _expiry, signature);
  }

  function testFuzz_RevertIf_InvalidNonce(
    uint256 _amount,
    address _holder,
    uint256 _currentNonce,
    uint256 _suppliedNonce,
    uint256 _expiry,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _assumeSafeHolder(_holder);
    vm.assume(_currentNonce != _suppliedNonce);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);

    // Mint and stake tokens for the holder
    _mintStakeToken(_holder, _amount);
    _stake(_holder, _amount);

    // Sign the message with an invalid nonce
    _setNonce(address(lst), _holder, _currentNonce);
    bytes memory signature =
      _signMessage(lst.UNSTAKE_TYPEHASH(), _holder, _amount, _suppliedNonce, _expiry, _stakerPrivateKey);

    // Attempt to perform the unstake on behalf with an invalid nonce
    vm.prank(_sender);
    bytes memory expectedRevertData =
      abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, _holder, lst.nonces(_holder));
    vm.expectRevert(expectedRevertData);
    lst.unstakeOnBehalf(_holder, _amount, _suppliedNonce, _expiry, signature);
  }

  function testFuzz_RevertIf_NonceReused(
    uint256 _amount,
    uint256 _expiry,
    uint256 _nonce,
    uint256 _stakerPrivateKey,
    address _sender
  ) public {
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _stakerPrivateKey = _boundToValidPrivateKey(_stakerPrivateKey);
    address _staker = vm.addr(_stakerPrivateKey);
    _assumeSafeHolder(_staker);
    _assumeFutureExpiry(_expiry);

    // Mint and stake tokens for the holder
    _mintStakeToken(_staker, _amount);
    _stake(_staker, _amount);

    // Sign the message with a valid nonce
    _setNonce(address(lst), _staker, _nonce);
    bytes memory signature = _signMessage(lst.UNSTAKE_TYPEHASH(), _staker, _amount, _nonce, _expiry, _stakerPrivateKey);

    // Perform the unstake on behalf with a valid nonce
    lst.unstakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);

    // Attempt to perform the unstake on behalf with the same nonce
    _expiry = block.timestamp + 1;
    vm.prank(_sender);
    bytes memory expectedRevertData =
      abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, _staker, lst.nonces(_staker));
    vm.expectRevert(expectedRevertData);
    lst.unstakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);
  }
}

contract Approve is UniLstTest {
  function testFuzz_CorrectlySetAllowance(address _caller, address _spender, uint256 _amount) public {
    vm.prank(_caller);
    bool approved = lst.approve(_spender, _amount);
    assertEq(lst.allowance(_caller, _spender), _amount);
    assertTrue(approved);
  }

  function testFuzz_SettingAllowanceEmitsApprovalEvent(address _caller, address _spender, uint256 _amount) public {
    vm.prank(_caller);
    vm.expectEmit();
    emit IERC20.Approval(_caller, _spender, _amount);
    lst.approve(_spender, _amount);
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

  function testFuzz_CalculatesTheCorrectBalanceWhenAHolderUnstakes(
    uint256 _stakeAmount,
    address _holder,
    address _delegatee,
    uint256 _unstakeAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _unstake(_holder, _unstakeAmount);

    assertEq(lst.balanceOf(_holder), _stakeAmount - _unstakeAmount);
  }

  function testFuzz_CalculatesTheCorrectBalanceWhenAHolderUnstakesAfterARewardHasBeenDistributed(
    uint256 _stakeAmount,
    address _holder,
    address _delegatee,
    uint256 _unstakeAmount,
    uint256 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenAmount(_rewardAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount);

    _unstake(_holder, _unstakeAmount);

    assertApproxEqAbs(lst.balanceOf(_holder), _stakeAmount + _rewardAmount - _unstakeAmount, ACCEPTABLE_DELTA);
  }

  function testFuzz_CalculatesTheCorrectBalancesOfAHolderAndFeeCollectorWhenARewardDistributionIncludesAFee(
    address _claimer,
    address _recipient,
    uint256 _rewardTokenAmount,
    uint256 _rewardPayoutAmount,
    address _holder,
    uint256 _stakeAmount,
    address _feeCollector,
    uint256 _feeAmount
  ) public {
    // Apply constraints to parameters.
    _assumeSafeHolders(_holder, _claimer);
    _assumeSafeHolder(_feeCollector);
    vm.assume(_feeCollector != address(0) && _feeCollector != _holder && _feeCollector != _claimer);
    _rewardTokenAmount = _boundToReasonableRewardTokenAmount(_rewardTokenAmount);
    _rewardPayoutAmount = _boundToReasonableStakeTokenAmount(_rewardPayoutAmount);
    _feeAmount = bound(_feeAmount, 0, _rewardPayoutAmount);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    // Set up actors to enable reward distribution with fees.
    _setPayoutAmount(_rewardPayoutAmount);
    _setFeeParameters(_feeAmount, _feeCollector);
    _mintStakeToken(_claimer, _rewardPayoutAmount);
    _mintAndStake(_holder, _stakeAmount);

    // Execute reward distribution that includes a fee payout.
    _approveLstAndClaimAndDistributeReward(_claimer, _rewardTokenAmount, _recipient);

    // Fee collector should now have a balance less than or equal to, within a small delta to account for truncation,
    // the fee amount.
    assertApproxEqAbs(lst.balanceOf(_feeCollector), _feeAmount, ACCEPTABLE_DELTA);
    assertTrue(lst.balanceOf(_feeCollector) <= _feeAmount);
    // The holder should have earned all the rewards except the fee amount, which went to the fee collector.
    assertApproxEqAbs(lst.balanceOf(_holder), _stakeAmount + _rewardPayoutAmount - _feeAmount, ACCEPTABLE_DELTA);
  }
}

contract TransferFrom is UniLstTest {
  function testFuzz_MovesFullBalanceToAReceiver(uint256 _amount, address _caller, address _sender, address _receiver)
    public
  {
    _assumeSafeHolders(_sender, _receiver);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_sender, _amount);

    vm.prank(_sender);
    lst.approve(_caller, _amount);

    vm.prank(_caller);
    lst.transferFrom(_sender, _receiver, _amount);

    assertEq(lst.balanceOf(_sender), 0);
    assertEq(lst.balanceOf(_receiver), _amount);
  }

  function testFuzz_MovesPartialBalanceToAReceiver(
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _caller,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    // Amount to send should be less than or equal to the full amount
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    _mintAndStake(_sender, _stakeAmount);
    vm.prank(_sender);
    lst.approve(_caller, _sendAmount);

    vm.prank(_caller);
    lst.transferFrom(_sender, _receiver, _sendAmount);

    assertEq(lst.balanceOf(_sender), _stakeAmount - _sendAmount);
    assertEq(lst.balanceOf(_receiver), _sendAmount);
  }

  function testFuzz_CorrectlyDecrementsAllowance(
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _caller,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    // Amount to send should be less than or equal to the full amount
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    _mintAndStake(_sender, _stakeAmount);
    vm.prank(_sender);
    lst.approve(_caller, _stakeAmount);

    vm.prank(_caller);
    lst.transferFrom(_sender, _receiver, _sendAmount);

    assertEq(lst.allowance(_sender, _caller), _stakeAmount - _sendAmount);
  }

  function testFuzz_DoesNotDecrementAllowanceIfMaxUint(
    uint256 _stakeAmount,
    uint256 _sendAmount,
    address _caller,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    // Amount to send should be less than or equal to the full amount
    _sendAmount = bound(_sendAmount, 0, _stakeAmount);

    _mintAndStake(_sender, _stakeAmount);
    vm.prank(_sender);
    lst.approve(_caller, type(uint256).max);

    vm.prank(_caller);
    lst.transferFrom(_sender, _receiver, _sendAmount);

    assertEq(lst.allowance(_sender, _caller), type(uint256).max);
  }

  function testFuzz_RevertIf_NotEnoughAllowanceGiven(
    uint256 _amount,
    uint256 _allowanceAmount,
    address _caller,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    // Amount to send should be less than or equal to the full stake amount
    _allowanceAmount = bound(_allowanceAmount, 0, _amount - 1);

    _mintAndStake(_sender, _allowanceAmount);
    vm.prank(_sender);
    lst.approve(_caller, _allowanceAmount);

    vm.prank(_caller);
    vm.expectRevert(stdError.arithmeticError);
    lst.transferFrom(_sender, _receiver, _amount);
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

  function testFuzz_MovesFullBalanceToAReceiverWhenBalanceOfSenderIncludesEarnedRewards(
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

  function testFuzz_MovesPartialBalanceToAReceiverWhenBalanceOfSenderIncludesEarnedRewards(
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

    // Truncation is expected to favor the sender, so the expected amount should be less than or equal to
    // the sender's balance, while the receiver's balance should be less than or equal to the send amount.
    // All within expected acceptable deltas to account for truncation.
    assertApproxEqAbs(_expectedSenderBalance, lst.balanceOf(_sender), ACCEPTABLE_DELTA);
    assertLe(_expectedSenderBalance, lst.balanceOf(_sender));
    assertApproxEqAbs(lst.balanceOf(_receiver), _sendAmount, ACCEPTABLE_DELTA);
    assertLe(lst.balanceOf(_receiver), _sendAmount);
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

  function testFuzz_MovesFullVotingWeightToTheReceiversDelegateeWhenBalanceOfSenderIncludesEarnedRewards(
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

  function testFuzz_MovesPartialVotingWeightToTheReceiversDelegateeWhenBalanceOfSenderIncludesRewards(
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

    // Truncation should favor the sender within acceptable tolerance.
    assertApproxEqAbs(_expectedSenderBalance, lst.balanceOf(_sender), ACCEPTABLE_DELTA);
    assertLe(_expectedSenderBalance, lst.balanceOf(_sender));
    assertApproxEqAbs(lst.balanceOf(_receiver), _sendAmount, ACCEPTABLE_DELTA);
    assertLe(lst.balanceOf(_receiver), _sendAmount);

    // It's important the balances are less than the votes, since the votes represent the "real" underlying tokens,
    // and balances being below the real tokens available means the rounding favors the protocol, which is desired.
    assertLteWithinOneUnit(
      lst.balanceOf(_sender),
      stakeToken.getCurrentVotes(_senderDelegatee) + stakeToken.getCurrentVotes(defaultDelegatee)
    );
    assertLteWithinOneUnit(lst.balanceOf(_receiver), stakeToken.getCurrentVotes(_receiverDelegatee));
  }

  function testFuzz_LeavesTheSendersDelegatedBalanceUntouchedIfTheSendAmountIsLessThanTheSendersUndelegatedBalance(
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
    // The amount sent will be less than or equal to the rewards the sender has earned
    _sendAmount = bound(_sendAmount, 0, _rewardAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _updateDelegatee(_receiver, _receiverDelegatee);
    _distributeReward(_rewardAmount);
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // The senders delegated balance checkpoint has not changed from the original staked amount.
    assertEq(lst.balanceCheckpoint(_sender), _stakeAmount);
    // It's important the delegated checkpoint is less than the votes, since the votes represent the "real" tokens.
    assertLteWithinOneBip(lst.balanceCheckpoint(_sender), stakeToken.getCurrentVotes(_senderDelegatee));
  }

  function testFuzz_PullsFromTheSendersDelegatedBalanceAfterTheUndelegatedBalanceHasBeenExhausted(
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
    // The amount sent will be more than the original stake amount
    _sendAmount = bound(_sendAmount, _rewardAmount, _rewardAmount + _stakeAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _updateDelegatee(_receiver, _receiverDelegatee);
    _distributeReward(_rewardAmount);
    uint256 _senderInitialBalance = lst.balanceOf(_sender);
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // Because the transfer method may end up sending slightly less than the user actually requested, we want to check
    // if the conditions this test is meant to establish have actually occurred. Namely, we want to make sure the amount
    // sent was greater than the sender's reward earnings. If they were not, we skip the assertions, as this is not
    // testing what we intended.
    uint256 _senderBalanceDecrease = _senderInitialBalance - lst.balanceOf(_sender);
    vm.assume(_senderBalanceDecrease > _rewardAmount);

    // The sender's delegated balance is now equal to his balance, because his full undelegated balance (and then some)
    // has been used to complete the transfer.
    assertEq(lst.balanceCheckpoint(_sender), lst.balanceOf(_sender));
    // It's important the delegated checkpoint is less than the votes, since the votes represent the "real" tokens.
    assertLteWithinOneBip(lst.balanceCheckpoint(_sender), stakeToken.getCurrentVotes(_senderDelegatee));
  }

  function testFuzz_AddsToTheBalanceCheckpointOfTheReceiverAndVotingWeightOfReceiversDelegatee(
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

    // The receiver's original stake and the tokens sent to him are staked to his designated delegatee
    assertLteWithinOneBip(lst.balanceCheckpoint(_receiver), _stakeAmount2 + _sendAmount);
    assertLteWithinOneBip(stakeToken.getCurrentVotes(_receiverDelegatee), _stakeAmount2 + _sendAmount);
    // It's important the delegated checkpoint is less than the votes, since the votes represent the "real" tokens.
    assertLteWithinOneBip(lst.balanceCheckpoint(_receiver), stakeToken.getCurrentVotes(_receiverDelegatee));

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

  function testFuzz_MovesPartialVotingWeightToTheReceiversDelegateeWhenBothBalancesIncludeRewards(
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

    // The receiver's checkpoint should be incremented by the amount sent.
    assertApproxEqAbs(lst.balanceCheckpoint(_receiver), _stakeAmount2 + _sendAmount, ACCEPTABLE_DELTA);
    assertLe(lst.balanceCheckpoint(_receiver), _stakeAmount2 + _sendAmount);
    assertApproxEqAbs(
      lst.balanceCheckpoint(_receiver), stakeToken.getCurrentVotes(_receiverDelegatee), ACCEPTABLE_DELTA
    );
    assertLe(lst.balanceCheckpoint(_receiver), stakeToken.getCurrentVotes(_receiverDelegatee));
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

    // The following assertions ensure balances have been updated correctly after the transfers

    // The amount actually sent should be truncated down, so the sender's balance should be greater than the expected
    assertApproxEqAbs(_balance1AfterReward - _sendAmount1, lst.balanceOf(_sender1), ACCEPTABLE_DELTA);
    assertLe(_balance1AfterReward - _sendAmount1, lst.balanceOf(_sender1));
    // This holder may have been short changed as a receiver, but kept up extra wei as a sender, so
    // their balance and the expected should be within the acceptable delta in either direction.
    assertApproxEqAbs(lst.balanceOf(_sender2), _balance2AfterReward + _sendAmount1 - _sendAmount2, ACCEPTABLE_DELTA);
    // The amount sent could be truncated down, so the receiver's balance may be less than the expected.
    assertApproxEqAbs(lst.balanceOf(_receiver), _sendAmount2, ACCEPTABLE_DELTA);
    assertLe(lst.balanceOf(_receiver), _sendAmount2);

    uint256 _expectedDefaultDelegateeWeight = (lst.balanceOf(_sender1) - lst.balanceCheckpoint(_sender1))
      + (lst.balanceOf(_sender2) - lst.balanceCheckpoint(_sender2)) + lst.balanceOf(_receiver);

    assertLteWithinOneUnit(lst.balanceCheckpoint(_sender1), stakeToken.getCurrentVotes(_sender1Delegatee));
    assertLteWithinOneUnit(lst.balanceCheckpoint(_sender2), stakeToken.getCurrentVotes(_sender2Delegatee));
    assertApproxEqAbs(_expectedDefaultDelegateeWeight, stakeToken.getCurrentVotes(defaultDelegatee), ACCEPTABLE_DELTA);
    assertLe(_expectedDefaultDelegateeWeight, stakeToken.getCurrentVotes(defaultDelegatee));
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
    emit IERC20.Transfer(_sender, _receiver, _sendAmount);
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
    vm.expectRevert(UniLst.UniLst__InsufficientBalance.selector);
    lst.transfer(_receiver, _sendAmount);
  }

  function testFuzz_UsesTheLiveBalanceForAUserIfTheirBalanceBecomesLowerThanTheirBalanceCheckpointDueToTruncation(
    address _holder1,
    address _holder2,
    address _receiver,
    address _delegatee1,
    address _delegatee2,
    address _receiverDelegatee,
    uint256 _transferAmount
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeHolder(_receiver);
    vm.assume(_holder1 != _receiver && _holder2 != _receiver);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    _assumeSafeDelegatee(_receiverDelegatee);
    vm.assume(_delegatee1 != _receiverDelegatee && _delegatee2 != _receiverDelegatee);
    // These specific values were discovered via fuzzing, and are tuned to represent a specific case that can occur
    // where one user's live balance drops below their last delegated balance checkpoint due to the actions of
    // another user.
    uint256 _firstStakeAmount = 100_000_001;
    uint256 _rewardAmount = 100_000_003;
    uint256 _secondStakeAmount = 100_000_002;
    uint256 _firstUnstakeAmount = 138_542_415;
    _transferAmount = bound(_transferAmount, 2, _secondStakeAmount - 1);
    _updateDelegatee(_receiver, _receiverDelegatee);

    // A holder stakes some tokens.
    _mintUpdateDelegateeAndStake(_holder1, _firstStakeAmount, _delegatee1);
    // A reward is distributed.
    _distributeReward(_rewardAmount);
    // Another user stakes some tokens, creating a delegated balance checkpoint.
    _mintUpdateDelegateeAndStake(_holder2, _secondStakeAmount, _delegatee2);
    // The first user unstakes, causing the second user's balance to drop slightly due to truncation.
    _unstake(_holder1, _firstUnstakeAmount);
    // The second user's live balance is now below the balance checkpoint that was created when they staked. We
    // validate this with a require statement rather than an assert, because it's an assumption of the specific test
    // values we've chosen, not a property of the system we are asserting.
    require(
      lst.balanceOf(_holder2) < lst.balanceCheckpoint(_holder2),
      "The assumption of this test is that the numbers chosen produce a case where the user's"
      "balance decreases below their checkpoint and this has been violated."
    );
    uint256 _senderPreTransferBalance = lst.balanceOf(_holder2);
    // Now the second user, whose balance is below their delegated balance checkpoint, transfers some tokens.
    vm.prank(_holder2);
    lst.transfer(_receiver, _transferAmount);
    // The actual amount of tokens moved is equal to the decrease in the sender's balance, which may not be the exact
    // amount they requested to send.
    uint256 _senderBalanceDecrease = _senderPreTransferBalance - lst.balanceOf(_holder2);

    // The sender's delegatee should still have whatever is left of the initial amount staked by the sender.
    // This indicates the extra wei has been left in their balance, as we intend.
    assertEq(stakeToken.getCurrentVotes(_delegatee2), _secondStakeAmount - _senderBalanceDecrease);
    // Meanwhile, the sender's balance is one less than this value due to the truncation
    assertEq(lst.balanceOf(_holder2), _secondStakeAmount - _senderBalanceDecrease - 1);
    // The receiver's delegatee has the voting weight of the tokens that have been transferred to him.
    assertEq(stakeToken.getCurrentVotes(_receiverDelegatee), _senderBalanceDecrease);
    // Finally, we ensure the second user's new balance checkpoint, created when they transferred, matches their
    // updated live balance.
    assertEq(lst.balanceOf(_holder2), lst.balanceCheckpoint(_holder2));
  }

  // TODO: figure out wtf is going on here
  function test_ShavesTheSendersSharesIfTruncationWouldFavorTheSender() public {
    uint256[2] memory _stakeAmounts;
    uint256[2] memory _rewardAmounts;
    uint256[2] memory _firstTransferAmounts;
    uint256[2] memory _secondTransferAmounts;

    _stakeAmounts[0] = 2_000_000_000_000_000_000_000_000_000;
    _rewardAmounts[0] = 250_000_000_000_000_000_000_000_000;
    _firstTransferAmounts[0] = 51_159_322_140_703;
    _secondTransferAmounts[0] = 7;

    _stakeAmounts[1] = 100_000_000_000_000;
    _rewardAmounts[1] = 100_000_000_000_002;
    _firstTransferAmounts[1] = 100_000_000_000_003;
    _secondTransferAmounts[1] = 2;

    // Remember chain state before executing any tests.
    uint256 _snapshotId = vm.snapshot();

    for (uint256 _index; _index < _stakeAmounts.length; _index++) {
      _executeSenderShaveTest(
        _stakeAmounts[_index], _rewardAmounts[_index], _firstTransferAmounts[_index], _secondTransferAmounts[_index]
      );
      // Reset the chain state after executing last test.
      vm.revertTo(_snapshotId);
    }
  }

  function _executeSenderShaveTest(
    uint256 _stakeAmount,
    uint256 _rewardAmount,
    uint256 _firstTransferAmount,
    uint256 _secondTransferAmount
  ) public {
    address _holder1 = makeAddr("Holder 1");
    address _delegatee1 = makeAddr("Delegatee 1");
    address _holder2 = makeAddr("Holder 2");
    address _delegatee2 = makeAddr("Delegatee 2");

    // First holder stakes.
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount, _delegatee1);
    // A reward is distributed.
    _distributeReward(_rewardAmount);
    // Second holder sets a custom delegatee.
    _updateDelegatee(_holder2, _delegatee2);
    // First holder transfers to the second holder.
    vm.prank(_holder1);
    lst.transfer(_holder2, _firstTransferAmount);

    // We record balances at this point
    uint256 _holder1InitBalance = lst.balanceOf(_holder1);
    uint256 _holder2InitBalance = lst.balanceOf(_holder2);

    // Second holder transfer some back to the first holder. Because of the specific values we've set up, the transfer
    // method must shave the shares of the sender to prevent the receiver's balance from increasing by less than the
    // the sender's balance decreases.
    vm.prank(_holder2);
    lst.transfer(_holder1, _secondTransferAmount);

    assertEq(lst.balanceOf(_holder1), _holder1InitBalance + _secondTransferAmount);
    assertEq(lst.balanceOf(_holder2), _holder2InitBalance - _secondTransferAmount);
    assertEq(lst.balanceCheckpoint(_holder1), stakeToken.getCurrentVotes(_delegatee1));
    // Because this holder's shares were shaved as part of the transfer, they may have lost control of 1 wei of
    // of their stake token, which is now "stuck" in the Staker deposit assigned to their delegatee. This is ok, and
    // means the system is performing truncations in a way that ensures each deposit will remain solvent.
    assertLteWithinOneUnit(lst.balanceOf(_holder2), stakeToken.getCurrentVotes(_delegatee2));
  }
}

contract ClaimAndDistributeReward is UniLstTest {
  struct RewardDistributedEventData {
    address claimer;
    address recipient;
    uint256 rewardAmount;
    uint256 payoutAmount;
    uint256 feeAmount;
    address feeCollector;
  }

  function testFuzz_TransfersStakeTokenPayoutFromTheClaimer(
    address _claimer,
    address _recipient,
    uint256 _rewardAmount,
    uint256 _payoutAmount,
    uint256 _extraBalance,
    address _holder,
    uint256 _stakeAmount
  ) public {
    _assumeSafeHolders(_holder, _claimer);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenAmount(_payoutAmount);
    _extraBalance = _boundToReasonableStakeTokenAmount(_extraBalance);
    _setPayoutAmount(_payoutAmount);
    // The claimer should hold at least the payout amount with some extra balance.
    _mintStakeToken(_claimer, _payoutAmount + _extraBalance);
    // There must be some stake in the LST for it to earn the underlying staker rewards
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);

    _approveLstAndClaimAndDistributeReward(_claimer, _rewardAmount, _recipient);

    // Because the tokens were transferred from the claimer, his balance should have decreased by the payout amount.
    assertEq(stakeToken.balanceOf(_claimer), _extraBalance);
  }

  function testFuzz_AssignsVotingWeightFromRewardsToTheDefaultDelegatee(
    address _claimer,
    address _recipient,
    uint256 _rewardAmount,
    uint256 _payoutAmount,
    address _holder,
    uint256 _stakeAmount
  ) public {
    _assumeSafeHolders(_holder, _claimer);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenAmount(_payoutAmount);
    _setPayoutAmount(_payoutAmount);
    _mintStakeToken(_claimer, _payoutAmount);
    // There must be some stake in the LST for it to earn the underlying staker rewards
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);

    _approveLstAndClaimAndDistributeReward(_claimer, _rewardAmount, _recipient);

    // If the LST moved the voting weight in the default delegatee's deposit, he should have its voting weight.
    assertEq(stakeToken.getCurrentVotes(defaultDelegatee), _stakeAmount + _payoutAmount);
  }

  function testFuzz_SendsStakerRewardsToRewardRecipient(
    address _claimer,
    address _recipient,
    uint256 _rewardAmount,
    uint256 _payoutAmount,
    address _holder,
    uint256 _stakeAmount
  ) public {
    _assumeSafeHolders(_holder, _claimer);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenAmount(_payoutAmount);
    _setPayoutAmount(_payoutAmount);
    _mintStakeToken(_claimer, _payoutAmount);
    // There must be some stake in the LST for it to earn the underlying staker rewards
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);

    _approveLstAndClaimAndDistributeReward(_claimer, _rewardAmount, _recipient);

    assertLteWithinOneUnit(rewardToken.balanceOf(_recipient), _rewardAmount);
  }

  function testFuzz_IncreasesTheTotalSupplyByThePayoutAmount(
    address _claimer,
    address _recipient,
    uint256 _rewardAmount,
    uint256 _payoutAmount,
    address _holder,
    uint256 _stakeAmount
  ) public {
    _assumeSafeHolders(_holder, _claimer);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenAmount(_payoutAmount);
    _setPayoutAmount(_payoutAmount);
    _mintStakeToken(_claimer, _payoutAmount);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);

    _approveLstAndClaimAndDistributeReward(_claimer, _rewardAmount, _recipient);

    // Total balance is the amount staked + payout earned
    assertEq(lst.totalSupply(), _stakeAmount + _payoutAmount);
  }

  function testFuzz_IssuesFeesToTheFeeCollectorEqualToTheFeeAmount(
    address _claimer,
    address _recipient,
    uint256 _rewardAmount,
    uint256 _payoutAmount,
    address _holder,
    uint256 _stakeAmount,
    address _feeCollector,
    uint256 _feeAmount
  ) public {
    // Apply constraints to parameters.
    _assumeSafeHolders(_holder, _claimer);
    _assumeSafeHolder(_feeCollector);
    vm.assume(_feeCollector != address(0) && _feeCollector != _holder && _feeCollector != _claimer);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenAmount(_payoutAmount);
    _feeAmount = bound(_feeAmount, 0, _payoutAmount);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    // Set up actors to enable reward distribution with fees.
    _setPayoutAmount(_payoutAmount);
    _setFeeParameters(_feeAmount, _feeCollector);
    _mintStakeToken(_claimer, _payoutAmount);
    _mintAndStake(_holder, _stakeAmount);

    // Execute reward distribution that includes a fee payout.
    _approveLstAndClaimAndDistributeReward(_claimer, _rewardAmount, _recipient);

    // The fee collector should now have a balance less than or equal to the fee amount, within some tolerable delta
    // to account for truncation issues.
    assertApproxEqAbs(lst.balanceOf(_feeCollector), _feeAmount, ACCEPTABLE_DELTA);
    assertTrue(lst.balanceOf(_feeCollector) <= _feeAmount);
  }

  function testFuzz_RevertIf_RewardsReceivedAreLessThanTheExpectedAmount(
    address _claimer,
    address _recipient,
    uint256 _rewardAmount,
    uint256 _payoutAmount,
    uint256 _minExpectedReward
  ) public {
    _assumeSafeHolder(_claimer);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenAmount(_payoutAmount);
    _setPayoutAmount(_payoutAmount);
    // The claimer will request a minimum reward amount greater than the actual reward.
    _minExpectedReward = bound(_minExpectedReward, _rewardAmount + 1, type(uint256).max);
    _mintStakeToken(_claimer, _payoutAmount);

    vm.startPrank(_claimer);
    stakeToken.approve(address(lst), _payoutAmount);
    vm.expectRevert(UniLst.UniLst__InsufficientRewards.selector);
    lst.claimAndDistributeReward(_recipient, _minExpectedReward);
    vm.stopPrank();
  }

  function testFuzz_EmitsRewardDistributedEvent(
    address _claimer,
    address _recipient,
    uint256 _rewardAmount,
    uint256 _payoutAmount,
    uint256 _extraBalance,
    address _holder,
    uint256 _stakeAmount,
    address _feeCollector,
    uint256 _feeAmount
  ) public {
    _assumeSafeHolders(_holder, _claimer);
    _assumeSafeHolder(_feeCollector);
    vm.assume(_feeCollector != address(0) && _feeCollector != _holder && _feeCollector != _claimer);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenAmount(_payoutAmount);
    _extraBalance = _boundToReasonableStakeTokenAmount(_extraBalance);
    _feeAmount = bound(_feeAmount, 1, _payoutAmount);
    _setPayoutAmount(_payoutAmount);
    _setFeeParameters(_feeAmount, _feeCollector);
    _mintStakeToken(_claimer, _payoutAmount + _extraBalance);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);

    // Puts reward token in the staker.
    _distributeStakerReward(_rewardAmount);
    // Approve the LST and claim the reward.
    vm.startPrank(_claimer);
    stakeToken.approve(address(lst), lst.payoutAmount());

    // Min expected rewards parameter is one less than reward amount due to truncation.
    vm.recordLogs();
    lst.claimAndDistributeReward(_recipient, _rewardAmount - 1);
    vm.stopPrank();

    Vm.Log[] memory entries = vm.getRecordedLogs();

    _assertRewardDistributedEvent(
      entries,
      RewardDistributedEventData({
        claimer: _claimer,
        recipient: _recipient,
        rewardAmount: _rewardAmount,
        payoutAmount: _payoutAmount,
        feeAmount: _feeAmount,
        feeCollector: _feeCollector
      })
    );
  }

  function _assertRewardDistributedEvent(Vm.Log[] memory entries, RewardDistributedEventData memory expectedData)
    internal
  {
    bool foundEvent = false;
    uint256 lastIndex = entries.length - 1;
    bytes32 eventSignature = keccak256("RewardDistributed(address,address,uint256,uint256,uint256,address)");

    if (entries[lastIndex].topics[0] == eventSignature) {
      RewardDistributedEventData memory actualData;
      actualData.claimer = address(uint160(uint256(entries[lastIndex].topics[1])));
      actualData.recipient = address(uint160(uint256(entries[lastIndex].topics[2])));
      (actualData.rewardAmount, actualData.payoutAmount, actualData.feeAmount, actualData.feeCollector) =
        abi.decode(entries[lastIndex].data, (uint256, uint256, uint256, address));

      assertEq(actualData.claimer, expectedData.claimer);
      assertEq(actualData.recipient, expectedData.recipient);
      assertLteWithinOneUnit(actualData.rewardAmount, expectedData.rewardAmount);
      assertEq(actualData.payoutAmount, expectedData.payoutAmount);
      assertEq(actualData.feeAmount, expectedData.feeAmount);
      assertEq(actualData.feeCollector, expectedData.feeCollector);

      foundEvent = true;
    }

    assertTrue(foundEvent, "RewardDistributed event not found");
  }
}

contract SetPayoutAmount is UniLstTest {
  function testFuzz_UpdatesThePayoutAmountWhenCalledByTheOwner(uint256 _newPayoutAmount) public {
    vm.prank(lstOwner);
    lst.setPayoutAmount(_newPayoutAmount);
    assertEq(lst.payoutAmount(), _newPayoutAmount);
  }

  function testFuzz_EmitsPayoutAmountSetEvent(uint256 _newPayoutAmount) public {
    vm.prank(lstOwner);
    vm.expectEmit();
    emit UniLst.PayoutAmountSet(initialPayoutAmount, _newPayoutAmount);
    lst.setPayoutAmount(_newPayoutAmount);
  }

  function testFuzz_RevertIf_CalledByNonOwnerAccount(address _notLstOwner, uint256 _newPayoutAmount) public {
    vm.assume(_notLstOwner != lstOwner);

    vm.prank(_notLstOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notLstOwner));
    lst.setPayoutAmount(_newPayoutAmount);
  }
}

contract SetWithdrawalGate is UniLstTest {
  function testFuzz_UpdatesTheWithdrawalGateWhenCalledByTheOwner(address _newWithdrawalGate) public {
    vm.prank(lstOwner);
    lst.setWithdrawalGate(_newWithdrawalGate);
    assertEq(address(lst.withdrawalGate()), _newWithdrawalGate);
  }

  function testFuzz_EmitsWithdrawalGateSetEvent(address _newWithdrawalGate) public {
    vm.prank(lstOwner);
    vm.expectEmit();
    emit UniLst.WithdrawalGateSet(address(mockWithdrawalGate), _newWithdrawalGate);
    lst.setWithdrawalGate(_newWithdrawalGate);
  }

  function testFuzz_RevertIf_CalledByNonOwnerAccount(address _notLstOwner, address _newWithdrawalGate) public {
    vm.assume(_notLstOwner != lstOwner);

    vm.prank(_notLstOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notLstOwner));
    lst.setWithdrawalGate(_newWithdrawalGate);
  }
}

contract SetFeeParameters is UniLstTest {
  function testFuzz_UpdatesTheFeeParametersWhenCalledByTheOwner(uint256 _newFeeAmount, address _newFeeCollector) public {
    vm.assume(_newFeeCollector != address(0));
    _newFeeAmount = bound(_newFeeAmount, 0, lst.payoutAmount());

    vm.prank(lstOwner);
    lst.setFeeParameters(_newFeeAmount, _newFeeCollector);

    assertEq(lst.feeAmount(), _newFeeAmount);
    assertEq(lst.feeCollector(), _newFeeCollector);
  }

  function testFuzz_EmitsFeeParametersSetEvent(uint256 _newFeeAmount, address _newFeeCollector) public {
    vm.assume(_newFeeCollector != address(0));
    _newFeeAmount = bound(_newFeeAmount, 0, lst.payoutAmount());

    vm.prank(lstOwner);
    vm.expectEmit();
    emit UniLst.FeeParametersSet(0, _newFeeAmount, address(0), _newFeeCollector);
    lst.setFeeParameters(_newFeeAmount, _newFeeCollector);
  }

  function testFuzz_RevertIf_TheFeeAmountIsGreaterThanThePayoutAmount(uint256 _newFeeAmount, address _newFeeCollector)
    public
  {
    vm.assume(_newFeeCollector != address(0));
    _newFeeAmount = bound(_newFeeAmount, lst.payoutAmount() + 1, type(uint256).max);

    vm.prank(lstOwner);
    vm.expectRevert(UniLst.UniLst__InvalidFeeParameters.selector);
    lst.setFeeParameters(_newFeeAmount, _newFeeCollector);
  }

  function testFuzz_RevertIf_TheFeeCollectorIsTheZeroAddress(uint256 _newFeeAmount) public {
    _newFeeAmount = bound(_newFeeAmount, 0, lst.payoutAmount());

    vm.prank(lstOwner);
    vm.expectRevert(UniLst.UniLst__InvalidFeeParameters.selector);
    lst.setFeeParameters(_newFeeAmount, address(0));
  }

  function testFuzz_RevertIf_CalledByNonOwnerAccount(
    address _notLstOwner,
    uint256 _newFeeAmount,
    address _newFeeCollector
  ) public {
    vm.assume(_notLstOwner != lstOwner);
    vm.assume(_newFeeCollector != address(0));
    _newFeeAmount = bound(_newFeeAmount, 0, lst.payoutAmount());

    vm.prank(_notLstOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notLstOwner));
    lst.setFeeParameters(_newFeeAmount, _newFeeCollector);
  }
}

contract Permit is UniLstTest {
  function _buildPermitStructHash(address _owner, address _spender, uint256 _value, uint256 _nonce, uint256 _deadline)
    internal
    view
    returns (bytes32)
  {
    return keccak256(abi.encode(lst.PERMIT_TYPEHASH(), _owner, _spender, _value, _nonce, _deadline));
  }

  function testFuzz_AllowsApprovalViaSignature(
    uint256 _ownerPrivateKey,
    address _spender,
    address _sender,
    uint256 _value,
    uint256 _deadline
  ) public {
    _ownerPrivateKey = _boundToValidPrivateKey(_ownerPrivateKey);
    address _owner = vm.addr(_ownerPrivateKey);
    _assumeSafeHolders(_owner, _spender);
    _assumeFutureExpiry(_deadline);
    _value = _boundToReasonableStakeTokenAmount(_value);

    uint256 _nonce = lst.nonces(_owner);
    bytes32 structHash = _buildPermitStructHash(_owner, _spender, _value, _nonce, _deadline);
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(_ownerPrivateKey, _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, "UniLst", "1", address(lst)));

    assertEq(lst.allowance(_owner, _spender), 0);

    vm.prank(_sender);
    lst.permit(_owner, _spender, _value, _deadline, v, r, s);

    assertEq(lst.allowance(_owner, _spender), _value);
    assertEq(lst.nonces(_owner), _nonce + 1);
  }

  function testFuzz_EmitsApprovalEvent(
    uint256 _ownerPrivateKey,
    address _spender,
    address _sender,
    uint256 _value,
    uint256 _deadline
  ) public {
    _ownerPrivateKey = _boundToValidPrivateKey(_ownerPrivateKey);
    address _owner = vm.addr(_ownerPrivateKey);
    _assumeSafeHolders(_owner, _spender);
    _assumeFutureExpiry(_deadline);
    _value = _boundToReasonableStakeTokenAmount(_value);

    uint256 _nonce = lst.nonces(_owner);
    bytes32 structHash = _buildPermitStructHash(_owner, _spender, _value, _nonce, _deadline);
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(_ownerPrivateKey, _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, "UniLst", "1", address(lst)));

    vm.prank(_sender);
    vm.expectEmit();
    emit IERC20.Approval(_owner, _spender, _value);
    lst.permit(_owner, _spender, _value, _deadline, v, r, s);
  }

  function testFuzz_RevertIf_DeadlineExpired(
    uint256 _ownerPrivateKey,
    address _spender,
    address _sender,
    uint256 _value,
    uint256 _deadline,
    uint256 _futureTimestamp
  ) public {
    _ownerPrivateKey = _boundToValidPrivateKey(_ownerPrivateKey);
    address _owner = vm.addr(_ownerPrivateKey);
    _assumeSafeHolders(_owner, _spender);
    _value = _boundToReasonableStakeTokenAmount(_value);

    // Bound _deadline to be in the past relative to _futureTimestamp
    _futureTimestamp = bound(_futureTimestamp, block.timestamp + 1, type(uint256).max);
    _deadline = bound(_deadline, 0, _futureTimestamp - 1);

    // Warp to the future timestamp
    vm.warp(_futureTimestamp);

    uint256 _nonce = lst.nonces(_owner);
    bytes32 structHash = _buildPermitStructHash(_owner, _spender, _value, _nonce, _deadline);
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(_ownerPrivateKey, _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, "UniLst", "1", address(lst)));

    vm.prank(_sender);
    vm.expectRevert(UniLst.UniLst__SignatureExpired.selector);
    lst.permit(_owner, _spender, _value, _deadline, v, r, s);
  }

  function testFuzz_RevertIf_SignatureInvalid(
    uint256 _ownerPrivateKey,
    uint256 _wrongPrivateKey,
    address _spender,
    address _sender,
    uint256 _value,
    uint256 _deadline
  ) public {
    _ownerPrivateKey = _boundToValidPrivateKey(_ownerPrivateKey);
    _wrongPrivateKey = _boundToValidPrivateKey(_wrongPrivateKey);
    vm.assume(_ownerPrivateKey != _wrongPrivateKey);
    address _owner = vm.addr(_ownerPrivateKey);
    _assumeSafeHolders(_owner, _spender);
    _assumeFutureExpiry(_deadline);
    _value = _boundToReasonableStakeTokenAmount(_value);

    uint256 _nonce = lst.nonces(_owner);
    bytes32 structHash = _buildPermitStructHash(_owner, _spender, _value, _nonce, _deadline);
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(_wrongPrivateKey, _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, "UniLst", "1", address(lst)));

    vm.prank(_sender);
    vm.expectRevert(UniLst.UniLst__InvalidSignature.selector);
    lst.permit(_owner, _spender, _value, _deadline, v, r, s);
  }

  function testFuzz_RevertIf_SignatureReused(
    uint256 _ownerPrivateKey,
    address _spender,
    address _sender,
    uint256 _value,
    uint256 _deadline
  ) public {
    _ownerPrivateKey = _boundToValidPrivateKey(_ownerPrivateKey);
    address _owner = vm.addr(_ownerPrivateKey);
    _assumeSafeHolders(_owner, _spender);
    _assumeFutureExpiry(_deadline);
    _value = _boundToReasonableStakeTokenAmount(_value);

    uint256 _nonce = lst.nonces(_owner);
    bytes32 structHash = _buildPermitStructHash(_owner, _spender, _value, _nonce, _deadline);
    (uint8 v, bytes32 r, bytes32 s) =
      vm.sign(_ownerPrivateKey, _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, "UniLst", "1", address(lst)));

    vm.prank(_sender);
    lst.permit(_owner, _spender, _value, _deadline, v, r, s);

    vm.prank(_sender);
    vm.expectRevert(UniLst.UniLst__InvalidSignature.selector);
    lst.permit(_owner, _spender, _value, _deadline, v, r, s);
  }
}

contract DOMAIN_SEPARATOR is UniLstTest {
  function test_MatchesTheExpectedValueRequiredByTheEIP712Standard() public view {
    bytes32 _expectedDomainSeparator = keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("UniLst"),
        keccak256("1"),
        block.chainid,
        address(lst)
      )
    );

    bytes32 _actualDomainSeparator = lst.DOMAIN_SEPARATOR();

    assertEq(_actualDomainSeparator, _expectedDomainSeparator, "Domain separator mismatch");
  }
}

contract Nonce is UniLstTest {
  function testFuzz_InitialReturnsZeroForAllAccounts(address _account) public view {
    assertEq(lst.nonces(_account), 0);
  }
}
