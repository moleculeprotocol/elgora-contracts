// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {ElgoraHub} from "../src/ElgoraHub.sol";
import {IPayoutScheme} from "../src/IPayoutScheme.sol";
import {ISubmissionGuard} from "../src/ISubmissionGuard.sol";
import {PassThroughSubmissionGuard} from "../src/PassThroughSubmissionGuard.sol";
import {WinnerTakesAllPayoutScheme} from "../src/WinnerTakesAllPayoutScheme.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {ReentrantUSDC} from "./ReentrantUSDC.sol";

contract ConfigurableSubmissionGuard is ISubmissionGuard {
    bool public allowed = true;
    bytes32 public requiredRosterHash;
    bytes32 public requiredExtraDataHash;
    uint256 public maximumPriorCount = type(uint256).max;

    function configure(
        bool allowed_,
        bytes32 requiredRosterHash_,
        bytes32 requiredExtraDataHash_,
        uint256 maximumPriorCount_
    ) external {
        allowed = allowed_;
        requiredRosterHash = requiredRosterHash_;
        requiredExtraDataHash = requiredExtraDataHash_;
        maximumPriorCount = maximumPriorCount_;
    }

    function canSubmit(
        address,
        SubmissionContext calldata context,
        uint256 submissionCount,
        bytes calldata extraData
    ) external view returns (bool) {
        return allowed && context.guardianRosterHash == requiredRosterHash
            && keccak256(extraData) == requiredExtraDataHash && submissionCount <= maximumPriorCount;
    }
}

contract ConfigurablePayoutScheme is IPayoutScheme {
    bool public overpay;

    function configure(bool overpay_) external {
        overpay = overpay_;
    }

    function claimAmount(
        uint256,
        address winner,
        uint256 winnerPool,
        bytes calldata,
        address claimant,
        bytes calldata
    ) external view returns (uint256 amount) {
        if (claimant != winner) return 0;
        return overpay ? winnerPool + 1 : winnerPool;
    }
}

contract EighteenDecimalToken is ERC20 {
    constructor() ERC20("Wrong decimals", "WRONG") {}
}

