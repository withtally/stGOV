// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

library Staker {
  type DepositIdentifier is uint256;
}

interface IGovLst {
  struct RewardParameters {
    uint80 payoutAmount;
    uint16 feeBips;
    address feeCollector;
  }

  error AddressEmptyCode(address target);
  error AddressInsufficientBalance(address account);
  error FailedInnerCall();
  error GovLst__EarningPowerNotQualified(uint256 earningPower, uint256 thresholdEarningPower);
  error GovLst__FeeBipsExceedMaximum(uint16 feeBips, uint16 maxFeeBips);
  error GovLst__FeeCollectorCannotBeZeroAddress();
  error GovLst__InsufficientBalance();
  error GovLst__InsufficientRewards();
  error GovLst__InvalidDeposit();
  error GovLst__InvalidFeeParameters();
  error GovLst__InvalidOverride();
  error GovLst__InvalidParameter();
  error GovLst__InvalidSignature();
  error GovLst__SignatureExpired();
  error GovLst__Unauthorized();
  error InvalidAccountNonce(address account, uint256 currentNonce);
  error InvalidShortString();
  error OwnableInvalidOwner(address owner);
  error OwnableUnauthorizedAccount(address account);
  error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);
  error SafeERC20FailedOperation(address token);
  error StringTooLong(string str);

  event Approval(address indexed owner, address indexed spender, uint256 value);
  event DefaultDelegateeSet(address oldDelegatee, address newDelegatee);
  event DelegateeGuardianSet(address oldDelegatee, address newDelegatee);
  event DepositInitialized(address indexed delegatee, Staker.DepositIdentifier depositId);
  event DepositSubsidized(Staker.DepositIdentifier indexed depositId, uint256 amount);
  event DepositUpdated(
    address indexed holder, Staker.DepositIdentifier oldDepositId, Staker.DepositIdentifier newDepositId
  );
  event EIP712DomainChanged();
  event MinQualifyingEarningPowerBipsSet(
    uint256 _oldMinQualifyingEarningPowerBips, uint256 _newMinQualifyingEarningPowerBips
  );
  event OverrideEnacted(Staker.DepositIdentifier depositId);
  event OverrideMigrated(Staker.DepositIdentifier depositId, address oldDelegatee, address newDelegatee);
  event OverrideRevoked(Staker.DepositIdentifier depositId);
  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
  event PayoutAmountSet(uint256 oldPayoutAmount, uint256 newPayoutAmount);
  event RewardDistributed(
    address indexed claimer,
    address indexed recipient,
    uint256 rewardsClaimed,
    uint256 payoutAmount,
    uint256 feeAmount,
    address feeCollector
  );
  event RewardParametersSet(uint256 payoutAmount, uint256 feeBips, address feeCollector);
  event Staked(address indexed account, uint256 amount);
  event StakedWithAttribution(Staker.DepositIdentifier _depositId, uint256 _amount, address indexed _referrer);
  event Transfer(address indexed from, address indexed to, uint256 value);
  event Unstaked(address indexed account, uint256 amount);

  function BIPS() external view returns (uint16);
  function DEFAULT_DEPOSIT_ID() external view returns (Staker.DepositIdentifier);
  function DOMAIN_SEPARATOR() external view returns (bytes32);
  function FIXED_LST() external view returns (address);
  function MAX_FEE_BIPS() external view returns (uint16);
  function MINIMUM_QUALIFYING_EARNING_POWER_BIPS_CAP() external view returns (uint256);
  function PERMIT_TYPEHASH() external view returns (bytes32);
  function REWARD_TOKEN() external view returns (address);
  function SHARE_SCALE_FACTOR() external view returns (uint256);
  function STAKER() external view returns (address);
  function STAKE_TOKEN() external view returns (address);
  function WITHDRAW_GATE() external view returns (address);
  function allowance(address holder, address spender) external view returns (uint256 amount);
  function approve(address _spender, uint256 _amount) external returns (bool);
  function balanceCheckpoint(address _holder) external view returns (uint256 _balanceCheckpoint);
  function balanceOf(address _holder) external view returns (uint256);
  function claimAndDistributeReward(
    address _recipient,
    uint256 _minExpectedReward,
    Staker.DepositIdentifier[] memory _depositIds
  ) external;
  function convertToFixed(address _account, uint256 _amount) external returns (uint256);
  function convertToRebasing(address _account, uint256 _shares) external returns (uint256);
  function convertToRebasingAndUnstake(address _account, uint256 _shares) external returns (uint256);
  function decimals() external pure returns (uint8);
  function defaultDelegatee() external view returns (address);
  function delegate(address _delegatee) external returns (Staker.DepositIdentifier _depositId);
  function delegateeForHolder(address _holder) external view returns (address _delegatee);
  function delegateeGuardian() external view returns (address);
  function delegates(address _holder) external view returns (address);
  function depositForDelegatee(address _delegatee) external view returns (Staker.DepositIdentifier);
  function depositIdForHolder(address _holder) external view returns (Staker.DepositIdentifier);
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
  function enactOverride(Staker.DepositIdentifier _depositId) external;
  function feeAmount() external view returns (uint256);
  function feeCollector() external view returns (address);
  function fetchOrInitializeDepositForDelegatee(address _delegatee) external returns (Staker.DepositIdentifier);
  function isGuardianControlled() external view returns (bool);
  function isOverridden(Staker.DepositIdentifier depositId) external view returns (bool isOverridden);
  function migrateOverride(Staker.DepositIdentifier _depositId) external;
  function minQualifyingEarningPowerBips() external view returns (uint256);
  function multicall(bytes[] memory data) external returns (bytes[] memory results);
  function name() external view returns (string memory);
  function nonces(address _owner) external view returns (uint256);
  function owner() external view returns (address);
  function payoutAmount() external view returns (uint256);
  function permit(address _owner, address _spender, uint256 _value, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
    external;
  function renounceOwnership() external;
  function revokeOverride(Staker.DepositIdentifier _depositId, address _originalDelegatee) external;
  function setDefaultDelegatee(address _newDelegatee) external;
  function setDelegateeGuardian(address _newDelegateeGuardian) external;
  function setMinQualifyingEarningPowerBips(uint256 _minQualifyingEarningPowerBips) external;
  function setRewardParameters(RewardParameters memory _params) external;
  function sharesForStake(uint256 _amount) external view returns (uint256);
  function sharesOf(address _holder) external view returns (uint256 _sharesOf);
  function stake(uint256 _amount) external returns (uint256);
  function stakeAndConvertToFixed(address _account, uint256 _amount) external returns (uint256);
  function stakeForShares(uint256 _shares) external view returns (uint256);
  function stakeWithAttribution(uint256 _amount, address _referrer) external returns (uint256);
  function subsidizeDeposit(Staker.DepositIdentifier _depositId, uint256 _amount) external;
  function symbol() external view returns (string memory);
  function totalShares() external view returns (uint256);
  function totalSupply() external view returns (uint256);
  function transfer(address _to, uint256 _value) external returns (bool);
  function transferAndReturnBalanceDiffs(address _receiver, uint256 _value)
    external
    returns (uint256 _senderBalanceDecrease, uint256 _receiverBalanceIncrease);
  function transferFixed(address _sender, address _receiver, uint256 _shares)
    external
    returns (uint256 _senderSharesDecrease, uint256 _receiverSharesIncrease);
  function transferFrom(address _from, address _to, uint256 _value) external returns (bool);
  function transferFromAndReturnBalanceDiffs(address _from, address _to, uint256 _value)
    external
    returns (uint256 _senderBalanceDecrease, uint256 _receiverBalanceIncrease);
  function transferOwnership(address newOwner) external;
  function unstake(uint256 _amount) external returns (uint256);
  function updateDeposit(Staker.DepositIdentifier _newDepositId) external;
  function updateFixedDeposit(address _account, Staker.DepositIdentifier _newDepositId)
    external
    returns (Staker.DepositIdentifier _oldDepositId);
  function version() external view returns (string memory);
}
