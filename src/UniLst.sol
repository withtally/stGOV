// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {IUni} from "src/interfaces/IUni.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {IWithdrawalGate} from "src/interfaces/IWithdrawalGate.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";

contract UniLst is Ownable {
  error UniLst__StakeTokenOperationFailed();

  IUniStaker public immutable STAKER;
  IUni public immutable STAKE_TOKEN;
  IWETH9 public immutable REWARD_TOKEN;
  uint256 public constant SHARE_SCALE_FACTOR = 1e18;

  event Transfer(address indexed from, address indexed to, uint256 value);
  event WithdrawalGateSet(address indexed oldWithdrawalGate, address indexed newWithdrawalGate);

  address public defaultDelegatee;
  IWithdrawalGate public withdrawalGate;
  uint256 public totalSupply;
  uint256 public totalShares;
  mapping(address delegatee => IUniStaker.DepositIdentifier depositId) public depositForDelegatee;
  mapping(address holder => address delegatee) private storedDelegateeForHolder;
  mapping(address holder => uint256 shares) public sharesOf;
  // CONSIDER: Maybe rename this to "delegatedBalance" or something similar
  mapping(address holder => uint256 balance) public balanceCheckpoint;

  constructor(IUniStaker _staker, address _initialDefaultDelegatee, address _initialOwner) Ownable(_initialOwner) {
    STAKER = _staker;
    STAKE_TOKEN = IUni(_staker.STAKE_TOKEN());
    REWARD_TOKEN = IWETH9(payable(_staker.REWARD_TOKEN()));
    defaultDelegatee = _initialDefaultDelegatee;

    // OPTIMIZE: We can actually remove these return value checks because UNI reverts (confirm)
    if (!STAKE_TOKEN.approve(address(_staker), type(uint256).max)) {
      revert UniLst__StakeTokenOperationFailed();
    }

    // Create initial deposit for default so other methods can assume it exists.
    // OPTIMIZE: Store this as an immutable to avoid having to ever look it up from storage
    depositForDelegatee[_initialDefaultDelegatee] = STAKER.stake(0, _initialDefaultDelegatee);
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
    balanceCheckpoint[msg.sender] += _amount;
    IUniStaker.DepositIdentifier _depositId = depositForDelegatee[delegateeForHolder(msg.sender)];

    STAKER.stakeMore(_depositId, uint96(_amount));
  }

  function transfer(address _receiver, uint256 _value) external returns (bool) {
    IUniStaker.DepositIdentifier _senderDepositId = _depositIdForHolder(msg.sender);
    IUniStaker.DepositIdentifier _receiverDepositId = _depositIdForHolder(_receiver);
    IUniStaker.DepositIdentifier _defaultDepositId = depositForDelegatee[defaultDelegatee];

    uint256 _balanceOf = balanceOf(msg.sender);
    uint256 _balanceCheckpoint = balanceCheckpoint[msg.sender];
    // This is the number of tokens in the default pool that the sender has claim to.
    uint256 _checkpointDiff = _balanceOf - balanceCheckpoint[msg.sender];
    // This is the number of tokens the sender will have after the transfer is complete.
    uint256 _remainingBalance = _balanceOf - _value;

    uint256 _shares = _sharesForStake(_value);
    sharesOf[msg.sender] -= _shares;
    sharesOf[_receiver] += _shares;

    balanceCheckpoint[msg.sender] = balanceOf(msg.sender);
    balanceCheckpoint[_receiver] += _value;

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

    emit Transfer(msg.sender, _receiver, _value);

    return true;
  }

  // This method is a placeholder for the real rewards distribution mechanism which we will have to spec and add
  // separately. We add this one for now to enable testing of the rebasing mechanism.
  function temp_distributeRewards(uint256 _amount) external {
    STAKE_TOKEN.transferFrom(msg.sender, address(this), _amount);
    totalSupply += _amount;
    STAKER.stakeMore(depositForDelegatee[defaultDelegatee], uint96(_amount));
  }

  function setWithdrawalGate(IWithdrawalGate _newWithdrawalGate) external onlyOwner {
    emit WithdrawalGateSet(address(withdrawalGate), address(_newWithdrawalGate));
    withdrawalGate = _newWithdrawalGate;
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
}
