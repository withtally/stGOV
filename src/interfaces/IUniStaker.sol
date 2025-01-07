// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Interface of UniStaker contract on Ethereum mainnet.
/// @dev Generated via Foundry `cast interface 0xE3071e87a7E6dD19A911Dbf1127BA9dD67Aa6fc8`
interface IUniStaker {
  type DepositIdentifier is uint256;

  error AddressEmptyCode(address target);
  error AddressInsufficientBalance(address account);
  error FailedInnerCall();
  error InvalidAccountNonce(address account, uint256 currentNonce);
  error InvalidShortString();
  error SafeERC20FailedOperation(address token);
  error StringTooLong(string str);
  error UniStaker__ExpiredDeadline();
  error UniStaker__InsufficientRewardBalance();
  error UniStaker__InvalidAddress();
  error UniStaker__InvalidRewardRate();
  error UniStaker__InvalidSignature();
  error UniStaker__Unauthorized(bytes32 reason, address caller);

  event AdminSet(address indexed oldAdmin, address indexed newAdmin);
  event BeneficiaryAltered(
    DepositIdentifier indexed depositId, address indexed oldBeneficiary, address indexed newBeneficiary
  );
  event DelegateeAltered(DepositIdentifier indexed depositId, address oldDelegatee, address newDelegatee);
  event EIP712DomainChanged();
  event RewardClaimed(address indexed beneficiary, uint256 amount);
  event RewardNotified(uint256 amount, address notifier);
  event RewardNotifierSet(address indexed account, bool isEnabled);
  event StakeDeposited(address owner, DepositIdentifier indexed depositId, uint256 amount, uint256 depositBalance);
  event StakeWithdrawn(DepositIdentifier indexed depositId, uint256 amount, uint256 depositBalance);
  event SurrogateDeployed(address indexed delegatee, address indexed surrogate);

  struct Deposit {
    uint96 balance;
    address owner;
    address delegatee;
    address beneficiary;
  }

  function ALTER_BENEFICIARY_TYPEHASH() external view returns (bytes32);
  function ALTER_DELEGATEE_TYPEHASH() external view returns (bytes32);
  function CLAIM_REWARD_TYPEHASH() external view returns (bytes32);
  function REWARD_DURATION() external view returns (uint256);
  function REWARD_TOKEN() external view returns (address);
  function SCALE_FACTOR() external view returns (uint256);
  function STAKE_MORE_TYPEHASH() external view returns (bytes32);
  function STAKE_TOKEN() external view returns (address);
  function STAKE_TYPEHASH() external view returns (bytes32);
  function WITHDRAW_TYPEHASH() external view returns (bytes32);
  function admin() external view returns (address);
  function alterBeneficiary(DepositIdentifier _depositId, address _newBeneficiary) external;
  function alterBeneficiaryOnBehalf(
    DepositIdentifier _depositId,
    address _newBeneficiary,
    address _depositor,
    uint256 _deadline,
    bytes memory _signature
  ) external;
  function alterDelegatee(DepositIdentifier _depositId, address _newDelegatee) external;
  function alterDelegateeOnBehalf(
    DepositIdentifier _depositId,
    address _newDelegatee,
    address _depositor,
    uint256 _deadline,
    bytes memory _signature
  ) external;
  function beneficiaryRewardPerTokenCheckpoint(address account) external view returns (uint256);
  function claimReward() external returns (uint256);
  function claimRewardOnBehalf(address _beneficiary, uint256 _deadline, bytes memory _signature)
    external
    returns (uint256);
  function depositorTotalStaked(address depositor) external view returns (uint256 amount);
  function deposits(DepositIdentifier depositId)
    external
    view
    returns (uint96 balance, address owner, address delegatee, address beneficiary);
  function earningPower(address beneficiary) external view returns (uint256 amount);
  function eip712Domain()
    external
    view
    returns (
      bytes1 fields,
      string memory name,
      string memory version,
      uint256 chainId,
      address verifyingContract,
      bytes32 salt,
      uint256[] memory extensions
    );
  function invalidateNonce() external;
  function isRewardNotifier(address rewardNotifier) external view returns (bool);
  function lastCheckpointTime() external view returns (uint256);
  function lastTimeRewardDistributed() external view returns (uint256);
  function multicall(bytes[] memory data) external returns (bytes[] memory results);
  function nonces(address owner) external view returns (uint256);
  function notifyRewardAmount(uint256 _amount) external;
  function permitAndStake(
    uint96 _amount,
    address _delegatee,
    address _beneficiary,
    uint256 _deadline,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external returns (DepositIdentifier _depositId);
  function permitAndStakeMore(
    DepositIdentifier _depositId,
    uint96 _amount,
    uint256 _deadline,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external;
  function rewardEndTime() external view returns (uint256);
  function rewardPerTokenAccumulated() external view returns (uint256);
  function rewardPerTokenAccumulatedCheckpoint() external view returns (uint256);
  function scaledRewardRate() external view returns (uint256);
  function scaledUnclaimedRewardCheckpoint(address account) external view returns (uint256 amount);
  function setAdmin(address _newAdmin) external;
  function setRewardNotifier(address _rewardNotifier, bool _isEnabled) external;
  function stake(uint96 _amount, address _delegatee, address _beneficiary)
    external
    returns (DepositIdentifier _depositId);
  function stake(uint96 _amount, address _delegatee) external returns (DepositIdentifier _depositId);
  function stakeMore(DepositIdentifier _depositId, uint96 _amount) external;
  function stakeMoreOnBehalf(
    DepositIdentifier _depositId,
    uint96 _amount,
    address _depositor,
    uint256 _deadline,
    bytes memory _signature
  ) external;
  function stakeOnBehalf(
    uint96 _amount,
    address _delegatee,
    address _beneficiary,
    address _depositor,
    uint256 _deadline,
    bytes memory _signature
  ) external returns (DepositIdentifier _depositId);
  function surrogates(address delegatee) external view returns (address surrogate);
  function totalStaked() external view returns (uint256);
  function unclaimedReward(address _beneficiary) external view returns (uint256);
  function withdraw(DepositIdentifier _depositId, uint96 _amount) external;
  function withdrawOnBehalf(
    DepositIdentifier _depositId,
    uint96 _amount,
    address _depositor,
    uint256 _deadline,
    bytes memory _signature
  ) external;
}
