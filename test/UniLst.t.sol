// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {UniLst, ERC20, UniStaker} from "src/UniLst.sol";

contract UniLstTest is Test {
  UniLst tUni;
  UniStaker staker = UniStaker(0xE3071e87a7E6dD19A911Dbf1127BA9dD67Aa6fc8);
  ERC20 stakeToken = ERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);

  uint256 constant FORK_BLOCK = 20_019_142; // fork block after UniStaker deployment

  function setUp() public {
    vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("Please set MAINNET_RPC_URL in your .env file")), FORK_BLOCK);

    tUni = new UniLst(stakeToken, staker, "Tally Liquid Staked UNI", "tUNI");
  }
}

contract Constructor is UniLstTest {
  function test_DeploysTheContractWithCorrectParametersInitialized() public view {
    assertTrue(address(tUni) != address(0));
    assertEq(address(tUni.STAKE_TOKEN()), address(stakeToken));
    assertEq(address(tUni.STAKER()), address(staker));
    assertEq(tUni.symbol(), "tUNI");
    assertEq(tUni.name(), "Tally Liquid Staked UNI");
  }
}
