# Legacy Contracts (V1) - DEPRECATED

These contracts are from the original milestone-based funding system (V1) and are **not deployed in production**. They are kept here for reference only.

Vibestarter launched with the V2 time-based tranche system. **Do not deploy these contracts.**

## Known Issues

These contracts contain unpatched vulnerabilities that were identified during audit but never fixed because V2 replaced them entirely:

- **VibesCampaignEscrow.sol** - `transferToDistributor` has an authorization bypass (checks user-supplied `caller` parameter instead of `msg.sender`)
- **VibesCampaignEscrow.sol** - `_verifyProofCapsule` is a stub that accepts any non-zero hash
- **VibesCampaignEscrow.sol** - `submitMilestoneProof` / `_verifyAndRelease` have no campaign status gating
- **VibesCampaignEscrow.sol** - `receive()` credits contributions to the contract address instead of the sender
- **VibesLaunchRouter.sol** - `withdrawLiquidityTokens` gives owner unrestricted access to LP tokens

## V1 → V2 Replacement Map

| V1 (Legacy) | V2 (Production) |
|---|---|
| `VibesCampaignEscrow.sol` | `VibesTranchEscrow.sol` |
| `VibesCampaignFactory.sol` | `VibesTranchEscrowFactory.sol` |
| `VibesLaunchRouter.sol` | `VibesLaunchRouterV2.sol` |
| `VibesTokenDistributor.sol` | `VibesTokenDistributorV2.sol` |
