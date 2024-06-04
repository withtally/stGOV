// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20, ERC20Votes} from "openzeppelin/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "openzeppelin/utils/cryptography/EIP712.sol";
import {UniStaker} from "unistaker/UniStaker.sol";

contract UniLst is ERC20Votes {
  ERC20 public immutable STAKE_TOKEN;
  UniStaker public immutable STAKER;

  constructor(ERC20 _stakeToken, UniStaker _staker, string memory _name, string memory _symbol)
    ERC20(_name, _symbol)
    EIP712(_name, "1")
  {
    STAKE_TOKEN = _stakeToken;
    STAKER = _staker;
  }
}
