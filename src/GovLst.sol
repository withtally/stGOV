// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Staker} from "staker/Staker.sol";
import {WithdrawGate} from "./WithdrawGate.sol";
import {FixedGovLst} from "./FixedGovLst.sol";
import {FixedLstAddressAlias} from "./FixedLstAddressAlias.sol";

/// @title GovLst
/// @author [ScopeLift](https://scopelift.co)
/// @notice A liquid staking token implemented on top of Staker. Users can deposit a governance token and receive
/// a liquid staked governance token in exchange. Holders can specify a delegatee to which staked tokens' voting weight
/// will be delegated. 1 staked token is equivalent to 1 underlying governance token. As rewards are distributed,
/// holders' balances automatically increase to reflect their share of the rewards earned. Reward balances are delegated
/// to a default delegatee set by the token owner. Holders can consolidate their voting weight back to their chosen
/// delegate. Holders who don't specify a custom delegatee also have their stake's voting weight assigned to the default
/// delegatee.
///
/// To enable delegation functionality, the LST must manage an individual stake deposit for each delegatee,
/// including one for the default delegatee. As tokens are staked, unstaked, or transferred, the LST must move tokens
/// between these deposits to reflect the changing state. Because a holder balance is a dynamic calculation based on
/// its share of the total staked supply, the balance is subject to truncation. Care must be taken to ensure all
/// deposits remain solvent. Where a deposit might be left short due to truncation, we aim to accumulate these
/// shortfalls in the default deposit, which can be subsidized to remain solvent.
abstract contract GovLst is IERC20, IERC20Metadata, IERC20Permit, Ownable, Multicall, EIP712, Nonces {
  using FixedLstAddressAlias for address;
  using SafeCast for uint256;
  using SafeERC20 for IERC20;

  /// @notice Emitted when the LST owner updates the payout amount required for the MEV reward game in
  /// `claimAndDistributeReward`.
  event PayoutAmountSet(uint256 oldPayoutAmount, uint256 newPayoutAmount);

  /// @notice Emitted when the LST owner updates the reward parameters.
  event RewardParametersSet(uint256 payoutAmount, uint256 feeBips, address feeCollector);

  /// @notice Emitted when the default delegatee is updated by the owner or guardian.
  event DefaultDelegateeSet(address oldDelegatee, address newDelegatee);

  /// @notice Emitted when the delegatee guardian is updated by the owner or guardian itself.
  event DelegateeGuardianSet(address oldDelegatee, address newDelegatee);

  /// @notice Emitted when the max override tip is set.
  event MaxOverrideTipSet(uint256 _oldMaxOverrideTip, uint256 _newMaxOverrideTip);

  /// @notice Emitted when the minimum qualifying earning power bips is set.
  event MinQualifyingEarningPowerBipsSet(
    uint256 _oldMinQualifyingEarningPowerBips, uint256 _newMinQualifyingEarningPowerBips
  );

  /// @notice Emitted when a stake deposit is initialized for a new delegatee.
  event DepositInitialized(address indexed delegatee, Staker.DepositIdentifier depositId);

  /// @notice Emitted when a user updates their stake deposit, moving their staked tokens accordingly.
  /// @dev This event must be combined with the `DepositUpdated` event on the FixedGovLst for an accurate picture all
  /// deposit ids for a given holder.
  event DepositUpdated(
    address indexed holder, Staker.DepositIdentifier oldDepositId, Staker.DepositIdentifier newDepositId
  );

  /// @notice Emitted when a user stakes tokens in exchange for liquid staked tokens.
  event Staked(address indexed account, uint256 amount);

  /// @notice Emitted when a user exchanges their liquid staked tokens for the underlying staked token.
  event Unstaked(address indexed account, uint256 amount);

  /// @notice Emitted when a deposit delegatee is overridden to the default delegatee.
  event OverrideEnacted(Staker.DepositIdentifier depositId, address tipReceiver, uint160 tipShares);

  /// @notice Emitted when an overridden deposit delegatee is set back to the original delegatee.
  event OverrideRevoked(Staker.DepositIdentifier depositId, address tipReceiver, uint160 tipShares);

  /// @notice Emitted when an overridden deposit is migrated to a new default delegatee.
  event OverrideMigrated(
    Staker.DepositIdentifier depositId,
    address oldDelegatee,
    address newDelegatee,
    address tipReceiver,
    uint160 tipShares
  );

  ///@notice Emitted when a reward is distributed by an MEV searcher who claims the LST's stake rewards in exchange
  /// for providing the payout amount of the stake token to the LST.
  event RewardDistributed(
    address indexed claimer,
    address indexed recipient,
    uint256 rewardsClaimed,
    uint256 payoutAmount,
    uint256 feeAmount,
    address feeCollector
  );

  /// @notice Struct to encapsulate reward-related parameters.
  struct RewardParameters {
    /// @notice The amount of stake token that an MEV searcher must provide in order to earn the right to claim the
    /// stake rewards earned by the LST. Can be set by the LST owner.
    uint80 payoutAmount;
    /// @notice The amount of stake token issued to the fee collector, expressed in basis points.
    /// @dev Fee in basis points (1 bips = 0.01%)
    uint16 feeBips;
    /// @notice The address that receives the fees when rewards are distributed.
    address feeCollector;
  }

  /// @notice Emitted when a user stakes and attributes their staking action to a referrer address.
  event StakedWithAttribution(Staker.DepositIdentifier _depositId, uint256 _amount, address indexed _referrer);

  /// @notice Emitted when someone irrevocably adds stake tokens to a deposit without receiving liquid tokens.
  event DepositSubsidized(Staker.DepositIdentifier indexed depositId, uint256 amount);

  /// @notice Thrown when an operation to change the default delegatee or its guardian is attempted by an account that
  /// does not have permission to alter it.
  error GovLst__Unauthorized();

  /// @notice Thrown when an operation is not possible because the holder's balance is insufficient.
  error GovLst__InsufficientBalance();

  /// @notice Thrown when a caller (likely an MEV searcher) would receive an insufficient payout in
  /// `claimAndDistributeReward`.
  error GovLst__InsufficientRewards();

  /// @notice Thrown when the LST owner attempts to set invalid fee parameters.
  error GovLst__InvalidFeeParameters();

  /// @notice Thrown by signature-based "onBehalf" methods when a signature is invalid.
  error GovLst__InvalidSignature();

  /// @notice Thrown by signature-based "onBehalf" methods when a signature is past its expiry date.
  error GovLst__SignatureExpired();

  /// @notice Thrown when the fee bips exceed the maximum allowed value.
  error GovLst__FeeBipsExceedMaximum(uint16 feeBips, uint16 maxFeeBips);

  /// @notice Thrown when attempting to set the fee collector to the zero address.
  error GovLst__FeeCollectorCannotBeZeroAddress();

  /// @notice Thrown when attempting to improperly override a deposit's delegatee.
  error GovLst__InvalidOverride();

  /// @notice Thrown when attempting to update a parameter with an invalid value.
  error GovLst__InvalidParameter();

  /// @notice Thrown when an overrider requests a tip greater than the max tip.
  error GovLst__GreaterThanMaxTip();

  /// @notice Thrown when a deposit does not have the required amount of earning power for a certain action to be taken.
  /// An example of this is an attempted override of a deposit that has an earning power above the minimum earning power
  /// threshold.
  error GovLst__EarningPowerNotQualified(uint256 earningPower, uint256 thresholdEarningPower);

  /// @notice Thrown when a holder tries to update their deposit to an invalid deposit.
  error GovLst__InvalidDeposit();

  /// @notice The Staker instance in which staked tokens will be deposited to earn rewards.
  Staker public immutable STAKER;

  /// @notice The governance token used by the staking system.
  IERC20 public immutable STAKE_TOKEN;

  /// @notice The token distributed as rewards by the staking instance.
  IERC20 public immutable REWARD_TOKEN;

  /// @notice A coupled contract used by the LST to enforce an optional delay when withdrawing staked tokens from the
  /// LST. Can be used to prevent users from frontrunning rewards by staking and withdrawing repeatedly at opportune
  /// times. Said strategy would likely be unprofitable due to gas fees, but we eliminate the possibility via a delay.
  WithdrawGate public immutable WITHDRAW_GATE;

  /// @notice A coupled ERC20 contract that represents a fixed balance version of the LST. Whereas this  LST has
  /// dynamic, rebasing balances, the Fixed LST is deployed alongside of it but has balances that remain fixed. To
  /// achieve this, the Fixed LST contract is privileged to make special calls on behalf if its holders, allowing the
  /// Fixed LST to use the same accounting system as this rebasing LST.
  FixedGovLst public immutable FIXED_LST;

  /// @notice The deposit identifier of the default deposit.
  Staker.DepositIdentifier public immutable DEFAULT_DEPOSIT_ID;

  /// @notice Scale factor applied to the stake token before converting it to shares, which are tracked internally and
  /// used to
  /// calculate holders' balances dynamically as rewards are accumulated.
  uint256 public constant SHARE_SCALE_FACTOR = 1e10;

  /// @notice Data structure for global totals for the LST.
  /// @param supply The total staked tokens in the whole system, which by definition also represents the total supply
  /// of the LST token itself.
  /// @param shares The total shares that have been issued to all token holders, representing their proportional claim
  /// on the total supply.
  /// @dev The data types chosen for each parameter are meant to enable the data to pack into a single slot, while
  /// ensuring that real values occurring in the system are safe from overflow.
  struct Totals {
    uint96 supply;
    uint160 shares;
  }

  /// @notice Data structure for data pertaining to a given LST holder.
  /// @param depositId The staking system deposit identifier corresponding to the holder's delegatee of choice.
  /// @param balanceCheckpoint The portion of the holder's balance that is currently delegated to the delegatee of
  /// their choosing. LST tokens are assigned to this delegatee when a user stakes or receives tokens via transfer.
  /// When rewards are distributed, they accrue to the default delegatee unless the holder chooses to consolidate them.
  /// Holders who leave their delegatee set to the default have a balance checkpoint of zero by definition.
  /// @param shares The number of shares held by this holder, used to calculate the holder's balance dynamically, based
  /// on their proportion of the total shares, and thus the total staked supply.
  /// @dev The data types chosen for each parameter are meant to enable the data to pack into a single slot while still
  /// being safe from overflow for real values that can occur in the system.
  struct HolderState {
    uint32 depositId;
    uint96 balanceCheckpoint;
    uint128 shares;
  }

  /// @notice Data structure for deploying the `GovLst`.
  /// @param _fixedLstName The name for the fixed liquid stake token.
  /// @param _fixedLstSymbol The symbol for the fixed liquid stake token.
  /// @param _rebasingLstName The name for the rebasing liquid stake token.
  /// @param _rebasingLstSymbol The symbol for the rebasing liquid stake token.
  /// @param _staker The staker deployment where tokens will be staked.
  /// @param _initialDefaultDelegatee The initial delegatee to which the default deposit will be delegated.
  /// @param _initialOwner The address of the initial LST owner.
  /// @param _initialPayoutAmount The initial amount that must be provided to win the MEV race and claim the LST's
  /// stake rewards.
  /// @param _stakeToBurn The stake amount to burn in order to avoid divide by 0 errors. A reasonable value for this
  /// would be 1e15.
  /// @param _maxOverrideTip The max tip an overrider can request for performing an override action.
  /// @param _minQualifyingEarningPowerBips The minimum qualifying earning power amount in BIPs (1/10,000) for a deposit
  /// to not be overridden.
  struct ConstructorParams {
    string fixedLstName;
    string fixedLstSymbol;
    string rebasingLstName;
    string rebasingLstSymbol;
    string version;
    Staker staker;
    address initialDefaultDelegatee;
    address initialOwner;
    uint80 initialPayoutAmount;
    address initialDelegateeGuardian;
    uint256 stakeToBurn;
    uint256 maxOverrideTip;
    uint256 minQualifyingEarningPowerBips;
  }

  /// @notice Type hash used when encoding data for `permit` calls.
  bytes32 public constant PERMIT_TYPEHASH =
    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

  /// @notice The name of the LST token.
  string private NAME;

  /// @notice The symbol of the LST token.
  string private SYMBOL;

  /// @notice The denominator for a basis point which is 1/100 of a percentage point.
  uint16 public constant BIPS = 1e4;

  /// @notice Maximum allowable fee in basis points (20%).
  uint16 public constant MAX_FEE_BIPS = 2000;

  /// @notice Maximum BIPs value for minimum qualifying earning power BIPs.
  uint256 public immutable MINIMUM_QUALIFYING_EARNING_POWER_BIPS_CAP = 20_000;

  /// @notice Maximum value to set the max override tip.
  uint256 public immutable MAX_OVERRIDE_TIP_CAP = 2000e18;

  /// @notice The global total supply and total shares for the LST.
  Totals internal totals;

  /// @notice The delegatee to whom the voting weight in the default deposit is delegated. Can be set by the LST owner,
  /// or the delegatee guardian. Once the guardian sets it, only the guardian can change it moving forward. The owner
  /// is no longer able to update it.
  address public defaultDelegatee;

  /// @notice Address which has the right to update the default delegatee assigned to the default deposit. Once this
  /// address takes an action, it can no longer be changed or overridden by the LST owner.
  address public delegateeGuardian;

  /// @notice One way switch that flips to true when the delegatee guardian takes its first action. Once set to true,
  /// the default delegatee and the guardian address can only be changed by the guardian itself.
  bool public isGuardianControlled;

  /// @notice The max tip an overrider can request.
  uint256 public maxOverrideTip;

  /// @notice The minimum qualifying earning amount in bips (1/10,000).
  uint256 public minQualifyingEarningPowerBips;

  /// @notice Struct to store reward-related parameters.
  RewardParameters internal rewardParams;

  /// @notice Mapping of delegatee address to the delegate's GovLST-created Staker deposit identifier. The
  /// delegatee for a given deposit can not change. All LST holders who choose the same delegatee will have their
  /// tokens staked in the corresponding deposit. Each delegatee can only have a single deposit.
  mapping(address delegatee => Staker.DepositIdentifier depositId) internal storedDepositIdForDelegatee;

  /// @notice Mapping of holder addresses to the data pertaining to their holdings.
  mapping(address holder => HolderState state) private holderStates;

  /// @notice Mapping used to determine the amount of LST tokens the spender has been approved to transfer on the
  /// holder's behalf.
  mapping(address holder => mapping(address spender => uint256 amount)) public allowance;

  /// @notice A mapping used to determine if a deposit's delegatee has been overridden to the default delegatee.
  mapping(Staker.DepositIdentifier depositId => bool isOverridden) public isOverridden;

  constructor(ConstructorParams memory _params)
    Ownable(_params.initialOwner)
    EIP712(_params.rebasingLstName, _params.version)
  {
    STAKER = _params.staker;
    STAKE_TOKEN = IERC20(_params.staker.STAKE_TOKEN());
    REWARD_TOKEN = IERC20(_params.staker.REWARD_TOKEN());
    NAME = _EIP712Name();
    SYMBOL = _params.rebasingLstSymbol;

    _setDefaultDelegatee(_params.initialDefaultDelegatee);
    _setRewardParams(_params.initialPayoutAmount, 0, _params.initialOwner);
    _setDelegateeGuardian(_params.initialDelegateeGuardian);
    _setMaxOverrideTip(_params.maxOverrideTip);
    _setMinQualifyingEarningPowerBips(_params.minQualifyingEarningPowerBips);

    STAKE_TOKEN.approve(address(_params.staker), type(uint256).max);
    // Create initial deposit for default so other methods can assume it exists.
    DEFAULT_DEPOSIT_ID = STAKER.stake(0, _params.initialDefaultDelegatee);
    STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), _params.stakeToBurn);
    _stake(address(this), _params.stakeToBurn);

    // Deploy the WithdrawGate
    WITHDRAW_GATE = new WithdrawGate(_params.initialOwner, address(this), address(STAKE_TOKEN), 0);
    FIXED_LST = _deployFixedGovLst(
      _params.fixedLstName, _params.fixedLstSymbol, _params.version, this, STAKE_TOKEN, SHARE_SCALE_FACTOR
    );
  }

  /// @notice The name of the liquid stake token.
  function name() external view virtual override returns (string memory) {
    return NAME;
  }

  /// @notice The symbol for the liquid stake token.
  function symbol() external view virtual override returns (string memory) {
    return SYMBOL;
  }

  /// @notice The decimal precision which the LST tokens stores its balances with.
  function decimals() external pure virtual override returns (uint8) {
    return 18;
  }

  /// @notice The EIP712 signing version of the contract.
  function version() external view virtual returns (string memory) {
    return _EIP712Version();
  }

  /// @notice The total amount of LST token supply, also equal to the total number of stake tokens in the system.
  function totalSupply() external view virtual returns (uint256) {
    return uint256(totals.supply);
  }

  /// @notice The total number of outstanding shares issued to LST token holders. Each shares represents a proportional
  /// claim on the LST's total supply. As rewards are distributed, each share becomes worth proportionally more.
  function totalShares() external view virtual returns (uint256) {
    return uint256(totals.shares);
  }

  /// @notice Returns the number of shares that are valued at a given amount of stake token. Note that shares have a
  /// scale factor of `SHARE_SCALE_FACTOR` applied to minimize precision loss due to truncation.
  /// @param _amount The quantity of stake token that will be converted to a number of shares.
  /// @return The quantity of shares that is worth the requested quantity of stake token.
  function sharesForStake(uint256 _amount) external view virtual returns (uint256) {
    Totals memory _totals = totals;
    return _calcSharesForStakeUp(_amount, _totals);
  }

  /// @notice Returns the quantity of stake tokens that a given number of shares is valued at. In other words,
  /// ownership of a given number of shares translates to a claim on the quantity of stake tokens returned.
  /// @param _amount The quantity of shares that will be converted to stake tokens.
  /// @return The quantity of stake tokens which backs the provided quantity of shares.
  function stakeForShares(uint256 _amount) public view virtual returns (uint256) {
    Totals memory _totals = totals;
    return _calcStakeForShares(_amount, _totals);
  }

  /// @notice The current balance of LST tokens owned by the holder. Unlike a standard ERC20, this amount is calculated
  /// dynamically based on the holder's shares and the total supply of the LST. As rewards are distributed, a holder's
  /// balance will increase, even if they take no actions. In certain circumstances, a holder's balance can also
  /// decrease by tiny amounts without any action taken by the holder. This is due to changes in the global number of
  /// shares and supply resulting in a slightly different balance calculation after rounding.
  function balanceOf(address _holder) external view virtual returns (uint256) {
    HolderState memory _holderState = holderStates[_holder];
    Totals memory _totals = totals;

    return _calcBalanceOf(_holderState, _totals);
  }

  /// @notice The number of shares a given holder owns. Unlike a holder's balance, shares are stored statically and do
  /// not change unless the user is subject to some action, such as staking, unstaking, or transferring. The user's
  /// balance is calculated based on their proportion of the total outstanding shares.
  function sharesOf(address _holder) external view virtual returns (uint256 _sharesOf) {
    _sharesOf = holderStates[_holder].shares;
  }

  /// @notice The portion of the holder's balance that is currently delegated to the delegatee of their
  /// choosing. When a user stakes or receives LST tokens via transfer, they are a assigned to their delegatee, and
  /// accounted for in the balance checkpoint. This means the tokens are held in the corresponding deposit, and the
  /// voting weight for these tokens is assigned to the holder's chosen delegatee. When rewards are distributed, they
  /// accrue to the default delegatee unless the holder chooses to consolidate them. Therefore, the difference between
  /// the user's live balance and their balance checkpoint represents the number of tokens the holder has claim to that
  /// are currently held in the default deposit. Holders who leave their delegatee set to the default have a balance
  /// checkpoint of zero by definition.
  function balanceCheckpoint(address _holder) external view virtual returns (uint256 _balanceCheckpoint) {
    _balanceCheckpoint = holderStates[_holder].balanceCheckpoint;
  }

  /// @notice The delegatee to which a given holder of LST tokens has assigned their voting weight.
  /// @param _holder The holder in question.
  /// @return _delegatee The address to which this holder has assigned his staked voting weight.
  function delegateeForHolder(address _holder) external view virtual returns (address _delegatee) {
    HolderState memory _holderState = holderStates[_holder];
    (,,, _delegatee,,,) = STAKER.deposits(_calcDepositId(_holderState));
  }

  /// @notice The stake deposit identifier associated with a given delegatee address.
  /// @param _delegatee The delegatee in question.
  /// @return The deposit identifier of the deposit in question.
  function depositForDelegatee(address _delegatee) public view virtual returns (Staker.DepositIdentifier) {
    if (_delegatee == defaultDelegatee || _delegatee == address(0)) {
      return DEFAULT_DEPOSIT_ID;
    } else {
      return storedDepositIdForDelegatee[_delegatee];
    }
  }

  /// @notice Returns the stake deposit identifier a given LST holder address is currently assigned to. If the
  /// address has not set a deposit identifier, it returns the default deposit.
  function depositIdForHolder(address _holder) external view virtual returns (Staker.DepositIdentifier) {
    HolderState memory _holderState = holderStates[_holder];
    return _calcDepositId(_holderState);
  }

  /// @notice Returns the current fee amount based on feeBips and payoutAmount.
  function feeAmount() external view virtual returns (uint256) {
    return _calcFeeAmount(rewardParams);
  }

  /// @notice Returns the current fee collector address.
  function feeCollector() external view virtual returns (address) {
    return rewardParams.feeCollector;
  }

  /// @notice Returns the current payout amount.
  function payoutAmount() external view virtual returns (uint256) {
    return uint256(rewardParams.payoutAmount);
  }

  /// @notice Get the current nonce for an owner
  /// @dev This function explicitly overrides both Nonces and IERC20Permit to allow compatibility
  /// @param _owner The address of the owner
  /// @return The current nonce for the owner
  function nonces(address _owner) public view virtual override(Nonces, IERC20Permit) returns (uint256) {
    return Nonces.nonces(_owner);
  }

  /// @notice The domain separator used by this contract for all EIP712 signature based methods.
  function DOMAIN_SEPARATOR() external view virtual returns (bytes32) {
    return _domainSeparatorV4();
  }

  /// @notice Returns the deposit identifier managed by the LST for a given delegatee. If that deposit does not yet
  /// exist, it initializes it. A depositor can call this method if the deposit for their chosen delegatee has not been
  /// previously initialized.
  /// @param _delegatee The address of the delegatee.
  /// @return The deposit identifier of the existing, or newly created, stake deposit for this delegatee.
  function fetchOrInitializeDepositForDelegatee(address _delegatee) public virtual returns (Staker.DepositIdentifier) {
    Staker.DepositIdentifier _depositId = depositForDelegatee(_delegatee);

    if (Staker.DepositIdentifier.unwrap(_depositId) != 0) {
      return _depositId;
    }

    // Create a new deposit for this delegatee if one is not yet managed by the LST
    _depositId = STAKER.stake(0, _delegatee);
    storedDepositIdForDelegatee[_delegatee] = _depositId;
    emit DepositInitialized(_delegatee, _depositId);
    return _depositId;
  }

  /// @notice Sets the deposit to which the message sender is choosing to assign their staked tokens. By using offchain
  /// indexing to find the deposit identifier corresponding with the delegatee of their choice, LST holders can choose
  /// to which address they want to assign the voting weight of their staked tokens. Additional staked tokens, or
  /// tokens transferred to the holder, will be moved into this deposit. Tokens distributed as rewards will remain in
  /// the default deposit, however holders may consolidate their reward tokens back to their preferred delegatee by
  /// calling this method again, even with their existing deposit identifier.
  /// @param _newDepositId The stake deposit identifier to which this holder's staked tokens will be moved to and
  /// kept in henceforth.
  function updateDeposit(Staker.DepositIdentifier _newDepositId) public virtual {
    Staker.DepositIdentifier _oldDepositId = _updateDeposit(msg.sender, _newDepositId);
    _emitDepositUpdatedEvent(msg.sender, _oldDepositId, _newDepositId);
  }

  /// @notice Stake tokens to receive liquid stake tokens. The caller must pre-approve the LST contract to spend at
  /// least the would-be amount of tokens.
  /// @param _amount The quantity of tokens that will be staked.
  /// @dev The increase in the holder's balance after staking may be slightly less than the amount staked due to
  /// rounding.
  function stake(uint256 _amount) external virtual returns (uint256) {
    STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);
    _emitStakedEvent(msg.sender, _amount);
    _emitTransferEvent(address(0), msg.sender, _amount);
    return _stake(msg.sender, _amount);
  }

  /// @notice Stake tokens to receive liquid stake tokens, while also declaring the address that is responsible for
  /// referring the holder to the LST. This can be, for example, the owner of the frontend client who allowed the
  /// holder to interact with the contracts onchain. The call must pre-approve the LST contract to spend at least the
  /// would-be amount of tokens.
  /// @param _amount The quantity of tokens that will be staked.
  /// @param _referrer The address the holder is declaring has referred them to the LST. It will be emitted in an
  /// attribution event, but not otherwise used.
  function stakeWithAttribution(uint256 _amount, address _referrer) external virtual returns (uint256) {
    Staker.DepositIdentifier _depositId = _calcDepositId(holderStates[msg.sender]);
    emit StakedWithAttribution(_depositId, _amount, _referrer);
    STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);
    _emitStakedEvent(msg.sender, _amount);
    _emitTransferEvent(address(0), msg.sender, _amount);
    return _stake(msg.sender, _amount);
  }

  /// @notice Destroy liquid staked tokens to receive the underlying token in exchange. Tokens are removed first from
  /// the default deposit, if any are present, then from holder's specified deposit if any are needed.
  /// @param _amount The amount of tokens to unstake.
  /// @dev The amount of tokens actually unstaked may be slightly less than the amount specified due to rounding.
  function unstake(uint256 _amount) external virtual returns (uint256) {
    _emitUnstakedEvent(msg.sender, _amount);
    _emitTransferEvent(msg.sender, address(0), _amount);
    return _unstake(msg.sender, _amount);
  }

  /// @notice Grant an allowance to the spender to transfer up to a certain amount of LST tokens on behalf of the
  /// message sender.
  /// @param _spender The address which is granted the allowance to transfer from the message sender.
  /// @param _amount The total amount of the message sender's LST tokens that the spender will be permitted to transfer.
  function approve(address _spender, uint256 _amount) external virtual returns (bool) {
    allowance[msg.sender][_spender] = _amount;
    emit Approval(msg.sender, _spender, _amount);
    return true;
  }

  /// @notice Grant an allowance to the spender to transfer up to a certain amount of LST tokens on behalf of a user
  /// who has signed a message testifying to their intent to grant this allowance.
  /// @param _owner The account which is granting the allowance.
  /// @param _spender The address which is granted the allowance to transfer from the holder.
  /// @param _value The total amount of LST tokens the spender will be permitted to transfer from the holder.
  /// @param _deadline The timestamp after which the signature should expire.
  /// @param _v ECDSA signature component: Parity of the `y` coordinate of point `R`
  /// @param _r ECDSA signature component: x-coordinate of `R`
  /// @param _s ECDSA signature component: `s` value of the signature
  function permit(address _owner, address _spender, uint256 _value, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s)
    external
    virtual
  {
    if (block.timestamp > _deadline) {
      revert GovLst__SignatureExpired();
    }

    bytes32 _structHash;
    // Unchecked because the only math done is incrementing
    // the owner's nonce which cannot realistically overflow.
    unchecked {
      _structHash = keccak256(abi.encode(PERMIT_TYPEHASH, _owner, _spender, _value, _useNonce(_owner), _deadline));
    }

    bytes32 _hash = _hashTypedDataV4(_structHash);

    address _recoveredAddress = ecrecover(_hash, _v, _r, _s);

    if (_recoveredAddress == address(0) || _recoveredAddress != _owner) {
      revert GovLst__InvalidSignature();
    }

    allowance[_recoveredAddress][_spender] = _value;

    emit Approval(_owner, _spender, _value);
  }

  /// @notice Send liquid stake tokens from the message sender to the receiver.
  /// @param _to The address that will receive the message sender's tokens.
  /// @param _value The quantity of liquid stake tokens to send.
  /// @dev The sender's underlying tokens are moved first from the default deposit, if any are present, then from
  /// sender's specified deposit, if any are needed. All tokens are moved into the receiver's specified deposit.
  /// @dev The amount of tokens received by the user can be slightly less than the amount lost by the sender.
  /// Furthermore, both amounts can be less the value requested by the sender. All such effects are due to truncation.
  function transfer(address _to, uint256 _value) external virtual returns (bool) {
    _emitTransferEvent(msg.sender, _to, _value);
    _transfer(msg.sender, _to, _value);
    return true;
  }

  /// @notice Send liquid stake tokens from the message sender to the receiver, returning the changes in balances of
  /// each. Primarily intended for use by integrators, who might need to know the exact balance changes for internal
  /// accounting in other contracts.
  /// @param _receiver The address that will receive the message sender's tokens.
  /// @param _value The quantity of liquid stake tokens to send.
  /// @return _senderBalanceDecrease The amount by which the sender's balance of lst tokens decreased.
  /// @return _receiverBalanceIncrease The amount by which the receiver's balance of lst tokens increased.
  /// @dev The amount of tokens received by the user can be slightly less than the amount lost by the sender.
  /// Furthermore, both amounts can be less the value requested by the sender. All such effects are due to truncation.
  function transferAndReturnBalanceDiffs(address _receiver, uint256 _value)
    external
    virtual
    returns (uint256 _senderBalanceDecrease, uint256 _receiverBalanceIncrease)
  {
    _emitTransferEvent(msg.sender, _receiver, _value);
    return _transfer(msg.sender, _receiver, _value);
  }

  /// @notice Send liquid stake tokens from one account to the another on behalf of a user who has granted the
  /// message sender an allowance to do so.
  /// @param _from The address from where tokens will be transferred, which has previously granted the message sender
  /// an allowance of at least the quantity of tokens being transferred.
  /// @param _to The address that will receive the sender's tokens.
  /// @param _value The quantity of liquid stake tokens to send.
  /// @dev The sender's underlying tokens are moved first from the default deposit, if any are present, then from
  /// sender's specified deposit, if any are needed. All tokens are moved into the receiver's specified deposit.
  /// @dev The amount of tokens received by the receiver can be slightly less than the amount lost by the sender.
  /// Furthermore, both amounts can be less the value requested by the sender. All such effects are due to truncation.
  function transferFrom(address _from, address _to, uint256 _value) external virtual returns (bool) {
    _checkAndUpdateAllowance(_from, _value);
    _emitTransferEvent(_from, _to, _value);
    _transfer(_from, _to, _value);
    return true;
  }

  /// @notice Send liquid stake tokens from one account to the another on behalf of a user who has granted
  /// the message sender an allowance to do so, returning the changes in balances of each. Primarily intended for use
  /// by integrators, who might need to know the exact balance changes for internal accounting in other contracts.
  /// @param _from The address from where tokens will be transferred, which has previously granted the message sender
  /// an allowance of at least the quantity of tokens being transferred.
  /// @param _to The address that will receive the message sender's tokens.
  /// @param _value The quantity of liquid stake tokens to send.
  /// @return _senderBalanceDecrease The amount by which the sender's balance of lst tokens decreased.
  /// @return _receiverBalanceIncrease The amount by which the receiver's balance of lst tokens increased.
  /// @dev The amount of tokens received by the user can be slightly less than the amount lost by the sender.
  /// Furthermore, both amounts can be less the value requested by the sender. All such effects are due to truncation.
  function transferFromAndReturnBalanceDiffs(address _from, address _to, uint256 _value)
    external
    virtual
    returns (uint256 _senderBalanceDecrease, uint256 _receiverBalanceIncrease)
  {
    _checkAndUpdateAllowance(_from, _value);
    _emitTransferEvent(_from, _to, _value);
    return _transfer(_from, _to, _value);
  }

  /// @notice Public method that allows any caller to claim the stake rewards earned by the LST. Caller must pre-
  /// approve the LST on the stake token contract for at least the payout amount, which is transferred from the caller
  /// to the LST, added to the total supply, and sent to the default deposit. The effect of this is to distribute the
  /// reward proportionally to all LST holders, whose underlying shares will now be worth more of the stake token due
  /// the addition of the reward to the total supply. Because all holders' balances change simultaneously, transfer
  /// events cannot be emitted for all users. This makes the LST a non-standard ERC20, similar in nature to stETH.
  ///
  /// A quick example can help illustrate why an external party, such as an MEV searcher, would be incentivized to call
  /// this method. Imagine, purely for the sake of example, that the LST contract has accrued rewards of 1 ETH in the
  /// staking contract, and the payout amount here in the LST is set to 500 governance tokens. Imagine ETH is trading at
  /// $2,500 and the governance token is trading at $5. At this point, the value of ETH available to be claimed is equal
  /// to the value of the payout amount required in staking token. Once a bit more ETH accrues, it will be profitable
  /// for a searcher to trade the 500 staking tokens in exchange for the accrued ETH rewards. (This ignores other
  /// details, which real searchers would take into consideration, such as the gas/builder fee they would pay to call
  /// the method).
  ///
  /// Note that `payoutAmount` may be changed by the admin (governance). Any proposal that changes this amount is
  /// expected to be subject to the governance process, including a timelocked execution, and so it's unlikely that a
  /// caller would be surprised by a change in this value. Still, callers should be aware of the edge case where:
  /// 1. The caller grants a higher-than-necessary payout token approval to this LST.
  /// 2. Caller's claimAndDistributeReward transaction is in the mempool.
  /// 3. The payoutAmount is changed.
  /// 4. The claimAndDistributeReward transaction is now included in a block.
  /// @param _recipient The address that will receive the stake reward payout.
  /// @param _minExpectedReward The minimum reward payout, in the reward token of the underlying staker contract, that
  /// the caller will accept in exchange for providing the payout amount of stake token. If the amount claimed is less
  /// than this, the transaction will revert. This parameter is a last line of defense against the MEV caller losing
  /// funds because they've been frontrun by another searcher.
  /// @param _depositIds List of deposits owned by the LST from which rewards will be claimed by the caller.
  function claimAndDistributeReward(
    address _recipient,
    uint256 _minExpectedReward,
    Staker.DepositIdentifier[] calldata _depositIds
  ) external virtual {
    RewardParameters memory _rewardParams = rewardParams;

    uint256 _feeAmount = _calcFeeAmount(_rewardParams);

    Totals memory _totals = totals;

    // By increasing the total supply by the amount of tokens that are distributed as part of the reward, the balance
    // of every holder increases proportional to the underlying shares which they hold.
    uint96 _newTotalSupply = _totals.supply + _rewardParams.payoutAmount; // payoutAmount is assumed safe

    uint160 _feeShares;
    if (_feeAmount > 0) {
      // Our goal is to issue shares to the fee collector such that the new shares the fee collector receives are
      // worth `feeAmount` of `stakeToken` after the reward is distributed. This can be expressed mathematically
      // as feeAmount = (feeShares * newTotalSupply) / newTotalShares, where the newTotalShares is equal to the sum of
      // the fee shares and the total existing shares. In this equation, all the terms are known except the fee shares.
      // Solving for the fee shares yields the following calculation.
      _feeShares = _calcFeeShares(_feeAmount, _newTotalSupply, _totals.shares);

      // By issuing these new shares to the `feeCollector` we effectively give the it `feeAmount` of the reward by
      // slightly diluting all other LST holders.
      holderStates[rewardParams.feeCollector].shares += uint128(_feeShares);
    }

    totals = Totals({supply: _newTotalSupply, shares: _totals.shares + _feeShares});

    // Transfer stake token to the LST
    STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), _rewardParams.payoutAmount);
    // Stake the rewards with the default delegatee
    STAKER.stakeMore(DEFAULT_DEPOSIT_ID, _rewardParams.payoutAmount);

    // Claim the reward tokens earned by the LST for each deposit
    uint256 _rewards;
    for (uint256 _index = 0; _index < _depositIds.length; _index++) {
      _rewards += STAKER.claimReward(_depositIds[_index]);
    }

    // Ensure rewards distributed meet the claimers expectations; provides protection from frontrunning resulting in
    // loss of funds for the MEV racers.
    if (_rewards < _minExpectedReward) {
      revert GovLst__InsufficientRewards();
    }
    // Transfer the reward tokens to the recipient
    REWARD_TOKEN.safeTransfer(_recipient, _rewards);

    emit RewardDistributed(
      msg.sender, _recipient, _rewards, rewardParams.payoutAmount, _feeAmount, rewardParams.feeCollector
    );
  }

  /// @notice Allow a depositor to change the address they are delegating their staked tokens.
  /// @param _delegatee The address where voting is delegated.
  /// @return _depositId The deposit identifier for the delegatee.
  function delegate(address _delegatee) public virtual returns (Staker.DepositIdentifier _depositId) {
    _depositId = fetchOrInitializeDepositForDelegatee(_delegatee);
    updateDeposit(_depositId);
  }

  /// @notice Open method which allows anyone to add funds to a stake deposit owned by the LST. These funds are not
  /// added to the LST's supply and no tokens or shares are issues to the caller. The  purpose of this method is to
  /// provide buffer funds for shortfalls in deposits due to rounding errors. In particular, the system is designed
  /// such that rounding errors are known to accrue to the default deposit. Being able to provably provide a buffer for
  /// the default deposit is the primary intended use case for this method. That said, if other unknown issues were to
  /// arise, it could also be used to ensure the internal solvency of the other stake deposits as well.
  /// @param _depositId The stake deposit identifier that is being subsidized.
  /// @param _amount The quantity of stake tokens that will be sent to the deposit.
  /// @dev Caller must approve the LST contract for at least the `_amount` on the stake token before calling this
  /// method.
  function subsidizeDeposit(Staker.DepositIdentifier _depositId, uint256 _amount) external virtual {
    STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);

    // This will revert if the deposit is not owned by this contract
    STAKER.stakeMore(_depositId, uint96(_amount));

    emit DepositSubsidized(_depositId, _amount);
  }

  /// @notice An open method which allows anyone to override the delegatee of a deposit to the default delegatee
  /// if the deposit's earning power is below the minimum qualifying earning power. The caller will receive shares
  /// valued at the requested tip. These new shares will dilute existing depositor's shares.
  /// @param _depositId The id of the deposit to override the delegatee.
  /// @param _tipReceiver The address that receives the reward for carrying out the override action.
  /// @param _requestedTip The amount to reward the tip receiver for carrying out the override action.
  function enactOverride(Staker.DepositIdentifier _depositId, address _tipReceiver, uint160 _requestedTip)
    external
    virtual
  {
    _revertIfGreaterThanMaxTip(_requestedTip);
    (uint96 _balance,, uint96 _earningPower,,,,) = STAKER.deposits(_depositId);
    Staker.DepositIdentifier _defaultDepositId = depositForDelegatee(defaultDelegatee);

    if (_isSameDepositId(_depositId, _defaultDepositId) || isOverridden[_depositId] || _balance == 0) {
      revert GovLst__InvalidOverride();
    }

    bool _isAboveMin = uint256(_earningPower) * BIPS >= minQualifyingEarningPowerBips * _balance;
    if (_isAboveMin) {
      revert GovLst__EarningPowerNotQualified(
        uint256(_earningPower) * BIPS, uint256(minQualifyingEarningPowerBips) * _balance
      );
    }

    // Move the deposit delegatee to the default delegatee
    STAKER.alterDelegatee(_depositId, defaultDelegatee);

    isOverridden[_depositId] = true;

    uint160 _tipShares = _transferFeeInShares(_requestedTip, _tipReceiver);

    emit OverrideEnacted(_depositId, _tipReceiver, _tipShares);
  }

  /// @notice An open method which allows anyone to reset a deposit with an overridden delegatee to the original
  /// deposit delegatee if the deposit's earning power is above the minimum qualifying earning power. The caller will
  /// receive shares valued at the requested tip. These new shares will dilute existing depositor's shares.
  /// @param _depositId The id of the deposit in the override state.
  /// @param _tipReceiver The address that receives the reward for carrying out the revoke action.
  /// @param _requestedTip The amount to reward the tip receiver for carrying out the revoke action.
  function revokeOverride(
    Staker.DepositIdentifier _depositId,
    address _originalDelegatee,
    address _tipReceiver,
    uint160 _requestedTip
  ) external virtual {
    _revertIfGreaterThanMaxTip(_requestedTip);
    if (!_isSameDepositId(storedDepositIdForDelegatee[_originalDelegatee], _depositId) || !isOverridden[_depositId]) {
      revert GovLst__InvalidOverride();
    }

    // Move the deposit's delegatee back to the original
    STAKER.alterDelegatee(_depositId, _originalDelegatee);

    (uint96 _balance,, uint96 _earningPower,,,,) = STAKER.deposits(_depositId);
    if (_balance == 0) {
      revert GovLst__InvalidOverride();
    }

    // Make sure earning power is above min earning power
    bool _isBelowMin = uint256(_earningPower) * BIPS < minQualifyingEarningPowerBips * _balance;
    if (_isBelowMin) {
      revert GovLst__EarningPowerNotQualified(
        uint256(_earningPower) * BIPS, uint256(minQualifyingEarningPowerBips) * _balance
      );
    }

    isOverridden[_depositId] = false;

    uint160 _tipShares = _transferFeeInShares(_requestedTip, _tipReceiver);

    emit OverrideRevoked(_depositId, _tipReceiver, _tipShares);
  }

  /// @notice An open method that allows anyone to migrate an overridden deposit to a new default delegatee. This method
  /// handles cases where the `GovLst` owner sets a new default delegatee while some existing deposits are overridden,
  /// still referencing the old default delegatee.
  /// @param _depositId The id of the deposit in the override state.
  /// @param _tipReceiver The address that receives the reward for carrying out the migrate action.
  /// @param _requestedTip The amount to reward the tip receiver for carrying out the migrate action.
  function migrateOverride(Staker.DepositIdentifier _depositId, address _tipReceiver, uint160 _requestedTip)
    external
    virtual
  {
    // Requested tip cannot be above the max tip
    _revertIfGreaterThanMaxTip(_requestedTip);
    // Deposit must be overridden
    if (!isOverridden[_depositId]) {
      revert GovLst__InvalidOverride();
    }

    (,,, address _currentDelegatee,,,) = STAKER.deposits(_depositId);
    // Deposit cannot be the current default delegatee
    if (_currentDelegatee == defaultDelegatee) {
      revert GovLst__InvalidOverride();
    }

    // Move the deposit's delegatee back to the current default delegatee.
    STAKER.alterDelegatee(_depositId, defaultDelegatee);

    // Distribute shares to the caller
    uint160 _tipShares = _transferFeeInShares(_requestedTip, _tipReceiver);

    // Emit event
    emit OverrideMigrated(_depositId, _currentDelegatee, defaultDelegatee, _tipReceiver, _tipShares);
  }

  /// @notice Sets the reward parameters including payout amount, fee in bips, and fee collector.
  /// @param _params The new reward parameters.
  function setRewardParameters(RewardParameters memory _params) external virtual {
    _checkOwner();
    _setRewardParams(_params.payoutAmount, _params.feeBips, _params.feeCollector);
  }

  /// @notice Sets the maximum override tip.
  /// @param _maxOverrideTip The new maximum requested tip an overrider can request.
  /// @dev Keep in mind that this value is in tokens and must be converted into shares. The conversion into shares can
  /// lead to overflow errors if the maximum tip is too high.
  function setMaxOverrideTip(uint256 _maxOverrideTip) external virtual {
    _checkOwner();
    if (_maxOverrideTip > MAX_OVERRIDE_TIP_CAP) {
      revert GovLst__InvalidParameter();
    }
    _setMaxOverrideTip(_maxOverrideTip);
  }

  /// @notice Sets the minimum qualifying earning power amount in bips (1/10,000). This value determines whether a
  /// deposits delegatee needs to be overridden because it isn't earning enough of its possible staking rewards.
  /// @param _minQualifyingEarningPowerBips The new minimum qualifying earning power amount in bips (1/10,000).
  function setMinQualifyingEarningPowerBips(uint256 _minQualifyingEarningPowerBips) external virtual {
    _checkOwner();
    if (_minQualifyingEarningPowerBips > MINIMUM_QUALIFYING_EARNING_POWER_BIPS_CAP) {
      revert GovLst__InvalidParameter();
    }
    _setMinQualifyingEarningPowerBips(_minQualifyingEarningPowerBips);
  }

  /// @notice Update the default delegatee. Can only be called by the delegatee guardian or by the LST owner. Once the
  /// guardian takes an action on the LST, the owner can no longer override it.
  /// @param _newDelegatee The address which will be assigned as the delegatee for the default staker deposit.
  function setDefaultDelegatee(address _newDelegatee) external virtual {
    _checkAndToggleGuardianControlOrOwner();
    _setDefaultDelegatee(_newDelegatee);
    STAKER.alterDelegatee(DEFAULT_DEPOSIT_ID, _newDelegatee);
  }

  /// @notice Update the delegatee guardian. Can only be called by the delegatee guardian or by the LST owner. Once the
  /// guardian takes an action on the LST, the owner can no longer override it.
  /// @param _newDelegateeGuardian The address which will become the new delegatee guardian.
  function setDelegateeGuardian(address _newDelegateeGuardian) external virtual {
    _checkAndToggleGuardianControlOrOwner();
    _setDelegateeGuardian(_newDelegateeGuardian);
  }

  //---------------------------------------- Begin Fixed LST Helper Methods ------------------------------------------/

  /// @notice Permissioned fixed LST helper method which updates the deposit of the holder's fixed LST alias address.
  /// @param _account The holder setting their deposit in the fixed LST.
  /// @param _newDepositId The stake deposit identifier to which this holder's fixed LST staked tokens will be
  /// moved to and kept in henceforth.
  /// @return _oldDepositId The stake deposit identifier from which this holder's fixed LST staked tokens were
  /// moved.
  function updateFixedDeposit(address _account, Staker.DepositIdentifier _newDepositId)
    external
    virtual
    returns (Staker.DepositIdentifier _oldDepositId)
  {
    _revertIfNotFixedLst();
    _oldDepositId = _updateDeposit(_account.fixedAlias(), _newDepositId);
  }

  /// @notice Permissioned fixed LST helper method which performs the staking operation on behalf of the holder's fixed
  /// LST alias address, allowing the holder to stake in the fixed LST directly.
  /// @param _account The holder staking in the fixed LST.
  /// @param _amount The quantity of tokens that will be staked in the fixed LST.
  /// @return The number of _shares_ received by the holder's fixed alias address.
  function stakeAndConvertToFixed(address _account, uint256 _amount) external virtual returns (uint256) {
    _revertIfNotFixedLst();
    uint256 _initialShares = holderStates[_account.fixedAlias()].shares;

    // Externally, we model this as the Fixed LST contract staking on behalf of the account in question, so we emit
    // an event that shows the Fixed LST contract as the staker.
    _emitStakedEvent(address(FIXED_LST), _amount);
    _emitTransferEvent(address(0), address(FIXED_LST), _amount);

    // We assume that the stake tokens have already been transferred to this contract by the FixedLst.
    _stake(_account.fixedAlias(), _amount);
    return holderStates[_account.fixedAlias()].shares - _initialShares;
  }

  /// @notice Permissioned fixed LST helper method which moves a holder's rebasing LST tokens into its fixed alias
  /// address, effectively converting rebasing LST tokens to fixed LST tokens.
  /// @param _account The holder converting rebasing LST tokens into fixed LST tokens.
  /// @param _amount The number of rebasing LST tokens to convert.
  /// @return The number of _shares_ received by the holder's fixed alias address.
  function convertToFixed(address _account, uint256 _amount) external virtual returns (uint256) {
    _revertIfNotFixedLst();
    uint256 _initialShares = holderStates[_account.fixedAlias()].shares;

    // Externally, we model this as the holder moving rebasing LST tokens into the Fixed LST contract, so we emit
    // an event that reflects this transfer to the Fixed LST contract.
    _emitTransferEvent(_account, address(FIXED_LST), _amount);

    _transfer(_account, _account.fixedAlias(), _amount);
    return holderStates[_account.fixedAlias()].shares - _initialShares;
  }

  /// @notice Permissioned fixed LST helper method which transfers tokens between fixed alias addresses.
  /// @param _sender The address of the fixed LST holder sending fixed LST tokens.
  /// @param _receiver The address receiving fixed LST tokens.
  /// @param _shares The number of rebasing LST _shares_ to move between sender and receiver aliases.
  /// @return _senderSharesDecrease The decrease in the sender alias address' shares.
  /// @return _receiverSharesIncrease The increase in the receiver alias address' shares.
  function transferFixed(address _sender, address _receiver, uint256 _shares)
    external
    virtual
    returns (uint256 _senderSharesDecrease, uint256 _receiverSharesIncrease)
  {
    _revertIfNotFixedLst();
    uint256 _senderInitialShares = holderStates[_sender.fixedAlias()].shares;
    uint256 _receiverInitialShares = holderStates[_receiver.fixedAlias()].shares;
    uint256 _amount = stakeForShares(_shares);
    _transfer(_sender.fixedAlias(), _receiver.fixedAlias(), _amount);
    uint256 _senderFinalShares = holderStates[_sender.fixedAlias()].shares;
    uint256 _receiverFinalShares = holderStates[_receiver.fixedAlias()].shares;
    return (_senderInitialShares - _senderFinalShares, _receiverFinalShares - _receiverInitialShares);
  }

  /// @notice Permissioned fixed LST helper method which moves rebasing LST tokens from a holder's alias back to his
  /// standard address, effectively converting fixed LST tokens back to rebasing LST tokens.
  /// @param _account The holder converting fixed LST tokens into rebasing LST tokens.
  /// @param _shares The number of _shares_ worth of rebasing LST tokens to be moved from the holder's fixed alias
  /// to their standard address.
  /// @return The number of rebasing LST tokens moved back into the holder's address.
  function convertToRebasing(address _account, uint256 _shares) external virtual returns (uint256) {
    _revertIfNotFixedLst();
    uint256 _amount = stakeForShares(_shares);
    uint256 _amountUnfixed;
    (, _amountUnfixed) = _transfer(_account.fixedAlias(), _account, _amount);

    // Externally, we model this as the fixed LST sending rebasing LST tokens back to the holder, so we emit an
    // that reflects this.
    _emitTransferEvent(address(FIXED_LST), _account, _amountUnfixed);

    return _amountUnfixed;
  }

  /// @notice Permissioned fixed LST helper method which transfers rebasing LST tokens from the holder's fixed alias
  /// address then unstakes them on his behalf, allowing the holder to unstake from the fixed LST directly.
  /// @param _account The holder unstaking his fixed LST tokens.
  /// @param _shares The number of _shares_ worth of rebasing LST tokens to be unstaked.
  /// @return The number of governance tokens unstaked.
  /// @dev If their is a withdrawal delay being enforced, the tokens will be moved into the withdrawal gate on behalf
  /// of the holder's account, not his alias.
  function convertToRebasingAndUnstake(address _account, uint256 _shares) external virtual returns (uint256) {
    _revertIfNotFixedLst();
    uint256 _amount = stakeForShares(_shares);
    uint256 _amountUnfixed;
    (, _amountUnfixed) = _transfer(_account.fixedAlias(), _account, _amount);

    // Externally, we model this as the fixed LST unstaking on behalf of the account in question, so we emit
    // an event that shows the Fixed LST contract as the unstaker.
    _emitUnstakedEvent(address(FIXED_LST), _amountUnfixed);
    _emitTransferEvent(address(FIXED_LST), address(0), _amount);

    return _unstake(_account, _amountUnfixed);
  }

  //------------------------------------------ End Fixed LST Helper Methods ------------------------------------------/

  /// @notice Method called in the GovLst constructor which deploys the corresponding FixedGovLst
  /// instance that accompanies this instance of the rebasing GovLst. This is a virtual method that
  /// must be implemented by each concrete instance of GovLst.
  /// @dev The parameters called in this method match 1:1 the parameters in the constructor of the
  /// FixedGovLst contract.
  function _deployFixedGovLst(
    string memory _name,
    string memory _symbol,
    string memory _version,
    GovLst _lst,
    IERC20 _stakeToken,
    uint256 _shareScaleFactor
  ) internal virtual returns (FixedGovLst _fixedLst);

  /// @notice Internal helper method that takes an amount of stake tokens and metadata representing the global state of
  /// the LST and returns the quantity of shares that is worth the requested quantity of stake token. All data for the
  /// calculation is provided in memory and the calculation is performed there, making it a pure function.
  /// @param _amount The quantity of stake token that will be converted to a number of shares.
  /// @param _totals The metadata representing current global conditions.
  /// @return The quantity of shares that is worth the provided quantity of stake token.
  function _calcSharesForStake(uint256 _amount, Totals memory _totals) internal pure virtual returns (uint256) {
    if (_totals.supply == 0) {
      return SHARE_SCALE_FACTOR * _amount;
    }

    return (_amount * _totals.shares) / _totals.supply;
  }

  /// @notice Internal helper method that takes an amount of stake tokens and metadata representing the global state of
  /// the LST and returns the quantity of shares that is worth the requested quantity of stake token, __rounded up__.
  /// All data for the calculation is provided in memory and the calculation is performed there, making it a pure
  /// function.
  /// @param _amount The quantity of stake token that will be converted to a number of shares.
  /// @param _totals The metadata representing current global conditions.
  /// @return The quantity of shares that is worth the provided quantity of stake token, __rounded up__.
  function _calcSharesForStakeUp(uint256 _amount, Totals memory _totals) internal pure virtual returns (uint256) {
    uint256 _result = _calcSharesForStake(_amount, _totals);

    if (mulmod(_amount, _totals.shares, _totals.supply) > 0) {
      _result += 1;
    }

    return _result;
  }

  /// @notice Internal helper method that takes an amount of shares, and metadata representing the global state of
  /// the LST, and returns the quantity of stake tokens that the requested shares are worth. All data for the
  /// calculation is provided in memory and the calculation is performed there, making it a pure function.
  /// @param _amount The quantity of shares that will be converted to stake tokens.
  /// @param _totals The metadata representing current global conditions.
  /// @return The quantity of stake tokens which backs the provide quantity of shares.
  function _calcStakeForShares(uint256 _amount, Totals memory _totals) internal pure virtual returns (uint256) {
    if (_totals.shares == 0) {
      return _amount / SHARE_SCALE_FACTOR;
    }

    return (_amount * _totals.supply) / _totals.shares;
  }

  /// @notice Internal method that takes a holder's state and the global state and calculates the holder's would-be
  /// balance in such conditions.
  /// @param _holder The metadata associated with a given holder.
  /// @param _totals The metadata representing current global conditions.
  /// @return The calculated balance of the holder given the global conditions.
  function _calcBalanceOf(HolderState memory _holder, Totals memory _totals) internal pure virtual returns (uint256) {
    if (_holder.shares == 0) {
      return 0;
    }

    return _calcStakeForShares(_holder.shares, _totals);
  }

  /// @notice Internal helper method that takes the metadata representing an LST holder and returns the staker
  /// deposit identifier that holder has assigned his voting weight to.
  function _calcDepositId(HolderState memory _holder) internal view virtual returns (Staker.DepositIdentifier) {
    if (_holder.depositId == 0) {
      return DEFAULT_DEPOSIT_ID;
    } else {
      return Staker.DepositIdentifier.wrap(_holder.depositId);
    }
  }

  function _calcFeeShares(uint256 _feeAmount, uint256 _newTotalSupply, uint256 _totalShares)
    internal
    pure
    virtual
    returns (uint160)
  {
    return SafeCast.toUint160((uint256(_feeAmount) * _totalShares) / (_newTotalSupply - _feeAmount));
  }

  /// @notice Internal convenience method which performs deposit update operations.
  /// @dev This method must only be called after proper authorization has been completed.
  /// @dev See public updateDeposit methods for additional documentation.
  function _updateDeposit(address _account, Staker.DepositIdentifier _newDepositId)
    internal
    virtual
    returns (Staker.DepositIdentifier _oldDepositId)
  {
    // Read required state from storage once.
    Totals memory _totals = totals;
    HolderState memory _holderState = holderStates[_account];

    _oldDepositId = _calcDepositId(_holderState);

    uint256 _balanceOf = _calcBalanceOf(_holderState, _totals);

    // If the user's deposit is currently zero, and the deposit identifier specified is indeed owned by the LST as it
    // must be, we can simply update their deposit identifier and avoid actions on the underlying Staker.
    if (_balanceOf == 0) {
      (, address _owner,,,,,) = STAKER.deposits(_newDepositId);
      if (_owner == address(this)) {
        holderStates[_account].depositId = _depositIdToUInt32(_newDepositId);
        _revertIfInvalidDeposit(_newDepositId);
        return _oldDepositId;
      }
    }

    uint256 _delegatedBalance = _holderState.balanceCheckpoint;
    // This is the number of tokens in the default pool that the account has claim to
    uint256 _undelegatedBalance = _balanceOf - _delegatedBalance;

    // Make internal state updates.
    if (_isSameDepositId(_oldDepositId, _newDepositId) && _isSameDepositId(_newDepositId, DEFAULT_DEPOSIT_ID)) {
      // do nothing and return
      return _oldDepositId;
    } else if (_isSameDepositId(_oldDepositId, _newDepositId)) {
      _holderState.balanceCheckpoint = uint96(_balanceOf);
      STAKER.withdraw(DEFAULT_DEPOSIT_ID, uint96(_undelegatedBalance));
      STAKER.stakeMore(_newDepositId, uint96(_undelegatedBalance));
    } else if (_isSameDepositId(_newDepositId, DEFAULT_DEPOSIT_ID)) {
      _holderState.balanceCheckpoint = 0;
      _holderState.depositId = 0;
      STAKER.withdraw(_oldDepositId, uint96(_delegatedBalance));
      STAKER.stakeMore(_newDepositId, uint96(_delegatedBalance));
    } else if ((_isSameDepositId(_oldDepositId, DEFAULT_DEPOSIT_ID))) {
      _holderState.balanceCheckpoint = uint96(_balanceOf);
      _holderState.depositId = _depositIdToUInt32(_newDepositId);
      STAKER.withdraw(DEFAULT_DEPOSIT_ID, uint96(_balanceOf));
      STAKER.stakeMore(_newDepositId, uint96(_balanceOf));
      _revertIfInvalidDeposit(_newDepositId);
    } else {
      _holderState.balanceCheckpoint = uint96(_balanceOf);
      _holderState.depositId = _depositIdToUInt32(_newDepositId);
      if (_undelegatedBalance > 0) {
        STAKER.withdraw(DEFAULT_DEPOSIT_ID, uint96(_undelegatedBalance));
      }
      STAKER.withdraw(_oldDepositId, uint96(_delegatedBalance));
      STAKER.stakeMore(_newDepositId, uint96(_balanceOf));
      _revertIfInvalidDeposit(_newDepositId);
    }

    // Write updated states back to storage.
    holderStates[_account] = _holderState;
  }

  /// @notice Internal helper method that emits a DepositUpdated event with the parameters provided.
  function _emitDepositUpdatedEvent(
    address _account,
    Staker.DepositIdentifier _oldDepositId,
    Staker.DepositIdentifier _newDepositId
  ) internal virtual {
    emit DepositUpdated(_account, _oldDepositId, _newDepositId);
  }

  /// @notice Internal convenience method which performs staking operations.
  /// @dev This method must only be called after proper authorization has been completed.
  /// @dev See public stake methods for additional documentation.
  /// @return The difference in LST token balance of the account after the stake operation.
  function _stake(address _account, uint256 _amount) internal virtual returns (uint256) {
    // Read required state from storage once.
    Totals memory _totals = totals;
    HolderState memory _holderState = holderStates[_account];

    uint256 _initialBalance = _calcBalanceOf(_holderState, _totals);
    uint256 _newShares = _calcSharesForStake(_amount, _totals);

    // cast is safe because we have transferred token amount
    _totals.supply = _totals.supply + uint96(_amount);
    // _newShares cast to uint128 later would fail if overflowed
    _totals.shares = _totals.shares + uint160(_newShares);

    _holderState.shares = _holderState.shares + _newShares.toUint128();
    uint256 _balanceDiff = _calcBalanceOf(_holderState, _totals) - _initialBalance;
    if (!_isSameDepositId(_calcDepositId(_holderState), DEFAULT_DEPOSIT_ID)) {
      _holderState.balanceCheckpoint =
        _min(_holderState.balanceCheckpoint + uint96(_amount), uint96(_calcBalanceOf(_holderState, _totals)));
    }

    // Write updated states back to storage.
    totals = _totals;
    holderStates[_account] = _holderState;

    STAKER.stakeMore(_calcDepositId(_holderState), uint96(_amount));
    return _balanceDiff;
  }

  /// @notice Internal helper method that emits a Staked event with the parameters provided.
  function _emitStakedEvent(address _account, uint256 _amount) internal virtual {
    emit Staked(_account, _amount);
  }

  /// @notice Internal convenience method which performs unstaking operations.
  /// @dev This method must only be called after proper authorization has been completed.
  /// @dev See public unstake methods for additional documentation.
  /// @return The amount of LST tokens unstaked and either transferred to the user directly or placed in the withdrawal
  /// gate.
  function _unstake(address _account, uint256 _amount) internal virtual returns (uint256) {
    // Read required state from storage once.
    Totals memory _totals = totals;
    HolderState memory _holderState = holderStates[_account];

    uint256 _initialBalanceOf = _calcBalanceOf(_holderState, _totals);

    if (_amount > _initialBalanceOf) {
      revert GovLst__InsufficientBalance();
    }

    // Decreases the holder's balance by the amount being withdrawn
    uint256 _sharesDestroyed = _calcSharesForStakeUp(_amount, _totals);
    _holderState.shares -= _sharesDestroyed.toUint128();

    // cast is safe because we've validated user has sufficient balance
    _totals.supply = _totals.supply - uint96(_amount);
    // cast is safe because shares fits into uint128
    _totals.shares = _totals.shares - uint160(_sharesDestroyed);

    uint256 _delegatedBalance = _holderState.balanceCheckpoint;
    uint256 _undelegatedBalance = _initialBalanceOf - _delegatedBalance;
    uint256 _undelegatedBalanceToWithdraw;

    if (_amount > _undelegatedBalance) {
      // Since the amount needed is more than the full undelegated balance, we'll withdraw all of it, plus some from
      // the delegated balance.
      _undelegatedBalanceToWithdraw = _undelegatedBalance;
      uint256 _delegatedBalanceToWithdraw = _amount - _undelegatedBalanceToWithdraw;
      STAKER.withdraw(_calcDepositId(_holderState), uint96(_delegatedBalanceToWithdraw));
      _holderState.balanceCheckpoint = uint96(_delegatedBalance - _delegatedBalanceToWithdraw);
    } else {
      // Since the amount is less than or equal to the undelegated balance, we'll source all of it from said balance.
      _undelegatedBalanceToWithdraw = _amount;
    }

    // If the staker had zero undelegated balance, we won't waste gas executing the withdraw call.
    if (_undelegatedBalanceToWithdraw > 0) {
      STAKER.withdraw(DEFAULT_DEPOSIT_ID, uint96(_undelegatedBalanceToWithdraw));
    }

    // Ensure the holder's balance checkpoint is updated if it has decreased due to truncation.
    _holderState.balanceCheckpoint = _min(_holderState.balanceCheckpoint, uint96(_calcBalanceOf(_holderState, _totals)));

    // Write updated states back to storage.
    totals = _totals;
    holderStates[_account] = _holderState;

    // At this point, the LST holds _amount of stakeToken

    address _withdrawalTarget;
    if (WITHDRAW_GATE.delay() == 0) {
      // If there's currently a 0-delay on withdraws, just send the tokens straight to the user.
      _withdrawalTarget = _account;
    } else {
      _withdrawalTarget = address(WITHDRAW_GATE);
      WITHDRAW_GATE.initiateWithdrawal(uint96(_amount), _account);
    }

    STAKE_TOKEN.safeTransfer(_withdrawalTarget, _amount);
    return _amount;
  }

  /// @notice Internal helper method that emits an Unstaked event with the parameters provided.
  function _emitUnstakedEvent(address _account, uint256 _amount) internal virtual {
    emit Unstaked(_account, _amount);
  }

  /// @notice Internal convenience method which performs transfer operations.
  /// @dev This method must only be called after proper authorization has been completed.
  /// @dev See public transfer methods for additional documentation.
  /// @return A tuple containing the sender's balance decrease and the receiver's balance increase in that order.
  function _transfer(address _sender, address _receiver, uint256 _value) internal virtual returns (uint256, uint256) {
    // Early check for self-transfer
    if (_sender == _receiver) {
      emit Transfer(_sender, _receiver, _value);
      return (0, 0);
    }

    // Read required state from storage once.
    Totals memory _totals = totals;
    HolderState memory _senderState = holderStates[_sender];
    HolderState memory _receiverState = holderStates[_receiver];

    // Record initial balances.
    uint256 _senderInitBalance = _calcBalanceOf(_senderState, _totals);
    uint256 _receiverInitBalance = _calcBalanceOf(_receiverState, _totals);
    uint256 _senderDelegatedBalance = _senderState.balanceCheckpoint;
    uint256 _senderUndelegatedBalance = _senderInitBalance - _senderDelegatedBalance;

    if (_value > _senderInitBalance) {
      revert GovLst__InsufficientBalance();
    }

    // Move underlying shares.
    {
      uint256 _shares = _calcSharesForStakeUp(_value, _totals);
      _senderState.shares -= uint128(_shares);
      _receiverState.shares += uint128(_shares);
    }

    uint256 _receiverBalanceIncrease = _calcBalanceOf(_receiverState, _totals) - _receiverInitBalance;
    uint256 _senderBalanceDecrease = _senderInitBalance - _calcBalanceOf(_senderState, _totals);

    // Knowing the sender's balance has decreased by at least as much as the receiver's has increased, we now base the
    // calculation of how much to move between deposits on the greater number, i.e. the sender's decrease. However,
    // when we update the receiver's balance checkpoint, we use the smaller number—the receiver's balance change.
    // As a result, extra wei may be lost, i.e. no longer controlled by either the sender or the receiver,
    // but are instead stuck permanently in the receiver's deposit. This is ok, as the amount lost is miniscule, but
    // we've ensured the solvency of each underlying Staker deposit.

    if (!_isSameDepositId(_calcDepositId(_receiverState), DEFAULT_DEPOSIT_ID)) {
      _receiverState.balanceCheckpoint += uint96(_value);
    }

    // rescoping these vars to avoid stack too deep
    address _senderRescoped = _sender;
    address _receiverRescoped = _receiver;

    // If both the sender and receiver are using the default deposit, then no tokens whatsoever need to move
    // between Staker deposits.
    if (
      _isSameDepositId(_calcDepositId(_receiverState), DEFAULT_DEPOSIT_ID)
        && _isSameDepositId(_calcDepositId(_senderState), DEFAULT_DEPOSIT_ID)
    ) {
      // Write data back to storage once.
      holderStates[_senderRescoped] = _senderState;
      holderStates[_receiverRescoped] = _receiverState;
      return (_senderBalanceDecrease, _receiverBalanceIncrease);
    }

    // Create a new scope for this series of operations to avoid stack to deep.
    {
      // Rescoping these vars to avoid stack too deep.
      uint256 _valueRescoped = _value;
      Totals memory _totalsRescoped = _totals;
      HolderState memory _senderStateRescoped = _senderState;
      HolderState memory _receiverStateRescoped = _receiverState;

      uint256 _undelegatedBalanceToWithdraw;
      uint256 _delegatedBalanceToWithdraw;

      if (_valueRescoped > _senderUndelegatedBalance) {
        // Since the amount needed is more than the full undelegated balance, we'll withdraw all of it, plus some from
        // the delegated balance.
        _undelegatedBalanceToWithdraw = _senderUndelegatedBalance;
        _delegatedBalanceToWithdraw = _valueRescoped - _undelegatedBalanceToWithdraw;
        _senderStateRescoped.balanceCheckpoint = uint96(_senderDelegatedBalance - _delegatedBalanceToWithdraw);

        if (_isSameDepositId(_calcDepositId(_receiverStateRescoped), _calcDepositId(_senderStateRescoped))) {
          // If the sender and receiver are using the same deposit, we don't need to move these tokens, so we skip the
          // Staker withdraw and zero out this value so we don't try to "stakeMore" with it later.
          _delegatedBalanceToWithdraw = 0;
        } else {
          STAKER.withdraw(_calcDepositId(_senderStateRescoped), uint96(_delegatedBalanceToWithdraw));
        }
      } else {
        // Since the amount is less than or equal to the undelegated balance, we'll source all of it from said balance.
        _undelegatedBalanceToWithdraw = _valueRescoped;
      }

      // Ensure the sender's balance checkpoint is updated if it has decreased due to truncation.
      _senderStateRescoped.balanceCheckpoint =
        _min(_senderStateRescoped.balanceCheckpoint, uint96(_calcBalanceOf(_senderStateRescoped, _totalsRescoped)));

      // Write data back to storage once.
      holderStates[_senderRescoped] = _senderStateRescoped;
      holderStates[_receiverRescoped] = _receiverStateRescoped;

      // If the staker had zero undelegated balance, we won't waste gas executing the withdraw call.
      if (_undelegatedBalanceToWithdraw > 0) {
        STAKER.withdraw(DEFAULT_DEPOSIT_ID, uint96(_undelegatedBalanceToWithdraw));
      }

      // If both the delegated balance to withdraw and the undelegated balance to withdraw were zero, then we didn't
      // have to move any tokens out of Staker deposits, and none need to be put back into the receiver's deposit now.
      if ((_delegatedBalanceToWithdraw + _undelegatedBalanceToWithdraw) > 0) {
        STAKER.stakeMore(
          _calcDepositId(_receiverStateRescoped), uint96(_delegatedBalanceToWithdraw + _undelegatedBalanceToWithdraw)
        );
      }
    }

    return (_senderBalanceDecrease, _receiverBalanceIncrease);
  }

  /// @notice Internal helper method that emits an IERC20.Transfer event with the parameters provided.
  function _emitTransferEvent(address _sender, address _receiver, uint256 _value) internal virtual {
    emit Transfer(_sender, _receiver, _value);
  }

  /// @notice Internal function to set reward parameters
  /// @param _payoutAmount The new payout amount
  /// @param _feeBips The new fee in basis points
  /// @param _feeCollector The new fee collector address
  function _setRewardParams(uint80 _payoutAmount, uint16 _feeBips, address _feeCollector) internal virtual {
    if (_feeBips > MAX_FEE_BIPS) {
      revert GovLst__FeeBipsExceedMaximum(_feeBips, MAX_FEE_BIPS);
    }

    if (_feeCollector == address(0)) {
      revert GovLst__FeeCollectorCannotBeZeroAddress();
    }

    rewardParams = RewardParameters({payoutAmount: _payoutAmount, feeBips: _feeBips, feeCollector: _feeCollector});

    emit RewardParametersSet(_payoutAmount, _feeBips, _feeCollector);
  }

  /// @notice Internal helper method that sets the max override tip and emits an event.
  function _setMaxOverrideTip(uint256 _maxOverrideTip) internal virtual {
    emit MaxOverrideTipSet(maxOverrideTip, _maxOverrideTip);
    maxOverrideTip = _maxOverrideTip;
  }

  /// @notice Internal helper method that sets the min qualifying earning power and emits an event.
  function _setMinQualifyingEarningPowerBips(uint256 _minQualifyingEarningPowerBips) internal virtual {
    emit MinQualifyingEarningPowerBipsSet(minQualifyingEarningPowerBips, _minQualifyingEarningPowerBips);
    minQualifyingEarningPowerBips = _minQualifyingEarningPowerBips;
  }

  /// @notice Internal helper method that sets the delegatee and emits an event.
  function _setDefaultDelegatee(address _newDelegatee) internal virtual {
    emit DefaultDelegateeSet(defaultDelegatee, _newDelegatee);
    defaultDelegatee = _newDelegatee;
  }

  /// @notice Internal helper method that sets the guardian and emits an event.
  function _setDelegateeGuardian(address _newDelegateeGuardian) internal virtual {
    emit DelegateeGuardianSet(delegateeGuardian, _newDelegateeGuardian);
    delegateeGuardian = _newDelegateeGuardian;
  }

  /// @notice Internal helper that updates the allowance of the from address for the message sender, and reverts if the
  /// message sender does not have sufficient allowance.
  /// @param _from The address for which the message sender's allowance should be checked & updated.
  /// @param _value The amount of the allowance to check and decrement.
  function _checkAndUpdateAllowance(address _from, uint256 _value) internal virtual {
    uint256 allowed = allowance[_from][msg.sender];
    if (allowed != type(uint256).max) {
      allowance[_from][msg.sender] = allowed - _value;
    }
  }

  /// @notice Internal helper to compensate a receiver in shares based on a provided token amount.
  /// @param  _feeAmount The amount of tokens to convert to shares while diluting other shareholders.
  /// @param _feeReceiver The address that will receives the shares.
  function _transferFeeInShares(uint256 _feeAmount, address _feeReceiver) internal virtual returns (uint160) {
    Totals memory _totals = totals;
    uint160 _feeShares = _calcFeeShares(_feeAmount, _totals.supply, _totals.shares);
    totals.shares += _feeShares;
    holderStates[_feeReceiver].shares += SafeCast.toUint128(_feeShares);
    return _feeShares;
  }

  /// @notice Internal helper which checks that the message sender is either the delegatee guardian or the owner and
  /// reverts otherwise. If the caller is the owner, it also validates the guardian has never performed an action
  /// before, and reverts if it has. If the caller is the guardian, it toggles the guardian control flag to true if it
  /// hasn't yet been.
  function _checkAndToggleGuardianControlOrOwner() internal virtual {
    if (msg.sender != owner() && msg.sender != delegateeGuardian) {
      revert GovLst__Unauthorized();
    }
    if (msg.sender == owner() && isGuardianControlled) {
      revert GovLst__Unauthorized();
    }
    if (msg.sender == delegateeGuardian && !isGuardianControlled) {
      isGuardianControlled = true;
    }
  }

  /// @notice Internal helper which reverts if the caller is not the fixed lst contract.
  function _revertIfNotFixedLst() internal view virtual {
    if (msg.sender != address(FIXED_LST)) {
      revert GovLst__Unauthorized();
    }
  }

  /// @notice Internal helper which reverts if the tip is greater than the max tip.
  /// @param _tip The tip amount to check against the max tip.
  function _revertIfGreaterThanMaxTip(uint256 _tip) internal view virtual {
    if (_tip > maxOverrideTip) {
      revert GovLst__GreaterThanMaxTip();
    }
  }

  /// @notice Internal helper which reverts if an action for example, updating a deposit, is taken on an invalid
  /// deposit.
  /// @param _depositId The id of the deposit to check.
  function _revertIfInvalidDeposit(Staker.DepositIdentifier _depositId) internal view {
    if (isOverridden[_depositId]) {
      revert GovLst__InvalidDeposit();
    }
    (uint96 _balance,, uint96 _earningPower,,,,) = STAKER.deposits(_depositId);
    bool _isBelowMin = uint256(_earningPower) * BIPS < minQualifyingEarningPowerBips * _balance;
    if (_isBelowMin) {
      revert GovLst__EarningPowerNotQualified(
        uint256(_earningPower) * BIPS, uint256(minQualifyingEarningPowerBips) * _balance
      );
    }

    if (_balance == 0) {
      revert GovLst__InvalidDeposit();
    }
  }

  /// @notice Internal helper function to calculate the fee amount based on the payout amount and fee percentage.
  /// @param _rewardParams The reward parameters containing payout amount and fee percentage.
  /// @return The calculated fee amount.
  function _calcFeeAmount(RewardParameters memory _rewardParams) internal pure virtual returns (uint256) {
    return (uint256(_rewardParams.payoutAmount) * uint256(_rewardParams.feeBips)) / BIPS;
  }

  /// @notice Internal convenience helper for comparing the equality of two staker DepositIdentifiers.
  /// @param _depositIdA The first deposit identifier.
  /// @param _depositIdB The second deposit identifier.
  /// @return True if the deposit identifiers are equal, false if they are different.
  function _isSameDepositId(Staker.DepositIdentifier _depositIdA, Staker.DepositIdentifier _depositIdB)
    internal
    pure
    virtual
    returns (bool)
  {
    return Staker.DepositIdentifier.unwrap(_depositIdA) == Staker.DepositIdentifier.unwrap(_depositIdB);
  }

  /// @notice Internal helper function to convert a Staker DepositIdentifier to a uint32
  /// @param _depositId The DepositIdentifier to convert
  /// @return The uint32 representation of the DepositIdentifier
  function _depositIdToUInt32(Staker.DepositIdentifier _depositId) internal pure virtual returns (uint32) {
    return SafeCast.toUint32(Staker.DepositIdentifier.unwrap(_depositId));
  }

  /// @notice Internal helper that returns the lesser of the two parameters passed.
  function _min(uint96 _a, uint96 _b) internal pure virtual returns (uint96) {
    return (_a < _b) ? _a : _b;
  }
}
