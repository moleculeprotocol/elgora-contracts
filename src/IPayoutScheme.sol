// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title IPayoutScheme
/// @notice Resolves one claimant's share of an awarded ElgoraHub bounty's winner pool, on demand.
interface IPayoutScheme {
    /// @notice Returns the amount `claimant` may withdraw right now from `winnerPool`, given the
    /// Guardian-agreed `payoutData` and whatever `proof` `claimant` supplies. ElgoraHub calls this
    /// once per claimAward() and enforces that the running total paid out across every claimant
    /// never exceeds `winnerPool`; the scheme is responsible for its own double-claim bookkeeping
    /// (e.g. marking a proof spent) since ElgoraHub tracks only the aggregate remaining pool, not
    /// per-claimant entitlement.
    function claimAmount(
        uint256 bountyId,
        address winner,
        uint256 winnerPool,
        bytes calldata payoutData,
        address claimant,
        bytes calldata proof
    ) external returns (uint256 amount);
}