contract ElgoraHubTest is Test {
    bytes32 private constant SPEC_COMMITMENT = keccak256("spec");
    bytes32 private constant SUBMISSION_A = keccak256("submission a");
    bytes32 private constant SUBMISSION_B = keccak256("submission b");
    uint256 private constant ESCROW_AMOUNT = 500e6;
    uint256 private constant TREASURY_FEE = 7_500_000;
    uint256 private constant GUARDIAN_FEE = 17_500_000;
    uint256 private constant WINNER_POOL = 475e6;
    uint64 private constant REVIEW_WINDOW = 6 hours;
    uint64 private constant MIN_BOUNTY_DURATION = 5 days;
    uint64 private constant MAX_BOUNTY_DURATION = 180 days;
    uint16 private constant TREASURY_FEE_BPS = 150;
    uint16 private constant GUARDIAN_FEE_BPS = 350;
    uint64 private constant COORDINATOR_GRACE_PERIOD = 1 hours;
    // Leaves time for a permissionless fallback before settlementTimeoutAt.
    uint64 private constant GATED_COORDINATOR_GRACE_PERIOD = 2 hours;

    MockUSDC private usdc;
    PassThroughSubmissionGuard private passThroughGuard;
    WinnerTakesAllPayoutScheme private winnerTakesAll;
    ElgoraHub private hub;

    address private protocolOwner = makeAddr("protocol owner");
    address private poster = makeAddr("poster");
    address private guardianRosterAdmin = makeAddr("guardian roster admin");
    address private guardianA = makeAddr("guardian a");
    address private guardianB = makeAddr("guardian b");
    address private guardianC = makeAddr("guardian c");
    address private guardianD = makeAddr("guardian d");
    address private guardianE = makeAddr("guardian e");
    address private treasury = makeAddr("treasury");
    address private guardianFeeRecipient = makeAddr("guardian fee recipient");
    address private solverA = makeAddr("solver a");
    address private solverB = makeAddr("solver b");
    address private collaborator = makeAddr("collaborator");

    function setUp() public {
        vm.warp(1_000);
        usdc = new MockUSDC();
        passThroughGuard = new PassThroughSubmissionGuard();
        winnerTakesAll = new WinnerTakesAllPayoutScheme();
        hub = _deployHub(IERC20(address(usdc)), address(passThroughGuard), address(winnerTakesAll));
        usdc.mint(poster, 1_000_000e6);
    }

    function testConstructorRequiresSixDecimalTokenAndValidContracts() public {
        EighteenDecimalToken wrongToken = new EighteenDecimalToken();
        vm.expectRevert(abi.encodeWithSelector(ElgoraHub.InvalidTokenDecimals.selector, 18));
        _deployHub(IERC20(address(wrongToken)), address(passThroughGuard), address(winnerTakesAll));

        vm.expectRevert(ElgoraHub.InvalidContract.selector);
        _deployHub(IERC20(address(usdc)), address(0), address(winnerTakesAll));

        vm.expectRevert(ElgoraHub.InvalidContract.selector);
        _deployHub(IERC20(address(usdc)), address(passThroughGuard), address(0));
    }

    function testGuardianRosterIsReturnedAndHashIsComputedOnChain() public view {
        ElgoraHub.Guardian[] memory roster = hub.getGuardianRoster();
        assertEq(roster.length, 3);
        assertEq(roster[0].name, "Guardian A");
        assertEq(roster[0].account, guardianA);
        assertEq(roster[0].encryptionPublicKey, "guardian-a-key");
        assertEq(roster[1].account, guardianB);
        assertEq(roster[2].account, guardianC);
        assertEq(hub.guardianRosterHash(), keccak256(abi.encode(roster)));
        assertEq(hub.getGuardianRosterAtHash(hub.guardianRosterHash()).length, 3);
        assertEq(hub.getGuardianRosterAtHash(hub.guardianRosterHash())[0], guardianA);
    }

    function testOnlyGuardianRosterAdminCanManageRosterNotOwner() public {
        bytes32 originalHash = hub.guardianRosterHash();

        vm.prank(protocolOwner);
        vm.expectRevert(ElgoraHub.NotGuardianRosterAdmin.selector);
        hub.addGuardian("Guardian D", guardianD, "guardian-d-key");

        vm.prank(guardianRosterAdmin);
        hub.addGuardian("Guardian D", guardianD, "guardian-d-key");
        assertNotEq(hub.guardianRosterHash(), originalHash);
        assertEq(hub.getGuardianRoster().length, 4);

        vm.prank(protocolOwner);
        vm.expectRevert(ElgoraHub.NotGuardianRosterAdmin.selector);
        hub.removeGuardian(guardianD);

        vm.prank(guardianRosterAdmin);
        hub.removeGuardian(guardianD);
        ElgoraHub.Guardian[] memory roster = hub.getGuardianRoster();
        assertEq(roster.length, 3);
        assertEq(hub.guardianRosterHash(), keccak256(abi.encode(roster)));

        // Adding then removing the same Guardian returns the roster to a byte-identical
        // earlier state; the hash (and its snapshot) must round-trip, not accumulate.
        assertEq(hub.guardianRosterHash(), originalHash);
        assertEq(hub.getGuardianRosterAtHash(originalHash).length, 3);
        assertEq(hub.getGuardianRosterAtHash(originalHash)[0], guardianA);
        assertEq(hub.getGuardianRosterAtHash(originalHash)[2], guardianC);

        vm.prank(poster);
        vm.expectRevert(ElgoraHub.NotGuardianRosterAdmin.selector);
        hub.addGuardian("unauthorized", poster, "key");
    }

    function testRosterValidationRejectsDuplicatesInvalidEntriesAndEmptyRoster() public {
        vm.startPrank(guardianRosterAdmin);
        vm.expectRevert(ElgoraHub.GuardianAlreadyExists.selector);
        hub.addGuardian("duplicate", guardianA, "new-key");
        vm.expectRevert(ElgoraHub.InvalidGuardian.selector);
        hub.addGuardian("", guardianD, "key");

        hub.removeGuardian(guardianB);
        hub.removeGuardian(guardianC);
        vm.expectRevert(ElgoraHub.InvalidGuardian.selector);
        hub.removeGuardian(guardianA);
        vm.stopPrank();
    }

    function testReplaceGuardianSwapsInPlaceInOneTransaction() public {
        bytes32 originalHash = hub.guardianRosterHash();
        uint256 priorBountyId = _createDefaultBounty();
        (ElgoraHub.BountyParameters memory priorParameters,) = hub.getBounty(priorBountyId);
        assertEq(priorParameters.guardianRosterHash, originalHash);

        vm.prank(protocolOwner);
        vm.expectRevert(ElgoraHub.NotGuardianRosterAdmin.selector);
        hub.replaceGuardian(guardianC, "Guardian D", guardianD, "guardian-d-key");

        vm.prank(guardianRosterAdmin);
        hub.replaceGuardian(guardianC, "Guardian D", guardianD, "guardian-d-key");

        assertNotEq(hub.guardianRosterHash(), originalHash);

        ElgoraHub.Guardian[] memory roster = hub.getGuardianRoster();
        assertEq(roster.length, 3);
        assertEq(roster[0].account, guardianA);
        assertEq(roster[1].account, guardianB);
        assertEq(roster[2].account, guardianD);
        assertEq(roster[2].name, "Guardian D");
        assertEq(roster[2].encryptionPublicKey, "guardian-d-key");
        assertEq(hub.guardianRosterHash(), keccak256(abi.encode(roster)));

        uint256 newBountyId = _createDefaultBounty();
        (ElgoraHub.BountyParameters memory newParameters,) = hub.getBounty(newBountyId);
        assertEq(newParameters.guardianRosterHash, hub.guardianRosterHash());
        assertNotEq(newParameters.guardianRosterHash, originalHash);

        // The bounty pinned before the swap still answers to the old member, not the new one.
        vm.prank(guardianC);
        hub.commitVerdict(
            priorBountyId,
            ElgoraHub.Outcome.NoValidSubmission,
            address(0),
            bytes32(0),
            _reportCommitment(guardianC),
            ""
        );
        vm.prank(guardianD);
        vm.expectRevert(ElgoraHub.NotRosterGuardian.selector);
        hub.commitVerdict(
            priorBountyId,
            ElgoraHub.Outcome.NoValidSubmission,
            address(0),
            bytes32(0),
            _reportCommitment(guardianD),
            ""
        );

        // A bounty created after the swap answers to the new member, not the old one.
        vm.prank(guardianD);
        hub.commitVerdict(
            newBountyId,
            ElgoraHub.Outcome.NoValidSubmission,
            address(0),
            bytes32(0),
            _reportCommitment(guardianD),
            ""
        );
        vm.prank(guardianC);
        vm.expectRevert(ElgoraHub.NotRosterGuardian.selector);
        hub.commitVerdict(
            newBountyId,
            ElgoraHub.Outcome.NoValidSubmission,
            address(0),
            bytes32(0),
            _reportCommitment(guardianC),
            ""
        );
    }

    /// The roster event is the only place the hash's preimage reaches the log stream, so prove
    /// every mutation path emits an array that hashes back to the digest it is indexed under.
    function testGuardianRosterHashEventCarriesItsOwnPreimage() public {
        bytes32 rosterEventTopic =
            keccak256("GuardianRosterHashUpdated(bytes32,(string,address,string)[])");

        vm.recordLogs();
        vm.startPrank(guardianRosterAdmin);
        hub.addGuardian("Guardian D", guardianD, "guardian-d-key");
        hub.removeGuardian(guardianB);
        // replaceGuardian writes in place. Its old GuardianRemoved-then-GuardianAdded log pair
        // was byte-identical to a remove-then-add that appends at the end instead, so an indexer
        // could not reproduce the array the contract hashed. The array below can.
        hub.replaceGuardian(guardianC, "Guardian E", guardianE, "guardian-e-key");
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 rosterEvents = 0;
        ElgoraHub.Guardian[] memory lastRoster;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != rosterEventTopic) continue;
            rosterEvents++;
            lastRoster = abi.decode(logs[i].data, (ElgoraHub.Guardian[]));
            // The log data is the preimage itself; an indexer needs no decoding to check it.
            assertEq(keccak256(logs[i].data), logs[i].topics[1]);
            assertEq(keccak256(abi.encode(lastRoster)), logs[i].topics[1]);
        }
        assertEq(rosterEvents, 3);

        // The last event's array is the live roster itself, in position order: the replacement
        // sits at the replaced Guardian's index, not appended after it.
        assertEq(lastRoster.length, 3);
        assertEq(lastRoster[0].account, guardianA);
        assertEq(lastRoster[1].account, guardianE);
        assertEq(lastRoster[1].name, "Guardian E");
        assertEq(lastRoster[1].encryptionPublicKey, "guardian-e-key");
        assertEq(lastRoster[2].account, guardianD);
        assertEq(hub.guardianRosterHash(), keccak256(abi.encode(lastRoster)));
    }

    function testReplaceGuardianSameAddressKeepsEarlierBountyPinnedAndValidatesInput() public {
        bytes32 originalHash = hub.guardianRosterHash();
        uint256 earlierBountyId = _createDefaultBounty();

        vm.startPrank(guardianRosterAdmin);

        // Same account and name: rotating only the encryption key changes the roster snapshot.
        hub.replaceGuardian(guardianA, "Guardian A", guardianA, "guardian-a-key-2");
        bytes32 rotatedHash = hub.guardianRosterHash();
        assertNotEq(rotatedHash, originalHash);
        ElgoraHub.Guardian[] memory roster = hub.getGuardianRoster();
        assertEq(roster[0].account, guardianA);
        assertEq(roster[0].name, "Guardian A");
        assertEq(roster[0].encryptionPublicKey, "guardian-a-key-2");

        vm.expectRevert(ElgoraHub.GuardianNotFound.selector);
        hub.replaceGuardian(guardianD, "Guardian D", guardianD, "guardian-d-key");

        vm.expectRevert(ElgoraHub.InvalidGuardian.selector);
        hub.replaceGuardian(guardianB, "", guardianD, "guardian-d-key");

        vm.expectRevert(ElgoraHub.InvalidGuardian.selector);
        hub.replaceGuardian(guardianB, "Guardian D", address(0), "guardian-d-key");

        vm.expectRevert(ElgoraHub.GuardianAlreadyExists.selector);
        hub.replaceGuardian(guardianB, "duplicate", guardianC, "guardian-c-key");

        vm.stopPrank();

        (ElgoraHub.BountyParameters memory earlierParameters,) = hub.getBounty(earlierBountyId);
        assertEq(earlierParameters.guardianRosterHash, originalHash);
        assertTrue(hub.isGuardianAtRosterHash(originalHash, guardianA));

        uint256 laterBountyId = _createDefaultBounty();
        (ElgoraHub.BountyParameters memory laterParameters,) = hub.getBounty(laterBountyId);
        assertEq(laterParameters.guardianRosterHash, rotatedHash);

        _submit(earlierBountyId, solverA, SUBMISSION_A, originalHash, "");
        _submit(laterBountyId, solverA, SUBMISSION_A, rotatedHash, "");

        vm.prank(solverB);
        vm.expectRevert(ElgoraHub.StaleGuardianRoster.selector);
        hub.submit(earlierBountyId, SUBMISSION_B, rotatedHash, "");
    }

    function testOneSignatureFundingCreatesTheBountyOrLeavesTheAuthorizationUnspent() public {
        (address signingPoster, uint256 signingPosterKey) = makeAddrAndKey("signing poster");
        usdc.mint(signingPoster, 10_000e6);
        uint64 deadline = _deadline();
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("authorization one");
        ElgoraHub.EscrowAuthorization memory authorization = _escrowAuthorization(
            signingPosterKey, signingPoster, ESCROW_AMOUNT, nonce, validBefore
        );

        // A creation that fails its own checks must not spend the authorization: everything the
        // token wrote rolls back with the revert, so the Poster can simply retry.
        vm.prank(signingPoster);
        vm.expectRevert(ElgoraHub.InvalidDeadline.selector);
        hub.createBountyWithAuthorization(
            SPEC_COMMITMENT, ESCROW_AMOUNT, uint64(block.timestamp + 1), authorization
        );
        assertFalse(usdc.authorizationState(signingPoster, nonce));
        assertEq(usdc.balanceOf(address(hub)), 0);

        uint256 posterBalanceBefore = usdc.balanceOf(signingPoster);
        vm.prank(signingPoster);
        uint256 bountyId = hub.createBountyWithAuthorization(
            SPEC_COMMITMENT, ESCROW_AMOUNT, deadline, authorization
        );

        // Funded in one transaction, with no allowance granted and none left standing after.
        assertEq(usdc.allowance(signingPoster, address(hub)), 0);
        assertEq(usdc.balanceOf(address(hub)), ESCROW_AMOUNT);
        assertEq(posterBalanceBefore - usdc.balanceOf(signingPoster), ESCROW_AMOUNT);
        (ElgoraHub.BountyParameters memory parameters,) = hub.getBounty(bountyId);
        assertEq(parameters.poster, signingPoster);
        assertEq(parameters.escrowAmount, ESCROW_AMOUNT);

        // The nonce is spent, so the same signature cannot fund a second bounty.
        assertTrue(usdc.authorizationState(signingPoster, nonce));
        vm.prank(signingPoster);
        vm.expectRevert(MockUSDC.InvalidAuthorization.selector);
        hub.createBountyWithAuthorization(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline, authorization);
    }

    function testOneSignatureFundingIsUsableOnlyByItsOwnSigner() public {
        (address signingPoster, uint256 signingPosterKey) = makeAddrAndKey("signing poster");
        usdc.mint(signingPoster, 10_000e6);
        usdc.mint(poster, 10_000e6);
        uint64 deadline = _deadline();
        uint256 validBefore = block.timestamp + 1 hours;

        ElgoraHub.EscrowAuthorization memory authorization = _escrowAuthorization(
            signingPosterKey, signingPoster, ESCROW_AMOUNT, keccak256("nonce"), validBefore
        );

        // The entry point takes no `from`: the authorizer is always msg.sender. Another wallet
        // relaying this signature is signing for itself and the token rejects it, which is what
        // removes front-running and any question of who the Poster is.
        vm.prank(poster);
        vm.expectRevert(MockUSDC.InvalidAuthorization.selector);
        hub.createBountyWithAuthorization(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline, authorization);

        // An amount other than the one signed for recovers a different signer, so the escrow
        // cannot be inflated past what the Poster approved.
        vm.prank(signingPoster);
        vm.expectRevert(MockUSDC.InvalidAuthorization.selector);
        hub.createBountyWithAuthorization(
            SPEC_COMMITMENT, ESCROW_AMOUNT + 1, deadline, authorization
        );

        // An expired authorization is refused by the token, not silently accepted late.
        ElgoraHub.EscrowAuthorization memory expired = _escrowAuthorization(
            signingPosterKey, signingPoster, ESCROW_AMOUNT, keccak256("expired"), block.timestamp
        );
        vm.prank(signingPoster);
        vm.expectRevert(MockUSDC.InvalidAuthorization.selector);
        hub.createBountyWithAuthorization(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline, expired);

        assertEq(hub.bountyCount(), 0);
        assertEq(usdc.balanceOf(address(hub)), 0);
    }

    function testOneSignatureFundingHonoursPauseAndExactEscrow() public {
        (address signingPoster, uint256 signingPosterKey) = makeAddrAndKey("signing poster");
        usdc.mint(signingPoster, 10_000e6);
        uint64 deadline = _deadline();
        bytes32 nonce = keccak256("nonce");
        ElgoraHub.EscrowAuthorization memory authorization = _escrowAuthorization(
            signingPosterKey, signingPoster, ESCROW_AMOUNT, nonce, block.timestamp + 1 hours
        );

        // Paused: refused before the token is touched, so the authorization stays unspent.
        vm.prank(protocolOwner);
        hub.pause();
        vm.prank(signingPoster);
        vm.expectRevert(ElgoraHub.ContractPaused.selector);
        hub.createBountyWithAuthorization(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline, authorization);
        assertFalse(usdc.authorizationState(signingPoster, nonce));
        vm.prank(protocolOwner);
        hub.unpause();

        // A token that delivers less than authorized fails the same exact-delta check as
        // createBounty, and the revert leaves the authorization unspent for a retry.
        usdc.setTransferFeeBps(100);
        vm.prank(signingPoster);
        vm.expectRevert(ElgoraHub.TransferFromFailed.selector);
        hub.createBountyWithAuthorization(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline, authorization);
        assertFalse(usdc.authorizationState(signingPoster, nonce));
        assertEq(usdc.balanceOf(address(hub)), 0);

        usdc.setTransferFeeBps(0);
        vm.prank(signingPoster);
        hub.createBountyWithAuthorization(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline, authorization);
        assertTrue(usdc.authorizationState(signingPoster, nonce));
    }

    function testCreateBountyStoresParametersAndSeparateMutableState() public {
        uint64 deadline = _deadline();
        uint256 bountyId = _createBounty(deadline);
        (ElgoraHub.BountyParameters memory parameters, ElgoraHub.BountyState memory state) =
            hub.getBounty(bountyId);

        assertEq(parameters.poster, poster);
        assertEq(parameters.specCommitment, SPEC_COMMITMENT);
        assertEq(parameters.escrowAmount, ESCROW_AMOUNT);
        assertEq(parameters.submissionDeadline, deadline);
        assertEq(parameters.judgingDeadlineAt, deadline + REVIEW_WINDOW / 2);
        assertEq(parameters.settlementTimeoutAt, deadline + REVIEW_WINDOW);
        assertEq(parameters.guardianRosterHash, hub.guardianRosterHash());
        assertEq(parameters.payoutScheme, address(winnerTakesAll));
        assertEq(parameters.treasuryFeeBps, TREASURY_FEE_BPS);
        assertEq(parameters.guardianFeeBps, GUARDIAN_FEE_BPS);
        assertEq(uint8(state.status), uint8(ElgoraHub.Status.Open));
        assertEq(state.winner, address(0));
        assertEq(state.submissionCount, 0);
        assertEq(usdc.balanceOf(address(hub)), ESCROW_AMOUNT);
        assertEq(hub.guardianThreshold(bountyId), 2);
        assertEq(hub.judgingDeadlineAt(bountyId), deadline + REVIEW_WINDOW / 2);
    }

    function testEscrowAndDeadlineBoundsAreInclusiveAndCheckedBeforeFunding() public {
        vm.startPrank(poster);
        usdc.approve(address(hub), type(uint256).max);
        uint256 balanceBefore = usdc.balanceOf(poster);

        vm.expectRevert(ElgoraHub.InvalidEscrowAmount.selector);
        hub.createBounty(SPEC_COMMITMENT, 1e6 - 1, _deadline());
        vm.expectRevert(ElgoraHub.InvalidEscrowAmount.selector);
        hub.createBounty(SPEC_COMMITMENT, 1_000e6 + 1, _deadline());
        vm.expectRevert(ElgoraHub.InvalidDeadline.selector);
        hub.createBounty(
            SPEC_COMMITMENT, ESCROW_AMOUNT, uint64(block.timestamp + MIN_BOUNTY_DURATION - 1)
        );
        vm.expectRevert(ElgoraHub.InvalidDeadline.selector);
        hub.createBounty(
            SPEC_COMMITMENT, ESCROW_AMOUNT, uint64(block.timestamp + MAX_BOUNTY_DURATION + 1)
        );

        hub.createBounty(SPEC_COMMITMENT, 1e6, uint64(block.timestamp + MIN_BOUNTY_DURATION));
        hub.createBounty(SPEC_COMMITMENT, 1_000e6, _deadline());
        hub.createBounty(
            SPEC_COMMITMENT, ESCROW_AMOUNT, uint64(block.timestamp + MAX_BOUNTY_DURATION)
        );
        vm.stopPrank();

        assertEq(hub.bountyCount(), 3);
        assertEq(usdc.balanceOf(poster), balanceBefore - 1_001e6 - ESCROW_AMOUNT);
    }

    function testOwnerCreationConfigUpdatesAffectOnlyLaterBounties() public {
        uint256 first = _createDefaultBounty();
        vm.startPrank(protocolOwner);
        hub.setEscrowBounds(10e6, 20e6);
        hub.setBountyDurationBounds(1 days, MAX_BOUNTY_DURATION);
        vm.stopPrank();

        (ElgoraHub.BountyParameters memory firstParameters,) = hub.getBounty(first);
        assertEq(firstParameters.escrowAmount, ESCROW_AMOUNT);
        assertEq(firstParameters.submissionDeadline, 1_000 + 7 days);

        vm.startPrank(poster);
        usdc.approve(address(hub), 10e6);
        uint256 second = hub.createBounty(SPEC_COMMITMENT, 10e6, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        (ElgoraHub.BountyParameters memory secondParameters,) = hub.getBounty(second);
        assertEq(secondParameters.escrowAmount, 10e6);
    }

    function testInvalidCreationInputAndNonExactFundingRevertAtomically() public {
        vm.startPrank(poster);
        usdc.approve(address(hub), ESCROW_AMOUNT);
        vm.expectRevert(ElgoraHub.InvalidCommitment.selector);
        hub.createBounty(bytes32(0), ESCROW_AMOUNT, _deadline());
        vm.stopPrank();

        usdc.setTransferFeeBps(100);
        vm.startPrank(poster);
        usdc.approve(address(hub), ESCROW_AMOUNT);
        vm.expectRevert(ElgoraHub.TransferFromFailed.selector);
        hub.createBounty(SPEC_COMMITMENT, ESCROW_AMOUNT, _deadline());
        vm.stopPrank();
        assertEq(hub.bountyCount(), 0);
        assertEq(usdc.balanceOf(address(hub)), 0);
    }

    function testSubmitAllowsTwoSolversToHoldTheSameActiveCommitment() public {
        uint256 bountyId = _createDefaultBounty();
        bytes32 bountyRosterHash = hub.guardianRosterHash();

        _submit(bountyId, solverA, SUBMISSION_A, bountyRosterHash, "");
        _submit(bountyId, solverB, SUBMISSION_A, bountyRosterHash, "");

        assertEq(hub.activeSubmissionCommitment(bountyId, solverA), SUBMISSION_A);
        assertEq(hub.activeSubmissionCommitment(bountyId, solverB), SUBMISSION_A);
    }

    function testSubmitChecksSnapshottedRosterAndCountsEveryAcceptedReplacement() public {
        uint256 bountyId = _createDefaultBounty();
        bytes32 bountyRosterHash = hub.guardianRosterHash();

        _submit(bountyId, solverA, SUBMISSION_A, bountyRosterHash, "");
        _submit(bountyId, solverA, SUBMISSION_B, bountyRosterHash, "");
        _submit(bountyId, solverB, SUBMISSION_A, bountyRosterHash, "");

        (, ElgoraHub.BountyState memory state) = hub.getBounty(bountyId);
        assertEq(state.submissionCount, 3);
        assertEq(hub.activeSubmissionCommitment(bountyId, solverA), SUBMISSION_B);
        assertEq(hub.activeSubmissionCommitment(bountyId, solverB), SUBMISSION_A);

        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.StaleGuardianRoster.selector);
        hub.submit(bountyId, SUBMISSION_A, keccak256("stale"), "");
        (, state) = hub.getBounty(bountyId);
        assertEq(state.submissionCount, 3);
    }

    function testRosterRotationAffectsNewBountiesWithoutInvalidatingOpenBounty() public {
        uint256 first = _createDefaultBounty();
        (ElgoraHub.BountyParameters memory firstParameters,) = hub.getBounty(first);

        vm.prank(guardianRosterAdmin);
        hub.addGuardian("Guardian D", guardianD, "guardian-d-key");
        uint256 second = _createDefaultBounty();
        (ElgoraHub.BountyParameters memory secondParameters,) = hub.getBounty(second);
        assertNotEq(firstParameters.guardianRosterHash, secondParameters.guardianRosterHash);
        assertEq(hub.guardianThreshold(second), 3);

        _submit(first, solverA, SUBMISSION_A, firstParameters.guardianRosterHash, "");
        _submit(second, solverA, SUBMISSION_A, secondParameters.guardianRosterHash, "");
    }

    function testOwnerCanSwapLiveSubmissionGuardWithContextCountAndExtraData() public {
        uint256 bountyId = _createDefaultBounty();
        bytes32 rosterHash = hub.guardianRosterHash();
        ConfigurableSubmissionGuard guard = new ConfigurableSubmissionGuard();
        bytes memory proof = hex"1234";
        guard.configure(true, rosterHash, keccak256(proof), 0);

        vm.prank(protocolOwner);
        hub.setSubmissionGuard(address(guard));
        _submit(bountyId, solverA, SUBMISSION_A, rosterHash, proof);

        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.SubmissionRejected.selector);
        hub.submit(bountyId, SUBMISSION_B, rosterHash, proof);
        assertEq(hub.activeSubmissionCommitment(bountyId, solverA), SUBMISSION_A);
        (, ElgoraHub.BountyState memory state) = hub.getBounty(bountyId);
        assertEq(state.submissionCount, 1);
    }

    function testSubmitRejectsInvalidCommitmentAndDeadline() public {
        uint256 bountyId = _createDefaultBounty();
        bytes32 rosterHash = hub.guardianRosterHash();
        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.InvalidCommitment.selector);
        hub.submit(bountyId, bytes32(0), rosterHash, "");

        (ElgoraHub.BountyParameters memory parameters,) = hub.getBounty(bountyId);
        vm.warp(parameters.submissionDeadline);
        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.DeadlinePassed.selector);
        hub.submit(bountyId, SUBMISSION_A, rosterHash, "");
    }

    function testCommitVerdictOnlyPinnedRosterMembers() public {
        uint256 bountyId = _createAndSubmit();
        vm.prank(poster);
        vm.expectRevert(ElgoraHub.NotRosterGuardian.selector);
        hub.commitVerdict(
            bountyId, ElgoraHub.Outcome.Awarded, solverA, SUBMISSION_A, _reportCommitment(poster), ""
        );
    }

    function testCommitVerdictRejectsMalformedOutcomeShapes() public {
        uint256 bountyId = _createAndSubmit();

        vm.startPrank(guardianA);
        vm.expectRevert(ElgoraHub.InvalidVerdict.selector);
        hub.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.Awarded,
            address(0),
            SUBMISSION_A,
            _reportCommitment(guardianA),
            ""
        );
        vm.expectRevert(ElgoraHub.InvalidVerdict.selector);
        hub.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.NoValidSubmission,
            solverA,
            bytes32(0),
            _reportCommitment(guardianA),
            ""
        );
        vm.expectRevert(ElgoraHub.InvalidVerdict.selector);
        hub.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.NoValidSubmission,
            address(0),
            bytes32(0),
            _reportCommitment(guardianA),
            "unexpected"
        );
        vm.expectRevert(ElgoraHub.InvalidCommitment.selector);
        hub.commitVerdict(bountyId, ElgoraHub.Outcome.Awarded, solverA, SUBMISSION_A, bytes32(0), "");
        vm.stopPrank();
    }

    function testCommitVerdictRejectsOutOfRangeOutcome() public {
        uint256 bountyId = _createAndSubmit();

        vm.prank(guardianA);
        (bool ok,) = address(hub)
            .call(
                abi.encodeWithSelector(
                    ElgoraHub.commitVerdict.selector,
                    bountyId,
                    uint8(2),
                    address(0),
                    bytes32(0),
                    _reportCommitment(guardianA),
                    ""
                )
            );

        assertFalse(ok);
        (bool committed,,,,,) = hub.verdicts(bountyId, guardianA);
        assertFalse(committed);
        assertEq(uint8(hub.status(bountyId)), uint8(ElgoraHub.Status.Open));
    }

    function testCommitVerdictOneSlotPerGuardianOverwrites() public {
        uint256 bountyId = _createAndSubmit();
        _commitAwarded(bountyId, guardianA, solverA);
        _commitNoValidSubmission(bountyId, guardianA);

        (bool committed, ElgoraHub.Outcome outcome, address winner_,,,) =
            hub.verdicts(bountyId, guardianA);
        assertTrue(committed);
        assertEq(uint8(outcome), uint8(ElgoraHub.Outcome.NoValidSubmission));
        assertEq(winner_, address(0));
    }

    function testCommitVerdictRevisableBeforeLockFrozenAfterExceptFirstEverVerdict() public {
        uint256 bountyId = _createAndSubmit();
        (ElgoraHub.BountyParameters memory parameters,) = hub.getBounty(bountyId);

        _commitAwarded(bountyId, guardianA, solverA);
        _commitNoValidSubmission(bountyId, guardianA);

        vm.warp(parameters.judgingDeadlineAt);
        vm.prank(guardianA);
        vm.expectRevert(ElgoraHub.JudgingDeadlinePassed.selector);
        hub.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.Awarded,
            solverA,
            SUBMISSION_A,
            _reportCommitment(guardianA),
            ""
        );

        _commitAwarded(bountyId, guardianB, solverA);
        (bool committed,,,,,) = hub.verdicts(bountyId, guardianB);
        assertTrue(committed);
    }

    function testSplitRosterNeverSettlesFallsThroughToTimeout() public {
        uint256 bountyId = _createDefaultBounty();
        _submit(bountyId, solverA, SUBMISSION_A, hub.guardianRosterHash(), "");
        _submit(bountyId, solverB, SUBMISSION_B, hub.guardianRosterHash(), "");

        _commitAwarded(bountyId, guardianA, solverA);
        _commitAwarded(bountyId, guardianB, solverA);
        (, ElgoraHub.BountyState memory stateAfterConsensus) = hub.getBounty(bountyId);
        assertGt(stateAfterConsensus.consensusReachedAt, 0);

        _commitVerdict(bountyId, guardianB, ElgoraHub.Outcome.Awarded, solverB, SUBMISSION_B, "");
        _commitNoValidSubmission(bountyId, guardianC);

        _warpToJudgingDeadline(bountyId);
        vm.expectRevert(ElgoraHub.ConsensusNotReached.selector);
        hub.settle(bountyId);

        vm.warp(hub.settlementTimeoutAt(bountyId));
        hub.timeoutSettlement(bountyId);
        assertEq(uint8(hub.status(bountyId)), uint8(ElgoraHub.Status.TimedOut));
        assertEq(hub.claimable(bountyId, poster), ESCROW_AMOUNT);
    }

    function testPinnedRosterKeepsInFlightBountyJudgeableAfterRemoval() public {
        uint256 bountyId = _createAndSubmit();
        bytes32 pinnedHash = hub.guardianRosterHash();

        vm.prank(guardianRosterAdmin);
        hub.removeGuardian(guardianC);

        _commitAwarded(bountyId, guardianC, solverA);
        _commitAwarded(bountyId, guardianA, solverA);
        _warpToJudgingDeadline(bountyId);
        hub.settle(bountyId);
        assertEq(uint8(hub.status(bountyId)), uint8(ElgoraHub.Status.Awarded));

        uint256 laterBounty = _createDefaultBounty();
        (ElgoraHub.BountyParameters memory laterParameters,) = hub.getBounty(laterBounty);
        assertNotEq(laterParameters.guardianRosterHash, pinnedHash);

        vm.prank(guardianC);
        vm.expectRevert(ElgoraHub.NotRosterGuardian.selector);
        hub.commitVerdict(
            laterBounty,
            ElgoraHub.Outcome.NoValidSubmission,
            address(0),
            bytes32(0),
            _reportCommitment(guardianC),
            ""
        );
    }

    function testWinnerTakesAllSettlementPersistsWinnerAndConservesEscrow() public {
        uint256 bountyId = _createAndSubmit();
        _settleAwarded(bountyId);

        (, ElgoraHub.BountyState memory state) = hub.getBounty(bountyId);
        assertEq(uint8(state.status), uint8(ElgoraHub.Status.Awarded));
        assertEq(state.winner, solverA);
        assertEq(hub.winner(bountyId), solverA);
        assertEq(hub.claimable(bountyId, solverA), 0);
        assertEq(hub.winnerPoolClaimed(bountyId), 0);
        assertEq(hub.treasuryFeeClaimable(), TREASURY_FEE);
        assertEq(hub.guardianFeeClaimable(), GUARDIAN_FEE);
        assertEq(WINNER_POOL + TREASURY_FEE + GUARDIAN_FEE, ESCROW_AMOUNT);

        vm.prank(solverA);
        hub.claimAward(bountyId, "");
        assertEq(usdc.balanceOf(solverA), WINNER_POOL);
        assertEq(hub.winnerPoolClaimed(bountyId), WINNER_POOL);
    }

    /// @dev A Guardian verdict carries no payout-scheme field at all — see commitVerdict. Unlike
    /// the old eager-allocation model, an overpaying scheme no longer blocks settle() itself —
    /// settlement only ever finalizes outcome/winner/fees; a scheme that tries to pay a claimant
    /// more than the bounty's remaining winner pool is rejected atomically at claimAward(),
    /// without disturbing anything already paid out.
    function testOverpayingPayoutSchemeRevertsClaimAwardWithoutOverpaying() public {
        ConfigurablePayoutScheme overpaying = new ConfigurablePayoutScheme();
        overpaying.configure(true);
        (ElgoraHub splitHub, uint256 bountyId) = _createAndSubmitOnScheme(address(overpaying));
        _commitAwardedOn(splitHub, bountyId, guardianA, solverA);
        _commitAwardedOn(splitHub, bountyId, guardianB, solverA);
        _warpToJudgingDeadlineOn(splitHub, bountyId);
        splitHub.settle(bountyId);
        assertEq(uint8(splitHub.status(bountyId)), uint8(ElgoraHub.Status.Awarded));

        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.InvalidPayout.selector);
        splitHub.claimAward(bountyId, "");
        assertEq(splitHub.winnerPoolClaimed(bountyId), 0);
        assertEq(splitHub.claimable(bountyId, solverA), 0);
    }

    function testEmptyBountyRefundsFullEscrowWithoutFees() public {
        uint256 bountyId = _createDefaultBounty();
        _commitNoValidSubmission(bountyId, guardianA);
        _commitNoValidSubmission(bountyId, guardianB);
        _warpToJudgingDeadline(bountyId);
        vm.recordLogs();
        hub.settle(bountyId);

        assertEq(uint8(hub.status(bountyId)), uint8(ElgoraHub.Status.NoValidSubmission));
        assertEq(hub.claimable(bountyId, poster), ESCROW_AMOUNT);
        assertEq(hub.treasuryFeeClaimable(), 0);
        assertEq(hub.guardianFeeClaimable(), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory feeLog = logs[logs.length - 2];
        assertEq(feeLog.topics[0], keccak256("ClaimQueued(uint256,address,uint256)"));
        assertEq(feeLog.topics[2], bytes32(uint256(uint160(guardianFeeRecipient))));
        assertEq(abi.decode(feeLog.data, (uint256)), 0);
        uint256 beforeBalance = usdc.balanceOf(poster);
        vm.prank(poster);
        hub.claim(bountyId);
        assertEq(usdc.balanceOf(poster), beforeBalance + ESCROW_AMOUNT);
        assertEq(usdc.balanceOf(address(hub)), 0);
    }

    function testJunkSubmissionPreventsEmptyBountyFeeWaiver() public {
        uint256 bountyId = _createDefaultBounty();
        _commitNoValidSubmission(bountyId, guardianA);
        _commitNoValidSubmission(bountyId, guardianB);
        // A fee recipient can submit an arbitrary commitment, even after empty Verdicts.
        _submit(bountyId, guardianFeeRecipient, keccak256("junk"), hub.guardianRosterHash(), "");
        _warpToJudgingDeadline(bountyId);
        hub.settle(bountyId);
        assertEq(hub.claimable(bountyId, poster), ESCROW_AMOUNT - GUARDIAN_FEE);
        assertEq(hub.guardianFeeClaimable(), GUARDIAN_FEE);
        assertEq(hub.treasuryFeeClaimable(), 0);
    }

    function testNoValidSubmissionWaivesTreasuryFeeAndChargesGuardianFee() public {
        uint256 bountyId = _createAndSubmit();
        _commitNoValidSubmission(bountyId, guardianA);
        _commitNoValidSubmission(bountyId, guardianB);
        _warpToJudgingDeadline(bountyId);
        vm.recordLogs();
        hub.settle(bountyId);

        assertEq(uint8(hub.status(bountyId)), uint8(ElgoraHub.Status.NoValidSubmission));
        assertEq(hub.winner(bountyId), address(0));
        assertEq(hub.claimable(bountyId, poster), ESCROW_AMOUNT - GUARDIAN_FEE);
        assertEq(hub.treasuryFeeClaimable(), 0);
        assertEq(hub.guardianFeeClaimable(), GUARDIAN_FEE);

        bytes32 claimQueuedTopic = keccak256("ClaimQueued(uint256,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 claimQueuedCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != claimQueuedTopic) continue;
            claimQueuedCount++;
            assertNotEq(logs[i].topics[2], bytes32(uint256(uint160(treasury))));
        }
        assertEq(claimQueuedCount, 2);
    }

    function testFuzzSettlementConservesEscrowWhenPayoutRolesOverlap(
        uint96 amountSeed,
        uint16 treasuryFeeSeed,
        uint16 guardianFeeSeed,
        bool awardWinner,
        bool hasSubmission
    ) public {
        uint256 escrowAmount = bound(uint256(amountSeed), 1, 1_000_000e6);
        uint16 maxTotalFeeBps = hub.MAX_TOTAL_FEE_BPS();
        uint16 treasuryBps = uint16(bound(uint256(treasuryFeeSeed), 0, maxTotalFeeBps));
        uint16 guardianBps =
            uint16(bound(uint256(guardianFeeSeed), 0, uint256(maxTotalFeeBps - treasuryBps)));
        address recipient = awardWinner ? solverA : poster;
        ElgoraHub overlapHub =
            _deployHub(IERC20(address(usdc)), address(passThroughGuard), address(winnerTakesAll));
        vm.startPrank(protocolOwner);
        overlapHub.setFeeConfig(recipient, recipient, treasuryBps, guardianBps);
        overlapHub.setEscrowBounds(1, 1_000_000e6);
        vm.stopPrank();

        vm.startPrank(poster);
        usdc.approve(address(overlapHub), escrowAmount);
        uint256 bountyId = overlapHub.createBounty(SPEC_COMMITMENT, escrowAmount, _deadline());
        vm.stopPrank();

        if (awardWinner || hasSubmission) {
            bytes32 rosterHash = overlapHub.guardianRosterHash();
            vm.prank(solverA);
            overlapHub.submit(bountyId, SUBMISSION_A, rosterHash, "");
        }
        vm.prank(guardianA);
        overlapHub.commitVerdict(
            bountyId,
            awardWinner ? ElgoraHub.Outcome.Awarded : ElgoraHub.Outcome.NoValidSubmission,
            awardWinner ? solverA : address(0),
            awardWinner ? SUBMISSION_A : bytes32(0),
            _reportCommitment(guardianA),
            ""
        );
        vm.prank(guardianB);
        overlapHub.commitVerdict(
            bountyId,
            awardWinner ? ElgoraHub.Outcome.Awarded : ElgoraHub.Outcome.NoValidSubmission,
            awardWinner ? solverA : address(0),
            awardWinner ? SUBMISSION_A : bytes32(0),
            _reportCommitment(guardianB),
            ""
        );
        (ElgoraHub.BountyParameters memory parameters,) = overlapHub.getBounty(bountyId);
        vm.warp(parameters.judgingDeadlineAt);
        vm.recordLogs();
        overlapHub.settle(bountyId);

        uint256 expectedTreasury =
            awardWinner ? (escrowAmount * treasuryBps) / 10_000 : 0;
        uint256 expectedGuardian =
            (awardWinner || hasSubmission) ? (escrowAmount * guardianBps) / 10_000 : 0;
        uint256 expectedPrimary = escrowAmount - expectedTreasury - expectedGuardian;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory feeLog = logs[logs.length - 2];
        assertEq(feeLog.topics[0], keccak256("ClaimQueued(uint256,address,uint256)"));
        assertEq(feeLog.topics[2], bytes32(uint256(uint160(recipient))));
        assertEq(abi.decode(feeLog.data, (uint256)), expectedGuardian);
        if (awardWinner) {
            assertEq(overlapHub.claimable(bountyId, recipient), 0);
            assertEq(overlapHub.winnerPoolClaimed(bountyId), 0);
        } else {
            assertEq(overlapHub.claimable(bountyId, recipient), expectedPrimary);
        }
        assertEq(overlapHub.treasuryFeeClaimable(), expectedTreasury);
        assertEq(overlapHub.guardianFeeClaimable(), expectedGuardian);
        assertEq(usdc.balanceOf(address(overlapHub)), escrowAmount);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);
        vm.prank(recipient);
        if (awardWinner) {
            overlapHub.claimAward(bountyId, "");
        } else {
            overlapHub.claim(bountyId);
        }
        if (expectedTreasury + expectedGuardian != 0) {
            vm.prank(recipient);
            overlapHub.claimFees();
        }

        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + escrowAmount);
        assertEq(overlapHub.claimable(bountyId, recipient), 0);
        assertEq(overlapHub.treasuryFeeClaimable(), 0);
        assertEq(overlapHub.guardianFeeClaimable(), 0);
        assertEq(usdc.balanceOf(address(overlapHub)), 0);
    }

    function testFuzzDonatedTokensStayUnclaimableAfterSettlement(bool hasSubmission) public {
        uint256 bountyId = hasSubmission ? _createAndSubmit() : _createDefaultBounty();
        uint256 donation = 77e6;
        address donor = makeAddr("donor");
        usdc.mint(donor, donation);
        vm.prank(donor);
        assertTrue(usdc.transfer(address(hub), donation));

        _commitNoValidSubmission(bountyId, guardianA);
        _commitNoValidSubmission(bountyId, guardianB);
        _warpToJudgingDeadline(bountyId);
        hub.settle(bountyId);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(ElgoraHub.NothingToClaim.selector);
        hub.claim(bountyId);

        vm.prank(poster);
        hub.claim(bountyId);
        vm.prank(guardianFeeRecipient);
        if (!hasSubmission) vm.expectRevert(ElgoraHub.NothingToClaim.selector);
        hub.claimFees();

        assertEq(usdc.balanceOf(address(hub)), donation);
        assertEq(hub.claimable(bountyId, poster), 0);
        assertEq(hub.claimable(bountyId, stranger), 0);
        assertEq(hub.treasuryFeeClaimable(), 0);
        assertEq(hub.guardianFeeClaimable(), 0);
    }

    function testDustEscrowConservesWhenFeesRoundToZero() public {
        vm.prank(protocolOwner);
        hub.setEscrowBounds(1, 1_000e6);

        vm.startPrank(poster);
        usdc.approve(address(hub), 1);
        uint256 bountyId = hub.createBounty(SPEC_COMMITMENT, 1, _deadline());
        vm.stopPrank();
        bytes32 rosterHash = hub.guardianRosterHash();
        vm.prank(solverA);
        hub.submit(bountyId, SUBMISSION_A, rosterHash, "");
        _commitAwarded(bountyId, guardianA, solverA);
        _commitAwarded(bountyId, guardianB, solverA);
        _warpToJudgingDeadline(bountyId);
        hub.settle(bountyId);

        assertEq(hub.claimable(bountyId, solverA), 0);
        assertEq(hub.winnerPoolClaimed(bountyId), 0);
        assertEq(hub.treasuryFeeClaimable(), 0);
        assertEq(hub.guardianFeeClaimable(), 0);
        assertEq(usdc.balanceOf(address(hub)), 1);

        vm.prank(solverA);
        hub.claimAward(bountyId, "");
        assertEq(usdc.balanceOf(solverA), 1);
        assertEq(usdc.balanceOf(address(hub)), 0);
    }

    function testTimeoutQueuesFullPosterRefundWithoutFeesAndZeroWinner() public {
        uint256 bountyId = _createAndSubmit();
        _commitAwarded(bountyId, guardianA, solverA);
        _commitAwarded(bountyId, guardianB, solverA);
        vm.warp(hub.settlementTimeoutAt(bountyId));
        vm.expectRevert(ElgoraHub.SettlementWindowExpired.selector);
        hub.settle(bountyId);
        hub.timeoutSettlement(bountyId);
        assertEq(uint8(hub.status(bountyId)), uint8(ElgoraHub.Status.TimedOut));
        assertEq(hub.winner(bountyId), address(0));
        assertEq(hub.claimable(bountyId, poster), ESCROW_AMOUNT);
        assertEq(hub.treasuryFeeClaimable(), 0);
        assertEq(hub.guardianFeeClaimable(), 0);
    }

    function testSettlementAuthorityTimingWinnerAndFinalityChecks() public {
        uint256 bountyId = _createAndSubmit();
        _commitAwarded(bountyId, guardianA, solverA);
        _commitAwarded(bountyId, guardianB, solverA);

        vm.expectRevert(ElgoraHub.DeadlineNotPassed.selector);
        hub.settle(bountyId);

        (ElgoraHub.BountyParameters memory parameters,) = hub.getBounty(bountyId);
        vm.warp(parameters.submissionDeadline);
        vm.expectRevert(ElgoraHub.DeadlineNotPassed.selector);
        hub.settle(bountyId);

        _warpToJudgingDeadline(bountyId);

        hub.settle(bountyId);
        vm.expectRevert(ElgoraHub.InvalidStatus.selector);
        hub.settle(bountyId);
        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.InvalidStatus.selector);
        hub.submit(bountyId, SUBMISSION_B, parameters.guardianRosterHash, "");
        vm.prank(guardianC);
        vm.expectRevert(ElgoraHub.InvalidStatus.selector);
        hub.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.Awarded,
            solverA,
            SUBMISSION_A,
            _reportCommitment(guardianC),
            ""
        );
        vm.expectRevert(ElgoraHub.InvalidStatus.selector);
        hub.timeoutSettlement(bountyId);

        uint256 unreachedBounty = _createDefaultBounty();
        _warpToJudgingDeadline(unreachedBounty);
        vm.expectRevert(ElgoraHub.ConsensusNotReached.selector);
        hub.settle(unreachedBounty);

        uint256 noSubmissionBounty = _createDefaultBounty();
        _commitAwarded(noSubmissionBounty, guardianA, solverB);
        _commitAwarded(noSubmissionBounty, guardianB, solverB);
        _warpToJudgingDeadline(noSubmissionBounty);
        vm.expectRevert(ElgoraHub.NoActiveSubmission.selector);
        hub.settle(noSubmissionBounty);
    }

    function testAwardedSettlementRequiresWinnerStillHoldsExactCommitment() public {
        uint256 bountyId = _createAndSubmit();
        _commitAwarded(bountyId, guardianA, solverA);
        _commitAwarded(bountyId, guardianB, solverA);

        _submit(bountyId, solverA, SUBMISSION_B, hub.guardianRosterHash(), "");
        _warpToJudgingDeadline(bountyId);

        vm.expectRevert(ElgoraHub.NoActiveSubmission.selector);
        hub.settle(bountyId);
    }

    function testSettledEventRecordsSupportingGuardiansAndReportCommitments() public {
        uint256 bountyId = _createAndSubmit();
        _commitAwarded(bountyId, guardianA, solverA);
        _commitAwarded(bountyId, guardianB, solverA);
        _warpToJudgingDeadline(bountyId);

        address[] memory expectedSupporters = new address[](2);
        expectedSupporters[0] = guardianA;
        expectedSupporters[1] = guardianB;
        bytes32[] memory expectedReports = new bytes32[](2);
        expectedReports[0] = _reportCommitment(guardianA);
        expectedReports[1] = _reportCommitment(guardianB);

        vm.expectEmit(address(hub));
        emit ElgoraHub.Settled(
            bountyId,
            ElgoraHub.Status.Awarded,
            solverA,
            address(winnerTakesAll),
            expectedSupporters,
            expectedReports
        );
        hub.settle(bountyId);
    }

    function testCoordinatorGracePeriodWindowGatesFirstCallerThenOpensToAnyone() public {
        address dedicatedCoordinator = makeAddr("dedicated coordinator");
        ElgoraHub gatedHub = _deployGatedHub(dedicatedCoordinator, GATED_COORDINATOR_GRACE_PERIOD);

        usdc.mint(poster, ESCROW_AMOUNT);
        vm.startPrank(poster);
        usdc.approve(address(gatedHub), ESCROW_AMOUNT);
        uint256 bountyId = gatedHub.createBounty(SPEC_COMMITMENT, ESCROW_AMOUNT, _deadline());
        vm.stopPrank();
        bytes32 gatedRosterHash = gatedHub.guardianRosterHash();
        vm.prank(solverA);
        gatedHub.submit(bountyId, SUBMISSION_A, gatedRosterHash, "");

        (ElgoraHub.BountyParameters memory parameters,) = gatedHub.getBounty(bountyId);
        vm.warp(parameters.submissionDeadline);

        vm.prank(guardianA);
        gatedHub.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.Awarded,
            solverA,
            SUBMISSION_A,
            _reportCommitment(guardianA),
            ""
        );
        vm.prank(guardianB);
        gatedHub.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.Awarded,
            solverA,
            SUBMISSION_A,
            _reportCommitment(guardianB),
            ""
        );

        vm.warp(parameters.judgingDeadlineAt);

        vm.prank(poster);
        vm.expectRevert(ElgoraHub.NotCoordinator.selector);
        gatedHub.settle(bountyId);

        vm.prank(dedicatedCoordinator);
        gatedHub.settle(bountyId);
        assertEq(uint8(gatedHub.status(bountyId)), uint8(ElgoraHub.Status.Awarded));
    }

    function testCoordinatorGracePeriodWindowOpensToAnyoneAfterExpiry() public {
        address dedicatedCoordinator = makeAddr("dedicated coordinator 2");
        ElgoraHub gatedHub = _deployGatedHub(dedicatedCoordinator, GATED_COORDINATOR_GRACE_PERIOD);

        usdc.mint(poster, ESCROW_AMOUNT);
        vm.startPrank(poster);
        usdc.approve(address(gatedHub), ESCROW_AMOUNT);
        uint256 bountyId = gatedHub.createBounty(SPEC_COMMITMENT, ESCROW_AMOUNT, _deadline());
        vm.stopPrank();
        bytes32 gatedRosterHash = gatedHub.guardianRosterHash();
        vm.prank(solverA);
        gatedHub.submit(bountyId, SUBMISSION_A, gatedRosterHash, "");

        (ElgoraHub.BountyParameters memory parameters,) = gatedHub.getBounty(bountyId);
        vm.warp(parameters.submissionDeadline);

        vm.prank(guardianA);
        gatedHub.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.Awarded,
            solverA,
            SUBMISSION_A,
            _reportCommitment(guardianA),
            ""
        );
        vm.prank(guardianB);
        gatedHub.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.Awarded,
            solverA,
            SUBMISSION_A,
            _reportCommitment(guardianB),
            ""
        );
        (, ElgoraHub.BountyState memory stateAfterConsensus) = gatedHub.getBounty(bountyId);
        uint64 reachedAt = stateAfterConsensus.consensusReachedAt;
        assertGt(reachedAt, 0);

        vm.warp(parameters.judgingDeadlineAt);

        vm.prank(poster);
        vm.expectRevert(ElgoraHub.NotCoordinator.selector);
        gatedHub.settle(bountyId);

        vm.warp(parameters.judgingDeadlineAt + GATED_COORDINATOR_GRACE_PERIOD);
        vm.prank(poster);
        gatedHub.settle(bountyId);
        assertEq(uint8(gatedHub.status(bountyId)), uint8(ElgoraHub.Status.Awarded));
    }

    function testOpenBountySnapshotsFeesReviewWindowAndPayoutScheme() public {
        uint256 bountyId = _createAndSubmit();
        address nextTreasury = makeAddr("next treasury");
        ConfigurablePayoutScheme nextScheme = new ConfigurablePayoutScheme();
        nextScheme.configure(true);
        vm.startPrank(protocolOwner);
        hub.setGuardianRosterAdmin(makeAddr("next signer"));
        hub.setFeeConfig(nextTreasury, collaborator, 100, 200);
        hub.setGuardianReviewWindow(1 hours);
        hub.setPayoutScheme(address(nextScheme));
        vm.stopPrank();

        (ElgoraHub.BountyParameters memory parameters,) = hub.getBounty(bountyId);
        assertEq(parameters.treasuryRecipient, treasury);
        assertEq(parameters.guardianFeeRecipient, guardianFeeRecipient);
        assertEq(parameters.treasuryFeeBps, TREASURY_FEE_BPS);
        assertEq(parameters.guardianFeeBps, GUARDIAN_FEE_BPS);
        assertEq(parameters.payoutScheme, address(winnerTakesAll));
        assertEq(parameters.settlementTimeoutAt, parameters.submissionDeadline + REVIEW_WINDOW);

        _commitAwarded(bountyId, guardianA, solverA);
        _commitAwarded(bountyId, guardianB, solverA);
        vm.warp(parameters.judgingDeadlineAt);
        hub.settle(bountyId);

        // Had claimAward consulted the owner's later nextScheme instead of the pinned
        // winnerTakesAll, its overpay configuration would have reverted this claim instead of
        // paying out exactly WINNER_POOL.
        vm.prank(solverA);
        hub.claimAward(bountyId, "");
        assertEq(usdc.balanceOf(solverA), WINNER_POOL);
    }

    function testPauseBlocksExternalLifecycleAndClaimCallsButNotConfiguration() public {
        uint256 submissionBounty = _createDefaultBounty();
        uint256 verdictBounty = _createAndSubmit();
        uint256 settlementBounty = _createAndSubmit();
        _commitAwarded(settlementBounty, guardianA, solverA);
        _commitAwarded(settlementBounty, guardianB, solverA);
        uint256 timeoutBounty = _createDefaultBounty();
        uint256 claimBounty = _createAndSubmit();
        _settleAwarded(claimBounty);

        vm.prank(protocolOwner);
        hub.pause();
        assertTrue(hub.paused());

        vm.prank(poster);
        vm.expectRevert(ElgoraHub.ContractPaused.selector);
        hub.createBounty(SPEC_COMMITMENT, ESCROW_AMOUNT, _deadline());
        bytes32 currentRosterHash = hub.guardianRosterHash();
        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.ContractPaused.selector);
        hub.submit(submissionBounty, SUBMISSION_A, currentRosterHash, "");
        vm.prank(guardianA);
        vm.expectRevert(ElgoraHub.ContractPaused.selector);
        hub.commitVerdict(
            verdictBounty,
            ElgoraHub.Outcome.Awarded,
            solverA,
            SUBMISSION_A,
            _reportCommitment(guardianA),
            ""
        );
        vm.expectRevert(ElgoraHub.ContractPaused.selector);
        hub.settle(settlementBounty);
        vm.expectRevert(ElgoraHub.ContractPaused.selector);
        hub.timeoutSettlement(timeoutBounty);
        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.ContractPaused.selector);
        hub.claim(claimBounty);
        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.ContractPaused.selector);
        hub.claimAward(claimBounty, "");

        ConfigurableSubmissionGuard nextGuard = new ConfigurableSubmissionGuard();
        ConfigurablePayoutScheme nextScheme = new ConfigurablePayoutScheme();
        vm.startPrank(protocolOwner);
        hub.setSubmissionGuard(address(nextGuard));
        hub.setPayoutScheme(address(nextScheme));
        hub.setFeeConfig(treasury, guardianFeeRecipient, 100, 200);
        hub.setEscrowBounds(2e6, 200e6);
        hub.setBountyDurationBounds(1 days, MAX_BOUNTY_DURATION);
        hub.setGuardianReviewWindow(1 hours);
        address replacementSigner = makeAddr("replacement signer");
        hub.setGuardianRosterAdmin(replacementSigner);
        hub.setCoordinator(makeAddr("replacement coordinator"));
        hub.setCoordinatorGracePeriod(2 hours);
        vm.stopPrank();
        vm.prank(replacementSigner);
        hub.addGuardian("Guardian D", guardianD, "guardian-d-key");
        vm.prank(protocolOwner);
        hub.unpause();
        assertFalse(hub.paused());
    }

    function testPauseAuthorityNeverExpiresUntilOwnerPermanentlyDisablesIt() public {
        vm.warp(block.timestamp + 3650 days);
        vm.startPrank(protocolOwner);
        hub.pause();
        assertTrue(hub.paused());
        hub.unpause();
        assertFalse(hub.paused());
        vm.stopPrank();

        assertFalse(hub.pausingDisabled());

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, poster));
        hub.disablePauseAuthority();

        vm.startPrank(protocolOwner);
        vm.expectEmit(address(hub));
        emit ElgoraHub.PauseAuthorityDisabled(protocolOwner);
        hub.disablePauseAuthority();
        assertTrue(hub.pausingDisabled());

        vm.expectRevert(ElgoraHub.PauseUnavailable.selector);
        hub.pause();

        vm.expectRevert(ElgoraHub.PauseUnavailable.selector);
        hub.disablePauseAuthority();
        vm.stopPrank();

        _createDefaultBounty();
    }

    function testOwnerCanRenounceAndFreezesOwnerConfiguration() public {
        vm.prank(protocolOwner);
        hub.renounceOwnership();
        assertEq(hub.owner(), address(0));

        vm.prank(protocolOwner);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, protocolOwner)
        );
        hub.setEscrowBounds(2e6, 200e6);

        vm.prank(guardianRosterAdmin);
        hub.addGuardian("Guardian D", guardianD, "guardian-d-key");
    }

    function testClaimAwardClearsRemainingPoolAndTransfersOnlyOnce() public {
        uint256 bountyId = _createAndSubmit();
        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.InvalidStatus.selector);
        hub.claimAward(bountyId, "");

        _settleAwarded(bountyId);

        vm.prank(solverA);
        hub.claimAward(bountyId, "");
        assertEq(usdc.balanceOf(solverA), WINNER_POOL);
        assertEq(hub.winnerPoolClaimed(bountyId), WINNER_POOL);
        vm.prank(solverA);
        vm.expectRevert(ElgoraHub.NothingToClaim.selector);
        hub.claimAward(bountyId, "");
    }

    function testFuzzClaimRevertRestoresBalanceAndClaimRejectsReentrancy(bool hasSubmission)
        public
    {
        uint256 bountyId = hasSubmission ? _createAndSubmit() : _createDefaultBounty();
        uint256 expectedRefund = hasSubmission ? ESCROW_AMOUNT - GUARDIAN_FEE : ESCROW_AMOUNT;
        _commitNoValidSubmission(bountyId, guardianA);
        _commitNoValidSubmission(bountyId, guardianB);
        _warpToJudgingDeadline(bountyId);
        hub.settle(bountyId);
        usdc.setBlocked(poster, true);
        vm.prank(poster);
        vm.expectRevert(MockUSDC.BlockedTransfer.selector);
        hub.claim(bountyId);
        assertEq(hub.claimable(bountyId, poster), expectedRefund);

        vm.prank(guardianFeeRecipient);
        if (!hasSubmission) vm.expectRevert(ElgoraHub.NothingToClaim.selector);
        hub.claimFees();
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(guardianFeeRecipient), hasSubmission ? GUARDIAN_FEE : 0);
        assertEq(hub.claimable(bountyId, poster), expectedRefund);
        assertEq(hub.treasuryFeeClaimable(), 0);
        assertEq(hub.guardianFeeClaimable(), 0);
        assertEq(usdc.balanceOf(address(hub)), expectedRefund);

        usdc.setBlocked(poster, false);
        uint256 posterBalance = usdc.balanceOf(poster);
        vm.prank(poster);
        hub.claim(bountyId);
        assertEq(usdc.balanceOf(poster), posterBalance + expectedRefund);
        assertEq(hub.claimable(bountyId, poster), 0);
        assertEq(usdc.balanceOf(address(hub)), 0);

        ReentrantUSDC reentrantUsdc = new ReentrantUSDC();
        ElgoraHub reentrantHub = _deployHub(
            IERC20(address(reentrantUsdc)), address(passThroughGuard), address(winnerTakesAll)
        );
        reentrantUsdc.mint(poster, ESCROW_AMOUNT);
        vm.startPrank(poster);
        reentrantUsdc.approve(address(reentrantHub), ESCROW_AMOUNT);
        uint256 reentrantBounty =
            reentrantHub.createBounty(SPEC_COMMITMENT, ESCROW_AMOUNT, _deadline());
        vm.stopPrank();
        address claimant = address(reentrantUsdc);
        bytes32 reentrantRosterHash = reentrantHub.guardianRosterHash();
        vm.prank(claimant);
        reentrantHub.submit(reentrantBounty, SUBMISSION_A, reentrantRosterHash, "");
        vm.prank(guardianA);
        reentrantHub.commitVerdict(
            reentrantBounty,
            ElgoraHub.Outcome.Awarded,
            claimant,
            SUBMISSION_A,
            _reportCommitment(guardianA),
            ""
        );
        vm.prank(guardianB);
        reentrantHub.commitVerdict(
            reentrantBounty,
            ElgoraHub.Outcome.Awarded,
            claimant,
            SUBMISSION_A,
            _reportCommitment(guardianB),
            ""
        );
        (ElgoraHub.BountyParameters memory parameters,) = reentrantHub.getBounty(reentrantBounty);
        vm.warp(parameters.judgingDeadlineAt);
        reentrantHub.settle(reentrantBounty);
        reentrantUsdc.setReentry(reentrantHub, reentrantBounty, true);
        reentrantUsdc.claimFromTarget();
        assertTrue(reentrantUsdc.reentryAttempted());
        assertEq(reentrantUsdc.reentryRevertSelector(), ElgoraHub.ReentrantCall.selector);
        // The legitimate outer claimAward still succeeded exactly once despite the reentry
        // attempt during its token transfer — paid in full, not doubled.
        assertEq(reentrantHub.winnerPoolClaimed(reentrantBounty), WINNER_POOL);
    }

    function testClaimManyCombinesMultipleBountiesAndSkipsEmptyIds() public {
        uint256 bountyId1 = _createDefaultBounty();
        uint256 bountyId2 = _createDefaultBounty();
        uint256 openBountyId = _createDefaultBounty();
        uint256 awardedBountyId = _createAndSubmit();
        _settleAwarded(awardedBountyId);

        vm.warp(hub.settlementTimeoutAt(bountyId1));
        hub.timeoutSettlement(bountyId1);
        hub.timeoutSettlement(bountyId2);

        uint256[] memory ids = new uint256[](4);
        ids[0] = bountyId1;
        ids[1] = bountyId2;
        ids[2] = openBountyId;
        ids[3] = awardedBountyId;

        uint256 balanceBefore = usdc.balanceOf(poster);
        vm.prank(poster);
        uint256 total = hub.claimMany(ids);

        assertEq(total, ESCROW_AMOUNT * 2);
        assertEq(usdc.balanceOf(poster), balanceBefore + ESCROW_AMOUNT * 2);
        assertEq(hub.claimable(bountyId1, poster), 0);
        assertEq(hub.claimable(bountyId2, poster), 0);
        assertEq(hub.claimable(awardedBountyId, poster), 0);
        assertEq(hub.claimable(awardedBountyId, solverA), 0);

        vm.prank(solverA);
        hub.claimAward(awardedBountyId, "");
        assertEq(usdc.balanceOf(solverA), WINNER_POOL);

        vm.prank(poster);
        vm.expectRevert(ElgoraHub.NothingToClaim.selector);
        hub.claimMany(ids);
    }

    function testFuzzAwardedAndNoValidSubmissionBountyAccountingIsIsolated(bool hasSubmission)
        public
    {
        uint256 awardedBountyId = _createAndSubmit();
        uint256 noValidSubmissionBountyId =
            hasSubmission ? _createAndSubmit() : _createDefaultBounty();
        uint256 expectedRefund = hasSubmission ? ESCROW_AMOUNT - GUARDIAN_FEE : ESCROW_AMOUNT;
        uint256 expectedGuardianFees = hasSubmission ? GUARDIAN_FEE * 2 : GUARDIAN_FEE;
        _commitAwarded(awardedBountyId, guardianA, solverA);
        _commitAwarded(awardedBountyId, guardianB, solverA);
        _commitNoValidSubmission(noValidSubmissionBountyId, guardianA);
        _commitNoValidSubmission(noValidSubmissionBountyId, guardianB);

        _warpToJudgingDeadline(awardedBountyId);
        hub.settle(awardedBountyId);
        hub.settle(noValidSubmissionBountyId);

        assertEq(hub.claimable(awardedBountyId, solverA), 0);
        assertEq(hub.winnerPoolClaimed(awardedBountyId), 0);
        assertEq(hub.claimable(noValidSubmissionBountyId, solverA), 0);
        assertEq(hub.claimable(awardedBountyId, poster), 0);
        assertEq(hub.claimable(noValidSubmissionBountyId, poster), expectedRefund);
        assertEq(hub.treasuryFeeClaimable(), TREASURY_FEE);
        assertEq(hub.guardianFeeClaimable(), expectedGuardianFees);

        vm.prank(solverA);
        hub.claimAward(awardedBountyId, "");
        assertEq(usdc.balanceOf(solverA), WINNER_POOL);
        assertEq(hub.claimable(noValidSubmissionBountyId, poster), expectedRefund);
        assertEq(usdc.balanceOf(address(hub)), expectedRefund + TREASURY_FEE + expectedGuardianFees);

        vm.prank(poster);
        hub.claim(noValidSubmissionBountyId);
        assertEq(hub.winnerPoolClaimed(awardedBountyId), WINNER_POOL);
        assertEq(hub.claimable(noValidSubmissionBountyId, poster), 0);
        assertEq(usdc.balanceOf(address(hub)), TREASURY_FEE + expectedGuardianFees);
    }

    function testClaimFeesPullsAggregateFeesIndependentOfBountyId() public {
        uint256 bountyId1 = _createAndSubmit();
        uint256 bountyId2 = _createAndSubmit();
        _settleAwarded(bountyId1);
        _settleAwarded(bountyId2);

        assertEq(hub.treasuryFeeClaimable(), TREASURY_FEE * 2);
        assertEq(hub.guardianFeeClaimable(), GUARDIAN_FEE * 2);

        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        vm.prank(treasury);
        (uint256 treasuryAmount, uint256 guardianAmount) = hub.claimFees();
        assertEq(treasuryAmount, TREASURY_FEE * 2);
        assertEq(guardianAmount, 0);
        assertEq(usdc.balanceOf(treasury), treasuryBalanceBefore + TREASURY_FEE * 2);
        assertEq(hub.treasuryFeeClaimable(), 0);

        uint256 guardianBalanceBefore = usdc.balanceOf(guardianFeeRecipient);
        vm.prank(guardianFeeRecipient);
        (uint256 treasuryAmount2, uint256 guardianAmount2) = hub.claimFees();
        assertEq(treasuryAmount2, 0);
        assertEq(guardianAmount2, GUARDIAN_FEE * 2);
        assertEq(usdc.balanceOf(guardianFeeRecipient), guardianBalanceBefore + GUARDIAN_FEE * 2);

        vm.prank(treasury);
        vm.expectRevert(ElgoraHub.NothingToClaim.selector);
        hub.claimFees();
    }

    function testClaimFeesFollowsLiveRecipientNotHistoricalSnapshot() public {
        uint256 bountyId1 = _createAndSubmit();
        _settleAwarded(bountyId1);

        address newTreasury = makeAddr("new treasury");
        address newGuardianFeeRecipient = makeAddr("new guardian fee recipient");
        vm.prank(protocolOwner);
        hub.setFeeConfig(newTreasury, newGuardianFeeRecipient, TREASURY_FEE_BPS, GUARDIAN_FEE_BPS);

        uint256 bountyId2 = _createAndSubmit();
        _settleAwarded(bountyId2);

        assertEq(hub.treasuryFeeClaimable(), TREASURY_FEE * 2);
        assertEq(hub.guardianFeeClaimable(), GUARDIAN_FEE * 2);

        vm.prank(treasury);
        vm.expectRevert(ElgoraHub.NothingToClaim.selector);
        hub.claimFees();
        vm.prank(guardianFeeRecipient);
        vm.expectRevert(ElgoraHub.NothingToClaim.selector);
        hub.claimFees();

        uint256 treasuryBalanceBefore = usdc.balanceOf(newTreasury);
        vm.prank(newTreasury);
        (uint256 treasuryAmount, uint256 guardianAmount) = hub.claimFees();
        assertEq(treasuryAmount, TREASURY_FEE * 2);
        assertEq(guardianAmount, 0);
        assertEq(usdc.balanceOf(newTreasury), treasuryBalanceBefore + TREASURY_FEE * 2);

        uint256 guardianBalanceBefore = usdc.balanceOf(newGuardianFeeRecipient);
        vm.prank(newGuardianFeeRecipient);
        (uint256 treasuryAmount2, uint256 guardianAmount2) = hub.claimFees();
        assertEq(treasuryAmount2, 0);
        assertEq(guardianAmount2, GUARDIAN_FEE * 2);
        assertEq(usdc.balanceOf(newGuardianFeeRecipient), guardianBalanceBefore + GUARDIAN_FEE * 2);
    }

    function testOwnerSettersRejectUnauthorizedAndInvalidConfig() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, poster));
        hub.setFeeConfig(treasury, guardianFeeRecipient, 150, 350);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, poster));
        hub.setCoordinator(poster);

        vm.startPrank(protocolOwner);
        vm.expectRevert(ElgoraHub.InvalidAddress.selector);
        hub.setGuardianRosterAdmin(address(0));
        vm.expectRevert(ElgoraHub.InvalidAddress.selector);
        hub.setFeeConfig(address(0), guardianFeeRecipient, 150, 350);
        vm.expectRevert(ElgoraHub.InvalidFeeConfig.selector);
        hub.setFeeConfig(treasury, guardianFeeRecipient, 651, 350);
        vm.expectRevert(ElgoraHub.InvalidEscrowBounds.selector);
        hub.setEscrowBounds(10e6, 1e6);
        vm.expectRevert(ElgoraHub.InvalidDurationBounds.selector);
        hub.setBountyDurationBounds(0, MAX_BOUNTY_DURATION);
        vm.expectRevert(ElgoraHub.InvalidDurationBounds.selector);
        hub.setBountyDurationBounds(MAX_BOUNTY_DURATION, MIN_BOUNTY_DURATION);
        vm.expectRevert(ElgoraHub.InvalidDeadline.selector);
        hub.setGuardianReviewWindow(0);
        vm.expectRevert(ElgoraHub.InvalidContract.selector);
        hub.setSubmissionGuard(address(1));
        vm.expectRevert(ElgoraHub.InvalidContract.selector);
        hub.setPayoutScheme(address(1));
        hub.setCoordinator(address(0));
        assertEq(hub.coordinator(), address(0));
        vm.stopPrank();
    }

    function _deployHub(IERC20 token, address guard, address scheme)
        private
        returns (ElgoraHub deployed)
    {
        ElgoraHub.Guardian[] memory roster = new ElgoraHub.Guardian[](3);
        roster[0] = ElgoraHub.Guardian({
            name: "Guardian A", account: guardianA, encryptionPublicKey: "guardian-a-key"
        });
        roster[1] = ElgoraHub.Guardian({
            name: "Guardian B", account: guardianB, encryptionPublicKey: "guardian-b-key"
        });
        roster[2] = ElgoraHub.Guardian({
            name: "Guardian C", account: guardianC, encryptionPublicKey: "guardian-c-key"
        });
        deployed = new ElgoraHub(
            token,
            protocolOwner,
            ElgoraHub.InitialConfig({
                guardianRosterAdmin: guardianRosterAdmin,
                guardianReviewWindow: REVIEW_WINDOW,
                treasuryRecipient: treasury,
                guardianFeeRecipient: guardianFeeRecipient,
                treasuryFeeBps: TREASURY_FEE_BPS,
                guardianFeeBps: GUARDIAN_FEE_BPS,
                minimumEscrowAmount: 1e6,
                maximumEscrowAmount: 1_000e6,
                minBountyDuration: MIN_BOUNTY_DURATION,
                maxBountyDuration: MAX_BOUNTY_DURATION,
                submissionGuard: guard,
                payoutScheme: scheme,
                coordinator: address(0),
                coordinatorGracePeriod: COORDINATOR_GRACE_PERIOD
            }),
            roster
        );
    }

    function _deployGatedHub(address coordinatorAddress, uint64 coordinatorGracePeriod_)
        private
        returns (ElgoraHub deployed)
    {
        ElgoraHub.Guardian[] memory roster = new ElgoraHub.Guardian[](2);
        roster[0] = ElgoraHub.Guardian({
            name: "Guardian A", account: guardianA, encryptionPublicKey: "guardian-a-key"
        });
        roster[1] = ElgoraHub.Guardian({
            name: "Guardian B", account: guardianB, encryptionPublicKey: "guardian-b-key"
        });
        deployed = new ElgoraHub(
            IERC20(address(usdc)),
            protocolOwner,
            ElgoraHub.InitialConfig({
                guardianRosterAdmin: guardianRosterAdmin,
                guardianReviewWindow: REVIEW_WINDOW,
                treasuryRecipient: treasury,
                guardianFeeRecipient: guardianFeeRecipient,
                treasuryFeeBps: TREASURY_FEE_BPS,
                guardianFeeBps: GUARDIAN_FEE_BPS,
                minimumEscrowAmount: 1e6,
                maximumEscrowAmount: 1_000e6,
                minBountyDuration: MIN_BOUNTY_DURATION,
                maxBountyDuration: MAX_BOUNTY_DURATION,
                submissionGuard: address(passThroughGuard),
                payoutScheme: address(winnerTakesAll),
                coordinator: coordinatorAddress,
                coordinatorGracePeriod: coordinatorGracePeriod_
            }),
            roster
        );
    }

    function _createDefaultBounty() private returns (uint256) {
        return _createBounty(_deadline());
    }

    function _createBounty(uint64 deadline) private returns (uint256 bountyId) {
        vm.startPrank(poster);
        usdc.approve(address(hub), ESCROW_AMOUNT);
        bountyId = hub.createBounty(SPEC_COMMITMENT, ESCROW_AMOUNT, deadline);
        vm.stopPrank();
    }

    function _createAndSubmit() private returns (uint256 bountyId) {
        bountyId = _createDefaultBounty();
        _submit(bountyId, solverA, SUBMISSION_A, hub.guardianRosterHash(), "");
    }

    /// @dev Deploys a fresh Hub pinning `scheme` as its payout scheme, so tests can exercise
    /// IPayoutScheme edge cases at settlement without a Guardian ever naming a scheme itself —
    /// see commitVerdict, which carries no payout-scheme field at all.
    function _createAndSubmitOnScheme(address scheme)
        private
        returns (ElgoraHub deployed, uint256 bountyId)
    {
        deployed = _deployHub(IERC20(address(usdc)), address(passThroughGuard), scheme);
        vm.startPrank(poster);
        usdc.approve(address(deployed), ESCROW_AMOUNT);
        bountyId = deployed.createBounty(SPEC_COMMITMENT, ESCROW_AMOUNT, _deadline());
        vm.stopPrank();
        bytes32 rosterHash = deployed.guardianRosterHash();
        vm.prank(solverA);
        deployed.submit(bountyId, SUBMISSION_A, rosterHash, "");
    }

    function _submit(
        uint256 bountyId,
        address solver,
        bytes32 commitment,
        bytes32 rosterHash,
        bytes memory extraData
    ) private {
        vm.prank(solver);
        hub.submit(bountyId, commitment, rosterHash, extraData);
    }

    function _commitVerdict(
        uint256 bountyId,
        address guardian,
        ElgoraHub.Outcome outcome,
        address winner_,
        bytes32 submissionCommitment,
        bytes memory payoutData
    ) private {
        vm.prank(guardian);
        hub.commitVerdict(
            bountyId,
            outcome,
            winner_,
            submissionCommitment,
            _reportCommitment(guardian),
            payoutData
        );
    }

    function _commitAwarded(uint256 bountyId, address guardian, address winner_) private {
        _commitVerdict(bountyId, guardian, ElgoraHub.Outcome.Awarded, winner_, SUBMISSION_A, "");
    }

    function _commitAwardedOn(ElgoraHub target, uint256 bountyId, address guardian, address winner_)
        private
    {
        vm.prank(guardian);
        target.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.Awarded,
            winner_,
            SUBMISSION_A,
            _reportCommitment(guardian),
            ""
        );
    }

    function _commitNoValidSubmission(uint256 bountyId, address guardian) private {
        _commitVerdict(
            bountyId, guardian, ElgoraHub.Outcome.NoValidSubmission, address(0), bytes32(0), ""
        );
    }

    function _reportCommitment(address guardian) private pure returns (bytes32) {
        return keccak256(abi.encode("report", guardian));
    }

    function _settleAwarded(uint256 bountyId) private {
        _commitAwarded(bountyId, guardianA, solverA);
        _commitAwarded(bountyId, guardianB, solverA);
        _warpToJudgingDeadline(bountyId);
        hub.settle(bountyId);
    }

    function _warpToJudgingDeadline(uint256 bountyId) private {
        (ElgoraHub.BountyParameters memory parameters,) = hub.getBounty(bountyId);
        vm.warp(parameters.judgingDeadlineAt);
    }

    function _warpToJudgingDeadlineOn(ElgoraHub target, uint256 bountyId) private {
        (ElgoraHub.BountyParameters memory parameters,) = target.getBounty(bountyId);
        vm.warp(parameters.judgingDeadlineAt);
    }

    function _escrowAuthorization(
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
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return ElgoraHub.EscrowAuthorization({
            validAfter: 0, validBefore: validBefore, nonce: nonce, v: v, r: r, s: s
        });
    }

    function _deadline() private view returns (uint64) {
        return uint64(block.timestamp + 7 days);
    }
}
