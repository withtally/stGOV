// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console2, stdStorage, StdStorage, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Staker} from "staker/Staker.sol";
import {IERC20Staking} from "staker/interfaces/IERC20Staking.sol";
import {GovLst, Ownable} from "../src/GovLst.sol";
import {GovLstHarness} from "./harnesses/GovLstHarness.sol";
import {WithdrawGate} from "../src/WithdrawGate.sol";
import {UnitTestBase} from "./UnitTestBase.sol";
import {TestHelpers} from "./helpers/TestHelpers.sol";
import {Eip712Helper} from "./helpers/Eip712Helper.sol";
import {PercentAssertions} from "./helpers/PercentAssertions.sol";
import {MockFullEarningPowerCalculator} from "./mocks/MockFullEarningPowerCalculator.sol";
import {FakeStaker} from "./fakes/FakeStaker.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract GovLstTest is UnitTestBase, PercentAssertions, TestHelpers, Eip712Helper {
  using stdStorage for StdStorage;

  bytes32 constant PERMIT_TYPEHASH =
    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

  FakeStaker staker;
  MockFullEarningPowerCalculator earningPowerCalculator;
  GovLstHarness lst;
  WithdrawGate withdrawGate;
  address lstOwner;
  uint80 initialPayoutAmount = 2500e18;
  address claimer = makeAddr("Claimer");
  uint256 rewardTokenAmount = 10e18; // arbitrary amount of reward token
  uint256 maxTip = 1e18; // Higher values cause overflow issues

  address defaultDelegatee = makeAddr("Default Delegatee");
  address delegateeFunder = makeAddr("Delegatee Funder");
  address delegateeGuardian = makeAddr("Delegatee Guardian");
  string tokenName = "Staked Gov";
  string tokenSymbol = "stGov";

  // The maximum single reward that should be distributed—denominated in the stake token—to the LST in various tests.
  // For UNI, 1.2 Million UNI represents approx. $10 Million at current prices, and is thus well above realistic
  // reward values for some setups.
  uint256 constant MAX_STAKE_TOKEN_REWARD_DISTRIBUTION = 1_200_000e18;

  // We cache this value in setUp() to avoid slowing down tests by fetching it in each call.
  uint256 SHARE_SCALE_FACTOR;

  function setUp() public virtual override {
    super.setUp();
    require(
      MAX_STAKE_TOKEN_REWARD_DISTRIBUTION < type(uint80).max,
      "Invalid constant selected for max stake token reward distribution"
    );
    lstOwner = makeAddr("LST Owner");

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
        fixedLstName: tokenName,
        fixedLstSymbol: tokenSymbol,
        rebasingLstName: string.concat("Rebased ", tokenName),
        rebasingLstSymbol: string.concat("r", tokenSymbol),
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
    // Store the withdraw gate for convenience, set a non-zero withdrawal delay
    withdrawGate = lst.WITHDRAW_GATE();
    vm.prank(lstOwner);
    withdrawGate.setDelay(1 hours);

    // Cache for use throughout tests.
    SHARE_SCALE_FACTOR = lst.SHARE_SCALE_FACTOR();
  }

  function _computeCreate1Address(address deployer, uint8 nonce) internal pure returns (address) {
    // RLP = 0xd6 0x94 <address> <1-byte nonce>
    // 0xd6 = 0xc0 + 0x16 => 22 decimal bytes after
    // 0x94 => 20 bytes for address
    // The last byte is the nonce itself (when 1 <= nonce <= 0x7f)

    // Special case for nonce == 0 can be handled if needed
    bytes memory rlpEncoded = abi.encodePacked(hex"d6", hex"94", deployer, bytes1(nonce));

    bytes32 hash = keccak256(rlpEncoded);
    return address(uint160(uint256(hash)));
  }

  function __dumpGlobalState() public view {
    console2.log("");
    console2.log("GLOBAL");
    console2.log("totalSupply");
    console2.log(lst.totalSupply());
    console2.log("totalShares");
    console2.log(lst.totalShares());
    (uint96 _defaultDepositBalance,,,,,,) = staker.deposits(lst.DEFAULT_DEPOSIT_ID());
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
    console2.log("getVotes(delegatee)");
    console2.log(ERC20Votes(address(stakeToken)).getVotes(lst.delegateeForHolder(_holder)));
  }

  function _assumeSafeHolder(address _holder) internal view {
    // It's not safe to `deal` to an address that has already assigned a delegate, because deal overwrites the
    // balance directly without checkpointing vote weight, so subsequent transactions will cause the moving of
    // delegation weight to underflow.
    vm.assume(
      _holder != address(0) && _holder != stakeMinter
        && ERC20Votes(address(stakeToken)).delegates(_holder) == address(0)
    );
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

  // Bound to a reasonable value for the amount of the reward token that should be distributed in the underlying
  // staker implementation. For Staker, this is a quantity of ETH.
  function _boundToReasonableRewardTokenAmount(uint256 _amount) internal pure returns (uint80) {
    // Bound to within 1/1,000,000th of an ETH and the maximum value of uint80
    return uint80(bound(_amount, 0.000001e18, type(uint80).max));
  }

  // Bound to a reasonable value for the amount of stake token. This could be used for a value to be staked,
  // transferred, or withdrawn. For stake token rewards, use `_boundToReasonableStakeTokenReward` instead.
  function _boundToReasonableStakeTokenAmount(uint256 _amount) internal view returns (uint256 _boundedAmount) {
    // Our assumptions around the magnitude of errors caused by truncation assume that the raw total supply is
    // always less than the raw total shares. Since the total shares has a large scale factor applied, it is virtually
    // impossible for this not to be the case, unless huge rewards are distributed while a tiny amount of tokens
    // have been staked. To avoid hitting these exceptionally unlikely cases in fuzz tests, we calculate the minimum
    // amount of stake tokens here based on the upper bound of the stake token reward amount and the scale factor
    // of the staker. We apply a fudge-factor of 3x to this value for tests that might include multiple stake, transfer
    // and withdraw operations.
    uint256 _minStakeAmount = 3 * (MAX_STAKE_TOKEN_REWARD_DISTRIBUTION / SHARE_SCALE_FACTOR);
    // Upper bound is 4x the current total supply of UNI
    _boundedAmount = uint256(bound(_amount, _minStakeAmount, 2_000_000_000e18));
  }

  // Bound to a reasonable value for the amount of stake token distributed to the LST as rewards. This should be used
  // in tests for stake token denominated rewards.
  function _boundToReasonableStakeTokenReward(uint256 _amount) internal pure returns (uint80 _boundedAmount) {
    // Lower bound is 1/10,000th of a UNI
    _boundedAmount = uint80(bound(_amount, 0.00001e18, MAX_STAKE_TOKEN_REWARD_DISTRIBUTION));
  }

  function _boundToValidPrivateKey(uint256 _privateKey) internal pure returns (uint256) {
    return bound(_privateKey, 1, SECP256K1_ORDER - 1);
  }

  function _boundToReasonablePayoutAmount(uint256 _payoutAmount) internal pure returns (uint80) {
    return uint80(bound(_payoutAmount, 0.0001e18, type(uint80).max));
  }

  function _boundToValidTipAmount(uint256 _tipAmount) internal view returns (uint160) {
    return uint160(bound(_tipAmount, 0, maxTip));
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

  function _updateDeposit(address _holder, Staker.DepositIdentifier _depositId) internal {
    vm.prank(_holder);
    lst.updateDeposit(_depositId);
  }

  function _stakeOnDelegateeDeposit(Staker.DepositIdentifier _depositId, address _depositor) internal {
    _mintStakeToken(_depositor, 1e18);

    vm.startPrank(_depositor);
    stakeToken.approve(address(lst), 1e18);
    lst.stake(1e18);
    lst.updateDeposit(_depositId);
    vm.stopPrank();
  }

  function _unstakeOnDelegateeDeposit(address _depositor) internal {
    uint256 _time = block.timestamp;
    vm.startPrank(_depositor);
    uint256 _identifier = withdrawGate.getNextWithdrawalId();
    lst.unstake(lst.balanceOf(_depositor));
    if (withdrawGate.delay() != 0) {
      vm.warp(_time + withdrawGate.delay());
      withdrawGate.completeWithdrawal(_identifier);
    }
    vm.stopPrank();
  }

  function _updateDelegatee(address _holder, address _delegatee) internal {
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeDeposit(_depositId, delegateeFunder);
    vm.prank(_holder);
    lst.updateDeposit(_depositId);
    _unstakeOnDelegateeDeposit(delegateeFunder);
  }

  function _stake(address _holder, uint256 _amount) internal returns (uint256) {
    vm.startPrank(_holder);
    stakeToken.approve(address(lst), _amount);
    uint256 _balanceDelta = lst.stake(_amount);
    vm.stopPrank();
    return _balanceDelta;
  }

  function _stakeWithAttribution(address _holder, uint256 _amount, address _referrer) internal {
    vm.startPrank(_holder);
    stakeToken.approve(address(lst), _amount);
    lst.stakeWithAttribution(_amount, _referrer);
    vm.stopPrank();
  }

  function _mintAndStake(address _holder, uint256 _amount) internal {
    _mintStakeToken(_holder, _amount);
    _stake(_holder, _amount);
  }

  function _updateDelegateeAndStake(address _holder, uint256 _amount, address _delegatee) internal {
    _stake(_holder, _amount);
    _updateDelegatee(_holder, _delegatee);
  }

  function _updateDelegateeAndStakeWithAttribution(
    address _holder,
    uint256 _amount,
    address _delegatee,
    address _referrer
  ) internal {
    _stakeWithAttribution(_holder, _amount, _referrer);
    _updateDelegatee(_holder, _delegatee);
  }

  function _mintUpdateDelegateeAndStake(address _holder, uint256 _amount, address _delegatee) internal {
    _mintStakeToken(_holder, _amount);
    _updateDelegateeAndStake(_holder, _amount, _delegatee);
  }

  function _mintUpdateDelegateeAndStakeWithAttribution(
    address _holder,
    uint256 _amount,
    address _delegatee,
    address _referrer
  ) internal {
    _mintStakeToken(_holder, _amount);
    _updateDelegateeAndStakeWithAttribution(_holder, _amount, _delegatee, _referrer);
  }

  function _unstake(address _holder, uint256 _amount) internal returns (uint256) {
    vm.prank(_holder);
    return lst.unstake(_amount);
  }

  function _setRewardParameters(uint80 _payoutAmount, uint16 _feeBips, address _feeCollector) internal {
    vm.prank(lstOwner);
    lst.setRewardParameters(
      GovLst.RewardParameters({payoutAmount: _payoutAmount, feeBips: _feeBips, feeCollector: _feeCollector})
    );
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
    address _rewardTokenRecipient,
    Staker.DepositIdentifier _depositId
  ) internal {
    // Puts reward token in the staker.
    _distributeStakerReward(_rewardTokenAmount);
    // Approve the LST and claim the reward.
    vm.startPrank(_claimer);
    stakeToken.approve(address(lst), lst.payoutAmount());

    Staker.DepositIdentifier[] memory _deposits = new Staker.DepositIdentifier[](1);
    _deposits[0] = _depositId;

    // Min expected rewards parameter is one less than reward amount due to truncation.
    lst.claimAndDistributeReward(_rewardTokenRecipient, _rewardTokenAmount - 1, _deposits);
    vm.stopPrank();
  }

  function _distributeReward(uint80 _payoutAmount, Staker.DepositIdentifier _depositId) internal {
    _setRewardParameters(_payoutAmount, 0, address(1));
    _mintStakeToken(claimer, _payoutAmount);
    _approveLstAndClaimAndDistributeReward(claimer, rewardTokenAmount, claimer, _depositId);
  }

  function _distributeReward(uint80 _payoutAmount, Staker.DepositIdentifier _depositId, uint256 _percentOfAmount)
    internal
  {
    _setRewardParameters(_payoutAmount, 0, address(1));

    _mintStakeToken(claimer, _payoutAmount);
    // Puts reward token in the staker.
    _distributeStakerReward(rewardTokenAmount);
    // Approve the LST and claim the reward.
    vm.startPrank(claimer);
    stakeToken.approve(address(lst), lst.payoutAmount());

    Staker.DepositIdentifier[] memory _deposits = new Staker.DepositIdentifier[](1);
    _deposits[0] = _depositId;

    // Min expected rewards parameter is one less than reward amount due to truncation.
    lst.claimAndDistributeReward(claimer, _percentOf(rewardTokenAmount - 1, _percentOfAmount), _deposits);
    vm.stopPrank();
  }

  function _distributeReward(uint80 _payoutAmount) internal {
    _setRewardParameters(_payoutAmount, 0, address(1));
    address _claimer = makeAddr("Claimer");
    uint256 _rewardTokenAmount = 10e18; // arbitrary amount of reward token
    _mintStakeToken(_claimer, _payoutAmount);
    _approveLstAndClaimAndDistributeReward(_claimer, _rewardTokenAmount, _claimer, Staker.DepositIdentifier.wrap(1));
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
    bytes32 hash =
      _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, bytes(lst.name()), bytes(lst.version()), address(lst));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPrivateKey, hash);
    return abi.encodePacked(r, s, v);
  }

  function _setNonce(address _target, address _account, uint256 _currentNonce) internal {
    stdstore.target(_target).sig("nonces(address)").with_key(_account).checked_write(_currentNonce);
  }

  function _setMaxOverrideTip() internal {
    address _delegatee = makeAddr("Max tip delegate");
    address _holder = makeAddr("Max tip holder");
    _mintUpdateDelegateeAndStake(_delegatee, maxTip, _holder);
    vm.prank(lstOwner);
    lst.setMaxOverrideTip(maxTip);
  }

  function _setMinQualifyingEarningPowerBips(uint256 _minQualifyingEarningPowerBips) internal {
    vm.prank(lstOwner);
    lst.setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);
  }

  function _calcFeeShares(uint256 _tipAmount) internal view returns (uint160) {
    return uint160((uint256(_tipAmount) * lst.totalShares()) / (lst.totalSupply() - _tipAmount));
  }

  function _bumpBelowEarningPowerQualifyingThreshold(
    uint256 _earningPower,
    uint256 _minQualifyingEarningPowerBips,
    Staker.DepositIdentifier _depositId
  ) internal returns (uint256) {
    (uint96 _depositBalance,,, address _delegatee,,,) = staker.deposits(_depositId);
    _earningPower = 0;
    if (_minQualifyingEarningPowerBips * _depositBalance > 0) {
      _earningPower = bound(_earningPower, 0, ((_minQualifyingEarningPowerBips * _depositBalance) - 1) / 1e4);
    }
    earningPowerCalculator.__setEarningPowerForDelegatee(_delegatee, _earningPower);

    // Force the earning power on the deposit to change
    vm.prank(address(lst));
    staker.stakeMore(_depositId, 0);
    return _earningPower;
  }

  function _bumpAboveEarningPowerQualifyingThreshold(
    uint256 _earningPower,
    uint256 _minQualifyingEarningPowerBips,
    Staker.DepositIdentifier _depositId,
    address _delegatee
  ) internal returns (uint256) {
    (uint96 _depositBalance,,,,,,) = staker.deposits(_depositId);
    _earningPower =
      bound(_earningPower, ((_minQualifyingEarningPowerBips * _depositBalance) / 1e4) + 1, 20_000_000_000e18);
    earningPowerCalculator.__setEarningPowerForDelegatee(_delegatee, _earningPower);

    // Force the earning power on the deposit to change
    vm.prank(address(lst));
    staker.stakeMore(_depositId, 0);

    return _earningPower;
  }
}

