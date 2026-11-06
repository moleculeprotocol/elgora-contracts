// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";
import {ElgoraHub} from "../../src/ElgoraHub.sol";
import {PassThroughSubmissionGuard} from "../../src/PassThroughSubmissionGuard.sol";
import {WinnerTakesAllPayoutScheme} from "../../src/WinnerTakesAllPayoutScheme.sol";

contract BaseSepoliaUsdcForkTest is Test {
    address private constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    bytes32 private constant SPEC_COMMITMENT = keccak256("spec");
    bytes32 private constant SUBMISSION_COMMITMENT = keccak256("submission");
    bytes32 private constant REPORT_COMMITMENT = keccak256("written verdict");
    uint256 private constant ESCROW_AMOUNT = 200e6;

    address private poster = makeAddr("poster");
    address private protocolOwner = makeAddr("protocol owner");
    address private guardianRosterAdmin = makeAddr("guardian roster admin");
    address private guardian = makeAddr("guardian");
    address private treasury = makeAddr("treasury");
    address private guardianFeeRecipient = makeAddr("guardian fee recipient");
    address private solver = makeAddr("solver");

    /// The one extra read a signer needs off Circle's FiatToken; the interface ElgoraHub itself
    /// uses covers the write.
    function _usdcDomainSeparator() private view returns (bytes32) {
        (bool ok, bytes memory data) =
            BASE_SEPOLIA_USDC.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok, "USDC DOMAIN_SEPARATOR() missing");
        return abi.decode(data, (bytes32));
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ELGORA_BASE_SEPOLIA_RPC_URL"));
    }

    function testBaseSepoliaUsdcFundingSubmissionSettlementAndClaimFlow() public {
        assertGt(BASE_SEPOLIA_USDC.code.length, 0, "Base Sepolia USDC missing");
        assertEq(IERC20Metadata(BASE_SEPOLIA_USDC).decimals(), 6);

        ElgoraHub hub = _deployForkHub();

        deal(BASE_SEPOLIA_USDC, poster, ESCROW_AMOUNT);
        vm.startPrank(poster);
        IERC20(BASE_SEPOLIA_USDC).approve(address(hub), ESCROW_AMOUNT);
        uint64 deadline = uint64(block.timestamp + 5 days);
        uint256 bountyId = hub.createBounty(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline);
        vm.stopPrank();

        bytes32 rosterHash = hub.guardianRosterHash();
        vm.prank(solver);
        hub.submit(bountyId, SUBMISSION_COMMITMENT, rosterHash, "");
        vm.warp(deadline);
        vm.prank(guardian);
        hub.commitVerdict(
            bountyId, ElgoraHub.Outcome.Awarded, solver, SUBMISSION_COMMITMENT, REPORT_COMMITMENT, ""
        );
        vm.warp(hub.judgingDeadlineAt(bountyId));
        hub.settle(bountyId);
        vm.prank(solver);
        hub.claimAward(bountyId, "");

        assertEq(bountyId, 0);
        assertEq(hub.winner(bountyId), solver);
        assertEq(IERC20(BASE_SEPOLIA_USDC).balanceOf(solver), 190e6);
        assertEq(IERC20(BASE_SEPOLIA_USDC).balanceOf(address(hub)), 10e6);

        vm.prank(treasury);
        (uint256 treasuryAmount,) = hub.claimFees();
        assertEq(treasuryAmount, 3e6);

        vm.prank(guardianFeeRecipient);
        (, uint256 guardianAmount) = hub.claimFees();
        assertEq(guardianAmount, 7e6);

        assertEq(IERC20(BASE_SEPOLIA_USDC).balanceOf(treasury), 3e6);
        assertEq(IERC20(BASE_SEPOLIA_USDC).balanceOf(guardianFeeRecipient), 7e6);
    }

    function testNativeUsdcOneSignatureFundingIsExactSingleUseAndSignerBound() public {
        (address signingPoster, uint256 signingPosterKey) = makeAddrAndKey("signing poster");
        ElgoraHub hub = _deployForkHub();
        deal(BASE_SEPOLIA_USDC, signingPoster, ESCROW_AMOUNT);

        uint64 deadline = uint64(block.timestamp + 5 days);
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("fork authorization");
        ElgoraHub.EscrowAuthorization memory authorization = _escrowAuthorization(
            hub, signingPosterKey, signingPoster, ESCROW_AMOUNT, nonce, validBefore
        );

        // Nobody but the signer can spend it: the entry point takes no `from`, so a relayed
        // signature is checked against the relayer's own address and native USDC rejects it.
        vm.prank(poster);
        vm.expectRevert();
        hub.createBountyWithAuthorization(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline, authorization);

        // Nor can the amount be inflated past what was signed.
        vm.prank(signingPoster);
        vm.expectRevert();
        hub.createBountyWithAuthorization(
            SPEC_COMMITMENT, ESCROW_AMOUNT - 1, deadline, authorization
        );

        // A failed creation leaves the authorization unspent, so the Poster can retry.
        vm.prank(signingPoster);
        vm.expectRevert(ElgoraHub.InvalidDeadline.selector);
        hub.createBountyWithAuthorization(
            SPEC_COMMITMENT, ESCROW_AMOUNT, uint64(block.timestamp + 1), authorization
        );
        assertEq(IERC20(BASE_SEPOLIA_USDC).balanceOf(address(hub)), 0);

        uint256 bountyId =
            _fundWithAuthorization(hub, signingPoster, ESCROW_AMOUNT, deadline, authorization);

        // Exact escrow, no allowance anywhere, and the signer recorded as the Poster.
        assertEq(IERC20(BASE_SEPOLIA_USDC).balanceOf(address(hub)), ESCROW_AMOUNT);
        assertEq(IERC20(BASE_SEPOLIA_USDC).balanceOf(signingPoster), 0);
        assertEq(IERC20(BASE_SEPOLIA_USDC).allowance(signingPoster, address(hub)), 0);
        (ElgoraHub.BountyParameters memory parameters,) = hub.getBounty(bountyId);
        assertEq(parameters.poster, signingPoster);
        assertEq(parameters.escrowAmount, ESCROW_AMOUNT);

        // Native USDC's own nonce store makes the signature single-use.
        deal(BASE_SEPOLIA_USDC, signingPoster, ESCROW_AMOUNT);
        vm.prank(signingPoster);
        vm.expectRevert();
        hub.createBountyWithAuthorization(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline, authorization);

        // A second, freshly nonced authorization funds a second bounty, so nothing about the
        // first spend blocks an intentional repeat.
        ElgoraHub.EscrowAuthorization memory second = _escrowAuthorization(
            hub, signingPosterKey, signingPoster, ESCROW_AMOUNT, keccak256("second"), validBefore
        );
        uint256 secondBountyId =
            _fundWithAuthorization(hub, signingPoster, ESCROW_AMOUNT, deadline, second);
        assertEq(secondBountyId, bountyId + 1);

        // An expired authorization is refused rather than accepted late.
        deal(BASE_SEPOLIA_USDC, signingPoster, ESCROW_AMOUNT);
        ElgoraHub.EscrowAuthorization memory expired = _escrowAuthorization(
            hub,
            signingPosterKey,
            signingPoster,
            ESCROW_AMOUNT,
            keccak256("expired"),
            block.timestamp
        );
        vm.prank(signingPoster);
        vm.expectRevert();
        hub.createBountyWithAuthorization(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline, expired);
    }

    function _deployForkHub() private returns (ElgoraHub) {
        PassThroughSubmissionGuard guard = new PassThroughSubmissionGuard();
        WinnerTakesAllPayoutScheme scheme = new WinnerTakesAllPayoutScheme();
        ElgoraHub.Guardian[] memory roster = new ElgoraHub.Guardian[](1);
        roster[0] = ElgoraHub.Guardian({
            name: "Fork Guardian", account: guardian, encryptionPublicKey: "fork-guardian-key"
        });
        return new ElgoraHub(
            IERC20(BASE_SEPOLIA_USDC),
            protocolOwner,
            ElgoraHub.InitialConfig({
                guardianRosterAdmin: guardianRosterAdmin,
                guardianReviewWindow: 6 hours,
                treasuryRecipient: treasury,
                guardianFeeRecipient: guardianFeeRecipient,
                treasuryFeeBps: 150,
                guardianFeeBps: 350,
                minimumEscrowAmount: 1e6,
                maximumEscrowAmount: 250e6,
                minBountyDuration: 5 days,
                maxBountyDuration: 180 days,
                submissionGuard: address(guard),
                payoutScheme: address(scheme),
                coordinator: address(0),
                coordinatorGracePeriod: 1 hours
            }),
            roster
        );
    }

    function _fundWithAuthorization(
        ElgoraHub hub,
        address signingPoster,
        uint256 escrowAmount,
        uint64 deadline,
        ElgoraHub.EscrowAuthorization memory authorization
    ) private returns (uint256) {
        vm.prank(signingPoster);
        return
            hub.createBountyWithAuthorization(
                SPEC_COMMITMENT, escrowAmount, deadline, authorization
            );
    }

    function _escrowAuthorization(
        ElgoraHub hub,
        uint256 signerKey,
        address signer,
        uint256 value,
        bytes32 nonce,
        uint256 validBefore
    ) private view returns (ElgoraHub.EscrowAuthorization memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                ),
                signer,
                address(hub),
                value,
                uint256(0),
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _usdcDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return ElgoraHub.EscrowAuthorization({
            validAfter: 0, validBefore: validBefore, nonce: nonce, v: v, r: r, s: s
        });
    }
}
