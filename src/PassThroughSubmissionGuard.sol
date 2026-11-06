// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {ISubmissionGuard} from "./ISubmissionGuard.sol";

/// @title PassThroughSubmissionGuard
/// @notice Day-zero permissionless admission policy for ElgoraHub submissions.
contract PassThroughSubmissionGuard is ISubmissionGuard {
    /// @inheritdoc ISubmissionGuard
    function canSubmit(address, SubmissionContext calldata, uint256, bytes calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}