contract Constructor is GovLstTest {
  function test_SetsConfigurationParameters() public view {
    assertEq(address(lst.STAKER()), address(staker));
    assertEq(address(lst.STAKE_TOKEN()), address(stakeToken));
    assertEq(address(lst.REWARD_TOKEN()), address(rewardToken));
    assertEq(lst.defaultDelegatee(), defaultDelegatee);
    assertEq(uint80(lst.payoutAmount()), initialPayoutAmount);
    assertEq(lst.owner(), lstOwner);
    assertEq(lst.name(), string.concat("Rebased ", tokenName));
    assertEq(lst.symbol(), string.concat("r", tokenSymbol));
    assertEq(lst.decimals(), 18);
    assertEq(lst.delegateeGuardian(), delegateeGuardian);
    assertEq(lst.MAX_FEE_BIPS(), 2000); // 20% in bips
  }

  function test_MaxApprovesTheStakerContractToTransferStakeToken() public view {
    assertEq(stakeToken.allowance(address(lst), address(staker)), type(uint256).max);
  }

  function test_CreatesDepositForTheDefaultDelegatee() public view {
    assertTrue(Staker.DepositIdentifier.unwrap(lst.depositForDelegatee(defaultDelegatee)) != 0);
  }

  function testFuzz_DeploysTheContractWithArbitraryValuesForParameters(
    address _defaultDelegatee,
    uint80 _payoutAmount,
    address _lstOwner,
    string memory _tokenName,
    string memory _tokenSymbol,
    address _delegateeGuardian,
    uint64 _stakeToBurn,
    uint256 _maxOverrideTip,
    uint256 _minQualifyingEarningPowerBips
  ) public {
    vm.assume(_lstOwner != address(0) && _defaultDelegatee != address(0));
    _maxOverrideTip = bound(_maxOverrideTip, 0, lst.MAX_OVERRIDE_TIP_CAP());
    _minQualifyingEarningPowerBips =
      bound(_minQualifyingEarningPowerBips, 0, lst.MINIMUM_QUALIFYING_EARNING_POWER_BIPS_CAP());

    address lstAddr = _computeCreate1Address(address(this), uint8(vm.getNonce(address(this))));
    _mintStakeToken(address(this), _stakeToBurn);
    stakeToken.approve(address(lstAddr), _stakeToBurn);

    GovLst _lst = new GovLstHarness(
      GovLst.ConstructorParams({
        fixedLstName: _tokenName,
        fixedLstSymbol: _tokenSymbol,
        rebasingLstName: string.concat("Rebased ", _tokenName),
        rebasingLstSymbol: string.concat("r", _tokenSymbol),
        version: "2",
        staker: Staker(staker),
        initialDefaultDelegatee: _defaultDelegatee,
        initialOwner: _lstOwner,
        initialPayoutAmount: _payoutAmount,
        initialDelegateeGuardian: _delegateeGuardian,
        stakeToBurn: _stakeToBurn,
        maxOverrideTip: _maxOverrideTip,
        minQualifyingEarningPowerBips: _minQualifyingEarningPowerBips
      })
    );

    assertEq(address(_lst.STAKER()), address(staker));
    assertEq(address(_lst.STAKE_TOKEN()), address(stakeToken));
    assertEq(address(_lst.REWARD_TOKEN()), address(rewardToken));
    assertEq(_lst.defaultDelegatee(), _defaultDelegatee);
    assertEq(Staker.DepositIdentifier.unwrap(_lst.depositForDelegatee(_defaultDelegatee)), 2);
    assertEq(_lst.payoutAmount(), _payoutAmount);
    assertEq(_lst.owner(), _lstOwner);
    assertEq(_lst.delegateeGuardian(), _delegateeGuardian);
    assertEq(_lst.maxOverrideTip(), _maxOverrideTip);
    assertEq(_lst.minQualifyingEarningPowerBips(), _minQualifyingEarningPowerBips);
  }
}

contract DelegateeForHolder is GovLstTest {
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

contract Delegate is GovLstTest {
  function testFuzz_UpdatesCallersDepositToExistingDelegatee(address _holder, address _delegatee, uint256 _amount)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    lst.fetchOrInitializeDepositForDelegatee(_delegatee);

    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintAndStake(_holder, _amount);

    vm.prank(_holder);
    lst.delegate(_delegatee);

    assertEq(lst.delegateeForHolder(_holder), _delegatee);
  }

  function testFuzz_UpdatesCallersDepositToANewDelegatee(address _holder, address _delegatee, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);

    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintAndStake(_holder, _amount);

    vm.prank(_holder);
    lst.delegate(_delegatee);

    assertEq(lst.delegateeForHolder(_holder), _delegatee);
  }
}

contract DepositForDelegatee is GovLstTest {
  function test_ReturnsTheDefaultDepositIdForTheZeroAddress() public view {
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(address(0));
    assertEq(_depositId, lst.DEFAULT_DEPOSIT_ID());
  }

  function test_ReturnsTheDefaultDepositIdForTheDefaultDelegatee() public view {
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(defaultDelegatee);
    assertEq(_depositId, lst.DEFAULT_DEPOSIT_ID());
  }

  function testFuzz_ReturnsZeroAddressForAnUninitializedDelegatee(address _delegatee) public view {
    _assumeSafeDelegatee(_delegatee);
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    assertEq(_depositId, Staker.DepositIdentifier.wrap(0));
  }

  function testFuzz_ReturnsTheStoredDepositIdForAnInitializedDelegatee(address _delegatee) public {
    _assumeSafeDelegatee(_delegatee);
    Staker.DepositIdentifier _initializedDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    assertEq(_depositId, _initializedDepositId);
  }
}

contract FetchOrInitializeDepositForDelegatee is GovLstTest {
  function testFuzz_CreatesANewDepositForAnUninitializedDelegatee(address _delegatee) public {
    _assumeSafeDelegatee(_delegatee);
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    (,,, address _depositDelegatee,,,) = staker.deposits(_depositId);
    assertEq(_depositDelegatee, _delegatee);
  }

  function testFuzz_ReturnsTheExistingDepositIdForAPreviouslyInitializedDelegatee(address _delegatee) public {
    _assumeSafeDelegatee(_delegatee);
    Staker.DepositIdentifier _depositIdFirstCall = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    Staker.DepositIdentifier _depositIdSecondCall = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    assertEq(_depositIdFirstCall, _depositIdSecondCall);
  }

  function test_ReturnsTheDefaultDepositIdForTheZeroAddress() public {
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(address(0));
    assertEq(_depositId, lst.DEFAULT_DEPOSIT_ID());
  }

  function test_ReturnsTheDefaultDepositIdForTheDefaultDelegatee() public {
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(defaultDelegatee);
    assertEq(_depositId, lst.DEFAULT_DEPOSIT_ID());
  }

  function testFuzz_EmitsADepositInitializedEventWhenANewDepositIsCreated(address _delegatee1, address _delegatee2)
    public
  {
    _assumeSafeDelegatees(_delegatee1, _delegatee2);

    vm.expectEmit();
    // We did the 0th deposit in setUp() and the 1st deposit for the default deposit, so the next should be the 2nd
    emit GovLst.DepositInitialized(_delegatee1, Staker.DepositIdentifier.wrap(2));
    lst.fetchOrInitializeDepositForDelegatee(_delegatee1);

    vm.expectEmit();
    // Initialize another deposit to make sure the identifier in the event increments to track the deposit identifier
    emit GovLst.DepositInitialized(_delegatee2, Staker.DepositIdentifier.wrap(3));
    lst.fetchOrInitializeDepositForDelegatee(_delegatee2);
  }
}

contract UpdateDeposit is GovLstTest {
  using stdStorage for StdStorage;

  function testFuzz_SetsTheHoldersDepositToOneAssociatedWithAGivenInitializedDelegatee(
    address _holder,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    Staker.DepositIdentifier _depositId1 = lst.fetchOrInitializeDepositForDelegatee(_delegatee1);
    _stakeOnDelegateeDeposit(_depositId1, delegateeFunder);

    Staker.DepositIdentifier _depositId2 = lst.fetchOrInitializeDepositForDelegatee(_delegatee2);
    address _delegateeFunder2 = makeAddr("Delegatee Funder 2");
    _stakeOnDelegateeDeposit(_depositId2, _delegateeFunder2);

    _updateDeposit(_holder, _depositId1);
    assertEq(lst.delegateeForHolder(_holder), _delegatee1);

    _updateDeposit(_holder, _depositId2);
    assertEq(lst.delegateeForHolder(_holder), _delegatee2);
  }

  function testFuzz_EmitsDepositUpdatedEvent(address _holder, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeDeposit(_depositId, delegateeFunder);

    vm.expectEmit();
    emit GovLst.DepositUpdated(_holder, Staker.DepositIdentifier.wrap(1), _depositId);
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
    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);

    // The user is first staking to a particular delegate.
    _mintUpdateDelegateeAndStake(_holder, _amount, _initialDelegatee);
    // The user updates their deposit identifier.
    _updateDeposit(_holder, _newDepositId);

    // The voting weight should have moved to the new delegatee.
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_newDelegatee), _amount);
  }

  function testFuzz_MovesAllVotingWeightForAHolderWhoHasAccruedRewards(
    uint256 _stakeAmount,
    address _holder,
    address _initialDelegatee,
    address _newDelegatee,
    uint80 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_initialDelegatee);
    _assumeSafeDelegatee(_newDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _initialDelegatee);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));

    // Interim assertions after setup phase:
    // The amount staked by the user goes to their designated delegatee
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_initialDelegatee), _stakeAmount);
    // The amount earned in rewards has been delegated to the default delegatee
    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _rewardAmount);

    _updateDeposit(_holder, _newDepositId);

    // After update:
    // New delegatee has both the stake voting weight and the rewards accumulated
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_newDelegatee), _stakeAmount + _rewardAmount);
    // Default delegatee has had reward voting weight removed
    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), 0);
    assertEq(lst.balanceOf(_holder), _stakeAmount + _rewardAmount);
  }

  function testFuzz_MovesAllVotingWeightForAHolderWhoHasAccruedRewardsAndWasPreviouslyDelegatedToDefault(
    uint256 _stakeAmount,
    address _holder,
    address _newDelegatee,
    uint80 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_newDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _distributeReward(_rewardAmount);
    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);

    // Interim assertions after setup phase:
    // The amount staked by the user plus the rewards all go to the default delegatee
    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _stakeAmount + _rewardAmount);

    _updateDeposit(_holder, _newDepositId);

    // After update:
    // New delegatee has both the stake voting weight and the rewards accumulated
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_newDelegatee), _stakeAmount + _rewardAmount);
    // Default delegatee has had reward voting weight removed
    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), 0);
    assertEq(lst.balanceOf(_holder), _stakeAmount + _rewardAmount);
  }

  function testFuzz_MovesAllVotingWeightForAHolderWhoHasAccruedRewardsAndUpdatesToTheDefaultDelegatee(
    uint256 _stakeAmount,
    address _holder,
    address _initialDelegatee,
    uint80 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_initialDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _initialDelegatee);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));
    // Returns the default deposit ID.
    Staker.DepositIdentifier _newDepositId = lst.depositForDelegatee(address(0));

    // Interim assertions after setup phase:
    // The amount staked by the user goes to their designated delegatee
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_initialDelegatee), _stakeAmount);
    // The amount earned in rewards has been delegated to the default delegatee
    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _rewardAmount);

    _updateDeposit(_holder, _newDepositId);

    // After update:
    // Default delegatee has both the stake voting weight and the rewards accumulated
    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _stakeAmount + _rewardAmount);
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
    Staker.DepositIdentifier _depositId2 = lst.fetchOrInitializeDepositForDelegatee(_delegatee2);

    // Two holders stake to the same delegatee
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee1);

    // One holder updates their deposit
    _updateDeposit(_holder1, _depositId2);

    assertEq(ERC20Votes(address(stakeToken)).getVotes(_delegatee1), _stakeAmount2);
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_delegatee2), _stakeAmount1);
  }

  function testFuzz_MovesOnlyTheVotingWeightOfTheCallerWhenTwoUsersStakeAfterARewardHasBeenDistributed(
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    address _holder1,
    address _holder2,
    uint80 _rewardAmount,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    _stakeAmount2 = _boundToReasonableStakeTokenAmount(_stakeAmount2);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    Staker.DepositIdentifier _depositId2 = lst.fetchOrInitializeDepositForDelegatee(_delegatee2);

    // Two users stake to the same delegatee
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee1);
    // A reward is distributed
    _distributeReward(_rewardAmount, _depositId2, _percentOf(rewardTokenAmount, 0));

    // One holder updates their deposit
    _updateDeposit(_holder1, _depositId2);

    // The new delegatee should have voting weight equal to the balance of the holder that updated
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_delegatee2), lst.balanceOf(_holder1));
    // The original delegatee should have voting weight equal to the balance of the other holder's staked amount
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_delegatee1), _stakeAmount2);
    // The default delegatee should have voting weight equal to the rewards distributed to the other holder
    assertEq(
      ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee),
      _stakeAmount1 + _rewardAmount - lst.balanceOf(_holder1)
    );
  }

  function testFuzz_RevertIf_TheDepositIdProvidedDoesNotBelongToTheLstContract(address _holder) public {
    _assumeSafeHolder(_holder);

    vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not owner"), address(lst)));
    _updateDeposit(_holder, Staker.DepositIdentifier.wrap(0));
  }

  function testFuzz_RevertIf_UpdatingFromDepositDelegateeToInvalidDeposit(address _holder, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);

    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    stdstore.target(address(lst)).sig("isOverridden(uint256)").with_key(Staker.DepositIdentifier.unwrap(_depositId))
      .checked_write(true);
    _stakeOnDelegateeDeposit(lst.DEFAULT_DEPOSIT_ID(), _holder);

    _updateDeposit(_holder, lst.DEFAULT_DEPOSIT_ID());
    assertEq(lst.delegateeForHolder(_holder), lst.defaultDelegatee());

    uint256 _depositBalance = lst.balanceOf(_holder);
    vm.assertNotEq(_depositBalance, 0);
    vm.expectRevert(GovLst.GovLst__InvalidDeposit.selector);
    _updateDeposit(_holder, _depositId);
  }

  function testFuzz_RevertIf_UpdatingFromDepositDelegateeToDepositWithInvalidEarningPower(
    address _holder,
    address _delegatee,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);

    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeDeposit(lst.DEFAULT_DEPOSIT_ID(), _holder);

    _updateDeposit(_holder, lst.DEFAULT_DEPOSIT_ID());
    assertEq(lst.delegateeForHolder(_holder), lst.defaultDelegatee());

    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);
    _earningPower = _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);
    uint256 _depositBalance = lst.balanceOf(_holder);

    vm.assertNotEq(_depositBalance, 0);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovLst.GovLst__EarningPowerNotQualified.selector, 0, _depositBalance * _minQualifyingEarningPowerBips
      )
    );
    _updateDeposit(_holder, _depositId);
  }

  function testFuzz_RevertIf_UpdatingFromAnyDelegateeToAnInvalidDeposit(
    address _holder,
    address _oldDelegatee,
    address _newDelegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatees(_oldDelegatee, _newDelegatee);

    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);
    Staker.DepositIdentifier _oldDepositId = lst.fetchOrInitializeDepositForDelegatee(_oldDelegatee);
    stdstore.target(address(lst)).sig("isOverridden(uint256)").with_key(Staker.DepositIdentifier.unwrap(_newDepositId))
      .checked_write(true);
    _stakeOnDelegateeDeposit(_oldDepositId, _holder);

    _updateDeposit(_holder, _oldDepositId);
    assertEq(lst.delegateeForHolder(_holder), _oldDelegatee);

    uint256 _depositBalance = lst.balanceOf(_holder);
    vm.assertNotEq(_depositBalance, 0);
    vm.expectRevert(GovLst.GovLst__InvalidDeposit.selector);
    _updateDeposit(_holder, _newDepositId);
  }

  function testFuzz_RevertIf_UpdatingFromAnyDelegateeToDepositWithInvalidEarningPower(
    address _holder,
    address _oldDelegatee,
    address _newDelegatee,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatees(_oldDelegatee, _newDelegatee);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);

    Staker.DepositIdentifier _oldDepositId = lst.fetchOrInitializeDepositForDelegatee(_oldDelegatee);
    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);
    _stakeOnDelegateeDeposit(_oldDepositId, _holder);

    _updateDeposit(_holder, _oldDepositId);
    assertEq(lst.delegateeForHolder(_holder), _oldDelegatee);

    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);
    _earningPower =
      _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _newDepositId);

    uint256 _depositBalance = lst.balanceOf(_holder);
    vm.assertNotEq(_depositBalance, 0);
    vm.expectRevert(
      abi.encodeWithSelector(
        GovLst.GovLst__EarningPowerNotQualified.selector, 0, _depositBalance * _minQualifyingEarningPowerBips
      )
    );
    _updateDeposit(_holder, _newDepositId);
  }

  function testFuzz_RevertIf_HolderHasZeroBalanceAndUpdatesToDepositWithZeroBalance(address _holder, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    vm.assume(lst.balanceOf(_holder) == 0);

    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    (uint96 _balance,,,,,,) = staker.deposits(_depositId);
    vm.assertEq(_balance, 0);
    vm.assertFalse(lst.isOverridden(_depositId));

    vm.expectRevert(GovLst.GovLst__InvalidDeposit.selector);
    _updateDeposit(_holder, _depositId);
  }

  function testFuzz_RevertIf_HolderHasZeroBalanceAndUpdatesToAnOverriddenDeposit(
    address _holder,
    address _oldDelegatee,
    address _newDelegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatees(_oldDelegatee, _newDelegatee);

    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);
    Staker.DepositIdentifier _oldDepositId = lst.fetchOrInitializeDepositForDelegatee(_oldDelegatee);
    _stakeOnDelegateeDeposit(_oldDepositId, _holder);
    _stakeOnDelegateeDeposit(_newDepositId, delegateeFunder);
    stdstore.target(address(lst)).sig("isOverridden(uint256)").with_key(Staker.DepositIdentifier.unwrap(_newDepositId))
      .checked_write(true);

    _updateDeposit(_holder, _oldDepositId);
    assertEq(lst.delegateeForHolder(_holder), _oldDelegatee);

    _unstakeOnDelegateeDeposit(_holder);

    (uint96 _balance,,,,,,) = staker.deposits(_oldDepositId);
    vm.assertEq(_balance, 0);
    vm.expectRevert(GovLst.GovLst__InvalidDeposit.selector);
    _updateDeposit(_holder, _newDepositId);
  }

  function testFuzz_RevertIf_HolderHasZeroBalanceAndUpdatesToAnUnqualifiedDeposit(
    address _holder,
    address _oldDelegatee,
    address _newDelegatee,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _tipAmount,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatees(_oldDelegatee, _newDelegatee);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);

    Staker.DepositIdentifier _oldDepositId = lst.fetchOrInitializeDepositForDelegatee(_oldDelegatee);
    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_newDelegatee);
    _stakeOnDelegateeDeposit(_oldDepositId, _holder);
    _stakeOnDelegateeDeposit(_newDepositId, delegateeFunder);

    _updateDeposit(_holder, _oldDepositId);
    assertEq(lst.delegateeForHolder(_holder), _oldDelegatee);

    _unstakeOnDelegateeDeposit(_holder);

    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);
    _earningPower =
      _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _newDepositId);

    (uint96 _balance,,,,,,) = staker.deposits(_oldDepositId);
    vm.assertEq(_balance, 0);
    vm.expectRevert(GovLst.GovLst__InvalidDeposit.selector);
    _updateDeposit(_holder, _newDepositId);
  }
}

