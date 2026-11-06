// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {IERC3009} from "../src/IERC3009.sol";

/// Mirrors the parts of Circle's FiatToken ElgoraHub actually depends on, EIP-3009 included, so
/// the one-signature funding path can be exercised without a fork.
contract MockUSDC is ERC20, EIP712, IERC3009 {
    mapping(address account => bool blocked) public blocked;
    uint256 public transferFeeBps;
    address public feeCollector = address(0xFEE);

    /// Exactly the digest Circle's FiatToken signs; see EIP-3009.
    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// Spent authorizations, per authorizer; a reused nonce is rejected.
    mapping(address authorizer => mapping(bytes32 nonce => bool used)) public authorizationState;

    error BlockedTransfer();
    error InvalidFee();
    error InvalidAuthorization();

    constructor() ERC20("Mock USDC", "mUSDC") EIP712("Mock USDC", "2") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// Circle's FiatToken exposes this, and EIP-3009 signers need it to build the digest.
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function setTransferFeeBps(uint256 feeBps) external {
        if (feeBps > 10_000) revert InvalidFee();
        transferFeeBps = feeBps;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (blocked[_msgSender()] || blocked[to]) revert BlockedTransfer();
        _transferWithOptionalFee(_msgSender(), to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (blocked[from] || blocked[to]) revert BlockedTransfer();
        _spendAllowance(from, _msgSender(), value);
        _transferWithOptionalFee(from, to, value);
        return true;
    }

    /// @inheritdoc IERC3009
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
    ) external {
        // The defining property of the receive variant: only the recipient may redeem it.
        if (to != _msgSender()) revert InvalidAuthorization();
        if (block.timestamp <= validAfter || block.timestamp >= validBefore) {
            revert InvalidAuthorization();
        }
        if (authorizationState[from][nonce]) revert InvalidAuthorization();
        if (blocked[from] || blocked[to]) revert BlockedTransfer();

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                    from,
                    to,
                    value,
                    validAfter,
                    validBefore,
                    nonce
                )
            )
        );
        if (ECDSA.recover(digest, v, r, s) != from) revert InvalidAuthorization();

        authorizationState[from][nonce] = true;
        _transferWithOptionalFee(from, to, value);
    }

    function _transferWithOptionalFee(address from, address to, uint256 value) private {
        uint256 fee = (value * transferFeeBps) / 10_000;
        uint256 net = value - fee;
        super._transfer(from, to, net);
        if (fee > 0) {
            super._transfer(from, feeCollector, fee);
        }
    }
}
