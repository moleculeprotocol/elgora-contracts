// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ElgoraHub} from "../src/ElgoraHub.sol";
import {PassThroughSubmissionGuard} from "../src/PassThroughSubmissionGuard.sol";
import {WinnerTakesAllPayoutScheme} from "../src/WinnerTakesAllPayoutScheme.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract ElgoraHubInvariantTest is Test {
    MockUSDC private usdc;
    ElgoraHub private hub;
    ElgoraHubHandler private handler;

    function setUp() public {
        vm.warp(10_000);
        usdc = new MockUSDC();
        address guardianRosterAdmin = address(0xBEEF);
        address treasury = address(0xFEE1);
        address guardianFeeRecipient = address(0xFEE2);
        PassThroughSubmissionGuard guard = new PassThroughSubmissionGuard();
        WinnerTakesAllPayoutScheme scheme = new WinnerTakesAllPayoutScheme();

        ElgoraHub.Guardian[] memory roster = new ElgoraHub.Guardian[](1);
        roster[0] = ElgoraHub.Guardian({
            name: "Invariant Guardian",
            account: address(0xA11CE),
            encryptionPublicKey: "invariant-key"
        });
        hub = new ElgoraHub(
            IERC20(address(usdc)),
            address(0xCAFE),
            ElgoraHub.InitialConfig({
                guardianRosterAdmin: guardianRosterAdmin,
                guardianReviewWindow: 2 days,
                treasuryRecipient: treasury,
                guardianFeeRecipient: guardianFeeRecipient,
                treasuryFeeBps: 150,
                guardianFeeBps: 350,
                minimumEscrowAmount: 1,
                maximumEscrowAmount: 1_000_000e6,
                minBountyDuration: 1,
                maxBountyDuration: 180 days,
                submissionGuard: address(guard),
                payoutScheme: address(scheme),
                coordinator: address(0),
                coordinatorGracePeriod: 0
            }),
            roster
        );
        handler = new ElgoraHubHandler(usdc, hub, treasury, guardianFeeRecipient);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.submit.selector;
        selectors[3] = handler.settleAwarded.selector;
        selectors[4] = handler.settleNoValidSubmission.selector;
        selectors[5] = handler.timeoutSettlement.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.claimMany.selector;
        selectors[8] = handler.claimFees.selector;
        selectors[9] = handler.claimAward.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_escrowConservation() public view {
        _assertAccountingModel();
    }

    function invariant_donationsRemainSurplus() public view {
        assertGe(
            usdc.balanceOf(address(hub)),
            handler.totalDonated(),
            "claims consumed unsolicited donations"
        );
    }

    function invariant_openBountiesHaveNoClaimableBalances() public view {
        uint256 count = hub.bountyCount();
        uint256 recipientCount = handler.recipientCount();
        for (uint256 bountyId = 0; bountyId < count; bountyId++) {
            if (hub.status(bountyId) != ElgoraHub.Status.Open) continue;
            for (uint256 recipientIndex = 0; recipientIndex < recipientCount; recipientIndex++) {
                assertEq(
                    hub.claimable(bountyId, handler.recipientAt(recipientIndex)),
                    0,
                    "open bounty has claimable"
                );
            }
        }
    }

    function testHandlerReachesEveryAccountingTransition() public {
        handler.donate(1e6);

        handler.create(500e6, 7 days);
        handler.submit(0, 2);
        handler.settleAwarded(0, 2);
        handler.claimAward(0, 3);
        handler.claimFees(true);
        handler.claimFees(false);

        handler.create(500e6, 7 days);
        handler.settleNoValidSubmission(1);
        handler.claim(1, 0);

        handler.create(500e6, 7 days);
        handler.timeoutSettlement(2);
        handler.claimMany(0);

        assertEq(handler.successfulCreates(), 3);
        assertEq(handler.successfulDonations(), 1);
        assertEq(handler.successfulSubmissions(), 1);
        assertEq(handler.successfulAwardedSettlements(), 1);
        assertEq(handler.successfulNoValidSettlements(), 1);
        assertEq(handler.successfulTimeouts(), 1);
        assertEq(handler.successfulAwardClaims(), 1);
        assertEq(handler.successfulClaims(), 1);
        assertEq(handler.successfulClaimManyCalls(), 1);
        assertEq(handler.successfulFeeClaims(), 2);
        _assertAccountingModel();
    }

    function _assertAccountingModel() private view {
        assertFalse(
            handler.modelViolation(), "handler observed an unexpected successful transition"
        );
        assertEq(
            usdc.balanceOf(address(hub)) + handler.totalExpectedWithdrawn(),
            handler.totalEscrowed() + handler.totalDonated(),
            "hub balance plus modeled withdrawals must equal escrowed plus donated"
        );
        assertEq(
            usdc.balanceOf(address(hub)),
            handler.totalDonated() + handler.openEscrow() + handler.primaryClaimable()
                + handler.unclaimedWinnerPool() + handler.expectedTreasuryFeeClaimable()
                + handler.expectedGuardianFeeClaimable(),
            "hub balance must equal donations plus modeled liabilities"
        );
        assertEq(
            hub.treasuryFeeClaimable(),
            handler.expectedTreasuryFeeClaimable(),
            "treasury fee model mismatch"
        );
        assertEq(
            hub.guardianFeeClaimable(),
            handler.expectedGuardianFeeClaimable(),
            "guardian fee model mismatch"
        );

        uint256 count = hub.bountyCount();
        assertEq(count, handler.successfulCreates(), "bounty count model mismatch");
        uint256 recipientCount = handler.recipientCount();
        for (uint256 bountyId = 0; bountyId < count; bountyId++) {
            assertEq(
                uint8(hub.status(bountyId)),
                uint8(handler.expectedStatus(bountyId)),
                "bounty status model mismatch"
            );
            for (uint256 recipientIndex = 0; recipientIndex < recipientCount; recipientIndex++) {
                address recipient = handler.recipientAt(recipientIndex);
                assertEq(
                    hub.claimable(bountyId, recipient),
                    handler.expectedClaimable(bountyId, recipient),
                    "per-bounty claim model mismatch"
                );
            }
        }
    }
}

