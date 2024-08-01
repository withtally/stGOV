// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {IUni} from "src/interfaces/IUni.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {IWithdrawalGate} from "src/interfaces/IWithdrawalGate.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";

contract UniLst is IERC20, Ownable {
  error UniLst__StakeTokenOperationFailed();
  error UniLst__InsufficientBalance();
  error UniLst__InsufficientRewards();
  error UniLst__InvalidFeeParameters();

  IUniStaker public immutable STAKER;
  IUni public immutable STAKE_TOKEN;
  IWETH9 public immutable REWARD_TOKEN;
  uint256 public constant SHARE_SCALE_FACTOR = 1e18;

  event WithdrawalGateSet(address indexed oldWithdrawalGate, address indexed newWithdrawalGate);
  event PayoutAmountSet(uint256 oldPayoutAmount, uint256 newPayoutAmount);
  event FeeParametersSet(uint256 oldFeeAmount, uint256 newFeeAmount, address oldFeeCollector, address newFeeCollector);

  address public defaultDelegatee;
  IWithdrawalGate public withdrawalGate;
  uint256 public totalSupply;
  uint256 public totalShares;
  uint256 public payoutAmount;
  uint256 public feeAmount;
  address public feeCollector;
  mapping(address delegatee => IUniStaker.DepositIdentifier depositId) public depositForDelegatee;
  mapping(address holder => address delegatee) private storedDelegateeForHolder;
  mapping(address holder => uint256 shares) public sharesOf;
  // CONSIDER: Maybe rename this to "delegatedBalance" or something similar
  mapping(address holder => uint256 balance) public balanceCheckpoint;
  mapping(address holder => mapping(address spender => uint256 amount)) public allowance;

  constructor(IUniStaker _staker, address _initialDefaultDelegatee, address _initialOwner, uint256 _initialPayoutAmount)
    Ownable(_initialOwner)
  {
    STAKER = _staker;
    STAKE_TOKEN = IUni(_staker.STAKE_TOKEN());
    REWARD_TOKEN = IWETH9(payable(_staker.REWARD_TOKEN()));
    defaultDelegatee = _initialDefaultDelegatee;
    payoutAmount = _initialPayoutAmount;

    // OPTIMIZE: We can actually remove these return value checks because UNI reverts (confirm)
    if (!STAKE_TOKEN.approve(address(_staker), type(uint256).max)) {
      revert UniLst__StakeTokenOperationFailed();
    }

    // Create initial deposit for default so other methods can assume it exists.
    // OPTIMIZE: Store this as an immutable to avoid having to ever look it up from storage
    depositForDelegatee[_initialDefaultDelegatee] = STAKER.stake(0, _initialDefaultDelegatee);
  }

  function approve(address _spender, uint256 _amount) public virtual returns (bool) {
    allowance[msg.sender][_spender] = _amount;
    emit Approval(msg.sender, _spender, _amount);
    return true;
  }

  function balanceOf(address _holder) public view returns (uint256 _balance) {
    uint256 _sharesOf = sharesOf[_holder];

    if (_sharesOf == 0) {
      return 0;
    }

    _balance = _stakeForShares(_sharesOf);
  }

  function delegateeForHolder(address _holder) public view returns (address _delegatee) {
    _delegatee = storedDelegateeForHolder[_holder];

    if ((_delegatee == address(0))) {
      _delegatee = defaultDelegatee;
    }
  }

  // OPTIMIZE: This would be a bigger refactor with some tradeoffs, but if we assume that user can source the correct
  // depositId for a given delegatee by observing events offchain, we can have the user specify the depositId for their
  // updated delegatee, rather than the address. This would require adding a new method like "initializeDelegatee"
  // that would create the deposit (and prevent re-initialization?). If your delegatee doesn't yet have a deposit,
  // you'd first call `initializeDelegatee` rather than `updateDelegatee`. This would avoid having to store and lookup
  // the depositId for the delegatee. We could pre-initialize dozens or hundreds of existing delegates.
  function updateDelegatee(address _delegatee) external {
    IUniStaker.DepositIdentifier _oldDepositId = depositForDelegatee[delegateeForHolder(msg.sender)];
    storedDelegateeForHolder[msg.sender] = _delegatee;
    // OPTIMIZE: inefficient to do it this way, opportunity for optimization
    IUniStaker.DepositIdentifier _newDepositId = depositForDelegatee[delegateeForHolder(msg.sender)];
    IUniStaker.DepositIdentifier _defaultDepositId = depositForDelegatee[defaultDelegatee];

    // Create a new deposit for this delegatee if one is not yet managed by the LST
    if (IUniStaker.DepositIdentifier.unwrap(_newDepositId) == 0) {
      _newDepositId = STAKER.stake(0, _delegatee);
      depositForDelegatee[_delegatee] = _newDepositId;
    }

    // OPTIMIZE: Check if the deposit isn't changing to avoid unneeded movement, still consolidate checkpoint balance

    uint256 _balanceOf = balanceOf(msg.sender);
    uint256 _balanceCheckpoint = balanceCheckpoint[msg.sender];
    // This is the number of tokens in the default pool that the msg.sender has claim to
    uint256 _checkpointDiff = _balanceOf - balanceCheckpoint[msg.sender];

    // OPTIMIZE: if the new or the old delegatee is the default, we can avoid one unneeded withdraw
    if (_checkpointDiff > 0) {
      balanceCheckpoint[msg.sender] = _balanceOf;
      STAKER.withdraw(_defaultDepositId, uint96(_checkpointDiff));
    }

    STAKER.withdraw(_oldDepositId, uint96(_balanceCheckpoint));
    STAKER.stakeMore(_newDepositId, uint96(_balanceOf));
  }

  function stake(uint256 _amount) public {
    if (!STAKE_TOKEN.transferFrom(msg.sender, address(this), _amount)) {
      revert UniLst__StakeTokenOperationFailed();
    }

    uint256 _newShares = _sharesForStake(_amount);

    totalSupply += _amount;
    totalShares += _newShares;
    sharesOf[msg.sender] += _newShares;
    balanceCheckpoint[msg.sender] += _stakeForShares(_newShares);
    IUniStaker.DepositIdentifier _depositId = depositForDelegatee[delegateeForHolder(msg.sender)];

    STAKER.stakeMore(_depositId, uint96(_amount));
  }

  function unstake(uint256 _amount) external {
    uint256 _balanceOf = balanceOf(msg.sender);

    if (_amount > _balanceOf) {
      revert UniLst__InsufficientBalance();
    }

    // Decreases the holder's balance by the amount being withdrawn
    sharesOf[msg.sender] -= _sharesForStake(_amount);

    uint256 _delegatedBalance = balanceCheckpoint[msg.sender];
    uint256 _undelegatedBalance = _balanceOf - _delegatedBalance;
    uint256 _undelegatedBalanceToWithdraw;

    // OPTIMIZE: This can be smarter if the user is delegated to the default delegatee. It should only need to do one
    // withdrawal in that case.

    if (_amount > _undelegatedBalance) {
      // Since the amount needed is more than the full undelegated balance, we'll withdraw all of it, plus some from
      // the delegated balance.
      _undelegatedBalanceToWithdraw = _undelegatedBalance;
      uint256 _delegatedBalanceToWithdraw = _amount - _undelegatedBalanceToWithdraw;
      STAKER.withdraw(_depositIdForHolder(msg.sender), uint96(_delegatedBalanceToWithdraw));
      balanceCheckpoint[msg.sender] = _delegatedBalance - _delegatedBalanceToWithdraw;
    } else {
      // Since the amount is less than or equal to the undelegated balance, we'll source all of it from said balance.
      _undelegatedBalanceToWithdraw = _amount;
    }

    // If the staker had zero undelegated balance, we won't waste gas executing the withdraw call.
    if (_undelegatedBalanceToWithdraw > 0) {
      STAKER.withdraw(depositForDelegatee[defaultDelegatee], uint96(_undelegatedBalanceToWithdraw));
    }

    // At this point, the LST holds _amount of stakeToken

    // This logic determines if the unstaked funds go directly to the holder or to the withdrawal gate. The logic is
    // more complicated than simply checking if the withdrawal gate is set or not in order to protect stakers from
    // having their funds lost if an invalid address is set by the owner as the withdrawal gate. Ultimately, the
    // owner could always seize funds by setting a valid but malicious withdrawal gate, thus this logic is primarily
    // protection against an error.
    // OPTIMIZE: given the above, we should assess the gas savings to be had from removing this logic and determine if
    // it's worth the tradeoff. Another option would be to make the withdrawal gate an immutable variable set in the
    // constructor, if we're confident the parameters the features we need can be achieved without ever needing to
    // update the address. This would allow us to remove this check entirely. It would require some extra finagling in
    // the deploy script to use create2.
    address _withdrawalTarget = address(withdrawalGate);
    if (_withdrawalTarget.code.length == 0) {
      // If the withdrawal target is set to an address that is not a smart contract, unstaking should transfer directly
      // to the holder.
      _withdrawalTarget = msg.sender;
    } else {
      // Similarly, if the call to the withdrawal gate fails, tokens should be transferred directly to the holder.
      try withdrawalGate.initiateWithdrawal(_amount, msg.sender) {}
      catch {
        _withdrawalTarget = msg.sender;
      }
    }

    STAKE_TOKEN.transfer(_withdrawalTarget, _amount);
  }

  function transfer(address _receiver, uint256 _value) external returns (bool) {
    return _transfer(msg.sender, _receiver, _value);
  }

  function transferFrom(address _from, address _to, uint256 _amount) external returns (bool) {
    uint256 allowed = allowance[_from][msg.sender];
    if (allowed != type(uint256).max) {
      allowance[_from][msg.sender] = allowed - _amount;
    }
    return _transfer(_from, _to, _amount);
  }

  function claimAndDistributeReward(address _recipient, uint256 _minExpectedReward) external {
    uint256 _feeAmount = feeAmount;

    // By increasing the total supply by the amount of tokens that are distributed as part of the reward, the balance
    // of every holder increases proportional to the underlying shares which they hold.
    uint256 _newTotalSupply = totalSupply + payoutAmount;

    if (_feeAmount > 0) {
      uint256 _existingShares = totalShares;

      // Our goal is to issue shares to the fee collector such that the new shares the fee collector receives are
      // worth `feeAmount` of `stakeToken` after the reward is distributed. This can be expressed mathematically
      // as feeAmount = (feeShares * newTotalSupply) / newTotalShares, where the newTotalShares is equal to the sum of
      // the fee shares and the total existing shares. In this equation, all the terms are known except the fee shares.
      // Solving for the fee shares yields the following calculation.
      uint256 _feeShares = (_feeAmount * _existingShares) / (_newTotalSupply - _feeAmount);

      // By issuing these new shares to the `feeCollector` we effectively give the it `feeAmount` of the reward by
      // slightly diluting all other LST holders.
      sharesOf[feeCollector] += _feeShares;
      totalShares = _existingShares + _feeShares;
    }

    totalSupply = _newTotalSupply;

    // Transfer stake token to the LST
    STAKE_TOKEN.transferFrom(msg.sender, address(this), payoutAmount);
    // Stake the rewards with the default delegatee
    STAKER.stakeMore(depositForDelegatee[defaultDelegatee], uint96(payoutAmount));
    // Claim the reward tokens earned by the LST
    uint256 _rewards = STAKER.claimReward();
    // Ensure rewards distributed meet the claimers expectations; provides protection from frontrunning resulting in
    // loss of funds for the MEV racers.
    if (_rewards < _minExpectedReward) {
      revert UniLst__InsufficientRewards();
    }
    // Transfer the reward tokens to the recipient
    REWARD_TOKEN.transfer(_recipient, _rewards);
  }

  function setWithdrawalGate(address _newWithdrawalGate) external {
    _checkOwner();
    emit WithdrawalGateSet(address(withdrawalGate), _newWithdrawalGate);
    withdrawalGate = IWithdrawalGate(_newWithdrawalGate);
  }

  function setPayoutAmount(uint256 _newPayoutAmount) external {
    _checkOwner();
    emit PayoutAmountSet(payoutAmount, _newPayoutAmount);
    payoutAmount = _newPayoutAmount;
  }

  function setFeeParameters(uint256 _newFeeAmount, address _newFeeCollector) external {
    _checkOwner();
    if (_newFeeAmount > payoutAmount) {
      revert UniLst__InvalidFeeParameters();
    }
    if (_newFeeCollector == address(0)) {
      revert UniLst__InvalidFeeParameters();
    }

    emit FeeParametersSet(feeAmount, _newFeeAmount, feeCollector, _newFeeCollector);

    feeAmount = _newFeeAmount;
    feeCollector = _newFeeCollector;
  }

  function _sharesForStake(uint256 _amount) internal view returns (uint256) {
    // OPTIMIZE: If we force the constructor to stake some initial amount sourced from a contract that can never call
    // `unstake` we should be able to remove these 0 checks altogether.
    if (totalSupply == 0) {
      return SHARE_SCALE_FACTOR * _amount;
    }

    return (_amount * totalShares) / totalSupply;
  }

  function _stakeForShares(uint256 _amount) internal view returns (uint256) {
    if (totalShares == 0) {
      return 0;
    }

    return (_amount * totalSupply) / totalShares;
  }

  function _depositIdForHolder(address _holder) internal view returns (IUniStaker.DepositIdentifier) {
    return depositForDelegatee[delegateeForHolder(_holder)];
  }

  function _transfer(address _sender, address _receiver, uint256 _value) internal returns (bool) {
    IUniStaker.DepositIdentifier _senderDepositId = _depositIdForHolder(_sender);
    IUniStaker.DepositIdentifier _receiverDepositId = _depositIdForHolder(_receiver);
    IUniStaker.DepositIdentifier _defaultDepositId = depositForDelegatee[defaultDelegatee];

    uint256 _balanceOf = balanceOf(_sender);
    uint256 _balanceCheckpoint = balanceCheckpoint[_sender];
    // This is the number of tokens in the default pool that the sender has claim to.
    uint256 _checkpointDiff = _balanceOf - balanceCheckpoint[_sender];
    // This is the number of tokens the sender will have after the transfer is complete.
    uint256 _remainingBalance = _balanceOf - _value;

    // OPTIMIZE: This is the most naive implementation of a transfer:
    // 1. withdraw all tokens belonging to the sender from his designated deposit
    // 2. withdraw all tokens belonging to the sender from the default deposit (tokens earned from rewards)
    // 3. stakeMore the tokens being sent to the receiver's designated deposit
    // 4. stakeMore the remaining tokens back to the sender's designated deposit
    // There are many ways in which this can be optimized. For example, in certain conditions we could avoid having
    // to stakeMore back to the sender's deposit if their balance in the default deposit + some subset of their
    // designated deposit is sufficient to complete the transfer. Obviously, we can also avoid doing withdraws and
    // stakeMores in conditions where the sender and receiver delegatees match. There are also considerations for
    // optimizations that change the functionality to a certain degree. For example, if the senders checkpointDiff
    // is more than is being transferred, do we _need_ to move what's left of the checkpointDiff to the sender's
    // designated deposit? Or would it be acceptable to leave the remainder of their checkpointDiff in the default
    // deposit? This, and many other potential optimizations should be measured and considered, with input from the
    // broader team.
    STAKER.withdraw(_senderDepositId, uint96(_balanceCheckpoint));
    STAKER.withdraw(_defaultDepositId, uint96(_checkpointDiff));
    STAKER.stakeMore(_receiverDepositId, uint96(_value));
    STAKER.stakeMore(_senderDepositId, uint96(_remainingBalance));

    uint256 _shares = _sharesForStake(_value);
    sharesOf[_sender] -= _shares;
    sharesOf[_receiver] += _shares;

    balanceCheckpoint[_sender] = balanceOf(_sender);
    balanceCheckpoint[_receiver] += _stakeForShares(_shares);

    emit Transfer(_sender, _receiver, _value);

    return true;
  }
}
