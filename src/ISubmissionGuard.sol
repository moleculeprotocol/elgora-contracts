// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISubmissionGuard
/// @notice Admission policy called by ElgoraHub for every otherwise-valid submission.
interface ISubmissionGuard {
    /// @notice Immutable bounty facts relevant to submission admission.
    struct SubmissionContext {
        uint256 bountyId;
        address poster;
        bytes32 specCommitment;
        uint256 escrowAmount;
        uint64 submissionDeadline;
        uint64 settlementTimeoutAt;
        bytes32 guardianRosterHash;
        address payoutScheme;
    }

    /// @notice Returns whether `submitter` may record the next submission call.
    /// @dev Deliberately not `view`: a guard may keep admission state of its own (a per-bounty
    /// seat count, say), which a STATICCALL from the Hub would make impossible. An
    /// implementation that needs no state may still narrow this back to `view` or `pure`.
    /// Being non-`view` also means this cannot simply be read off-chain; nothing outside the
    /// chain does today, and a caller that ever needs a preview must simulate the call.
    function canSubmit(
        address submitter,
        SubmissionContext calldata context,
        uint256 submissionCount,
        bytes calldata extraData
    ) external returns (bool);
}
