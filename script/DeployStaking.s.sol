// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {VibesStaking} from "../src/VibesStaking.sol";
import {VibesStakerRewards} from "../src/VibesStakerRewards.sol";
import {VibesRouterExtension} from "../src/VibesRouterExtension.sol";

/// @notice Deploy staking contracts and wire to router
contract DeployStaking is Script {
    address constant ROUTER = 0x6E846B4013708B478F2132C590b0275B12525b2D;
    address constant VIBES_TOKEN = 0x40DD4D161F62f773280881B4910BF6805Cca102A;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========== STAKING DEPLOYMENT ==========");
        console.log("Deployer:", deployer);
        console.log("VIBES Token:", VIBES_TOKEN);
        console.log("Router:", ROUTER);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy VibesStaking (trustedSigner = address(0) for testnet bypass)
        VibesStaking staking = new VibesStaking(VIBES_TOKEN, address(0));
        console.log("1. VibesStaking:", address(staking));

        // 2. Deploy VibesStakerRewards
        VibesStakerRewards stakerRewards = new VibesStakerRewards(
            deployer,           // admin
            address(staking),   // staking contract
            ROUTER              // authorized router
        );
        console.log("2. VibesStakerRewards:", address(stakerRewards));

        // 3. Wire: set staker rewards in router
        VibesRouterExtension(ROUTER).setStakerRewardsContract(address(stakerRewards));
        console.log("3. StakerRewards set in router");

        vm.stopBroadcast();

        console.log("");
        console.log("========== STAKING DEPLOYMENT COMPLETE ==========");
        console.log("VibesStaking:        ", address(staking));
        console.log("VibesStakerRewards:  ", address(stakerRewards));
        console.log("");
        console.log("# Vercel env vars to add:");
        console.log(string.concat("NEXT_PUBLIC_STAKING_CONTRACT=", vm.toString(address(staking))));
        console.log(string.concat("NEXT_PUBLIC_STAKER_REWARDS=", vm.toString(address(stakerRewards))));
        console.log("");
        console.log("# addresses.ts updates:");
        console.log(string.concat("vibesToken: '", vm.toString(VIBES_TOKEN), "' as `0x${string}`,"));
        console.log(string.concat("vibesStaking: '", vm.toString(address(staking)), "' as `0x${string}`,"));
        console.log(string.concat("vibesStakerRewards: '", vm.toString(address(stakerRewards)), "' as `0x${string}`,"));
    }
}
