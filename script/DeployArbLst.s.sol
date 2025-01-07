// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {UniLst} from "../src/UniLst.sol";
import {UniStaker} from "unistaker/UniStaker.sol";

contract DeployArbLst is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Get necessary addresses from environment
        address arbStaker = vm.envAddress("ARB_STAKER_ADDRESS");
        address initialDefaultDelegatee = vm.envAddress("INITIAL_DELEGATEE");
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address initialDelegateeGuardian = vm.envAddress("INITIAL_GUARDIAN");
        
        // Configuration
        string memory name = "Arbitrum Liquid Staked Token";
        string memory symbol = "stARB";
        uint80 initialPayoutAmount = 100e18; // Adjust this value as needed

        vm.startBroadcast(deployerPrivateKey);

        // Deploy ArbLst
        UniLst lst = new UniLst(
            name,
            symbol,
            UniStaker(arbStaker),
            initialDefaultDelegatee,
            initialOwner,
            initialPayoutAmount,
            initialDelegateeGuardian
        );

        vm.stopBroadcast();
    }
}
