// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {ElgoraHub} from "../src/ElgoraHub.sol";
import {CappedSubmissionGuard} from "../src/CappedSubmissionGuard.sol";
import {ISubmissionGuard} from "../src/ISubmissionGuard.sol";
import {WinnerTakesAllPayoutScheme} from "../src/WinnerTakesAllPayoutScheme.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// Calls back into submit() from inside canSubmit, as the sharpest test of the Hub's
/// checks-effects-interactions ordering now that the guard call is a real CALL.
contract ReentrantSubmissionGuard is ISubmissionGuard {
    ElgoraHub public hub;
    bytes32 public rosterHash;
    bool private entered;

    function arm(ElgoraHub hub_, bytes32 rosterHash_) external {
        hub = hub_;
        rosterHash = rosterHash_;
    }

    function canSubmit(address, SubmissionContext calldata context, uint256, bytes calldata)
        external
        returns (bool)
    {
        if (!entered) {
            entered = true;
            hub.submit(context.bountyId, keccak256("reentrant"), rosterHash, "");
        }
        return true;
    }
}

contract CappedSubmissionGuardTest is Test {
    uint256 private constant ESCROW_AMOUNT = 10e6;
    uint64 private constant MIN_BOUNTY_DURATION = 1 days;
    uint64 private constant MAX_BOUNTY_DURATION = 180 days;
    uint256 private constant DEFAULT_MAXIMUM_SUBMISSIONS = 3;

    MockUSDC private usdc;
    WinnerTakesAllPayoutScheme private scheme;
    CappedSubmissionGuard private guard;
    ElgoraHub private hub;

    address private protocolOwner = makeAddr("protocol owner");
    address private guardOwner = makeAddr("guard owner");
    address private poster = makeAddr("poster");
    address private guardian = makeAddr("guardian");
    address private outsider = makeAddr("outsider");

    function setUp() public {
        vm.warp(1_000);
        usdc = new MockUSDC();
        scheme = new WinnerTakesAllPayoutScheme();
        guard = new CappedSubmissionGuard(guardOwner, DEFAULT_MAXIMUM_SUBMISSIONS);
        hub = _deployHub(address(guard));
        vm.prank(guardOwner);
        guard.bindHub(address(hub));
        usdc.mint(poster, 1_000_000e6);
    }

    function testOneSeatPerSolverAccountUntilTheCapRunsOut() public {
        uint256 bountyId = _createBounty(hub);
        bytes32 rosterHash = hub.guardianRosterHash();

        for (uint256 i = 0; i < DEFAULT_MAXIMUM_SUBMISSIONS; i++) {
            assertEq(guard.remainingSubmissions(bountyId), DEFAULT_MAXIMUM_SUBMISSIONS - i);
            // Every Solver here submits the identical commitment: two accounts holding the same
            // bytes are still two seats, because seats bound reviewers, not distinct content.
            _submit(hub, bountyId, _solver(i), keccak256("same"), rosterHash);
        }

        assertEq(guard.submissionSeatsUsed(bountyId), DEFAULT_MAXIMUM_SUBMISSIONS);
        assertEq(guard.remainingSubmissions(bountyId), 0);

        address latecomer = _solver(DEFAULT_MAXIMUM_SUBMISSIONS);
        vm.prank(latecomer);
        vm.expectRevert(ElgoraHub.SubmissionRejected.selector);
        hub.submit(bountyId, keccak256("late"), rosterHash, "");
        assertEq(hub.activeSubmissionCommitment(bountyId, latecomer), bytes32(0));

        // One seat per Solver account: the account that already holds this bounty's seat keeps
        // revising at the cap, however many times, because the Hub stores exactly one active
        // commitment per Solver and a revision costs the roster nothing.
        address incumbent = _solver(0);
        _submit(hub, bountyId, incumbent, keccak256("revised"), rosterHash);
        _submit(hub, bountyId, incumbent, keccak256("revised again"), rosterHash);
        assertEq(hub.activeSubmissionCommitment(bountyId, incumbent), keccak256("revised again"));
        assertEq(guard.submissionSeatsUsed(bountyId), DEFAULT_MAXIMUM_SUBMISSIONS);
    }

    function testSeatsAreCountedPerBounty() public {
        uint256 firstBounty = _createBounty(hub);
        uint256 secondBounty = _createBounty(hub);

        _submit(hub, firstBounty, _solver(0), keccak256("a"), hub.guardianRosterHash());

        assertEq(guard.submissionSeatsUsed(firstBounty), 1);
        assertEq(guard.submissionSeatsUsed(secondBounty), 0);
        assertTrue(guard.holdsSubmissionSeat(firstBounty, _solver(0)));
        assertFalse(guard.holdsSubmissionSeat(secondBounty, _solver(0)));
    }

    function testOnlyTheBoundHubCanTakeASeat() public {
        uint256 bountyId = _createBounty(hub);
        ISubmissionGuard.SubmissionContext memory context = _context(bountyId);
        address direct = _solver(0);

        // canSubmit is externally callable now that it is not a STATICCALL. Without this check
        // anyone could burn a bounty's seats without ever touching the Hub.
        vm.prank(outsider);
        vm.expectRevert(CappedSubmissionGuard.UnauthorizedHub.selector);
        guard.canSubmit(direct, context, 0, "");
        assertEq(guard.submissionSeatsUsed(bountyId), 0);

        // A second Hub pointed at this guard gets nothing from it, so its bounty ids can never
        // collide with the bound Hub's or drain its seats.
        ElgoraHub otherHub = _deployHub(address(guard));
        uint256 otherBountyId = _createBounty(otherHub);
        assertEq(otherBountyId, 0);
        bytes32 otherRosterHash = otherHub.guardianRosterHash();
        address otherSolver = _solver(1);
        vm.prank(otherSolver);
        vm.expectRevert(CappedSubmissionGuard.UnauthorizedHub.selector);
        otherHub.submit(otherBountyId, keccak256("a"), otherRosterHash, "");
        assertEq(guard.submissionSeatsUsed(otherBountyId), 0);
    }

    function testTheHubBindingIsWriteOnceAndRequiredBeforeAnySubmission() public {
        CappedSubmissionGuard unbound =
            new CappedSubmissionGuard(guardOwner, DEFAULT_MAXIMUM_SUBMISSIONS);
        assertEq(unbound.hub(), address(0));

        // A Hub pointed at an unbound guard fails loudly on every submission rather than
        // admitting anyone, so a deployment that skips the bind cannot go unnoticed.
        ElgoraHub unguardedHub = _deployHub(address(unbound));
        uint256 bountyId = _createBounty(unguardedHub);
        bytes32 rosterHash = unguardedHub.guardianRosterHash();
        address solver = _solver(0);
        vm.prank(solver);
        vm.expectRevert(CappedSubmissionGuard.UnauthorizedHub.selector);
        unguardedHub.submit(bountyId, keccak256("a"), rosterHash, "");

        vm.startPrank(guardOwner);
        vm.expectRevert(CappedSubmissionGuard.InvalidHub.selector);
        unbound.bindHub(outsider);
        unbound.bindHub(address(unguardedHub));
        assertEq(unbound.hub(), address(unguardedHub));

        // Permanent: not even the owner can repoint a bound guard at another Hub and inherit
        // that Hub's bounty ids, so a compromised owner cannot reach across deployments.
        vm.expectRevert(CappedSubmissionGuard.HubAlreadyBound.selector);
        unbound.bindHub(address(hub));
        vm.stopPrank();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider)
        );
        unbound.bindHub(address(hub));

        _submit(unguardedHub, bountyId, solver, keccak256("a"), rosterHash);
        assertEq(unbound.submissionSeatsUsed(bountyId), 1);
    }

    function testAReenteringGuardCannotExceedTheCap() public {
        ReentrantSubmissionGuard reentrant = new ReentrantSubmissionGuard();
        vm.prank(protocolOwner);
        hub.setSubmissionGuard(address(reentrant));
        uint256 bountyId = _createBounty(hub);
        bytes32 rosterHash = hub.guardianRosterHash();
        reentrant.arm(hub, rosterHash);
        address solver = _solver(0);

        // The Hub writes its own state before calling out and holds the reentrancy lock while
        // it does, so the callback cannot record a second submission behind the first.
        vm.prank(solver);
        vm.expectRevert(ElgoraHub.ReentrantCall.selector);
        hub.submit(bountyId, keccak256("outer"), rosterHash, "");

        (, ElgoraHub.BountyState memory state) = hub.getBounty(bountyId);
        assertEq(state.submissionCount, 0);
        assertEq(hub.activeSubmissionCommitment(bountyId, solver), bytes32(0));
    }

    function testPerBountyOverrideBeatsTheDefaultAndClearsBackToIt() public {
        uint256 bountyId = _createBounty(hub);
        bytes32 rosterHash = hub.guardianRosterHash();

        vm.prank(guardOwner);
        guard.setBountyMaximumSubmissions(bountyId, 1);
        assertEq(guard.maximumSubmissions(bountyId), 1);

        _submit(hub, bountyId, _solver(0), keccak256("a"), rosterHash);
        address blocked = _solver(1);
        vm.prank(blocked);
        vm.expectRevert(ElgoraHub.SubmissionRejected.selector);
        hub.submit(bountyId, keccak256("b"), rosterHash, "");

        // 0 is "unset", not "no seats": clearing the override returns the bounty to the live
        // default, and the seat already taken still counts against it.
        vm.prank(guardOwner);
        guard.setBountyMaximumSubmissions(bountyId, 0);
        assertEq(guard.maximumSubmissions(bountyId), DEFAULT_MAXIMUM_SUBMISSIONS);
        assertEq(guard.remainingSubmissions(bountyId), DEFAULT_MAXIMUM_SUBMISSIONS - 1);
        _submit(hub, bountyId, _solver(1), keccak256("b"), rosterHash);
    }

    function testLoweringTheDefaultReachesBountiesAlreadyOpen() public {
        uint256 bountyId = _createBounty(hub);
        bytes32 rosterHash = hub.guardianRosterHash();
        _submit(hub, bountyId, _solver(0), keccak256("a"), rosterHash);

        vm.prank(guardOwner);
        guard.setDefaultMaximumSubmissions(1);

        assertEq(guard.remainingSubmissions(bountyId), 0);
        address latecomer = _solver(1);
        vm.prank(latecomer);
        vm.expectRevert(ElgoraHub.SubmissionRejected.selector);
        hub.submit(bountyId, keccak256("b"), rosterHash, "");
        // Nobody is evicted: the Solver already seated keeps their seat.
        _submit(hub, bountyId, _solver(0), keccak256("revised"), rosterHash);
    }

    function testOwnerControlsAreTwoStepAndRejectInvalidInput() public {
        vm.expectRevert(CappedSubmissionGuard.InvalidMaximumSubmissions.selector);
        new CappedSubmissionGuard(guardOwner, 0);

        vm.startPrank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider)
        );
        guard.setDefaultMaximumSubmissions(5);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider)
        );
        guard.setBountyMaximumSubmissions(0, 5);
        vm.stopPrank();

        vm.startPrank(guardOwner);
        vm.expectRevert(CappedSubmissionGuard.InvalidMaximumSubmissions.selector);
        guard.setDefaultMaximumSubmissions(0);

        // The guard's ownership is its own: it moves without touching the Hub, and only in two
        // steps, so a mistyped address cannot strand it. The Hub binding does not move with it.
        guard.transferOwnership(protocolOwner);
        assertEq(guard.owner(), guardOwner);
        assertEq(guard.pendingOwner(), protocolOwner);
        vm.stopPrank();

        vm.prank(protocolOwner);
        guard.acceptOwnership();
        assertEq(guard.owner(), protocolOwner);
        assertEq(guard.hub(), address(hub));
        assertEq(hub.owner(), protocolOwner);
    }

    function testSeatsAreCheapToSquatAndRaisingTheCapEvictsNobody() public {
        uint256 bountyId = _createBounty(hub);
        bytes32 rosterHash = hub.guardianRosterHash();

        // One actor, fresh wallets up to the cap: a few submit calls' worth of gas.
        for (uint256 i = 0; i < DEFAULT_MAXIMUM_SUBMISSIONS; i++) {
            _submit(hub, bountyId, _solver(i), keccak256(abi.encode(i)), rosterHash);
        }
        address honest = makeAddr("honest solver");
        vm.prank(honest);
        vm.expectRevert(ElgoraHub.SubmissionRejected.selector);
        hub.submit(bountyId, keccak256("honest"), rosterHash, "");

        // The owner's only lever adds seats and evicts nobody, so the squatter refills them.
        vm.prank(guardOwner);
        guard.setBountyMaximumSubmissions(bountyId, DEFAULT_MAXIMUM_SUBMISSIONS + 1);
        _submit(hub, bountyId, _solver(DEFAULT_MAXIMUM_SUBMISSIONS), keccak256("more"), rosterHash);
        vm.prank(honest);
        vm.expectRevert(ElgoraHub.SubmissionRejected.selector);
        hub.submit(bountyId, keccak256("honest"), rosterHash, "");

        // A bounty holding only junk costs the Poster only the Guardian fee.
        (ElgoraHub.BountyParameters memory parameters,) = hub.getBounty(bountyId);
        vm.warp(parameters.judgingDeadlineAt);
        vm.prank(guardian);
        hub.commitVerdict(
            bountyId,
            ElgoraHub.Outcome.NoValidSubmission,
            address(0),
            bytes32(0),
            keccak256("report"),
            ""
        );
        hub.settle(bountyId);
        uint256 guardianFee = (ESCROW_AMOUNT * 350) / 10_000;
        assertEq(hub.claimable(bountyId, poster), ESCROW_AMOUNT - guardianFee);
        assertEq(hub.treasuryFeeClaimable(), 0);
        assertEq(hub.guardianFeeClaimable(), guardianFee);
    }

    function testFuzzSeatsUsedEqualsDistinctSeatHolders(uint8[16] memory picks) public {
        uint256 bountyId = _createBounty(hub);
        bytes32 rosterHash = hub.guardianRosterHash();
        bool[4] memory seated;
        uint256 distinct;
        for (uint256 i = 0; i < picks.length; i++) {
            uint256 who = picks[i] % 4;
            address solver = _solver(who);
            if (!seated[who] && distinct == DEFAULT_MAXIMUM_SUBMISSIONS) {
                vm.prank(solver);
                vm.expectRevert(ElgoraHub.SubmissionRejected.selector);
                hub.submit(bountyId, keccak256(abi.encode(i)), rosterHash, "");
                continue;
            }
            _submit(hub, bountyId, solver, keccak256(abi.encode(i)), rosterHash);
            if (!seated[who]) {
                seated[who] = true;
                distinct++;
            }
            assertEq(guard.submissionSeatsUsed(bountyId), distinct);
            assertTrue(guard.holdsSubmissionSeat(bountyId, solver));
        }
    }

    function _deployHub(address submissionGuard) private returns (ElgoraHub) {
        ElgoraHub.Guardian[] memory roster = new ElgoraHub.Guardian[](1);
        roster[0] =
            ElgoraHub.Guardian({name: "Guardian", account: guardian, encryptionPublicKey: "key"});
        return new ElgoraHub(
            IERC20(address(usdc)),
            protocolOwner,
            ElgoraHub.InitialConfig({
                guardianRosterAdmin: guardian,
                guardianReviewWindow: 6 hours,
                treasuryRecipient: makeAddr("treasury"),
                guardianFeeRecipient: makeAddr("guardian fee recipient"),
                treasuryFeeBps: 150,
                guardianFeeBps: 350,
                minimumEscrowAmount: 1e6,
                maximumEscrowAmount: 1_000e6,
                minBountyDuration: MIN_BOUNTY_DURATION,
                maxBountyDuration: MAX_BOUNTY_DURATION,
                submissionGuard: submissionGuard,
                payoutScheme: address(scheme),
                coordinator: address(0),
                coordinatorGracePeriod: 1 hours
            }),
            roster
        );
    }

    function _createBounty(ElgoraHub target) private returns (uint256) {
        vm.startPrank(poster);
        usdc.approve(address(target), ESCROW_AMOUNT);
        uint256 bountyId = target.createBounty(
            keccak256("spec"), ESCROW_AMOUNT, uint64(block.timestamp + MIN_BOUNTY_DURATION + 1)
        );
        vm.stopPrank();
        return bountyId;
    }

    function _submit(
        ElgoraHub target,
        uint256 bountyId,
        address solver,
        bytes32 commitment,
        bytes32 rosterHash
    ) private {
        vm.prank(solver);
        target.submit(bountyId, commitment, rosterHash, "");
    }

    function _context(uint256 bountyId)
        private
        view
        returns (ISubmissionGuard.SubmissionContext memory)
    {
        (ElgoraHub.BountyParameters memory parameters,) = hub.getBounty(bountyId);
        return ISubmissionGuard.SubmissionContext({
            bountyId: bountyId,
            poster: parameters.poster,
            specCommitment: parameters.specCommitment,
            escrowAmount: parameters.escrowAmount,
            submissionDeadline: parameters.submissionDeadline,
            settlementTimeoutAt: parameters.settlementTimeoutAt,
            guardianRosterHash: parameters.guardianRosterHash,
            payoutScheme: parameters.payoutScheme
        });
    }

    function _solver(uint256 index) private returns (address) {
        return makeAddr(string.concat("solver ", vm.toString(index)));
    }
}