contract SubsidizeDeposit is GovLstTest {
  function testFuzz_SubsidizesDepositOwnedByLST(address _subsidizer, uint256 _amount, address _delegatee) public {
    _assumeSafeHolder(_subsidizer);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

    _mintStakeToken(_subsidizer, _amount);

    vm.startPrank(_subsidizer);
    stakeToken.approve(address(lst), _amount);

    vm.expectEmit();
    emit GovLst.DepositSubsidized(_depositId, _amount);

    lst.subsidizeDeposit(_depositId, _amount);
    vm.stopPrank();

    // Check that the deposit balance has increased
    (uint96 _balance,,,,,,) = staker.deposits(_depositId);
    assertEq(_balance, _amount);

    // Check that the LST's total supply and shares haven't changed
    assertEq(lst.totalSupply(), 0);
    assertEq(lst.totalShares(), 0);

    // Check that the subsidizer's balance hasn't changed
    assertEq(lst.balanceOf(_subsidizer), 0);
  }

  function testFuzz_RevertIf_TransferFails(address _subsidizer, uint256 _amount, address _delegatee) public {
    _assumeSafeHolder(_subsidizer);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    Staker.DepositIdentifier _depositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);

    vm.startPrank(_subsidizer);
    stakeToken.approve(address(lst), _amount);

    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientBalance.selector, _subsidizer, stakeToken.balanceOf(_subsidizer), _amount
      )
    );
    lst.subsidizeDeposit(_depositId, _amount);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_StakeMoreToNonOwnedDeposit(
    address _subsidizer,
    uint256 _amount,
    Staker.DepositIdentifier _depositId
  ) public {
    _assumeSafeHolder(_subsidizer);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    vm.assume(Staker.DepositIdentifier.unwrap(_depositId) != 0);

    // Ensure the deposit is not owned by the LST
    (, address _owner,,,,,) = staker.deposits(_depositId);
    vm.assume(_owner != address(lst));

    _mintStakeToken(_subsidizer, _amount);

    vm.startPrank(_subsidizer);
    stakeToken.approve(address(lst), _amount);

    // Mock the STAKE_TOKEN.transferFrom to return true
    vm.mockCall(
      address(stakeToken),
      abi.encodeWithSelector(IERC20.transferFrom.selector, _subsidizer, address(lst), _amount),
      abi.encode(true)
    );

    // Expect revert from Staker when trying to stakeMore to a non-owned deposit
    vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not owner"), address(lst)));
    lst.subsidizeDeposit(_depositId, _amount);
    vm.stopPrank();
  }
}

contract EnactOverride is GovLstTest {
  function testFuzz_OverrideWhenEarningPowerBelowThreshold(
    address _holder,
    address _delegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Set deposit earning power below threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);

    (,,, address _depositDelegatee,,,) = staker.deposits(_depositId);

    assertEq(lst.defaultDelegatee(), _depositDelegatee);
    assertEq(lst.isOverridden(_depositId), true);
  }

  function testFuzz_SendOverriderTipInShares(
    address _holder,
    address _delegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeHolder(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMaxOverrideTip();
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Set deposit earning power below threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    uint256 _oldTotalShares = lst.totalShares();
    uint256 _oldShares = lst.sharesOf(_tipReceiver);
    uint256 _tipShares = _calcFeeShares(_tipAmount);

    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);
    assertWithinOneUnit(_oldShares + _tipShares, lst.sharesOf(_tipReceiver));
    assertWithinOneUnit(_oldTotalShares + _tipShares, lst.totalShares());
  }

  function testFuzz_EmitsOverrideEnactedEvent(
    address _holder,
    address _delegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeHolder(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMaxOverrideTip();
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Set deposit earning power below threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    vm.expectEmit();
    emit GovLst.OverrideEnacted(_depositId, _tipReceiver, _calcFeeShares(_tipAmount));

    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_DefaultDelegateeOverridden(
    address _holder,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount
  ) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, lst.defaultDelegatee());
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _setMaxOverrideTip();

    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(lst.defaultDelegatee());

    vm.expectRevert(GovLst.GovLst__InvalidOverride.selector);
    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_DepositHasZeroBalance(address _holder, address _tipReceiver, uint160 _tipAmount) public {
    vm.assume(_holder != address(0) && _holder != lst.defaultDelegatee());
    _mintUpdateDelegateeAndStake(_holder, 0, _holder);
    _tipAmount = uint160(bound(_tipAmount, 0, maxTip));
    _setMaxOverrideTip();

    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_holder);

    vm.expectRevert(GovLst.GovLst__InvalidOverride.selector);
    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_AlreadyOverridden(
    address _holder,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    address _delegatee,
    uint256 _earningPower,
    uint256 _minQualifyingEarningPowerBips
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _setMaxOverrideTip();
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Make sure earning power is below threshold for first override
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    // Successful override
    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);

    vm.expectRevert(GovLst.GovLst__InvalidOverride.selector);
    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_TipGreaterThanMaxTip(
    address _holder,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_holder);
    _tipAmount = uint160(bound(_tipAmount, maxTip + 1, 10_000_000_000e18));
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _holder);
    _setMaxOverrideTip();

    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_holder);

    vm.expectRevert(GovLst.GovLst__GreaterThanMaxTip.selector);
    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_EarningPowerIsAboveTheQualifiedEarningAmount(
    address _holder,
    address _delegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Make sure earning power is above threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    (uint96 _depositBalance,,,,,,) = staker.deposits(_depositId);
    _earningPower =
      _bumpAboveEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId, _delegatee);

    vm.expectRevert(
      abi.encodeWithSelector(
        GovLst.GovLst__EarningPowerNotQualified.selector,
        _earningPower * 1e4,
        _minQualifyingEarningPowerBips * _depositBalance
      )
    );
    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_EarningPowerIsEqualTheQualifiedEarningAmount(
    address _holder,
    address _delegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    uint256 _minQualifyingEarningPowerBips = 10_000;
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Make sure earning power is above threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    (uint96 _depositBalance,,,,,,) = staker.deposits(_depositId);

    // Earning power should always be equal to balance
    _earningPower = _depositBalance;
    earningPowerCalculator.__setEarningPowerForDelegatee(_delegatee, _earningPower);

    // Force the earning power on the deposit to change
    vm.prank(address(lst));
    staker.stakeMore(_depositId, 0);

    vm.expectRevert(
      abi.encodeWithSelector(
        GovLst.GovLst__EarningPowerNotQualified.selector,
        _earningPower * 1e4,
        _minQualifyingEarningPowerBips * _depositBalance
      )
    );
    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);
  }
}

contract RevokeOverride is GovLstTest {
  function testFuzz_RevokedWhenEarningPowerIsAboveThreshold(
    address _holder,
    address _delegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _setMaxOverrideTip();
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Set deposit earning power below threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _earningPower = _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);

    _earningPower =
      _bumpAboveEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId, _delegatee);

    lst.revokeOverride(_depositId, _delegatee, _tipReceiver, _tipAmount);

    (,,, address _depositDelegatee,,,) = staker.deposits(_depositId);
    assertEq(_delegatee, _depositDelegatee);
    assertEq(lst.isOverridden(_depositId), false);
  }

  function testFuzz_RevokedWhenEarningPowerIsEqualThreshold(
    address _holder,
    address _delegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _setMaxOverrideTip();
    uint256 _minQualifyingEarningPowerBips = 10_000;
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Set deposit earning power below threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _earningPower = _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);

    (uint96 _depositBalance,,,,,,) = staker.deposits(_depositId);

    // Earning power should always be equal to balance
    _earningPower = _depositBalance;
    earningPowerCalculator.__setEarningPowerForDelegatee(_delegatee, _earningPower);

    // Force the earning power on the deposit to change
    vm.prank(address(lst));
    staker.stakeMore(_depositId, 0);

    lst.revokeOverride(_depositId, _delegatee, _tipReceiver, _tipAmount);

    (,,, address _depositDelegatee,,,) = staker.deposits(_depositId);
    assertEq(_delegatee, _depositDelegatee);
    assertEq(lst.isOverridden(_depositId), false);
  }

  function testFuzz_SendOverriderTipInShares(
    address _holder,
    address _delegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeHolder(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMaxOverrideTip();
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Set deposit earning power below threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _earningPower = _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);
    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);

    uint256 _oldTotalShares = lst.totalShares();
    uint256 _oldShares = lst.sharesOf(_tipReceiver);
    uint256 _tipShares = _calcFeeShares(_tipAmount);

    _earningPower =
      _bumpAboveEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId, _delegatee);
    lst.revokeOverride(_depositId, _delegatee, _tipReceiver, _tipAmount);

    assertWithinOneUnit(_oldShares + _tipShares, lst.sharesOf(_tipReceiver));
    assertWithinOneUnit(_oldTotalShares + _tipShares, lst.totalShares());
  }

  function testFuzz_EmitsOverrideRevokedEvent(
    address _holder,
    address _delegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeHolder(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Set deposit earning power below threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _earningPower = _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);
    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);

    _earningPower =
      _bumpAboveEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId, _delegatee);

    vm.expectEmit();
    emit GovLst.OverrideRevoked(_depositId, _tipReceiver, _calcFeeShares(_tipAmount));

    lst.revokeOverride(_depositId, _delegatee, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_EarningPowerIsBelowTheQualifiedEarningAmount(
    address _holder,
    address _delegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Make sure earning power is above threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    (uint96 _depositBalance,,,,,,) = staker.deposits(_depositId);
    uint256 _minQualifyingEarningPower = (_minQualifyingEarningPowerBips * _depositBalance) / 1e4;
    _earningPower = bound(_earningPower, 0, _minQualifyingEarningPower - 1);
    earningPowerCalculator.__setEarningPowerForDelegatee(_delegatee, _earningPower);

    // Force the earning power on the deposit to change
    vm.prank(address(lst));
    staker.stakeMore(_depositId, 0);

    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);

    vm.expectRevert(
      abi.encodeWithSelector(
        GovLst.GovLst__EarningPowerNotQualified.selector,
        _earningPower * 1e4,
        _minQualifyingEarningPowerBips * _depositBalance
      )
    );
    lst.revokeOverride(_depositId, _delegatee, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_DepositHasZeroBalance(
    address _holder,
    uint256 _amount,
    uint256 _minQualifyingEarningPowerBips,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _holder);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_holder);
    _earningPower = _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);
    lst.enactOverride(_depositId, _tipReceiver, 0);

    _earningPower =
      _bumpAboveEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId, _holder);

    vm.prank(_holder);
    lst.unstake(_amount);

    vm.expectRevert(GovLst.GovLst__InvalidOverride.selector);
    lst.revokeOverride(_depositId, _holder, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_NotSameAsOriginalDelegatee(
    address _holder,
    address _delegatee,
    uint256 _amount,
    uint256 _minQualifyingEarningPowerBips,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _earningPower
  ) public {
    vm.assume(_holder != _delegatee);
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _holder);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_holder);
    _earningPower = _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    lst.enactOverride(_depositId, _tipReceiver, 0);

    _earningPower =
      _bumpAboveEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId, _holder);

    vm.expectRevert(GovLst.GovLst__InvalidOverride.selector);
    lst.revokeOverride(_depositId, _delegatee, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_TipGreaterThanMaxTip(
    address _holder,
    uint256 _amount,
    uint256 _minQualifyingEarningPowerBips,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_holder);
    _tipAmount = uint160(bound(_tipAmount, maxTip + 1, 10_000_000_000e18));
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _holder);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_holder);
    _earningPower = _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    lst.enactOverride(_depositId, _tipReceiver, 0);

    _earningPower =
      _bumpAboveEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId, _holder);

    vm.expectRevert(GovLst.GovLst__GreaterThanMaxTip.selector);
    lst.revokeOverride(_depositId, _holder, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_IsNotOverridden(address _holder, uint256 _amount, address _tipReceiver, uint160 _tipAmount)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_holder);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _holder);
    _setMaxOverrideTip();

    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_holder);

    vm.expectRevert(GovLst.GovLst__InvalidOverride.selector);
    lst.revokeOverride(_depositId, _holder, _tipReceiver, _tipAmount);
  }
}

contract MigrateOverride is GovLstTest {
  function testFuzz_MigrateOverrideWhenDefaultDelegateeChanges(
    address _holder,
    address _delegatee,
    address _newDefaultDelegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _assumeSafeHolder(_newDefaultDelegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Set deposit earning power below threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);

    vm.prank(lstOwner);
    lst.setDefaultDelegatee(_newDefaultDelegatee);

    lst.migrateOverride(_depositId, _tipReceiver, _tipAmount);

    assertEq(lst.defaultDelegatee(), _newDefaultDelegatee);
    assertEq(lst.isOverridden(_depositId), true);
  }

  function testFuzz_SendMigratorTipInShares(
    address _holder,
    address _delegatee,
    address _newDefaultDelegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeHolder(_delegatee);
    _assumeSafeHolder(_newDefaultDelegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMaxOverrideTip();
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Set deposit earning power below threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);

    vm.prank(lstOwner);
    lst.setDefaultDelegatee(_newDefaultDelegatee);

    uint256 _oldTotalShares = lst.totalShares();
    uint256 _oldShares = lst.sharesOf(_tipReceiver);
    uint256 _tipShares = _calcFeeShares(_tipAmount);

    lst.migrateOverride(_depositId, _tipReceiver, _tipAmount);

    assertWithinOneUnit(_oldShares + _tipShares, lst.sharesOf(_tipReceiver));
    assertWithinOneUnit(_oldTotalShares + _tipShares, lst.totalShares());
  }

  function testFuzz_EmitsOverrideEnactedEvent(
    address _holder,
    address _delegatee,
    address _newDefaultDelegatee,
    uint256 _amount,
    address _tipReceiver,
    uint160 _tipAmount,
    uint256 _minQualifyingEarningPowerBips,
    uint256 _earningPower
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeHolder(_delegatee);
    _assumeSafeHolder(_newDefaultDelegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _tipAmount = _boundToValidTipAmount(_tipAmount);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 20_000);
    _setMaxOverrideTip();
    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    // Set deposit earning power below threshold
    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_delegatee);
    _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    lst.enactOverride(_depositId, _tipReceiver, _tipAmount);
    address _currentDelegatee = lst.defaultDelegatee();

    vm.prank(lstOwner);
    lst.setDefaultDelegatee(_newDefaultDelegatee);

    vm.expectEmit();
    emit GovLst.OverrideMigrated(
      _depositId, _currentDelegatee, _newDefaultDelegatee, _tipReceiver, _calcFeeShares(_tipAmount)
    );

    lst.migrateOverride(_depositId, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_IsNotOverridden(address _holder, uint256 _amount, address _tipReceiver, uint160 _tipAmount)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_holder);
    _tipAmount = uint160(bound(_tipAmount, 0, maxTip));
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _holder);
    _setMaxOverrideTip();

    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_holder);

    vm.expectRevert(GovLst.GovLst__InvalidOverride.selector);
    lst.migrateOverride(_depositId, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_IsTheCurrentDefaultDelegatee(
    address _holder,
    uint256 _amount,
    uint256 _earningPower,
    uint256 _minQualifyingEarningPowerBips,
    address _tipReceiver,
    uint160 _tipAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_holder);
    _tipAmount = uint160(bound(_tipAmount, 0, maxTip));
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _holder);
    _setMaxOverrideTip();
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 1, 10_000);
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_holder);

    _bumpBelowEarningPowerQualifyingThreshold(_earningPower, _minQualifyingEarningPowerBips, _depositId);

    lst.enactOverride(_depositId, _tipReceiver, 0);

    vm.expectRevert(GovLst.GovLst__InvalidOverride.selector);
    lst.migrateOverride(_depositId, _tipReceiver, _tipAmount);
  }

  function testFuzz_RevertIf_TipGreaterThanMaxTip(
    address _holder,
    uint256 _amount,
    uint256 _minQualifyingEarningPowerBips,
    address _tipReceiver,
    uint160 _tipAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_holder);
    _tipAmount = uint160(bound(_tipAmount, maxTip + 1, 10_000_000_000e18));
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintUpdateDelegateeAndStake(_holder, _amount, _holder);
    _minQualifyingEarningPowerBips = bound(_minQualifyingEarningPowerBips, 0, 10_000);
    _setMaxOverrideTip();
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);

    Staker.DepositIdentifier _depositId = lst.depositForDelegatee(_holder);

    vm.expectRevert(GovLst.GovLst__GreaterThanMaxTip.selector);
    lst.migrateOverride(_depositId, _tipReceiver, _tipAmount);
  }
}

