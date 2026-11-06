// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {IPayoutScheme} from "./IPayoutScheme.sol";

/// @title WinnerTakesAllPayoutScheme
/// @notice Day-zero payout policy: the winner alone may claim the entire winner pool, once.
contract WinnerTakesAllPayoutScheme is IPayoutScheme {
    /// @inheritdoc IPayoutScheme
    function claimAmount(
        uint256,
        address winner,
        uint256 winnerPool,
        bytes calldata,
        address claimant,
        bytes calldata
    ) external pure returns (uint256 amount) {
        return claimant == winner ? winnerPool : 0;
    }
}
