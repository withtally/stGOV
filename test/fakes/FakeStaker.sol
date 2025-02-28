// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Staker} from "../../lib/staker/src/Staker.sol";
import {StakerPermitAndStake} from "../../lib/staker/src/extensions/StakerPermitAndStake.sol";
import {StakerOnBehalf} from "../../lib/staker/src/extensions/StakerOnBehalf.sol";
import {StakerDelegateSurrogateVotes} from "../../lib/staker/src/extensions/StakerDelegateSurrogateVotes.sol";
import {IERC20Staking} from "../../lib/staker/src/interfaces/IERC20Staking.sol";
import {IEarningPowerCalculator} from "../../lib/staker/src/interfaces/IEarningPowerCalculator.sol";
import {DelegationSurrogate} from "../../lib/staker/src/DelegationSurrogate.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract FakeStaker is Staker, StakerPermitAndStake, StakerOnBehalf, StakerDelegateSurrogateVotes {
  constructor(
    IERC20 _rewardsToken,
    IERC20Staking _stakeToken,
    IEarningPowerCalculator _earningPowerCalculator,
    uint256 _maxBumpTip,
    address _admin,
    string memory _name
  )
    Staker(_rewardsToken, _stakeToken, _earningPowerCalculator, _maxBumpTip, _admin)
    StakerPermitAndStake(_stakeToken)
    StakerDelegateSurrogateVotes(_stakeToken)
    EIP712(_name, "1")
  {
    MAX_CLAIM_FEE = 1e18;
    _setClaimFeeParameters(ClaimFeeParameters({feeAmount: 0, feeCollector: address(0)}));
  }

  function exposed_useDepositId() external returns (DepositIdentifier _depositId) {
    _depositId = _useDepositId();
  }

  function exposed_fetchOrDeploySurrogate(address delegatee) external returns (DelegationSurrogate _surrogate) {
    _surrogate = _fetchOrDeploySurrogate(delegatee);
  }
}
