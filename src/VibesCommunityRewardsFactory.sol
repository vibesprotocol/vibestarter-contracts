// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VibesCommunityRewards} from "./VibesCommunityRewards.sol";

/// @title VibesCommunityRewardsFactory
/// @notice Thin factory that creates a fresh `VibesCommunityRewards` on demand.
/// @dev Exists so the router does not have to carry VibesCommunityRewards' creation
///      code, which would push VibesLaunchRouterV2 over the EIP-170 24,576-byte
///      runtime-bytecode limit. `launchWithCampaign` calls `create(...)` on this
///      factory atomically inside the same transaction, so the PC-03 "one tx, one
///      community rewards contract" guarantee is preserved.
///
///      Permissionless by design: every call returns a brand-new contract bound to
///      the caller-supplied (token, unlockTime, admin). Deploying this factory is
///      the only operational step required beyond the standard router set-up —
///      the router then references it via the `communityRewardsFactory` storage slot
///      set through `VibesRouterExtension.setCommunityRewardsFactory`.
contract VibesCommunityRewardsFactory {
    event CommunityRewardsDeployed(
        address indexed communityRewards,
        address indexed token,
        address indexed admin,
        uint256 unlockTime
    );

    /// @notice Deploy a fresh VibesCommunityRewards contract.
    /// @param token       Token being distributed (the freshly-launched project ERC-20).
    /// @param unlockTime  Absolute timestamp before which no tokens can be released (cliff).
    /// @param admin       Admin address (expected: Community Rewards multisig) — may be zero
    ///                    only if the caller has a reason to permanently freeze the contract
    ///                    (validated at the VibesCommunityRewards constructor level, not here).
    /// @return deployed   Address of the newly-deployed VibesCommunityRewards.
    function create(IERC20 token, uint256 unlockTime, address admin) external returns (address deployed) {
        VibesCommunityRewards cr = new VibesCommunityRewards(token, unlockTime, admin);
        deployed = address(cr);
        emit CommunityRewardsDeployed(deployed, address(token), admin, unlockTime);
    }
}