contract UpdateDepositOnBehalf is GovLstTest {
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

    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeDeposit(_newDepositId, delegateeFunder);

    uint256 _nonce = lst.nonces(_staker);

    bytes memory signature = _signMessage(
      lst.UPDATE_DEPOSIT_TYPEHASH(),
      _staker,
      Staker.DepositIdentifier.unwrap(_newDepositId),
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

    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeDeposit(_newDepositId, delegateeFunder);

    uint256 _nonce = lst.nonces(_staker);

    bytes memory signature = _signMessage(
      lst.UPDATE_DEPOSIT_TYPEHASH(),
      _staker,
      Staker.DepositIdentifier.unwrap(_newDepositId),
      _nonce,
      _expiry,
      _stakerPrivateKey
    );

    vm.expectEmit();
    emit GovLst.DepositUpdated(_staker, Staker.DepositIdentifier.wrap(1), _newDepositId);

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

    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeDeposit(_newDepositId, delegateeFunder);

    uint256 _nonce = lst.nonces(_staker);

    bytes memory _invalidSignature = new bytes(65);

    vm.prank(_sender);
    vm.expectRevert(GovLst.GovLst__InvalidSignature.selector);
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

    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    uint256 _nonce = lst.nonces(_staker);

    bytes memory signature = _signMessage(
      lst.UPDATE_DEPOSIT_TYPEHASH(),
      _staker,
      Staker.DepositIdentifier.unwrap(_newDepositId),
      _nonce,
      _expiry,
      _stakerPrivateKey
    );

    vm.prank(_sender);
    vm.expectRevert(GovLst.GovLst__SignatureExpired.selector);
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

    Staker.DepositIdentifier _newDepositId = lst.fetchOrInitializeDepositForDelegatee(_delegatee);
    _stakeOnDelegateeDeposit(_newDepositId, delegateeFunder);

    uint256 _nonce = lst.nonces(_staker);

    bytes memory signature = _signMessage(
      lst.UPDATE_DEPOSIT_TYPEHASH(),
      _staker,
      Staker.DepositIdentifier.unwrap(_newDepositId),
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

contract Stake is GovLstTest {
  function testFuzz_RecordsTheDepositIdAssociatedWithTheDelegatee(uint256 _amount, address _holder, address _delegatee)
    public
  {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    _mintStakeToken(_holder, _amount);

    _updateDelegateeAndStake(_holder, _amount, _delegatee);

    assertTrue(Staker.DepositIdentifier.unwrap(lst.depositForDelegatee(_delegatee)) != 0);
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

  function testFuzz_ReturnedValueMatchesBalanceDelta(uint256 _amount, address _holder, address _delegatee) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintStakeToken(_holder, _amount);
    _updateDelegatee(_holder, _delegatee);

    uint256 _oldBalance = lst.balanceOf(_holder);
    uint256 _balanceDelta = _stake(_holder, _amount);

    assertEq(lst.balanceOf(_holder) - _oldBalance, _balanceDelta);
  }

  function testFuzz_DelegatesToTheDefaultDelegateeIfTheHolderHasNotSetADelegate(uint256 _amount, address _holder)
    public
  {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_holder, _amount);

    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _amount);
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

    assertEq(ERC20Votes(address(stakeToken)).getVotes(_delegatee), _amount);
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
    uint80 _rewardAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount1 = _boundToReasonableStakeTokenAmount(_amount1);
    _amount2 = _boundToReasonableStakeTokenAmount(_amount2);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _amount1, _delegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(address(_holder)));
    _mintAndStake(_holder, _amount2);

    assertLteWithinOneUnit(lst.balanceCheckpoint(_holder), _amount1 + _amount2);
  }

  function testFuzz_EmitsStakedEvent(uint256 _amount, address _holder) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintStakeToken(_holder, _amount);

    vm.startPrank(_holder);
    stakeToken.approve(address(lst), _amount);

    vm.expectEmit();
    emit GovLst.Staked(_holder, _amount);

    lst.stake(_amount);
    vm.stopPrank();
  }

  function testFuzz_EmitsTransferEvent(uint256 _amount, address _holder) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintStakeToken(_holder, _amount);

    vm.startPrank(_holder);
    stakeToken.approve(address(lst), _amount);

    vm.expectEmit();
    emit IERC20.Transfer(address(0), _holder, _amount);

    lst.stake(_amount);
    vm.stopPrank();
  }
}

contract StakeWithAttribution is GovLstTest {
  function testFuzz_IncreasesANewHoldersBalanceByTheAmountStaked(
    uint256 _amount,
    address _holder,
    address _delegatee,
    address _referrer
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintUpdateDelegateeAndStakeWithAttribution(_holder, _amount, _delegatee, _referrer);

    assertEq(lst.balanceOf(_holder), _amount);
  }

  function testFuzz_EmitsStakedWithAttributionEvent(uint256 _amount, address _holder, address _referrer) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintStakeToken(_holder, _amount);

    vm.startPrank(_holder);
    stakeToken.approve(address(lst), _amount);
    vm.expectEmit();
    emit GovLst.StakedWithAttribution(lst.DEFAULT_DEPOSIT_ID(), _amount, _referrer);
    lst.stakeWithAttribution(_amount, _referrer);
    vm.stopPrank();

    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _amount);
  }

  function testFuzz_EmitsAStakedEvent(uint256 _amount, address _holder, address _referrer) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintStakeToken(_holder, _amount);

    vm.startPrank(_holder);
    stakeToken.approve(address(lst), _amount);
    vm.expectEmit();
    emit GovLst.Staked(_holder, _amount);
    lst.stakeWithAttribution(_amount, _referrer);
    vm.stopPrank();

    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _amount);
  }
}

contract Unstake is GovLstTest {
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

    assertEq(stakeToken.balanceOf(address(withdrawGate)), _unstakeAmount);
  }

  function testFuzz_InitiatesWithdrawalOnTheWithdrawGate(
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
    uint256 _withdrawId = withdrawGate.getNextWithdrawalId();
    _unstake(_holder, _unstakeAmount);
    (address _receiver, uint256 _amount,) = withdrawGate.withdrawals(_withdrawId);

    assertEq(_amount, _unstakeAmount);
    assertEq(_receiver, _holder);
  }

  function testFuzz_TransfersToHolderIfWithdrawDelayIsSetToZero(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);
    vm.prank(lstOwner);
    withdrawGate.setDelay(0);
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _unstake(_holder, _unstakeAmount);

    assertEq(stakeToken.balanceOf(_holder), _unstakeAmount);
  }

  function testFuzz_ReturnValueMatchesAmount(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    vm.prank(lstOwner);
    withdrawGate.setDelay(0);
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);

    uint256 _oldBalance = lst.balanceOf(_holder);
    vm.prank(_holder);
    uint256 _unstakedAmountDelta = lst.unstake(_unstakeAmount);

    assertEq(_oldBalance - lst.balanceOf(_holder), _unstakedAmountDelta);
  }

  function testFuzz_AllowsAHolderToWithdrawBalanceThatIncludesEarnedRewards(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    // One holder stakes and earns the full reward amount
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));
    _unstake(_holder, _unstakeAmount);

    assertEq(stakeToken.balanceOf(address(withdrawGate)), _unstakeAmount);
  }

  function testFuzz_WithdrawsFromUndelegatedBalanceIfItCoversTheAmount(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    // The unstake amount is _less_ than the reward amount.
    _unstakeAmount = bound(_unstakeAmount, 0, _rewardAmount);

    // One holder stakes and earns the full reward amount
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));
    _unstake(_holder, _unstakeAmount);

    // Default delegatee has lost the unstake amount
    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _rewardAmount - _unstakeAmount);
    // Delegatee balance is untouched and therefore still exactly the original amount
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_delegatee), _stakeAmount);
    // The amount actually equal to the amount requested
    assertEq(stakeToken.balanceOf(address(withdrawGate)), _unstakeAmount);
  }

  function testFuzz_WithdrawsFromDelegatedBalanceAfterExhaustingUndelegatedBalance(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    // The unstake amount is _more_ than the reward amount.
    _unstakeAmount = bound(_unstakeAmount, _rewardAmount, _stakeAmount + _rewardAmount);

    // One holder stakes and earns the full reward amount
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));
    _unstake(_holder, _unstakeAmount);

    assertApproxEqAbs(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), 0, 1);
    assertApproxEqAbs(
      ERC20Votes(address(stakeToken)).getVotes(_delegatee), _stakeAmount + _rewardAmount - _unstakeAmount, 1
    );
    assertGe(ERC20Votes(address(stakeToken)).getVotes(_delegatee), _stakeAmount + _rewardAmount - _unstakeAmount);
    assertApproxEqAbs(stakeToken.balanceOf(address(withdrawGate)), _unstakeAmount, 1);
    assertLe(stakeToken.balanceOf(address(withdrawGate)), _unstakeAmount);
  }

  function testFuzz_RemovesUnstakedAmountFromHoldersBalance(
    uint256 _stakeAmount,
    address _holder,
    address _delegatee,
    uint256 _unstakeAmount,
    uint80 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));
    _unstake(_holder, _unstakeAmount);

    // The holder's lst balance decreases by the amount unstaked, within some tolerance to allow for truncation.
    assertApproxEqAbs(lst.balanceOf(_holder), _stakeAmount + _rewardAmount - _unstakeAmount, 1);
    assertLe(lst.balanceOf(_holder), _stakeAmount + _rewardAmount - _unstakeAmount);
  }

  function testFuzz_RemovesUnstakedAmountFromHoldersBalanceWithExpectedRoundingError(
    uint256 _stakeAmount,
    address _holder,
    address _delegatee,
    uint256 _unstakeAmount,
    uint80 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    // In this version of the test, we ensure that the amount staked is more than the rewards distributed. This
    // establishes that the total supply divided by the total shares is less than 1, in which case, we can expect the
    // difference due to rounding to be 1 or less.
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _stakeAmount = bound(_stakeAmount, _rewardAmount, 2_000_000_000e18);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));
    _unstake(_holder, _unstakeAmount);

    // Because we bound the reward to be less than the amount stake, we know the max rounding error is 1 wei.
    assertApproxEqAbs(lst.balanceOf(_holder), _stakeAmount + _rewardAmount - _unstakeAmount, 1);
    assertLe(lst.balanceOf(_holder), _stakeAmount + _rewardAmount - _unstakeAmount);
  }

  function testFuzz_SubtractsFromTheHoldersDelegatedBalanceCheckpointIfUndelegatedBalanceIsUnstaked(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _unstakeAmount,
    address _holder,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    // The unstake amount is _more_ than the reward amount.
    _unstakeAmount = bound(_unstakeAmount, _rewardAmount, _stakeAmount + _rewardAmount);

    // One holder stakes and earns the full reward amount
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));
    _unstake(_holder, _unstakeAmount);

    // Because the full undelegated balance was unstaked, whatever balance the holder has left must be reflected in
    // their delegated balance checkpoint. However, it's also possible that, because global shares are destroyed
    // after the user's shares are destroyed, truncation may cause the user's balance to go up slightly from the
    // calculated balance checkpoint. This is fine, as long as the system is remaining solvent, that is, the extra
    // 1 wei are actually being left in the default deposit as they should be. We also assert this here to ensure it
    // is the case.
    assertApproxEqAbs(lst.balanceCheckpoint(_holder), lst.balanceOf(_holder), 1);
    assertLe(lst.balanceCheckpoint(_holder), lst.balanceOf(_holder));
    (uint96 _defaultDepositBalance,,,,,,) = staker.deposits(lst.DEFAULT_DEPOSIT_ID());
    assertEq(_defaultDepositBalance, lst.balanceOf(_holder) - lst.balanceCheckpoint(_holder));
  }

  function testFuzz_SubtractsTheRealAmountUnstakedFromTheTotalSupply(
    uint256 _stakeAmount,
    address _holder,
    address _delegatee,
    uint256 _unstakeAmount,
    uint80 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));

    // Record the total supply before unstaking
    uint256 _initialTotalSupply = lst.totalSupply();
    // Perform the unstaking
    uint256 _amountUnstaked = _unstake(_holder, _unstakeAmount);

    uint256 _totalSupplyDiff = _initialTotalSupply - lst.totalSupply();
    assertEq(_totalSupplyDiff, _amountUnstaked);
  }

  function testFuzz_SubtractsTheEquivalentSharesForTheAmountFromTheTotalShares(
    uint256 _stakeAmount,
    address _holder,
    address _delegatee,
    uint256 _unstakeAmount,
    uint80 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));

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
    vm.expectRevert(GovLst.GovLst__InsufficientBalance.selector);
    lst.unstake(_stakeAmount + 1);
  }

  function testFuzz_EmitsUnstakedEvent(uint256 _stakeAmount, uint256 _unstakeAmount, address _holder) public {
    _assumeSafeHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    _mintAndStake(_holder, _stakeAmount);

    // Expect the event to be emitted
    vm.expectEmit();
    emit GovLst.Unstaked(_holder, _unstakeAmount);

    vm.prank(_holder);
    lst.unstake(_unstakeAmount);
  }

  function testFuzz_EmitsTransferEvent(uint256 _stakeAmount, uint256 _unstakeAmount, address _holder) public {
    _assumeSafeHolder(_holder);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount);

    _mintAndStake(_holder, _stakeAmount);

    // Expect the event to be emitted
    vm.expectEmit();
    emit IERC20.Transfer(_holder, address(0), _unstakeAmount);

    vm.prank(_holder);
    lst.unstake(_unstakeAmount);
  }
}

contract PermitAndStake is GovLstTest {
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
    bytes32 _message =
      keccak256(abi.encode(PERMIT_TYPEHASH, _depositor, address(lst), _stakeAmount, _currentNonce, _deadline));

    bytes32 _messageHash = _hashTypedDataV4(
      EIP712_DOMAIN_TYPEHASH, _message, bytes(ERC20Votes(address(stakeToken)).name()), "1", address(stakeToken)
    );
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
        PERMIT_TYPEHASH,
        _depositor,
        address(lst),
        _stakeAmount,
        ERC20Permit(address(stakeToken)).nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash = _hashTypedDataV4(
      EIP712_DOMAIN_TYPEHASH, _message, bytes(ERC20Permit(address(stakeToken)).name()), "1", address(stakeToken)
    );
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    lst.permitAndStake(_stakeAmount, _deadline, _v, _r, _s);

    assertEq(lst.balanceOf(_depositor), _stakeAmount);
  }

  function testFuzz_EmitsAStakedEvent(
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
        PERMIT_TYPEHASH,
        _depositor,
        address(lst),
        _stakeAmount,
        ERC20Permit(address(stakeToken)).nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash = _hashTypedDataV4(
      EIP712_DOMAIN_TYPEHASH, _message, bytes(ERC20Permit(address(stakeToken)).name()), "1", address(stakeToken)
    );
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);

    vm.prank(_depositor);
    vm.expectEmit();
    emit GovLst.Staked(_depositor, _stakeAmount);
    lst.permitAndStake(_stakeAmount, _deadline, _v, _r, _s);
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
        PERMIT_TYPEHASH,
        _notDepositor,
        address(lst),
        _stakeAmount,
        ERC20Permit(address(stakeToken)).nonces(_depositor),
        _deadline
      )
    );

    bytes32 _messageHash = _hashTypedDataV4(
      EIP712_DOMAIN_TYPEHASH, _message, bytes(ERC20Permit(address(stakeToken)).name()), "1", address(stakeToken)
    );
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_depositorPrivateKey, _messageHash);
    _notDepositor = _notDepositor;

    vm.prank(_depositor);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector,
        address(lst),
        lst.allowance(_depositor, address(lst)),
        _stakeAmount
      )
    );
    lst.permitAndStake(_stakeAmount, _deadline, _v, _r, _s);
  }
}

