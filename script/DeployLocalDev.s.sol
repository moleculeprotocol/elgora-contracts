// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ElgoraHub} from "../src/ElgoraHub.sol";
import {CappedSubmissionGuard} from "../src/CappedSubmissionGuard.sol";
import {WinnerTakesAllPayoutScheme} from "../src/WinnerTakesAllPayoutScheme.sol";
import {MockUSDC} from "../test/MockUSDC.sol";

/// @notice Deploys ElgoraHub and MockUSDC for local anvil use only.
contract DeployLocalDev is Script {
    uint256 private constant LOCAL_CHAIN_ID = 31_337;

    address internal constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 internal constant DEPLOYER_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address internal constant POSTER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant SOLVER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant GUARDIAN = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address internal constant CLAIMANT = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address internal constant TREASURY = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    string internal constant LOCAL_GUARDIAN_PUBLIC_KEY =
        "rjvxzYfC0u0lr0oaI57tBKmQ8A50A-TIBlkn3gEP0Xo";
    uint256 internal constant INITIAL_USDC = 1_000e6;
    uint64 internal constant LOCAL_COORDINATOR_GRACE_PERIOD = 10 minutes;
    uint256 internal constant LOCAL_MAXIMUM_SUBMISSIONS = 10;

    error WrongChain(uint256 chainId);

    function run() external returns (ElgoraHub hub, MockUSDC usdc) {
        if (block.chainid != LOCAL_CHAIN_ID) revert WrongChain(block.chainid);

        vm.startBroadcast(DEPLOYER_KEY);
        usdc = new MockUSDC();
        CappedSubmissionGuard guard = new CappedSubmissionGuard(DEPLOYER, LOCAL_MAXIMUM_SUBMISSIONS);
        WinnerTakesAllPayoutScheme scheme = new WinnerTakesAllPayoutScheme();

        ElgoraHub.Guardian[] memory roster = new ElgoraHub.Guardian[](1);
        roster[0] = ElgoraHub.Guardian({
            name: "local_test", account: GUARDIAN, encryptionPublicKey: LOCAL_GUARDIAN_PUBLIC_KEY
        });
        hub = new ElgoraHub(
            IERC20(address(usdc)),
            DEPLOYER,
            ElgoraHub.InitialConfig({
                guardianRosterAdmin: GUARDIAN,
                guardianReviewWindow: 6 hours,
                treasuryRecipient: TREASURY,
                guardianFeeRecipient: TREASURY,
                treasuryFeeBps: 150,
                guardianFeeBps: 350,
                minimumEscrowAmount: 1e6,
                maximumEscrowAmount: 250e6,
                minBountyDuration: 1 days,
                maxBountyDuration: 180 days,
                submissionGuard: address(guard),
                payoutScheme: address(scheme),
                coordinator: GUARDIAN,
                coordinatorGracePeriod: LOCAL_COORDINATOR_GRACE_PERIOD
            }),
            roster
        );
        guard.bindHub(address(hub));

        usdc.mint(POSTER, INITIAL_USDC);
        usdc.mint(SOLVER, INITIAL_USDC);
        usdc.mint(CLAIMANT, INITIAL_USDC);
        vm.stopBroadcast();

        console.log("ELGORA_HUB_ADDRESS=%s", address(hub));
        console.log("ELGORA_ESCROW_TOKEN_ADDRESS=%s", address(usdc));
        console.log("ELGORA_SUBMISSION_GUARD_ADDRESS=%s", address(guard));
        console.log("ELGORA_PAYOUT_SCHEME_ADDRESS=%s", address(scheme));
        console.log("ELGORA_GUARDIAN_ROSTER_HASH=%s", vm.toString(hub.guardianRosterHash()));
    }
}
