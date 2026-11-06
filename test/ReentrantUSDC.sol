// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ElgoraHub} from "../src/ElgoraHub.sol";

contract ReentrantUSDC is ERC20 {
    ElgoraHub private reentryTarget;
    uint256 private reentryBountyId;
    bool private reentryEnabled;
    bool private reentryActive;

    bool public reentryAttempted;
    bytes4 public reentryRevertSelector;

    constructor() ERC20("Reentrant USDC", "rUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReentry(ElgoraHub target, uint256 bountyId, bool enabled) external {
        reentryTarget = target;
        reentryBountyId = bountyId;
        reentryEnabled = enabled;
        reentryAttempted = false;
        reentryRevertSelector = bytes4(0);
    }

    function claimFromTarget() external {
        reentryTarget.claimAward(reentryBountyId, "");
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _attemptReentry();
        return super.transfer(to, value);
    }

    function _attemptReentry() private {
        if (!reentryEnabled || reentryActive) return;

        reentryActive = true;
        reentryAttempted = true;

        (bool ok, bytes memory result) =
            address(reentryTarget).call(abi.encodeCall(ElgoraHub.claimAward, (reentryBountyId, "")));
        if (!ok && result.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(result, 0x20))
            }
            reentryRevertSelector = selector;
        } else if (ok) {
            reentryRevertSelector = bytes4(uint32(1));
        }

        reentryActive = false;
    }
}
