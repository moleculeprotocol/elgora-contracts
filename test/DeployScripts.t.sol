// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ElgoraHub} from "../src/ElgoraHub.sol";
import {CappedSubmissionGuard} from "../src/CappedSubmissionGuard.sol";
import {WinnerTakesAllPayoutScheme} from "../src/WinnerTakesAllPayoutScheme.sol";
import {DeployElgoraHub} from "../script/DeployElgoraHub.s.sol";
import {DeployLocalDev} from "../script/DeployLocalDev.s.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract DeployScriptsTest is Test {
    uint256 private constant BASE_MAINNET_CHAIN_ID = 8_453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant LOCAL_CHAIN_ID = 31_337;
    address private constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 private constant DEPLOYER_PRIVATE_KEY = 1;
    address private constant PROTOCOL_OWNER = address(0x101);
    address private constant GUARDIAN_ROSTER_ADMIN = address(0x301);
    address private constant TREASURY_RECIPIENT = address(0x401);
    address private constant GUARDIAN_FEE_RECIPIENT = address(0x402);

    DeployElgoraHub private hubDeployment;
    DeployLocalDev private localDeployment;

    function setUp() public {
        hubDeployment = new DeployElgoraHub();
        localDeployment = new DeployLocalDev();
    }

    function testBaseSepoliaDeploymentInitializesLaunchDefaultsAndConfiguredRoles() public {
        _setValidEnvironment();
        _installMockUsdc(BASE_SEPOLIA_USDC);
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);

        ElgoraHub hub = hubDeployment.run();

        assertEq(hub.owner(), PROTOCOL_OWNER);
        assertEq(address(hub.ESCROW_TOKEN()), BASE_SEPOLIA_USDC);
        assertEq(hub.guardianRosterAdmin(), GUARDIAN_ROSTER_ADMIN);
        assertEq(hub.treasuryRecipient(), TREASURY_RECIPIENT);
        assertEq(hub.guardianFeeRecipient(), GUARDIAN_FEE_RECIPIENT);
        assertEq(hub.guardianReviewWindow(), 3 days);
        assertEq(hub.treasuryFeeBps(), 0);
        assertEq(hub.guardianFeeBps(), 1000);
        assertEq(hub.minimumEscrowAmount(), 20e6);
        assertEq(hub.maximumEscrowAmount(), 250e6);
        assertEq(hub.minBountyDuration(), 3 days);
        assertEq(hub.maxBountyDuration(), 30 days);
        CappedSubmissionGuard guard = CappedSubmissionGuard(address(hub.submissionGuard()));
        assertEq(address(guard).codehash, keccak256(type(CappedSubmissionGuard).runtimeCode));
        assertEq(guard.hub(), address(hub));
        assertEq(guard.defaultMaximumSubmissions(), 10);
        assertEq(guard.owner(), vm.addr(DEPLOYER_PRIVATE_KEY));
        assertEq(guard.pendingOwner(), PROTOCOL_OWNER);
        assertEq(
            address(hub.payoutScheme()).codehash,
            keccak256(type(WinnerTakesAllPayoutScheme).runtimeCode)
        );
        assertEq(hub.coordinator(), address(0));
        assertEq(hub.coordinatorGracePeriod(), hubDeployment.DEFAULT_COORDINATOR_GRACE_PERIOD());

        ElgoraHub.Guardian[] memory roster = hub.getGuardianRoster();
        assertEq(roster.length, 2);
        assertEq(roster[0].name, "Guardian One");
        assertEq(roster[0].account, address(0x201));
        assertEq(roster[0].encryptionPublicKey, "key-one");
        assertEq(roster[1].name, "Guardian Two");
        assertEq(roster[1].account, address(0x202));
        assertEq(roster[1].encryptionPublicKey, "key-two");
        assertEq(hub.guardianRosterHash(), keccak256(abi.encode(roster)));

        _setEnvUint("ELGORA_COORDINATOR_GRACE_PERIOD_SECONDS", type(uint64).max);
        ElgoraHub maximumGraceHub = hubDeployment.run();
        assertEq(maximumGraceHub.coordinatorGracePeriod(), type(uint64).max);

        uint256 invalidGracePeriod = uint256(type(uint64).max) + 1;
        _setEnvUint("ELGORA_COORDINATOR_GRACE_PERIOD_SECONDS", invalidGracePeriod);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployElgoraHub.InvalidDeploymentCoordinatorGracePeriod.selector, invalidGracePeriod
            )
        );
        hubDeployment.run();
    }

    function testBaseMainnetDeploymentEscrowsBaseUsdc() public {
        _setValidEnvironment();
        _installMockUsdc(BASE_MAINNET_USDC);
        vm.chainId(BASE_MAINNET_CHAIN_ID);

        ElgoraHub hub = hubDeployment.run();

        assertEq(address(hub.ESCROW_TOKEN()), BASE_MAINNET_USDC);
        assertEq(hub.owner(), PROTOCOL_OWNER);
        assertEq(CappedSubmissionGuard(address(hub.submissionGuard())).hub(), address(hub));
    }

    function testDeploymentRejectsOtherChains() public {
        _expectHubWrongChain(1);
        _expectHubWrongChain(LOCAL_CHAIN_ID);
    }

    function testDeployedGuardAdmitsTenSolversAndLetsThemRevise() public {
        _setValidEnvironment();
        _installMockUsdc(BASE_SEPOLIA_USDC);
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        ElgoraHub hub = hubDeployment.run();
        CappedSubmissionGuard guard = CappedSubmissionGuard(address(hub.submissionGuard()));

        vm.prank(PROTOCOL_OWNER);
        guard.acceptOwnership();
        assertEq(guard.owner(), PROTOCOL_OWNER);

        address poster = makeAddr("poster");
        uint256 escrowAmount = hub.minimumEscrowAmount();
        MockUSDC(BASE_SEPOLIA_USDC).mint(poster, escrowAmount);
        vm.startPrank(poster);
        MockUSDC(BASE_SEPOLIA_USDC).approve(address(hub), escrowAmount);
        uint256 bountyId = hub.createBounty(
            keccak256("spec"), escrowAmount, uint64(block.timestamp + hub.minBountyDuration())
        );
        vm.stopPrank();

        bytes32 rosterHash = hub.guardianRosterHash();
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(address(uint160(0x1000 + i)));
            hub.submit(bountyId, keccak256(abi.encode("submission", i)), rosterHash, "");
        }

        vm.prank(address(0x2000));
        vm.expectRevert(ElgoraHub.SubmissionRejected.selector);
        hub.submit(bountyId, keccak256("eleventh"), rosterHash, "");

        vm.prank(address(0x1000));
        hub.submit(bountyId, keccak256("revision"), rosterHash, "");
        assertEq(hub.activeSubmissionCommitment(bountyId, address(0x1000)), keccak256("revision"));
        assertEq(guard.submissionSeatsUsed(bountyId), 10);
    }

    function testLocalDeploymentRunsWithSameDayZeroPolicies() public {
        vm.chainId(LOCAL_CHAIN_ID);
        (ElgoraHub hub, MockUSDC usdc) = localDeployment.run();

        assertNotEq(address(hub), address(0));
        assertEq(address(hub.ESCROW_TOKEN()), address(usdc));
        assertEq(hub.guardianReviewWindow(), 6 hours);
        assertEq(hub.treasuryFeeBps(), 150);
        assertEq(hub.guardianFeeBps(), 350);
        CappedSubmissionGuard guard = CappedSubmissionGuard(address(hub.submissionGuard()));
        assertEq(guard.hub(), address(hub));
        assertEq(guard.defaultMaximumSubmissions(), 10);
        assertGt(address(hub.payoutScheme()).code.length, 0);
        assertEq(hub.coordinator(), 0x90F79bf6EB2c4f870365E785982E1f101E93b906);
        assertEq(hub.coordinatorGracePeriod(), 10 minutes);
        assertEq(hub.getGuardianRoster().length, 1);
        assertEq(usdc.balanceOf(0x70997970C51812dc3A010C7d01b50e0d17dc79C8), 1_000e6);
    }

    function testLocalDeploymentRejectsPublicAndArbitraryChains() public {
        _expectLocalWrongChain(BASE_SEPOLIA_CHAIN_ID);
        _expectLocalWrongChain(BASE_MAINNET_CHAIN_ID);
        _expectLocalWrongChain(1);
    }

    function _expectHubWrongChain(uint256 chainId) private {
        vm.chainId(chainId);
        vm.expectRevert(abi.encodeWithSelector(DeployElgoraHub.WrongChain.selector, chainId));
        hubDeployment.run();
    }

    function _expectLocalWrongChain(uint256 chainId) private {
        vm.chainId(chainId);
        vm.expectRevert(abi.encodeWithSelector(DeployLocalDev.WrongChain.selector, chainId));
        localDeployment.run();
    }

    // vm.setEnv only seeds values read by deploy scripts in this Forge process. The
    // grace-period boundary cases stay in one test because process env is shared.
    function _setValidEnvironment() private {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ELGORA_DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_PRIVATE_KEY));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ELGORA_PROTOCOL_OWNER_ADDRESS", vm.toString(PROTOCOL_OWNER));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ELGORA_GUARDIAN_ROSTER_ADMIN", vm.toString(GUARDIAN_ROSTER_ADMIN));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ELGORA_TREASURY_RECIPIENT", vm.toString(TREASURY_RECIPIENT));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ELGORA_GUARDIAN_FEE_RECIPIENT", vm.toString(GUARDIAN_FEE_RECIPIENT));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ELGORA_COORDINATOR_ADDRESS", vm.toString(address(0)));
        _setEnvUint(
            "ELGORA_COORDINATOR_GRACE_PERIOD_SECONDS",
            hubDeployment.DEFAULT_COORDINATOR_GRACE_PERIOD()
        );
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ELGORA_GUARDIAN_NAMES", "Guardian One|Guardian Two");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(
            "ELGORA_GUARDIAN_ADDRESSES",
            string.concat(vm.toString(address(0x201)), "|", vm.toString(address(0x202)))
        );
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ELGORA_GUARDIAN_ENCRYPTION_PUBLIC_KEYS", "key-one|key-two");
    }

    function _setEnvUint(string memory name, uint256 value) private {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(name, vm.toString(value));
    }

    function _installMockUsdc(address usdc) private {
        MockUSDC implementation = new MockUSDC();
        vm.etch(usdc, address(implementation).code);
    }
}