contract ElgoraHubHandler {
    uint16 private constant BPS_DENOMINATOR = 10_000;
    uint16 private constant TREASURY_FEE_BPS = 150;
    uint16 private constant GUARDIAN_FEE_BPS = 350;
    bytes32 private constant SPEC_COMMITMENT = keccak256("spec");
    bytes32 private constant SUBMISSION_A = keccak256("submission a");
    bytes32 private constant SUBMISSION_B = keccak256("submission b");
    bytes32 private constant REPORT_COMMITMENT = keccak256("report");
    // The invariant roster's sole Guardian; happens to equal `poster` below, a coincidence of
    // this fixture's minimal addressing, not a meaningful overlap.
    address private constant GUARDIAN = address(0xA11CE);
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockUSDC private immutable USDC;
    ElgoraHub private immutable HUB;

    address private poster = address(0xA11CE);
    address private solverA = address(0xA0A);
    address private solverB = address(0xB0B);
    address private immutable TREASURY;
    address private immutable GUARDIAN_FEE_RECIPIENT;
    address[5] private recipients;

    uint256 public totalEscrowed;
    uint256 public totalDonated;
    uint256 public totalExpectedWithdrawn;
    uint256 public openEscrow;
    uint256 public primaryClaimable;
    uint256 public unclaimedWinnerPool;
    uint256 public expectedTreasuryFeeClaimable;
    uint256 public expectedGuardianFeeClaimable;
    uint256 public successfulCreates;
    uint256 public successfulDonations;
    uint256 public successfulSubmissions;
    uint256 public successfulAwardedSettlements;
    uint256 public successfulNoValidSettlements;
    uint256 public successfulTimeouts;
    uint256 public successfulClaims;
    uint256 public successfulClaimManyCalls;
    uint256 public successfulAwardClaims;
    uint256 public successfulFeeClaims;
    bool public modelViolation;

    mapping(uint256 bountyId => uint256 amount) private escrowAmounts;
    mapping(uint256 bountyId => ElgoraHub.Status status_) private expectedStatuses;
    mapping(uint256 bountyId => mapping(address recipient => uint256 amount)) private
        expectedClaimables;
    mapping(uint256 bountyId => mapping(address solver => bytes32 commitment)) private
        expectedActiveCommitments;
    mapping(uint256 bountyId => uint256 amount) private expectedWinnerPool;
    mapping(uint256 bountyId => bool) private hasSubmission;

    constructor(MockUSDC usdc_, ElgoraHub hub_, address treasury_, address guardianFeeRecipient_) {
        USDC = usdc_;
        HUB = hub_;
        TREASURY = treasury_;
        GUARDIAN_FEE_RECIPIENT = guardianFeeRecipient_;
        recipients = [poster, solverA, solverB, treasury_, guardianFeeRecipient_];
    }

    function create(uint256 amountSeed, uint256 deadlineSeed) external {
        uint256 amount = _bound(amountSeed, 1, 1_000_000e6);
        uint64 deadline = uint64(block.timestamp + _bound(deadlineSeed, 1, 30 days));

        USDC.mint(poster, amount);
        VM.startPrank(poster);
        USDC.approve(address(HUB), amount);
        try HUB.createBounty(SPEC_COMMITMENT, amount, deadline) returns (uint256 bountyId) {
            if (bountyId != successfulCreates) modelViolation = true;
            successfulCreates++;
            totalEscrowed += amount;
            openEscrow += amount;
            escrowAmounts[bountyId] = amount;
            expectedStatuses[bountyId] = ElgoraHub.Status.Open;
        } catch {}
        VM.stopPrank();
    }

    function donate(uint256 amountSeed) external {
        uint256 amount = _bound(amountSeed, 1, 1_000e6);
        USDC.mint(address(this), amount);
        require(USDC.transfer(address(HUB), amount), "donation transfer failed");
        totalDonated += amount;
        successfulDonations++;
    }

    function submit(uint256 bountySeed, uint256 solverSeed) external {
        uint256 count = HUB.bountyCount();
        if (count == 0) return;
        uint256 bountyId = _bound(bountySeed, 0, count - 1);
        address solver = _solver(solverSeed);
        bytes32 commitment = solver == solverA ? SUBMISSION_A : SUBMISSION_B;
        (ElgoraHub.BountyParameters memory parameters,) = HUB.getBounty(bountyId);

        VM.prank(solver);
        try HUB.submit(bountyId, commitment, parameters.guardianRosterHash, "") {
            hasSubmission[bountyId] = true;
            successfulSubmissions++;
            expectedActiveCommitments[bountyId][solver] = commitment;
        } catch {}
    }

    function settleAwarded(uint256 bountySeed, uint256 solverSeed) external {
        uint256 count = HUB.bountyCount();
        if (count == 0) return;
        uint256 bountyId = _bound(bountySeed, 0, count - 1);
        address winner = _solver(solverSeed);
        bytes32 commitment = winner == solverA ? SUBMISSION_A : SUBMISSION_B;
        if (!_warpToSettlementWindow(bountyId)) return;

        VM.prank(GUARDIAN);
        try HUB.commitVerdict(
            bountyId, ElgoraHub.Outcome.Awarded, winner, commitment, REPORT_COMMITMENT, ""
        ) {}
            catch {}
        try HUB.settle(bountyId) {
            successfulAwardedSettlements++;
            _recordAwardedSettlement(bountyId, winner, commitment);
        } catch {}
    }

    function settleNoValidSubmission(uint256 bountySeed) external {
        uint256 count = HUB.bountyCount();
        if (count == 0) return;
        uint256 bountyId = _bound(bountySeed, 0, count - 1);
        if (!_warpToSettlementWindow(bountyId)) return;

        VM.prank(GUARDIAN);
        try HUB.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.NoValidSubmission,
            address(0),
            bytes32(0),
            REPORT_COMMITMENT,
            ""
        ) {}
            catch {}
        try HUB.settle(bountyId) {
            successfulNoValidSettlements++;
            _recordNoValidSettlement(bountyId);
        } catch {}
    }

    function timeoutSettlement(uint256 bountySeed) external {
        uint256 count = HUB.bountyCount();
        if (count == 0) return;
        uint256 bountyId = _bound(bountySeed, 0, count - 1);
        uint256 timeoutAt = HUB.settlementTimeoutAt(bountyId);
        if (block.timestamp < timeoutAt) VM.warp(timeoutAt);
        try HUB.timeoutSettlement(bountyId) {
            successfulTimeouts++;
            _recordTimeout(bountyId);
        } catch {}
    }

    function claim(uint256 bountySeed, uint256 recipientSeed) external {
        uint256 count = HUB.bountyCount();
        if (count == 0) return;
        uint256 bountyId = _bound(bountySeed, 0, count - 1);
        address recipient = recipients[_bound(recipientSeed, 0, recipients.length - 1)];
        uint256 balanceBefore = USDC.balanceOf(recipient);
        uint256 expectedAmount = expectedClaimables[bountyId][recipient];

        VM.prank(recipient);
        try HUB.claim(bountyId) {
            successfulClaims++;
            _recordPrimaryWithdrawal(
                bountyId, recipient, expectedAmount, USDC.balanceOf(recipient) - balanceBefore
            );
        } catch {}
    }

    function claimAward(uint256 bountySeed, uint256 recipientSeed) external {
        uint256 count = HUB.bountyCount();
        if (count == 0) return;
        uint256 bountyId = _bound(bountySeed, 0, count - 1);
        address recipient = recipients[_bound(recipientSeed, 0, recipients.length - 1)];
        address winner = HUB.winner(bountyId);
        uint256 claimedSoFar = HUB.winnerPoolClaimed(bountyId);
        uint256 remaining = expectedWinnerPool[bountyId] > claimedSoFar
            ? expectedWinnerPool[bountyId] - claimedSoFar
            : 0;
        uint256 expectedAmount = (winner != address(0) && recipient == winner) ? remaining : 0;
        uint256 balanceBefore = USDC.balanceOf(recipient);

        VM.prank(recipient);
        try HUB.claimAward(bountyId, "") {
            successfulAwardClaims++;
            uint256 actualAmount = USDC.balanceOf(recipient) - balanceBefore;
            if (expectedAmount == 0 || actualAmount != expectedAmount) modelViolation = true;
            unclaimedWinnerPool -= actualAmount;
            totalExpectedWithdrawn += actualAmount;
        } catch {}
    }

    function claimMany(uint256 recipientSeed) external {
        uint256 count = HUB.bountyCount();
        if (count == 0) return;
        address recipient = recipients[_bound(recipientSeed, 0, recipients.length - 1)];
        uint256[] memory ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = i;
        }
        uint256 balanceBefore = USDC.balanceOf(recipient);
        uint256 expectedAmount;
        for (uint256 i = 0; i < count; i++) {
            expectedAmount += expectedClaimables[i][recipient];
        }

        VM.prank(recipient);
        try HUB.claimMany(ids) {
            successfulClaimManyCalls++;
            uint256 actualAmount = USDC.balanceOf(recipient) - balanceBefore;
            if (expectedAmount == 0 || actualAmount != expectedAmount) modelViolation = true;
            for (uint256 i = 0; i < count; i++) {
                uint256 bountyAmount = expectedClaimables[i][recipient];
                if (bountyAmount == 0) continue;
                expectedClaimables[i][recipient] = 0;
                primaryClaimable -= bountyAmount;
            }
            totalExpectedWithdrawn += expectedAmount;
        } catch {}
    }

    function claimFees(bool claimTreasury) external {
        address recipient = claimTreasury ? TREASURY : GUARDIAN_FEE_RECIPIENT;
        uint256 balanceBefore = USDC.balanceOf(recipient);
        uint256 expectedTreasuryAmount = claimTreasury ? expectedTreasuryFeeClaimable : 0;
        uint256 expectedGuardianAmount = claimTreasury ? 0 : expectedGuardianFeeClaimable;
        uint256 expectedAmount = expectedTreasuryAmount + expectedGuardianAmount;

        VM.prank(recipient);
        try HUB.claimFees() returns (uint256 treasuryAmount, uint256 guardianAmount) {
            successfulFeeClaims++;
            uint256 actualAmount = USDC.balanceOf(recipient) - balanceBefore;
            if (
                expectedAmount == 0 || actualAmount != expectedAmount
                    || treasuryAmount != expectedTreasuryAmount
                    || guardianAmount != expectedGuardianAmount
            ) {
                modelViolation = true;
            }
            if (claimTreasury) {
                expectedTreasuryFeeClaimable = 0;
            } else {
                expectedGuardianFeeClaimable = 0;
            }
            totalExpectedWithdrawn += expectedAmount;
        } catch {}
    }

    function recipientCount() external pure returns (uint256) {
        return 5;
    }

    function recipientAt(uint256 index) external view returns (address) {
        return recipients[index];
    }

    function expectedStatus(uint256 bountyId) external view returns (ElgoraHub.Status) {
        return expectedStatuses[bountyId];
    }

    function expectedClaimable(uint256 bountyId, address recipient)
        external
        view
        returns (uint256)
    {
        return expectedClaimables[bountyId][recipient];
    }

    function _recordAwardedSettlement(uint256 bountyId, address winner, bytes32 commitment)
        private
    {
        if (expectedActiveCommitments[bountyId][winner] != commitment) {
            modelViolation = true;
        }
        if (HUB.status(bountyId) != ElgoraHub.Status.Awarded || HUB.winner(bountyId) != winner) {
            modelViolation = true;
        }
        (uint256 treasuryAmount, uint256 guardianAmount, uint256 winnerPool) =
            _recordFinalization(bountyId, ElgoraHub.Status.Awarded);
        expectedWinnerPool[bountyId] = winnerPool;
        unclaimedWinnerPool += winnerPool;
        expectedTreasuryFeeClaimable += treasuryAmount;
        expectedGuardianFeeClaimable += guardianAmount;
    }

    function _recordNoValidSettlement(uint256 bountyId) private {
        if (
            HUB.status(bountyId) != ElgoraHub.Status.NoValidSubmission
                || HUB.winner(bountyId) != address(0)
        ) {
            modelViolation = true;
        }
        (uint256 treasuryAmount, uint256 guardianAmount, uint256 winnerPool) =
            _recordFinalization(bountyId, ElgoraHub.Status.NoValidSubmission);
        _queuePrimaryClaim(bountyId, poster, winnerPool + treasuryAmount);
        expectedGuardianFeeClaimable += guardianAmount;
    }

    function _recordTimeout(uint256 bountyId) private {
        if (expectedStatuses[bountyId] != ElgoraHub.Status.Open) {
            modelViolation = true;
            return;
        }
        if (HUB.status(bountyId) != ElgoraHub.Status.TimedOut) modelViolation = true;
        uint256 amount = escrowAmounts[bountyId];
        expectedStatuses[bountyId] = ElgoraHub.Status.TimedOut;
        openEscrow -= amount;
        _queuePrimaryClaim(bountyId, poster, amount);
    }

    function _recordFinalization(uint256 bountyId, ElgoraHub.Status finalStatus)
        private
        returns (uint256 treasuryAmount, uint256 guardianAmount, uint256 winnerPool)
    {
        if (expectedStatuses[bountyId] != ElgoraHub.Status.Open) {
            modelViolation = true;
            return (0, 0, 0);
        }
        uint256 amount = escrowAmounts[bountyId];
        expectedStatuses[bountyId] = finalStatus;
        openEscrow -= amount;
        treasuryAmount = (amount * TREASURY_FEE_BPS) / BPS_DENOMINATOR;
        guardianAmount = finalStatus == ElgoraHub.Status.NoValidSubmission && !hasSubmission[bountyId]
            ? 0
            : (amount * GUARDIAN_FEE_BPS) / BPS_DENOMINATOR;
        winnerPool = amount - treasuryAmount - guardianAmount;
    }

    function _queuePrimaryClaim(uint256 bountyId, address recipient, uint256 amount) private {
        expectedClaimables[bountyId][recipient] += amount;
        primaryClaimable += amount;
    }

    function _recordPrimaryWithdrawal(
        uint256 bountyId,
        address recipient,
        uint256 expectedAmount,
        uint256 actualAmount
    ) private {
        if (expectedAmount == 0 || actualAmount != expectedAmount) {
            modelViolation = true;
        }
        if (expectedAmount > primaryClaimable) {
            modelViolation = true;
            return;
        }
        expectedClaimables[bountyId][recipient] = 0;
        primaryClaimable -= expectedAmount;
        totalExpectedWithdrawn += expectedAmount;
    }

    function _solver(uint256 seed) private view returns (address) {
        uint256 which = seed % 4;
        if (which == 0) return solverA;
        if (which == 1) return solverB;
        if (which == 2) return TREASURY;
        return GUARDIAN_FEE_RECIPIENT;
    }

    function _bound(uint256 value, uint256 min, uint256 max) private pure returns (uint256) {
        if (max <= min) return min;
        return min + (value % (max - min + 1));
    }

    function _warpToSettlementWindow(uint256 bountyId) private returns (bool) {
        (ElgoraHub.BountyParameters memory parameters,) = HUB.getBounty(bountyId);
        if (block.timestamp >= parameters.settlementTimeoutAt) return false;
        if (block.timestamp < parameters.judgingDeadlineAt) {
            VM.warp(parameters.judgingDeadlineAt);
        }
        return true;
    }
}