contract StakeOnBehalf is GovLstTest {
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

  function testFuzz_EmitsAStakedEvent(
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
    vm.expectEmit();
    emit GovLst.Staked(_staker, _amount);
    lst.stakeOnBehalf(_staker, _amount, _nonce, _expiry, signature);
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
    vm.expectRevert(GovLst.GovLst__InvalidSignature.selector);
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
    vm.expectRevert(GovLst.GovLst__SignatureExpired.selector);
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

contract UnstakeOnBehalf is GovLstTest {
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
    assertEq(stakeToken.balanceOf(address(withdrawGate)), _amount);
  }

  function testFuzz_EmitsAnUnstakedEvent(
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
    vm.expectEmit();
    emit GovLst.Unstaked(_staker, _amount);
    lst.unstakeOnBehalf(_staker, _amount, lst.nonces(_staker), _expiry, signature);
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
    vm.expectRevert(GovLst.GovLst__InvalidSignature.selector);
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
    vm.expectRevert(GovLst.GovLst__SignatureExpired.selector);
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

contract Approve is GovLstTest {
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

contract BalanceOf is GovLstTest {
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
    uint80 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));

    // Since there is only one LST holder, they should own the whole balance of the LST, both the tokens they staked
    // and the tokens distributed as rewards.
    assertEq(lst.balanceOf(_holder), _stakeAmount + _rewardAmount);
  }

  function testFuzz_CalculatesTheCorrectBalanceWhenTwoUsersStakeBeforeARewardIsDistributed(
    uint256 _stakeAmount1,
    address _holder1,
    address _holder2,
    uint80 _rewardAmount,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    // The second user will stake 150% of the first user
    uint256 _stakeAmount2 = _percentOf(_stakeAmount1, 150);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    // Both users stake
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee2);
    // A reward is distributed
    Staker.DepositIdentifier _depositId2 = lst.depositIdForHolder(_holder2);
    _distributeReward(_rewardAmount, _depositId2, 40);

    // Because the first user staked 40% of the test token, they should have earned 40% of rewards
    assertWithinOneBip(lst.balanceOf(_holder1), _stakeAmount1 + _percentOf(_rewardAmount, 40));
    // Because the second user staked 60% of the test token, they should have earned 60% of rewards
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
    uint80 _rewardAmount,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);

    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    _stakeAmount2 = _boundToReasonableStakeTokenAmount(_stakeAmount2);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    // The first user stakes
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);
    // A reward is distributed
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder1));
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
    uint80 _rewardAmount1,
    uint80 _rewardAmount2,
    address _delegatee1,
    address _delegatee2
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeDelegatees(_delegatee1, _delegatee2);
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    // second user will stake 250% of first user
    _stakeAmount2 = _percentOf(_stakeAmount1, 250);
    // the first reward will be 25 percent of the first holders stake amount
    _rewardAmount1 = _boundToReasonableStakeTokenReward(_percentOf(_stakeAmount1, 25));
    _rewardAmount2 = _boundToReasonableStakeTokenReward(
      bound(_rewardAmount2, _percentOf(_stakeAmount1, 5), _percentOf(_stakeAmount1, 150))
    );

    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _delegatee1);

    _distributeReward(_rewardAmount1, lst.depositIdForHolder(_holder1));

    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _delegatee2);

    // The second user stakes
    Staker.DepositIdentifier _depositId2 = lst.depositIdForHolder(_holder2);
    _distributeReward(_rewardAmount2, _depositId2, 66);

    // The first holder received all of the first reward and ~33% of the second reward
    uint256 _holder1ExpectedBalance = _stakeAmount1 + _rewardAmount1 + _percentOf(_rewardAmount2, 33);
    // The second holder received ~67% of the second reward
    uint256 _holder2ExpectedBalance = _stakeAmount2 + _percentOf(_rewardAmount2, 67);

    assertWithinOnePercent(lst.balanceOf(_holder1), _holder1ExpectedBalance);
    assertWithinOnePercent(lst.balanceOf(_holder2), _holder2ExpectedBalance);

    // Invariant: Sum of balanceOf should always be less than or equal to total stake + rewards
    assertLteWithinOneBip(
      lst.balanceOf(_holder1) + lst.balanceOf(_holder2), _holder1ExpectedBalance + _holder2ExpectedBalance
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
    uint80 _rewardAmount
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _unstakeAmount = bound(_unstakeAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_holder, _stakeAmount, _delegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_holder));

    _unstake(_holder, _unstakeAmount);

    assertApproxEqAbs(lst.balanceOf(_holder), _stakeAmount + _rewardAmount - _unstakeAmount, 1);
  }

  function testFuzz_CalculatesTheCorrectBalancesOfAHolderAndFeeCollectorWhenARewardDistributionIncludesAFee(
    address _claimer,
    address _recipient,
    uint256 _rewardTokenAmount,
    uint80 _rewardPayoutAmount,
    address _holder,
    uint256 _stakeAmount,
    address _feeCollector,
    uint16 _feeBips
  ) public {
    // Apply constraints to parameters.
    _assumeSafeHolders(_holder, _claimer);
    _assumeSafeHolder(_feeCollector);
    vm.assume(_feeCollector != address(0) && _feeCollector != _holder && _feeCollector != _claimer);
    _rewardTokenAmount = _boundToReasonableRewardTokenAmount(_rewardTokenAmount);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _rewardPayoutAmount = _boundToReasonableStakeTokenReward(_rewardPayoutAmount);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    // Set up actors to enable reward distribution with fees.
    _setRewardParameters(_rewardPayoutAmount, _feeBips, _feeCollector);
    _mintStakeToken(_claimer, _rewardPayoutAmount);
    _mintAndStake(_holder, _stakeAmount);

    // Execute reward distribution that includes a fee payout.
    _approveLstAndClaimAndDistributeReward(_claimer, _rewardTokenAmount, _recipient, lst.depositIdForHolder(_holder));

    uint256 _feeAmount = (uint256(_rewardPayoutAmount) * uint256(_feeBips)) / 1e4;

    // Fee collector should now have a balance less than or equal to, within a small delta to account for truncation,
    // the fee amount.
    assertApproxEqAbs(lst.balanceOf(_feeCollector), _feeAmount, 1);
    assertTrue(lst.balanceOf(_feeCollector) <= _feeAmount);
    // The holder should have earned all the rewards except the fee amount, which went to the fee collector.
    assertApproxEqAbs(lst.balanceOf(_holder), _stakeAmount + _rewardPayoutAmount - _feeAmount, 1);
  }
}

contract TransferFrom is GovLstTest {
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

  function testFuzz_EmitsATransferEvent(uint256 _amount, address _caller, address _sender, address _receiver) public {
    _assumeSafeHolders(_sender, _receiver);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_sender, _amount);

    vm.prank(_sender);
    lst.approve(_caller, _amount);

    vm.prank(_caller);
    vm.expectEmit();
    emit IERC20.Transfer(_sender, _receiver, _amount);
    lst.transferFrom(_sender, _receiver, _amount);
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

contract Transfer is GovLstTest {
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
    uint80 _rewardAmount,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    _mintAndStake(_sender, _stakeAmount);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender));
    // As the only staker, the sender's balance should be the stake and rewards
    vm.prank(_sender);
    lst.transfer(_receiver, _stakeAmount + _rewardAmount);

    assertEq(lst.balanceOf(_sender), 0);
    assertEq(lst.balanceOf(_receiver), _stakeAmount + _rewardAmount);
  }

  function testFuzz_MovesPartialBalanceToAReceiverWhenBalanceOfSenderIncludesEarnedRewards(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount + _rewardAmount);

    _mintAndStake(_sender, _stakeAmount);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender));

    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // The sender should have the full balance of his stake and the reward, minus what was sent.
    uint256 _expectedSenderBalance = _stakeAmount + _rewardAmount - _sendAmount;

    assertApproxEqAbs(_expectedSenderBalance, lst.balanceOf(_sender), 1);
    assertLe(lst.balanceOf(_sender), _expectedSenderBalance);
    assertEq(lst.balanceOf(_receiver), _sendAmount);
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
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_senderDelegatee), _stakeAmount - _sendAmount);
    assertEq(lst.balanceOf(_receiver), _sendAmount);
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_receiverDelegatee), _sendAmount);
  }

  function testFuzz_MovesFullVotingWeightToTheReceiversDelegateeWhenBalanceOfSenderIncludesEarnedRewards(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _updateDelegatee(_receiver, _receiverDelegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender));
    vm.prank(_sender);
    lst.transfer(_receiver, _stakeAmount + _rewardAmount); // As the only staker, sender has all rewards

    assertEq(lst.balanceOf(_sender), 0);
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_senderDelegatee), 0);
    assertEq(lst.balanceOf(_receiver), _stakeAmount + _rewardAmount);
    assertEq(ERC20Votes(address(stakeToken)).getVotes(_receiverDelegatee), _stakeAmount + _rewardAmount);
  }

  function testFuzz_MovesPartialVotingWeightToTheReceiversDelegateeWhenBalanceOfSenderIncludesRewards(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _updateDelegatee(_receiver, _receiverDelegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender));
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    uint256 _expectedSenderBalance = _stakeAmount + _rewardAmount - _sendAmount;

    // Truncation may cause the sender's balance to decrease more than amount requested.
    assertApproxEqAbs(_expectedSenderBalance, lst.balanceOf(_sender), 1);
    assertLe(lst.balanceOf(_sender), _expectedSenderBalance);
    assertEq(lst.balanceOf(_receiver), _sendAmount);

    // It's important the balances are less than the votes, since the votes represent the "real" underlying tokens,
    // and balances being below the real tokens available means the rounding favors the protocol, which is desired.
    assertLteWithinOneUnit(
      lst.balanceOf(_sender),
      ERC20Votes(address(stakeToken)).getVotes(_senderDelegatee)
        + ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee)
    );
    assertLteWithinOneUnit(lst.balanceOf(_receiver), ERC20Votes(address(stakeToken)).getVotes(_receiverDelegatee));
  }

  function testFuzz_LeavesTheSendersDelegatedBalanceUntouchedIfTheSendAmountIsLessThanTheSendersUndelegatedBalance(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    // The amount sent will be less than or equal to the rewards the sender has earned
    _sendAmount = bound(_sendAmount, 0, _rewardAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _updateDelegatee(_receiver, _receiverDelegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender));
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // The sender's delegated balance checkpoint may have dropped by, at most, 1 wei since the original staked amount.
    assertApproxEqAbs(lst.balanceCheckpoint(_sender), _stakeAmount, 1);
    assertLe(lst.balanceCheckpoint(_sender), _stakeAmount);
    // It's important the delegated checkpoint is less than the votes, since the votes represent the "real" tokens.
    assertLe(lst.balanceCheckpoint(_sender), ERC20Votes(address(stakeToken)).getVotes(_senderDelegatee));
  }

  function testFuzz_PullsFromTheSendersDelegatedBalanceAfterTheUndelegatedBalanceHasBeenExhausted(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    // The amount sent will be more than the original stake amount
    _sendAmount = bound(_sendAmount, _rewardAmount, _rewardAmount + _stakeAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _updateDelegatee(_receiver, _receiverDelegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender));
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // The sender's delegated balance is now equal to his balance, because his full undelegated balance (and then some)
    // has been used to complete the transfer.
    assertEq(lst.balanceCheckpoint(_sender), lst.balanceOf(_sender));
    // It's important the delegated checkpoint is less than the votes, since the votes represent the "real" tokens.
    assertApproxEqAbs(lst.balanceCheckpoint(_sender), ERC20Votes(address(stakeToken)).getVotes(_senderDelegatee), 1);
    assertLe(lst.balanceCheckpoint(_sender), ERC20Votes(address(stakeToken)).getVotes(_senderDelegatee));
  }

  function testFuzz_AddsToTheBalanceCheckpointOfTheReceiverAndVotingWeightOfReceiversDelegatee(
    uint256 _stakeAmount1,
    uint80 _rewardAmount,
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
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    // Both users stake
    _mintUpdateDelegateeAndStake(_sender, _stakeAmount1, _senderDelegatee);
    _mintUpdateDelegateeAndStake(_receiver, _stakeAmount2, _receiverDelegatee);
    // A reward is distributed
    Staker.DepositIdentifier _depositId2 = lst.depositIdForHolder(_sender);
    _distributeReward(_rewardAmount, _depositId2, 39);

    // The send amount must be less than the sender's balance after the reward distribution
    _sendAmount = bound(_sendAmount, 0, lst.balanceOf(_sender));

    // The sender transfers to the receiver
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // The receiver's original stake and the tokens sent to him are staked to his designated delegatee
    assertLteWithinOneBip(lst.balanceCheckpoint(_receiver), _stakeAmount2 + _sendAmount);
    assertLteWithinOneBip(ERC20Votes(address(stakeToken)).getVotes(_receiverDelegatee), _stakeAmount2 + _sendAmount);
    // It's important the delegated checkpoint is less than the votes, since the votes represent the "real" tokens.
    assertLteWithinOneBip(
      lst.balanceCheckpoint(_receiver), ERC20Votes(address(stakeToken)).getVotes(_receiverDelegatee)
    );

    // Invariant: Sum of balanceOf should always be less than or equal to total stake + rewards
    assertLteWithinOneBip(
      lst.balanceOf(_sender) + lst.balanceOf(_receiver), _stakeAmount1 + _stakeAmount2 + _rewardAmount
    );

    // Invariant: Total voting weight across delegatees equals the total tokens in the system
    assertEq(
      ERC20Votes(address(stakeToken)).getVotes(_senderDelegatee)
        + ERC20Votes(address(stakeToken)).getVotes(_receiverDelegatee)
        + ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee),
      _stakeAmount1 + _stakeAmount2 + _rewardAmount
    );
  }

  function testFuzz_MovesPartialVotingWeightToTheReceiversDelegateeWhenBothBalancesIncludeRewards(
    uint256 _stakeAmount1,
    uint80 _rewardAmount,
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
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    // Both users stake
    _mintUpdateDelegateeAndStake(_sender, _stakeAmount1, _senderDelegatee);
    _mintUpdateDelegateeAndStake(_receiver, _stakeAmount2, _receiverDelegatee);
    // A reward is distributed
    Staker.DepositIdentifier _depositId2 = lst.depositIdForHolder(_sender);
    _distributeReward(_rewardAmount, _depositId2, 39);

    // The send amount must be less than the sender's balance after the reward distribution
    _sendAmount = bound(_sendAmount, 0, lst.balanceOf(_sender));

    // The sender transfers to the receiver
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);

    // The receiver's checkpoint should be incremented by the amount sent.
    assertApproxEqAbs(lst.balanceCheckpoint(_receiver), _stakeAmount2 + _sendAmount, 1);
    assertLe(lst.balanceCheckpoint(_receiver), _stakeAmount2 + _sendAmount);
    assertApproxEqAbs(lst.balanceCheckpoint(_receiver), ERC20Votes(address(stakeToken)).getVotes(_receiverDelegatee), 1);
    assertLe(lst.balanceCheckpoint(_receiver), ERC20Votes(address(stakeToken)).getVotes(_receiverDelegatee));
  }

  function testFuzz_TransfersTheBalanceAndMovesTheVotingWeightBetweenMultipleHoldersWhoHaveStakedAndReceivedRewards(
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    uint80 _rewardAmount,
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
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _sendAmount1 = bound(_sendAmount1, 0.0001e18, _stakeAmount1);
    _sendAmount2 = bound(_sendAmount2, 0.0001e18, _stakeAmount2 + _sendAmount1);
    // Add two to avoid a situation where the min expected rewards is less than rewards when they are distributed.
    uint256 _stake2PercentOfTotalStake = _toPercentage(_stakeAmount2, _stakeAmount1 + _stakeAmount2 + 2);

    // Two users stake
    _mintUpdateDelegateeAndStake(_sender1, _stakeAmount1, _sender1Delegatee);
    _mintUpdateDelegateeAndStake(_sender2, _stakeAmount2, _sender2Delegatee);
    // A reward is distributed
    Staker.DepositIdentifier _depositId2 = lst.depositIdForHolder(address(_sender2));
    _distributeReward(_rewardAmount, _depositId2, _stake2PercentOfTotalStake);

    // Remember the the sender balances after they receive their reward
    uint256 _balance1AfterReward = lst.balanceOf(_sender1);
    uint256 _balance2AfterReward = lst.balanceOf(_sender2);

    // First sender transfers to the second sender
    vm.prank(_sender1);
    lst.transfer(_sender2, _sendAmount1);
    // Second sender transfers to the receiver
    vm.prank(_sender2);
    lst.transfer(_receiver, _sendAmount2);

    // --------------------------------------------------------------------------------------------------------- //
    // The following assertions ensure balances have been updated correctly after the transfers
    // --------------------------------------------------------------------------------------------------------- //

    // Sender's balance increases by up to 1 wei more than requested
    assertApproxEqAbs(_balance1AfterReward - _sendAmount1, lst.balanceOf(_sender1), 1);
    assertLe(lst.balanceOf(_sender1), _balance1AfterReward - _sendAmount1);
    // The second sender's balance may be off by 1 wei in either direction, because it may have received an extra wei
    // or sent an extra wei.
    assertApproxEqAbs(lst.balanceOf(_sender2), _balance2AfterReward + _sendAmount1 - _sendAmount2, 1);
    // The second receiver should get exactly what the second sender requested to be sent
    assertEq(lst.balanceOf(_receiver), _sendAmount2);

    // --------------------------------------------------------------------------------------------------------- //
    // The next assertions ensure the tokens have been managed correctly in the underlying deposits by observing
    // the actual voting weights of the various sender/receiver delegatees.
    // --------------------------------------------------------------------------------------------------------- //

    uint256 _expectedDefaultDelegateeWeight = (lst.balanceOf(_sender1) - lst.balanceCheckpoint(_sender1))
      + (lst.balanceOf(_sender2) - lst.balanceCheckpoint(_sender2)) + lst.balanceOf(_receiver);

    assertLteWithinOneUnit(lst.balanceCheckpoint(_sender1), ERC20Votes(address(stakeToken)).getVotes(_sender1Delegatee));
    assertLteWithinOneUnit(lst.balanceCheckpoint(_sender2), ERC20Votes(address(stakeToken)).getVotes(_sender2Delegatee));
    // The default deposit may have accrued up to 2 wei of shortfall from the two actions
    assertApproxEqAbs(_expectedDefaultDelegateeWeight, ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), 2);
    assertLe(_expectedDefaultDelegateeWeight, ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee));
  }

  function testFuzz_EmitsATransferEvent(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver,
    address _receiverDelegatee
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatees(_senderDelegatee, _receiverDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    _sendAmount = bound(_sendAmount, 0, _stakeAmount + _rewardAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender));

    vm.expectEmit();
    emit IERC20.Transfer(_sender, _receiver, _sendAmount);
    vm.prank(_sender);
    lst.transfer(_receiver, _sendAmount);
  }

  function testFuzz_RevertIf_TheHolderTriesToTransferMoreThanTheirBalance(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    uint256 _sendAmount,
    address _sender,
    address _senderDelegatee,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _assumeSafeDelegatee(_senderDelegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);
    uint256 _totalAmount = _rewardAmount + _stakeAmount;
    // Send amount will be some value more than the sender's balance, up to 2x as much
    _sendAmount = bound(_sendAmount, _totalAmount + 1, 2 * _totalAmount);

    _mintUpdateDelegateeAndStake(_sender, _stakeAmount, _senderDelegatee);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender));

    vm.prank(_sender);
    vm.expectRevert(GovLst.GovLst__InsufficientBalance.selector);
    lst.transfer(_receiver, _sendAmount);
  }

  function testFuzz_DoesNotChangeBalanceWhenSenderAndReceiverAreTheSame(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_holder, _amount);
    uint256 _initialBalance = lst.balanceOf(_holder);

    vm.prank(_holder);
    lst.transfer(_holder, _amount);

    assertEq(lst.balanceOf(_holder), _initialBalance, "Balance should remain unchanged after self-transfer");
  }

  function testFuzz_EmitsTransferEventWhenSenderAndReceiverAreTheSame(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_holder, _amount);

    vm.expectEmit();
    emit IERC20.Transfer(_holder, _holder, _amount);

    vm.prank(_holder);
    lst.transfer(_holder, _amount);
  }

  function testFuzz_DoesNotChangeBalanceCheckpointWhenSenderAndReceiverAreTheSame(address _holder, uint256 _amount)
    public
  {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_holder, _amount);
    uint256 _initialBalanceCheckpoint = lst.balanceCheckpoint(_holder);

    vm.prank(_holder);
    lst.transfer(_holder, _amount);

    assertEq(
      lst.balanceCheckpoint(_holder),
      _initialBalanceCheckpoint,
      "Balance checkpoint should remain unchanged after self-transfer"
    );
  }

  function testFuzz_DoesNotChangeVotingWeightWhenSenderAndReceiverAreTheSame(
    address _holder,
    uint256 _amount,
    address _delegatee
  ) public {
    _assumeSafeHolder(_holder);
    _assumeSafeDelegatee(_delegatee);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintUpdateDelegateeAndStake(_holder, _amount, _delegatee);
    uint256 _initialVotingWeight = ERC20Votes(address(stakeToken)).getVotes(_delegatee);

    vm.prank(_holder);
    lst.transfer(_holder, _amount);

    assertEq(
      ERC20Votes(address(stakeToken)).getVotes(_delegatee),
      _initialVotingWeight,
      "Voting weight should remain unchanged after self-transfer"
    );
  }
}

