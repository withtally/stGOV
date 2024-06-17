// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniStaker} from "src/interfaces/IUniStaker.sol";
import {IUni} from "src/interfaces/IUni.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";

contract UniLst {
  IUniStaker public immutable STAKER;
  IUni public immutable STAKE_TOKEN;
  IWETH9 public immutable REWARD_TOKEN;

  constructor(IUniStaker _staker) {
    STAKER = _staker;
    STAKE_TOKEN = IUni(_staker.STAKE_TOKEN());
    REWARD_TOKEN = IWETH9(payable(_staker.REWARD_TOKEN()));
  }
}
