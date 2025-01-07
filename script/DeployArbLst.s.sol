// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {UniLst} from "../src/UniLst.sol";
import {IUniStaker} from "../src/interfaces/IUniStaker.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        uint80 initialPayoutAmount = 100e18;

        console2.log("ArbStaker address:", arbStaker);
        console2.log("Initial Delegatee:", initialDefaultDelegatee);
        console2.log("Initial Owner:", initialOwner);
        console2.log("Initial Guardian:", initialDelegateeGuardian);
        
        vm.startBroadcast(deployerPrivateKey);

        IUniStaker staker = IUniStaker(arbStaker);
        IERC20 stakeToken = IERC20(staker.STAKE_TOKEN());
        
        // Transfer tiny amount to the LST
        uint96 initialStakeAmount = 1; // 1 wei of the stake token
        // Note: Make sure the deployer has enough stake token balance

        try new UniLst(
            name,
            symbol,
            IUniStaker(arbStaker),
            initialDefaultDelegatee,
            initialOwner,
            initialPayoutAmount,
            initialDelegateeGuardian
        ) returns (UniLst lst) {
            console2.log("LST deployed at:", address(lst));
            
            // Send the initial stake amount to the LST for initialization
            stakeToken.transfer(address(lst), initialStakeAmount);
        } catch Error(string memory reason) {
            console2.log("Deployment failed with reason:", reason);
            revert(reason);
        }

        vm.stopBroadcast();
    }
}
