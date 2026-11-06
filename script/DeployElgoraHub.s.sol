// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ElgoraHub} from "../src/ElgoraHub.sol";
import {CappedSubmissionGuard} from "../src/CappedSubmissionGuard.sol";
import {WinnerTakesAllPayoutScheme} from "../src/WinnerTakesAllPayoutScheme.sol";

/// @notice Deploys and initializes the ElgoraHub contract layer on Base or Base Sepolia.
contract DeployElgoraHub is Script {
    uint256 private constant BASE_MAINNET_CHAIN_ID = 8_453;
    address private constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    uint64 public constant DEFAULT_GUARDIAN_REVIEW_WINDOW = 3 days;
    uint16 public constant DEFAULT_TREASURY_FEE_BPS = 0;
    uint16 public constant DEFAULT_GUARDIAN_FEE_BPS = 1000;
    uint256 public constant DEFAULT_MINIMUM_ESCROW_AMOUNT = 20e6;
    uint256 public constant DEFAULT_MAXIMUM_ESCROW_AMOUNT = 250e6;
    uint64 public constant DEFAULT_MIN_BOUNTY_DURATION = 3 days;
    uint64 public constant DEFAULT_MAX_BOUNTY_DURATION = 30 days;
    uint64 public constant DEFAULT_COORDINATOR_GRACE_PERIOD = 1 hours;
    uint256 public constant DEFAULT_MAXIMUM_SUBMISSIONS = 10;

    error WrongChain(uint256 chainId);
    error InvalidGuardianRosterInput();
    error InvalidDeploymentCoordinatorGracePeriod(uint256 value);

    function run() external returns (ElgoraHub hub) {
        IERC20 escrowToken = _escrowTokenForChain(block.chainid);

        uint256 deployerPrivateKey = vm.envUint("ELGORA_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address protocolOwner = vm.envAddress("ELGORA_PROTOCOL_OWNER_ADDRESS");
        ElgoraHub.InitialConfig memory config = _readInitialConfig();
        ElgoraHub.Guardian[] memory roster = _readGuardianRosterFromEnv();

        vm.startBroadcast(deployerPrivateKey);
        // The Hub takes its guard at construction and the guard binds its Hub once, so the
        // deployer owns the guard just long enough to bind it, then hands it to the protocol
        // owner. The protocol owner still has to acceptOwnership(); see the "Submission guard"
        // section of OPERATIONS.md.
        CappedSubmissionGuard guard =
            new CappedSubmissionGuard(deployer, DEFAULT_MAXIMUM_SUBMISSIONS);
        WinnerTakesAllPayoutScheme scheme = new WinnerTakesAllPayoutScheme();
        config.submissionGuard = address(guard);
        config.payoutScheme = address(scheme);
        hub = new ElgoraHub(escrowToken, protocolOwner, config, roster);
        guard.bindHub(address(hub));
        guard.transferOwnership(protocolOwner);
        vm.stopBroadcast();

        require(guard.hub() == address(hub), "guard not bound to hub");
        require(guard.pendingOwner() == protocolOwner, "guard ownership not offered");

        _logDeployment(hub, guard, scheme);
    }

    function _escrowTokenForChain(uint256 chainId) private pure returns (IERC20) {
        if (chainId == BASE_MAINNET_CHAIN_ID) return IERC20(BASE_MAINNET_USDC);
        if (chainId == BASE_SEPOLIA_CHAIN_ID) return IERC20(BASE_SEPOLIA_USDC);
        revert WrongChain(chainId);
    }

    function _readInitialConfig() private returns (ElgoraHub.InitialConfig memory config) {
        config.guardianRosterAdmin = vm.envAddress("ELGORA_GUARDIAN_ROSTER_ADMIN");
        config.guardianReviewWindow = DEFAULT_GUARDIAN_REVIEW_WINDOW;
        config.treasuryRecipient = vm.envAddress("ELGORA_TREASURY_RECIPIENT");
        config.guardianFeeRecipient = vm.envAddress("ELGORA_GUARDIAN_FEE_RECIPIENT");
        config.treasuryFeeBps = DEFAULT_TREASURY_FEE_BPS;
        config.guardianFeeBps = DEFAULT_GUARDIAN_FEE_BPS;
        config.minimumEscrowAmount = DEFAULT_MINIMUM_ESCROW_AMOUNT;
        config.maximumEscrowAmount = DEFAULT_MAXIMUM_ESCROW_AMOUNT;
        config.minBountyDuration = DEFAULT_MIN_BOUNTY_DURATION;
        config.maxBountyDuration = DEFAULT_MAX_BOUNTY_DURATION;
        // Molecule's settlement coordinator; unset (zero) makes settle() permissionless from
        // deployment, the natural end state after ownership is renounced.
        config.coordinator = vm.envOr("ELGORA_COORDINATOR_ADDRESS", address(0));
        uint256 coordinatorGracePeriod = vm.envOr(
            "ELGORA_COORDINATOR_GRACE_PERIOD_SECONDS", uint256(DEFAULT_COORDINATOR_GRACE_PERIOD)
        );
        if (coordinatorGracePeriod > type(uint64).max) {
            revert InvalidDeploymentCoordinatorGracePeriod(coordinatorGracePeriod);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        config.coordinatorGracePeriod = uint64(coordinatorGracePeriod);
    }

    function _readGuardianRosterFromEnv() private returns (ElgoraHub.Guardian[] memory roster) {
        string[] memory guardianNames = vm.envString("ELGORA_GUARDIAN_NAMES", "|");
        address[] memory guardianAccounts = vm.envAddress("ELGORA_GUARDIAN_ADDRESSES", "|");
        string[] memory guardianKeys = vm.envString("ELGORA_GUARDIAN_ENCRYPTION_PUBLIC_KEYS", "|");
        roster = _buildGuardianRoster(guardianNames, guardianAccounts, guardianKeys);
    }

    function _buildGuardianRoster(
        string[] memory guardianNames,
        address[] memory guardianAccounts,
        string[] memory guardianKeys
    ) private pure returns (ElgoraHub.Guardian[] memory roster) {
        if (
            guardianNames.length == 0 || guardianNames.length != guardianAccounts.length
                || guardianNames.length != guardianKeys.length
        ) revert InvalidGuardianRosterInput();

        roster = new ElgoraHub.Guardian[](guardianNames.length);
        for (uint256 i = 0; i < roster.length; i++) {
            roster[i] = ElgoraHub.Guardian({
                name: guardianNames[i],
                account: guardianAccounts[i],
                encryptionPublicKey: guardianKeys[i]
            });
        }
    }

    function _logDeployment(
        ElgoraHub hub,
        CappedSubmissionGuard guard,
        WinnerTakesAllPayoutScheme scheme
    ) private view {
        console.log("ELGORA_HUB_ADDRESS=%s", address(hub));
        console.log("ELGORA_ESCROW_TOKEN_ADDRESS=%s", address(hub.ESCROW_TOKEN()));
        console.log("ELGORA_SUBMISSION_GUARD_ADDRESS=%s", address(guard));
        console.log("ELGORA_PAYOUT_SCHEME_ADDRESS=%s", address(scheme));
        console.log("ELGORA_GUARDIAN_ROSTER_HASH=%s", vm.toString(hub.guardianRosterHash()));
    }
}
