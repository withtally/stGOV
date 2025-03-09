// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {console2, stdStorage, StdStorage, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Staker} from "staker/Staker.sol";
import {IERC20Staking} from "staker/interfaces/IERC20Staking.sol";
import {GovLst, Ownable} from "../../src/GovLst.sol";
import {GovLstHarness} from "../harnesses/GovLstHarness.sol";
import {WithdrawGate} from "../../src/WithdrawGate.sol";
import {UnitTestBase} from "../UnitTestBase.sol";
import {TestHelpers} from "../helpers/TestHelpers.sol";
import {Eip712Helper} from "../helpers/Eip712Helper.sol";
import {PercentAssertions} from "../helpers/PercentAssertions.sol";
import {MockFullEarningPowerCalculator} from "../mocks/MockFullEarningPowerCalculator.sol";
import {FakeStaker} from "../fakes/FakeStaker.sol";
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

  function _advanceTime(uint256 _seconds) internal {
    skip(_seconds);
  }

  // Example POC test - replace with your own vulnerability demonstration
  function test_POC() public {
    address user1 = makeAddr("User 1");
    address attacker = makeAddr("Attacker");

    // ========== SETUP ==========
    // Configure the initial conditions for the vulnerability

    uint256 stakeAmount = 1000e18;
    _mintStakeToken(user1, stakeAmount);
    _stake(user1, stakeAmount);
    assertEq(lst.balanceOf(user1), stakeAmount, "User1 should have 1000 LST tokens");

    // Distribute a reward
    _distributeReward(100e18);

    // Advance time to simulate passing of time
    _advanceTime(1 days);

    // ========== EXPLOIT ==========
    // Demonstrate the vulnerability here

    vm.startPrank(attacker);
    // Replace with your exploit code
    // Example: stakeToken.approve(address(lst), 100e18);
    //          lst.stake(100e18);
    vm.stopPrank();

    // For demonstration, we'll just do a simple check
    // In a real POC, this would be replaced with the actual exploit

    // ========== VERIFICATION ==========
    // Verify that the exploit worked using assertions

    // Example verification (replace with actual exploit verification)
    uint256 user1BalanceAfter = lst.balanceOf(user1);
    assertGt(user1BalanceAfter, 1000e18, "User1 balance should have increased due to rewards");

    // In a real exploit, you would assert conditions that prove the vulnerability
    // Example: assertEq(stakeToken.balanceOf(attacker), expectedValue);
  }
}
