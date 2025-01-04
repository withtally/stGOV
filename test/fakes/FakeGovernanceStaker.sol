// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GovernanceStaker} from "@staker/src/GovernanceStaker.sol";
import {GovernanceStakerPermitAndStake} from "@staker/src/extensions/GovernanceStakerPermitAndStake.sol";
import {GovernanceStakerOnBehalf} from "@staker/src/extensions/GovernanceStakerOnBehalf.sol";
import {GovernanceStakerDelegateSurrogateVotes} from "@staker/src/extensions/GovernanceStakerDelegateSurrogateVotes.sol";
import {IERC20Staking} from "@staker/src/interfaces/IERC20Staking.sol";
import {IERC20Delegates} from "@staker/src/interfaces/IERC20Delegates.sol";
import {IEarningPowerCalculator} from "@staker/src/interfaces/IEarningPowerCalculator.sol";
import {DelegationSurrogate} from "@staker/src/DelegationSurrogate.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {EIP712} from "openzeppelin/utils/cryptography/EIP712.sol";

contract FakeGovernanceStaker is
  GovernanceStaker,
  GovernanceStakerPermitAndStake,
  GovernanceStakerOnBehalf,
  GovernanceStakerDelegateSurrogateVotes
{
  constructor(
    IERC20 _rewardsToken,
    IERC20Staking _stakeToken,
    IEarningPowerCalculator _earningPowerCalculator,
    uint256 _maxBumpTip,
    address _admin,
    string memory _name
  )
    GovernanceStaker(_rewardsToken, _stakeToken, _earningPowerCalculator, _maxBumpTip, _admin)
    GovernanceStakerPermitAndStake(_stakeToken)
    GovernanceStakerDelegateSurrogateVotes(_stakeToken)
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