contract TransferAndReturnBalanceDiffs is GovLstTest {
  function testFuzz_MovesFullBalanceToAReceiver(uint256 _amount, address _sender, address _receiver) public {
    _assumeSafeHolders(_sender, _receiver);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_sender, _amount);
    uint256 _originalSenderBalance = lst.balanceOf(_sender);
    uint256 _originalReceiverBalance = lst.balanceOf(_receiver);

    vm.prank(_sender);
    (uint256 _senderBalanceDecrease, uint256 _receiverBalanceIncrease) =
      lst.transferAndReturnBalanceDiffs(_receiver, _amount);

    assertEq(lst.balanceOf(_sender), _originalSenderBalance - _senderBalanceDecrease);
    assertEq(lst.balanceOf(_receiver), _originalReceiverBalance + _receiverBalanceIncrease);
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

    uint256 _originalSenderBalance = lst.balanceOf(_sender);
    uint256 _originalReceiverBalance = lst.balanceOf(_receiver);

    vm.prank(_sender);
    (uint256 _senderBalanceDecrease, uint256 _receiverBalanceIncrease) =
      lst.transferAndReturnBalanceDiffs(_receiver, _sendAmount);

    assertEq(lst.balanceOf(_sender), _originalSenderBalance - _senderBalanceDecrease);
    assertEq(lst.balanceOf(_receiver), _originalReceiverBalance + _receiverBalanceIncrease);
  }

  function testFuzz_MovesFullBalanceToAReceiverWhenBalanceOfSenderIncludesEarnedRewards(
    uint256 _stakeAmount,
    uint80 _rewardAmount,
    address _sender,
    address _receiver
  ) public {
    _assumeSafeHolders(_sender, _receiver);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _rewardAmount = _boundToReasonableStakeTokenReward(_rewardAmount);

    _mintAndStake(_sender, _stakeAmount);
    _distributeReward(_rewardAmount, lst.depositIdForHolder(_sender));

    uint256 _originalSenderBalance = lst.balanceOf(_sender);
    uint256 _originalReceiverBalance = lst.balanceOf(_receiver);

    // As the only staker, the sender's balance should be the stake and rewards
    vm.prank(_sender);
    (uint256 _senderBalanceDecrease, uint256 _receiverBalanceIncrease) =
      lst.transferAndReturnBalanceDiffs(_receiver, _stakeAmount + _rewardAmount);

    assertEq(lst.balanceOf(_sender), _originalSenderBalance - _senderBalanceDecrease);
    assertEq(lst.balanceOf(_receiver), _originalReceiverBalance + _receiverBalanceIncrease);
  }

  function testFuzz_ReturnsZeroBalanceDiffsWhenSenderAndReceiverAreTheSame(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_holder, _amount);

    vm.prank(_holder);
    (uint256 senderBalanceDecrease, uint256 receiverBalanceIncrease) =
      lst.transferAndReturnBalanceDiffs(_holder, _amount);

    assertEq(senderBalanceDecrease, 0, "Sender balance decrease should be zero for self-transfer");
    assertEq(receiverBalanceIncrease, 0, "Receiver balance increase should be zero for self-transfer");
  }

  function testFuzz_EmitsATransferEvent(uint256 _amount, address _sender, address _receiver) public {
    _assumeSafeHolders(_sender, _receiver);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_sender, _amount);

    vm.prank(_sender);
    vm.expectEmit();
    emit IERC20.Transfer(_sender, _receiver, _amount);
    lst.transferAndReturnBalanceDiffs(_receiver, _amount);
  }
}

contract TransferFromAndReturnBalanceDiffs is GovLstTest {
  function testFuzz_MovesFullBalanceToAReceiver(uint256 _amount, address _caller, address _sender, address _receiver)
    public
  {
    _assumeSafeHolders(_sender, _receiver);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_sender, _amount);
    uint256 _originalSenderBalance = lst.balanceOf(_sender);
    uint256 _originalReceiverBalance = lst.balanceOf(_receiver);

    vm.prank(_sender);
    lst.approve(_caller, _amount);

    vm.prank(_caller);
    (uint256 _senderBalanceDecrease, uint256 _receiverBalanceIncrease) =
      lst.transferFromAndReturnBalanceDiffs(_sender, _receiver, _amount);

    assertEq(lst.balanceOf(_sender), _originalSenderBalance - _senderBalanceDecrease);
    assertEq(lst.balanceOf(_receiver), _originalReceiverBalance + _receiverBalanceIncrease);
  }

  function testFuzz_EmitsATransferEvent(uint256 _amount, address _caller, address _sender, address _receiver) public {
    _assumeSafeHolders(_sender, _receiver);
    _amount = _boundToReasonableStakeTokenAmount(_amount);

    _mintAndStake(_sender, _amount);

    vm.prank(_sender);
    lst.approve(_caller, _amount);

    vm.prank(_caller);
    vm.expectEmit();
    emit IERC20.Transfer(_sender, _receiver, _amount);
    lst.transferFromAndReturnBalanceDiffs(_sender, _receiver, _amount);
  }
}

