// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title IERC3009
/// @notice The one EIP-3009 call ElgoraHub uses: a signed authorization the recipient itself
/// redeems. Deliberately not the `transferWithAuthorization` sibling — that variant can be
/// consumed by anyone calling the token directly, which would move escrow into the Hub with no
/// bounty created.
interface IERC3009 {
    /// @notice Redeems a signed transfer authorization; the token requires that its caller be `to`.
    /// @param from Authorizer, whose signature this is.
    /// @param to Recipient, which must equal the token's msg.sender.
    /// @param value Exact amount authorized, in the token's base units.
    /// @param validAfter Unix timestamp (seconds) the authorization becomes valid.
    /// @param validBefore Unix timestamp (seconds) the authorization expires.
    /// @param nonce Unique 32-byte nonce per authorizer; a reused one is rejected by the token.
    /// @param v Signature recovery byte.
    /// @param r Signature r value.
    /// @param s Signature s value.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