contract ClaimAndDistributeReward is GovLstTest {
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
    uint80 _rewardAmount,
    uint256 _payoutAmount,
    uint256 _extraBalance,
    address _holder,
    uint256 _stakeAmount,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    _assumeSafeHolders(_holder, _claimer);
    vm.assume(_feeCollector != address(0) && _feeCollector != _holder);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenReward(_payoutAmount);
    _extraBalance = _boundToReasonableStakeTokenAmount(_extraBalance);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _setRewardParameters(uint80(_payoutAmount), _feeBips, _feeCollector);

    // Calculate the fee amount
    uint256 _feeAmount = (_payoutAmount * _feeBips) / 10_000;

    // The claimer should hold at least the payout amount (including fee) with some extra balance.
    _mintStakeToken(_claimer, _payoutAmount + _extraBalance);
    // There must be some stake in the LST for it to earn the underlying staker rewards
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);
    // Remember the fee collector's initial balance
    uint256 _feeCollectorInitialBalance = lst.balanceOf(_feeCollector);

    _approveLstAndClaimAndDistributeReward(_claimer, _rewardAmount, _recipient, lst.depositIdForHolder(_holder));

    // Because the tokens were transferred from the claimer, his balance should have decreased by the payout amount.
    assertEq(stakeToken.balanceOf(_claimer), _extraBalance);

    // Check that the fee collector received the correct fee amount
    if (_feeAmount > 0) {
      assertApproxEqAbs(lst.balanceOf(_feeCollector) - _feeCollectorInitialBalance, _feeAmount, 1);
    }
  }

  function testFuzz_AssignsVotingWeightFromRewardsToTheDefaultDelegatee(
    address _claimer,
    address _recipient,
    uint80 _rewardAmount,
    uint256 _payoutAmount,
    address _holder,
    uint256 _stakeAmount,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    _assumeSafeHolders(_holder, _claimer);
    vm.assume(_feeCollector != address(0) && _feeCollector != _claimer && _feeCollector != _holder);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenReward(_payoutAmount);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _setRewardParameters(uint80(_payoutAmount), _feeBips, _feeCollector);
    _mintStakeToken(_claimer, _payoutAmount);
    // There must be some stake in the LST for it to earn the underlying staker rewards
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);

    _approveLstAndClaimAndDistributeReward(_claimer, _rewardAmount, _recipient, lst.depositIdForHolder(_holder));

    // If the LST moved the voting weight in the default delegatee's deposit, he should have its voting weight.
    assertEq(ERC20Votes(address(stakeToken)).getVotes(defaultDelegatee), _stakeAmount + _payoutAmount);
  }

  function testFuzz_SendsStakerRewardsToRewardRecipient(
    address _claimer,
    address _recipient,
    uint80 _rewardAmount,
    uint256 _payoutAmount,
    address _holder,
    uint256 _stakeAmount,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    _assumeSafeHolders(_holder, _claimer);
    vm.assume(_feeCollector != address(0) && _feeCollector != _claimer && _feeCollector != _holder);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenReward(_payoutAmount);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _setRewardParameters(uint80(_payoutAmount), _feeBips, _feeCollector);
    _mintStakeToken(_claimer, _payoutAmount);
    // There must be some stake in the LST for it to earn the underlying staker rewards
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);

    _approveLstAndClaimAndDistributeReward(_claimer, _rewardAmount, _recipient, lst.depositIdForHolder(_holder));

    assertLteWithinOneUnit(rewardToken.balanceOf(_recipient), _rewardAmount);
  }

  function testFuzz_SendsStakerRewardsFromMultipleDepositsToRewardRecipient(
    address _claimer,
    address _recipient,
    uint80 _rewardAmount,
    uint256 _payoutAmount,
    address _holder1,
    address _holder2,
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeHolder(_claimer);
    vm.assume(_claimer != _holder1 && _claimer != _holder2);
    vm.assume(
      _feeCollector != address(0) && _feeCollector != _claimer && _feeCollector != _holder1 && _feeCollector != _holder2
    );
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenReward(_payoutAmount);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _setRewardParameters(uint80(_payoutAmount), _feeBips, _feeCollector);
    _mintStakeToken(_claimer, _payoutAmount);

    // Two depositors stake with different delegatees (themselves) ensuring they will have unique
    // deposits
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    _stakeAmount2 = _boundToReasonableStakeTokenAmount(_stakeAmount2);
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _holder1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _holder2);

    Staker.DepositIdentifier[] memory _deposits = new Staker.DepositIdentifier[](2);
    _deposits[0] = lst.depositIdForHolder(_holder1);
    _deposits[1] = lst.depositIdForHolder(_holder2);

    // Puts reward token in the staker.
    _distributeStakerReward(_rewardAmount);

    vm.startPrank(_claimer);
    // Approve the LST to pull the payout token amount
    stakeToken.approve(address(lst), lst.payoutAmount());
    // Claim rewards, where min reward amount may be up to 2 wei less due to 1 wei truncation for
    // _each_ deposit reward claim.
    lst.claimAndDistributeReward(_recipient, _rewardAmount - 2, _deposits);
    vm.stopPrank();

    assertApproxEqAbs(rewardToken.balanceOf(_recipient), _rewardAmount, 2);
    assertLe(rewardToken.balanceOf(_recipient), _rewardAmount);
  }

  function testFuzz_DoesNotDistributeExtraRewardsIfTheClaimerDuplicatesADepositIdentifier(
    address _claimer,
    address _recipient,
    uint80 _rewardAmount,
    uint256 _payoutAmount,
    address _holder1,
    address _holder2,
    uint256 _stakeAmount1,
    uint256 _stakeAmount2,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeHolder(_claimer);
    vm.assume(_claimer != _holder1 && _claimer != _holder2);
    vm.assume(
      _feeCollector != address(0) && _feeCollector != _claimer && _feeCollector != _holder1 && _feeCollector != _holder2
    );
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenReward(_payoutAmount);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _setRewardParameters(uint80(_payoutAmount), _feeBips, _feeCollector);
    _mintStakeToken(_claimer, _payoutAmount);

    // Two depositors stake with different delegatees (themselves) ensuring they will have unique
    // deposits
    _stakeAmount1 = _boundToReasonableStakeTokenAmount(_stakeAmount1);
    _stakeAmount2 = _boundToReasonableStakeTokenAmount(_stakeAmount2);
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount1, _holder1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount2, _holder2);

    Staker.DepositIdentifier[] memory _deposits = new Staker.DepositIdentifier[](3);
    _deposits[0] = lst.depositIdForHolder(_holder1);
    _deposits[1] = lst.depositIdForHolder(_holder2);
    _deposits[2] = _deposits[0]; // first deposit is repeated twice

    // Puts reward token in the staker.
    _distributeStakerReward(_rewardAmount);

    vm.startPrank(_claimer);
    // Approve the LST to pull the payout token amount
    stakeToken.approve(address(lst), lst.payoutAmount());
    // Claim rewards, where min reward amount may be up to 2 wei less due to 1 wei truncation for
    // _each_ deposit reward claim.
    lst.claimAndDistributeReward(_recipient, _rewardAmount - 2, _deposits);
    vm.stopPrank();

    // Rewards received by the recipient are the same despite a deposit being included twice
    assertApproxEqAbs(rewardToken.balanceOf(_recipient), _rewardAmount, 2);
    assertLe(rewardToken.balanceOf(_recipient), _rewardAmount);
  }

  function testFuzz_SendsStakerOnlyStakerRewardsFromSpecifiedDepositsToToRewardRecipient(
    address _claimer,
    address _recipient,
    uint80 _rewardAmount,
    uint256 _payoutAmount,
    address _holder1,
    address _holder2,
    address _holder3,
    uint256 _stakeAmount,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    _assumeSafeHolders(_holder1, _holder2);
    _assumeSafeHolders(_holder3, _claimer);
    vm.assume(_holder3 != _holder1 && _holder3 != _holder2);
    vm.assume(_claimer != _holder1 && _claimer != _holder2);
    vm.assume(
      _feeCollector != address(0) && _feeCollector != _claimer && _feeCollector != _holder1 && _feeCollector != _holder2
        && _feeCollector != _holder3
    );
    //vm.assume(_holder1 != address(staker) && _holder2 != address(staker) && _holder3 != address(staker));
    vm.assume(_recipient != address(staker));
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenReward(_payoutAmount);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _setRewardParameters(uint80(_payoutAmount), _feeBips, _feeCollector);
    _mintStakeToken(_claimer, _payoutAmount);

    // Three depositors stake with different delegatees (themselves) ensuring they will have unique
    // deposits. They each stake the same amount.
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintUpdateDelegateeAndStake(_holder1, _stakeAmount, _holder1);
    _mintUpdateDelegateeAndStake(_holder2, _stakeAmount, _holder2);
    _mintUpdateDelegateeAndStake(_holder3, _stakeAmount, _holder3);

    // The claimer will only ask for rewards from two deposits
    Staker.DepositIdentifier[] memory _deposits = new Staker.DepositIdentifier[](2);
    _deposits[0] = lst.depositIdForHolder(_holder1);
    _deposits[1] = lst.depositIdForHolder(_holder3);

    // The expected rewards amount is thus 2/3rds of total rewards paid out to all deposits.
    uint256 _expectedRewardAmount = (2 * uint256(_rewardAmount)) / 3;

    // Distributes reward token in the staker.
    _distributeStakerReward(_rewardAmount);

    vm.startPrank(_claimer);
    // Approve the LST to pull the payout token amount
    stakeToken.approve(address(lst), lst.payoutAmount());
    // Claim rewards, where min reward amount may be up to 2 wei less due to 1 wei truncation for
    // _each_ deposit reward claim.
    lst.claimAndDistributeReward(_recipient, _expectedRewardAmount - 2, _deposits);
    vm.stopPrank();

    assertApproxEqAbs(rewardToken.balanceOf(_recipient), _expectedRewardAmount, 2);
    assertLe(rewardToken.balanceOf(_recipient), _expectedRewardAmount);
  }

  function testFuzz_IncreasesTheTotalSupplyByThePayoutAmount(
    address _claimer,
    address _recipient,
    uint80 _rewardAmount,
    uint256 _payoutAmount,
    address _holder,
    uint256 _stakeAmount,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    _assumeSafeHolders(_holder, _claimer);
    vm.assume(_feeCollector != address(0) && _feeCollector != _claimer && _feeCollector != _holder);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenReward(_payoutAmount);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _setRewardParameters(uint80(_payoutAmount), _feeBips, _feeCollector);
    _mintStakeToken(_claimer, _payoutAmount);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);

    _approveLstAndClaimAndDistributeReward(_claimer, _rewardAmount, _recipient, lst.depositIdForHolder(_holder));

    // Total balance is the amount staked + payout earned
    assertEq(lst.totalSupply(), _stakeAmount + _payoutAmount);
  }

  function testFuzz_IssuesFeesToTheFeeCollectorEqualToTheFeeAmount(
    address _claimer,
    address _recipient,
    uint80 _rewardAmount,
    uint256 _payoutAmount,
    address _holder,
    uint256 _stakeAmount,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    // Apply constraints to parameters.
    _assumeSafeHolders(_holder, _claimer);
    _assumeSafeHolder(_feeCollector);
    vm.assume(_feeCollector != address(0) && _feeCollector != _holder && _feeCollector != _claimer);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenReward(_payoutAmount);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    // Set up actors to enable reward distribution with fees.
    _setRewardParameters(uint80(_payoutAmount), _feeBips, _feeCollector);
    _mintStakeToken(_claimer, _payoutAmount);
    _mintAndStake(_holder, _stakeAmount);

    // Execute reward distribution that includes a fee payout.
    _approveLstAndClaimAndDistributeReward(_claimer, _rewardAmount, _recipient, lst.depositIdForHolder(_holder));

    uint256 _feeAmount = (_payoutAmount * _feeBips) / 10_000;
    // The fee collector should now have a balance less than or equal to the fee amount, within some tolerable delta
    // to account for truncation issues.
    assertApproxEqAbs(lst.balanceOf(_feeCollector), _feeAmount, 1);
    assertTrue(lst.balanceOf(_feeCollector) <= _feeAmount);
  }

  function testFuzz_RevertIf_RewardsReceivedAreLessThanTheExpectedAmount(
    address _claimer,
    address _recipient,
    uint80 _rewardAmount,
    uint256 _payoutAmount,
    uint256 _minExpectedReward,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    _assumeSafeHolder(_claimer);
    vm.assume(_feeCollector != address(0) && _feeCollector != _claimer);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenReward(_payoutAmount);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _setRewardParameters(uint80(_payoutAmount), _feeBips, _feeCollector);
    // The claimer will request a minimum reward amount greater than the actual reward.
    _minExpectedReward = bound(_minExpectedReward, uint256(_rewardAmount) + 1, type(uint256).max);
    _mintStakeToken(_claimer, _payoutAmount);
    vm.startPrank(_claimer);
    stakeToken.approve(address(lst), _payoutAmount);
    Staker.DepositIdentifier _depositId = lst.depositIdForHolder(_claimer);

    Staker.DepositIdentifier[] memory _deposits = new Staker.DepositIdentifier[](1);
    _deposits[0] = _depositId;

    vm.expectRevert(GovLst.GovLst__InsufficientRewards.selector);
    lst.claimAndDistributeReward(_recipient, _minExpectedReward, _deposits);
    vm.stopPrank();
  }

  function testFuzz_EmitsRewardDistributedEvent(
    address _claimer,
    address _recipient,
    uint80 _rewardAmount,
    uint256 _payoutAmount,
    uint256 _extraBalance,
    address _holder,
    uint256 _stakeAmount,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    _assumeSafeHolders(_holder, _claimer);
    _assumeSafeHolder(_feeCollector);
    vm.assume(_feeCollector != address(0) && _feeCollector != _holder && _feeCollector != _claimer);
    _rewardAmount = _boundToReasonableRewardTokenAmount(_rewardAmount);
    _payoutAmount = _boundToReasonableStakeTokenReward(_payoutAmount);
    _extraBalance = _boundToReasonableStakeTokenAmount(_extraBalance);
    _feeBips = uint16(bound(_feeBips, 0, lst.MAX_FEE_BIPS()));
    _setRewardParameters(uint80(_payoutAmount), _feeBips, _feeCollector);
    _mintStakeToken(_claimer, _payoutAmount + _extraBalance);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintAndStake(_holder, _stakeAmount);

    // Puts reward token in the staker.
    _distributeStakerReward(_rewardAmount);
    // Approve the LST and claim the reward.
    vm.startPrank(_claimer);
    stakeToken.approve(address(lst), lst.payoutAmount());

    // Local scope to avoid stack to deep in tests
    {
      Staker.DepositIdentifier _depositId = lst.depositIdForHolder(_claimer);
      Staker.DepositIdentifier[] memory _deposits = new Staker.DepositIdentifier[](1);
      _deposits[0] = _depositId;

      // Min expected rewards parameter is one less than reward amount due to truncation.
      vm.recordLogs();
      lst.claimAndDistributeReward(_recipient, _rewardAmount - 1, _deposits);
      vm.stopPrank();
    }

    Vm.Log[] memory entries = vm.getRecordedLogs();

    uint256 _feeAmount = (_payoutAmount * _feeBips) / 10_000;
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

contract SetRewardParameters is GovLstTest {
  function testFuzz_UpdatesRewardParametersWhenCalledByOwner(
    uint80 _payoutAmount,
    uint16 _feeBips,
    address _feeCollector
  ) public {
    vm.assume(_feeCollector != address(0));
    _feeBips = uint16(bound(_feeBips, 1, lst.MAX_FEE_BIPS()));
    _payoutAmount = _boundToReasonablePayoutAmount(_payoutAmount);

    vm.prank(lstOwner);
    lst.setRewardParameters(
      GovLst.RewardParameters({payoutAmount: _payoutAmount, feeBips: _feeBips, feeCollector: _feeCollector})
    );

    assertEq(lst.payoutAmount(), _payoutAmount);
    assertEq(lst.feeAmount(), (uint256(_payoutAmount) * uint256(_feeBips)) / 1e4);
    assertEq(lst.feeCollector(), _feeCollector);
  }

  function testFuzz_RevertIf_CalledByNonOwner(address _notOwner) public {
    vm.assume(_notOwner != lstOwner);

    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    lst.setRewardParameters(GovLst.RewardParameters({payoutAmount: 1000, feeBips: 100, feeCollector: address(0x1)}));
  }

  function testFuzz_RevertIf_FeeBipsExceedsMaximum(uint16 _invalidFeeBips, uint80 _payoutAmount, address _feeCollector)
    public
  {
    vm.assume(_feeCollector != address(0));
    _invalidFeeBips = uint16(bound(_invalidFeeBips, lst.MAX_FEE_BIPS() + 1, type(uint16).max));
    _payoutAmount = _boundToReasonablePayoutAmount(_payoutAmount);

    vm.startPrank(lstOwner);
    vm.expectRevert(
      abi.encodeWithSelector(GovLst.GovLst__FeeBipsExceedMaximum.selector, _invalidFeeBips, lst.MAX_FEE_BIPS())
    );
    lst.setRewardParameters(
      GovLst.RewardParameters({payoutAmount: _payoutAmount, feeBips: _invalidFeeBips, feeCollector: _feeCollector})
    );
    vm.stopPrank();
  }

  function testFuzz_RevertIf_FeeCollectorIsZeroAddress(uint80 _payoutAmount, uint16 _feeBips) public {
    _payoutAmount = _boundToReasonablePayoutAmount(_payoutAmount);
    _feeBips = uint16(bound(_feeBips, 1, lst.MAX_FEE_BIPS()));

    vm.prank(lstOwner);
    vm.expectRevert(GovLst.GovLst__FeeCollectorCannotBeZeroAddress.selector);
    lst.setRewardParameters(
      GovLst.RewardParameters({payoutAmount: _payoutAmount, feeBips: _feeBips, feeCollector: address(0)})
    );
  }

  function testFuzz_EmitsRewardParametersSetEvent(uint80 _payoutAmount, uint16 _feeBips, address _feeCollector) public {
    vm.assume(_feeCollector != address(0));
    _feeBips = uint16(bound(_feeBips, 1, lst.MAX_FEE_BIPS()));
    _payoutAmount = _boundToReasonablePayoutAmount(_payoutAmount);

    vm.startPrank(lstOwner);
    vm.expectEmit();
    emit GovLst.RewardParametersSet(_payoutAmount, _feeBips, _feeCollector);
    lst.setRewardParameters(
      GovLst.RewardParameters({payoutAmount: _payoutAmount, feeBips: _feeBips, feeCollector: _feeCollector})
    );
    vm.stopPrank();
  }

  function testFuzz_RevertIf_FeeBipsExceedMaximum(uint16 _invalidFeeBips, uint80 _payoutAmount, address _feeCollector)
    public
  {
    vm.assume(_feeCollector != address(0));
    _invalidFeeBips = uint16(bound(_invalidFeeBips, lst.MAX_FEE_BIPS() + 1, type(uint16).max));
    _payoutAmount = _boundToReasonablePayoutAmount(_payoutAmount);

    vm.startPrank(lstOwner);
    vm.expectRevert(
      abi.encodeWithSelector(GovLst.GovLst__FeeBipsExceedMaximum.selector, _invalidFeeBips, lst.MAX_FEE_BIPS())
    );
    lst.setRewardParameters(
      GovLst.RewardParameters({payoutAmount: _payoutAmount, feeBips: _invalidFeeBips, feeCollector: _feeCollector})
    );
    vm.stopPrank();
  }
}

contract SetMaxOverrideTip is GovLstTest {
  function testFuzz_CorrectlySetsNewMaxOverrideTip(uint256 _newMaxOverrideTip) public {
    _newMaxOverrideTip = bound(_newMaxOverrideTip, 0, lst.MAX_OVERRIDE_TIP_CAP());

    vm.prank(lstOwner);
    lst.setMaxOverrideTip(_newMaxOverrideTip);
    assertEq(lst.maxOverrideTip(), _newMaxOverrideTip);
  }

  function testFuzz_CorrectlyEmitsMaxOverrideTipSetEvent(uint256 _oldMaxOverrideTip, uint256 _newMaxOverrideTip) public {
    _oldMaxOverrideTip = bound(_oldMaxOverrideTip, 0, lst.MAX_OVERRIDE_TIP_CAP());
    _newMaxOverrideTip = bound(_newMaxOverrideTip, 0, lst.MAX_OVERRIDE_TIP_CAP());
    vm.prank(lstOwner);
    lst.setMaxOverrideTip(_oldMaxOverrideTip);

    vm.prank(lstOwner);
    vm.expectEmit();
    emit GovLst.MaxOverrideTipSet(_oldMaxOverrideTip, _newMaxOverrideTip);
    lst.setMaxOverrideTip(_newMaxOverrideTip);
  }

  function testFuzz_RevertIf_CalledByNonOwner(address _caller, uint256 _maxOverrideTip) public {
    vm.assume(_caller != lstOwner);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    lst.setMaxOverrideTip(_maxOverrideTip);
  }

  function testFuzz_RevertIf_AboveMaximumValue(uint256 _newMaxOverrideTip) public {
    _newMaxOverrideTip = bound(_newMaxOverrideTip, lst.MAX_OVERRIDE_TIP_CAP() + 1, type(uint256).max);

    vm.prank(lstOwner);
    vm.expectRevert(GovLst.GovLst__InvalidParameter.selector);
    lst.setMaxOverrideTip(_newMaxOverrideTip);
  }
}

contract SetMinQualifyingEarningPowerBips is GovLstTest {
  function testFuzz_CorrectlySetsNewMinQualifyingEarningPowerBips(uint256 _newMinQualifyingEarningPowerBips) public {
    _newMinQualifyingEarningPowerBips =
      bound(_newMinQualifyingEarningPowerBips, 0, lst.MINIMUM_QUALIFYING_EARNING_POWER_BIPS_CAP());

    vm.prank(lstOwner);
    lst.setMinQualifyingEarningPowerBips(_newMinQualifyingEarningPowerBips);
    assertEq(lst.minQualifyingEarningPowerBips(), _newMinQualifyingEarningPowerBips);
  }

  function testFuzz_CorrectlyEmitsMinQualifyingEarningPowerBipsSetEvent(
    uint256 _oldMinQualifyingEarningPowerBips,
    uint256 _newMinQualifyingEarningPowerBips
  ) public {
    _oldMinQualifyingEarningPowerBips =
      bound(_oldMinQualifyingEarningPowerBips, 0, lst.MINIMUM_QUALIFYING_EARNING_POWER_BIPS_CAP());
    _newMinQualifyingEarningPowerBips =
      bound(_newMinQualifyingEarningPowerBips, 0, lst.MINIMUM_QUALIFYING_EARNING_POWER_BIPS_CAP());

    vm.prank(lstOwner);
    lst.setMinQualifyingEarningPowerBips(_oldMinQualifyingEarningPowerBips);

    vm.prank(lstOwner);
    vm.expectEmit();
    emit GovLst.MinQualifyingEarningPowerBipsSet(_oldMinQualifyingEarningPowerBips, _newMinQualifyingEarningPowerBips);
    lst.setMinQualifyingEarningPowerBips(_newMinQualifyingEarningPowerBips);
  }

  function testFuzz_RevertIf_CalledByNonOwner(address _caller, uint256 _minQualifyingEarningPowerBips) public {
    vm.assume(_caller != lstOwner);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    lst.setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);
  }

  function testFuzz_RevertIf_AboveMaxmimumValue(uint256 _minQualifyingEarningPowerBips) public {
    _minQualifyingEarningPowerBips =
      bound(_minQualifyingEarningPowerBips, lst.MINIMUM_QUALIFYING_EARNING_POWER_BIPS_CAP() + 1, type(uint256).max);

    vm.expectRevert(GovLst.GovLst__InvalidParameter.selector);
    vm.prank(lstOwner);
    lst.setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);
  }

  function testFuzz_RevertIf_BelowMinimumValue(uint256 _minQualifyingEarningPowerBips) public {
    _minQualifyingEarningPowerBips =
      bound(_minQualifyingEarningPowerBips, lst.MINIMUM_QUALIFYING_EARNING_POWER_BIPS_CAP() + 1, type(uint256).max);

    vm.expectRevert(GovLst.GovLst__InvalidParameter.selector);
    vm.prank(lstOwner);
    lst.setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);
  }
}

contract FeeAmount is GovLstTest {
  function testFuzz_ReturnsFeeAmount(uint80 _payoutAmount, uint16 _feeBips, address _feeCollector) public {
    vm.assume(_feeCollector != address(0));
    _feeBips = uint16(bound(_feeBips, 1, lst.MAX_FEE_BIPS()));
    _payoutAmount = _boundToReasonablePayoutAmount(_payoutAmount);

    _setRewardParameters(_payoutAmount, _feeBips, _feeCollector);

    uint256 expectedFeeAmount = (uint256(_payoutAmount) * uint256(_feeBips)) / 1e4;
    assertEq(lst.feeAmount(), expectedFeeAmount);
  }
}

contract FeeCollector is GovLstTest {
  function testFuzz_ReturnsFeeCollector(uint80 _payoutAmount, uint16 _feeBips, address _feeCollector) public {
    vm.assume(_feeCollector != address(0));
    _feeBips = uint16(bound(_feeBips, 1, lst.MAX_FEE_BIPS()));
    _payoutAmount = _boundToReasonablePayoutAmount(_payoutAmount);

    _setRewardParameters(_payoutAmount, _feeBips, _feeCollector);

    assertEq(lst.feeCollector(), _feeCollector);
  }
}

contract PayoutAmount is GovLstTest {
  function testFuzz_ReturnsPayoutAmount(uint80 _payoutAmount, uint16 _feeBips, address _feeCollector) public {
    vm.assume(_feeCollector != address(0));
    _feeBips = uint16(bound(_feeBips, 1, lst.MAX_FEE_BIPS()));
    _payoutAmount = _boundToReasonablePayoutAmount(_payoutAmount);

    _setRewardParameters(_payoutAmount, _feeBips, _feeCollector);

    assertEq(lst.payoutAmount(), _payoutAmount);
  }
}

contract Permit is GovLstTest {
  function _buildPermitStructHash(address _owner, address _spender, uint256 _value, uint256 _nonce, uint256 _deadline)
    internal
    pure
    returns (bytes32)
  {
    return keccak256(abi.encode(PERMIT_TYPEHASH, _owner, _spender, _value, _nonce, _deadline));
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
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      _ownerPrivateKey,
      _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, bytes(lst.name()), bytes(lst.version()), address(lst))
    );

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
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      _ownerPrivateKey,
      _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, bytes(lst.name()), bytes(lst.version()), address(lst))
    );

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
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      _ownerPrivateKey,
      _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, bytes(lst.name()), bytes(lst.version()), address(lst))
    );

    vm.prank(_sender);
    vm.expectRevert(GovLst.GovLst__SignatureExpired.selector);
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
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      _wrongPrivateKey,
      _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, bytes(lst.name()), bytes(lst.version()), address(lst))
    );

    vm.prank(_sender);
    vm.expectRevert(GovLst.GovLst__InvalidSignature.selector);
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
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      _ownerPrivateKey,
      _hashTypedDataV4(EIP712_DOMAIN_TYPEHASH, structHash, bytes(lst.name()), bytes(lst.version()), address(lst))
    );

    vm.prank(_sender);
    lst.permit(_owner, _spender, _value, _deadline, v, r, s);

    vm.prank(_sender);
    vm.expectRevert(GovLst.GovLst__InvalidSignature.selector);
    lst.permit(_owner, _spender, _value, _deadline, v, r, s);
  }
}

contract DOMAIN_SEPARATOR is GovLstTest {
  function test_MatchesTheExpectedValueRequiredByTheEIP712Standard() public view {
    bytes32 _expectedDomainSeparator = keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256(bytes(lst.name())),
        keccak256(bytes(lst.version())),
        block.chainid,
        address(lst)
      )
    );

    bytes32 _actualDomainSeparator = lst.DOMAIN_SEPARATOR();

    assertEq(_actualDomainSeparator, _expectedDomainSeparator, "Domain separator mismatch");
  }
}

contract Nonce is GovLstTest {
  function testFuzz_InitialReturnsZeroForAllAccounts(address _account) public view {
    assertEq(lst.nonces(_account), 0);
  }
}

contract Multicall is GovLstTest {
  function testFuzz_CallsMultipleFunctionsInOneTransaction(
    address _actor,
    uint256 _stakeAmount,
    address _delegatee,
    address _receiver,
    uint256 _transferAmount
  ) public {
    _assumeSafeHolders(_actor, _receiver);
    _assumeSafeDelegatee(_delegatee);
    _stakeAmount = _boundToReasonableStakeTokenAmount(_stakeAmount);
    _mintStakeToken(_actor, _stakeAmount);
    _transferAmount = bound(_transferAmount, 0, _stakeAmount);

    vm.prank(_actor);
    stakeToken.approve(address(lst), _stakeAmount);

    // TODO: if API around fetchOrInitializeDepositForDelegatee changes, remove depositId workaround
    uint256 _depositId = 2;
    bytes[] memory _calls = new bytes[](4);
    _calls[0] = abi.encodeWithSelector(lst.stake.selector, _stakeAmount);
    _calls[1] = abi.encodeWithSelector(lst.fetchOrInitializeDepositForDelegatee.selector, _delegatee);
    _calls[2] = abi.encodeWithSelector(lst.updateDeposit.selector, _depositId);
    _calls[3] = abi.encodeWithSelector(lst.transfer.selector, _receiver, _transferAmount);

    vm.prank(_actor);
    lst.multicall(_calls);

    assertApproxEqAbs(_stakeAmount - _transferAmount, lst.balanceOf(_actor), 1);
    assertLe(_stakeAmount - _transferAmount, lst.balanceOf(_actor));
    assertApproxEqAbs(lst.balanceOf(_receiver), _transferAmount, 1);
    assertLe(lst.balanceOf(_receiver), _transferAmount);
    assertApproxEqAbs(lst.balanceOf(_actor), ERC20Votes(address(stakeToken)).getVotes(_delegatee), 1);
    assertLe(lst.balanceOf(_actor), ERC20Votes(address(stakeToken)).getVotes(_delegatee));
  }

  function testFuzz_RevertIf_AFunctionCallFails(address _actor) public {
    vm.assume(_actor != lstOwner);
    _assumeSafeHolder(_actor);
    uint256 _stakeAmount = 1000e18;
    _mintStakeToken(_actor, _stakeAmount);

    vm.prank(_actor);
    stakeToken.approve(address(lst), _stakeAmount);

    bytes[] memory _calls = new bytes[](4);
    _calls[0] = abi.encodeWithSelector(lst.stake.selector, _stakeAmount);
    _calls[1] = abi.encodeWithSelector(lst.setRewardParameters.selector, 100e18, 100, address(0x1));

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _actor));
    vm.prank(_actor);
    lst.multicall(_calls);
  }
}

contract SetDefaultDelegatee is GovLstTest {
  function testFuzz_SetsTheDefaultDelegateeWhenCalledByTheOwnerBeforeTheGuardianHasTakenControl(
    address _newDefaultDelegatee
  ) public {
    _assumeSafeDelegatee(_newDefaultDelegatee);

    vm.prank(lstOwner);
    lst.setDefaultDelegatee(_newDefaultDelegatee);

    (,,, address _depositDelegatee,,,) = staker.deposits(lst.DEFAULT_DEPOSIT_ID());

    assertEq(_depositDelegatee, _newDefaultDelegatee);
    assertEq(lst.defaultDelegatee(), _newDefaultDelegatee);
    assertFalse(lst.isGuardianControlled());
  }

  function testFuzz_SetsTheDefaultDelegateeAndActivatesGuardianControlWhenCalledByTheGuardianForTheFirstTime(
    address _newDefaultDelegatee
  ) public {
    _assumeSafeDelegatee(_newDefaultDelegatee);

    vm.prank(delegateeGuardian);
    lst.setDefaultDelegatee(_newDefaultDelegatee);

    (,,, address _depositDelegatee,,,) = staker.deposits(lst.DEFAULT_DEPOSIT_ID());

    assertEq(_depositDelegatee, _newDefaultDelegatee);
    assertEq(lst.defaultDelegatee(), _newDefaultDelegatee);
    assertTrue(lst.isGuardianControlled());
  }

  function testFuzz_EmitsDefaultDelegateeSetEvent(address _newDefaultDelegatee, bool _submitAsOwner) public {
    _assumeSafeDelegatee(_newDefaultDelegatee);
    address _caller = _submitAsOwner ? lstOwner : delegateeGuardian;

    vm.expectEmit();
    emit GovLst.DefaultDelegateeSet(lst.defaultDelegatee(), _newDefaultDelegatee);
    vm.prank(_caller);
    lst.setDefaultDelegatee(_newDefaultDelegatee);
  }

  function testFuzz_RevertIf_CalledByAnyoneOtherThanTheOwnerOrGuardian(
    address _unauthorizedAccount,
    address _newDefaultDelegatee
  ) public {
    vm.assume(_unauthorizedAccount != lstOwner && _unauthorizedAccount != delegateeGuardian);
    _assumeSafeDelegatee(_newDefaultDelegatee);

    vm.expectRevert(GovLst.GovLst__Unauthorized.selector);
    vm.prank(_unauthorizedAccount);
    lst.setDefaultDelegatee(_newDefaultDelegatee);
  }

  function testFuzz_RevertIf_CalledByTheOwnerAfterTheGuardianHasTakenControl(
    address _newDefaultDelegatee1,
    address _newDefaultDelegatee2
  ) public {
    _assumeSafeDelegatee(_newDefaultDelegatee1);
    _assumeSafeDelegatee(_newDefaultDelegatee2);

    vm.prank(delegateeGuardian);
    lst.setDefaultDelegatee(_newDefaultDelegatee1);

    vm.expectRevert(GovLst.GovLst__Unauthorized.selector);
    vm.prank(lstOwner);
    lst.setDefaultDelegatee(_newDefaultDelegatee2);
  }
}

contract SetDelegateeGuardian is GovLstTest {
  function testFuzz_SetsTheDelegateeGuardianWhenCalledByTheOwnerBeforeTheGuardianHasTakenControl(
    address _newDelegateeGuardian
  ) public {
    _assumeSafeDelegatee(_newDelegateeGuardian);

    vm.prank(lstOwner);
    lst.setDelegateeGuardian(_newDelegateeGuardian);

    assertEq(lst.delegateeGuardian(), _newDelegateeGuardian);
    assertFalse(lst.isGuardianControlled());
  }

  function testFuzz_SetsTheDelegateeGuardianAndActivatesGuardianControlWhenCalledByTheGuardianForTheFirstTime(
    address _newDelegateeGuardian
  ) public {
    _assumeSafeDelegatee(_newDelegateeGuardian);

    vm.prank(delegateeGuardian);
    lst.setDelegateeGuardian(_newDelegateeGuardian);

    assertEq(lst.delegateeGuardian(), _newDelegateeGuardian);
    assertTrue(lst.isGuardianControlled());
  }

  function testFuzz_EmitsDelegateeGuardianSetEvent(address _newDelegateeGuardian, bool _submitAsOwner) public {
    _assumeSafeDelegatee(_newDelegateeGuardian);
    address _caller = _submitAsOwner ? lstOwner : delegateeGuardian;

    vm.expectEmit();
    emit GovLst.DelegateeGuardianSet(lst.delegateeGuardian(), _newDelegateeGuardian);
    vm.prank(_caller);
    lst.setDelegateeGuardian(_newDelegateeGuardian);
  }

  function testFuzz_RevertIf_CalledByAnyoneOtherThanTheOwnerOrGuardian(
    address _unauthorizedAccount,
    address _newDelegateeGuardian
  ) public {
    vm.assume(_unauthorizedAccount != lstOwner && _unauthorizedAccount != delegateeGuardian);
    _assumeSafeDelegatee(_newDelegateeGuardian);

    vm.expectRevert(GovLst.GovLst__Unauthorized.selector);
    vm.prank(_unauthorizedAccount);
    lst.setDelegateeGuardian(_newDelegateeGuardian);
  }

  function testFuzz_RevertIf_CalledByTheOwnerAfterTheGuardianHasTakenControl(
    address _newDelegateeGuardian1,
    address _newDelegateeGuardian2
  ) public {
    _assumeSafeDelegatee(_newDelegateeGuardian1);
    _assumeSafeDelegatee(_newDelegateeGuardian2);

    vm.prank(delegateeGuardian);
    lst.setDelegateeGuardian(_newDelegateeGuardian1);

    vm.expectRevert(GovLst.GovLst__Unauthorized.selector);
    vm.prank(lstOwner);
    lst.setDelegateeGuardian(_newDelegateeGuardian2);
  }
}

// The tests below for all the Fixed LST related methods only test that they are properly restricted to being called by
// the Fixed LST contract. The actual functionality of the methods is exercised and tests adequately in the Fixed LST
// test suite. Given that these two contracts are tightly coupled and deployed together, it seems reasonable to allow
// the unit tests for one to cover functionality of another.

contract StakeAndConvertToFixed is GovLstTest {
  function testFuzz_EmitsAStakedEventToTheFixedLstContract(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    address _fixedLst = address(lst.FIXED_LST());
    _mintStakeToken(_fixedLst, _amount);

    vm.startPrank(_fixedLst);
    // simulates the fixed lst contract transferring the user's tokens to the rebasing lst.
    stakeToken.transfer(address(lst), _amount);
    vm.expectEmit();
    emit GovLst.Staked(_fixedLst, _amount);
    lst.stakeAndConvertToFixed(_holder, _amount);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_CallerIsNotTheFixedLstContract(address _caller, address _account, uint256 _amount) public {
    vm.assume(_caller != address(lst.FIXED_LST()));
    vm.expectRevert(GovLst.GovLst__Unauthorized.selector);
    vm.prank(_caller);
    lst.stakeAndConvertToFixed(_account, _amount);
  }
}

contract UpdateFixedDeposit is GovLstTest {
  function testFuzz_RevertIf_CallerIsNotTheFixedLstContract(
    address _caller,
    address _account,
    Staker.DepositIdentifier _newDepositId
  ) public {
    vm.assume(_caller != address(lst.FIXED_LST()));
    vm.expectRevert(GovLst.GovLst__Unauthorized.selector);
    vm.prank(_caller);
    lst.updateFixedDeposit(_account, _newDepositId);
  }
}

contract ConvertToFixed is GovLstTest {
  function testFuzz_EmitsATransferEventToTheFixedLstContract(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    address _fixedLst = address(lst.FIXED_LST());
    _mintAndStake(_holder, _amount);

    vm.startPrank(_fixedLst);
    vm.expectEmit();
    emit IERC20.Transfer(_holder, _fixedLst, _amount);
    lst.convertToFixed(_holder, _amount);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_CallerIsNotTheFixedLstContract(address _caller, address _account, uint256 _amount) public {
    vm.assume(_caller != address(lst.FIXED_LST()));
    vm.expectRevert(GovLst.GovLst__Unauthorized.selector);
    vm.prank(_caller);
    lst.convertToFixed(_account, _amount);
  }
}

contract TransferFixed is GovLstTest {
  function testFuzz_RevertIf_CallerIsNotTheFixedLstContract(
    address _caller,
    address _sender,
    address _receiver,
    uint256 _shares
  ) public {
    vm.assume(_caller != address(lst.FIXED_LST()));
    vm.expectRevert(GovLst.GovLst__Unauthorized.selector);
    vm.prank(_caller);
    lst.transferFixed(_sender, _receiver, _shares);
  }
}

contract ConvertToRebasing is GovLstTest {
  function testFuzz_EmitsATransferEventFromTheFixedLstContract(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    address _fixedLst = address(lst.FIXED_LST());
    _mintAndStake(_holder, _amount);

    vm.startPrank(_fixedLst);
    uint256 _shares = lst.convertToFixed(_holder, _amount);
    vm.expectEmit();
    // amount should be the same since no rewards were distributed
    emit IERC20.Transfer(_fixedLst, _holder, _amount);
    lst.convertToRebasing(_holder, _shares);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_CallerIsNotTheFixedLstContract(address _caller, address _account, uint256 _shares) public {
    vm.assume(_caller != address(lst.FIXED_LST()));
    vm.expectRevert(GovLst.GovLst__Unauthorized.selector);
    vm.prank(_caller);
    lst.convertToRebasing(_account, _shares);
  }
}

contract ConvertToRebasingAndUnstake is GovLstTest {
  function testFuzz_EmitsAnUnstakeEventFromTheLstContract(address _holder, uint256 _amount) public {
    _assumeSafeHolder(_holder);
    _amount = _boundToReasonableStakeTokenAmount(_amount);
    address _fixedLst = address(lst.FIXED_LST());
    _mintStakeToken(_fixedLst, _amount);

    vm.startPrank(_fixedLst);
    // simulates the fixed lst contract transferring user tokens to the rebasing lst
    stakeToken.transfer(address(lst), _amount);
    uint256 _shares = lst.stakeAndConvertToFixed(_holder, _amount);
    vm.expectEmit();
    // amount should be the same since no rewards were distributed
    emit GovLst.Unstaked(_fixedLst, _amount);
    lst.convertToRebasingAndUnstake(_holder, _shares);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_CallerIsNotTheFixedLstContract(address _caller, address _account, uint256 _shares) public {
    vm.assume(_caller != address(lst.FIXED_LST()));
    vm.expectRevert(GovLst.GovLst__Unauthorized.selector);
    vm.prank(_caller);
    lst.convertToRebasingAndUnstake(_account, _shares);
  }
}
