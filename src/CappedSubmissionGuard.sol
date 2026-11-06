// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ISubmissionGuard} from "./ISubmissionGuard.sol";

/// @title CappedSubmissionGuard
/// @notice Admission policy that bounds how many Solvers one bounty may admit, so a Guardian
/// roster is never asked to review an unbounded pile. The counter lives here rather than in the
/// non-upgradeable Hub: every later change to how seats are counted, or to how many there are,
/// becomes a guard swap or an owner transaction instead of a Hub redeploy.
/// @dev One seat per Solver account. A Solver's first submission takes a seat and every later
/// revision reuses it, because the Hub keeps exactly one active commitment per Solver — so a
/// resubmission costs the roster nothing and must not cost the bounty a seat.
///
/// One guard serves exactly one Hub, bound once and permanently at deployment. Two roles keep
/// it that way and they are deliberately different addresses:
///
/// - `hub` is the only caller `canSubmit` will act for. Dropping `view` from that function made
///   it callable by anyone, so without this check an attacker could burn a bounty's seats by
///   calling the guard directly, never touching the Hub at all.
/// - `owner` is the protocol owner, and only sets policy: the seat count and per-bounty
///   overrides. It cannot be the Hub, which has no way to forward such a call.
///
/// The Hub binding is write-once rather than owner-settable, so not even a later-compromised
/// owner can repoint a guard at a different Hub or inherit another Hub's counters.
contract CappedSubmissionGuard is ISubmissionGuard, Ownable2Step {
    /// @notice The one ElgoraHub this guard serves. Set once, at deployment, and never again; the zero address means it is not bound yet and no caller can consume a seat.
    address public hub;

    /// @notice Seats a bounty gets when no per-bounty override is set; applies to bounties that are already open.
    uint256 public defaultMaximumSubmissions;

    /// @notice Per-bounty seat count overriding defaultMaximumSubmissions; 0 means unset.
    mapping(uint256 bountyId => uint256 maximum) public bountyMaximumSubmissions;

    /// @notice Seats taken so far, i.e. how many distinct Solver accounts have submitted to this bounty.
    mapping(uint256 bountyId => uint256 used) public submissionSeatsUsed;

    /// @notice Whether this Solver account already holds this bounty's seat and may keep revising its submission.
    mapping(uint256 bountyId => mapping(address solver => bool held)) public holdsSubmissionSeat;

    error InvalidMaximumSubmissions();
    error InvalidHub();
    error HubAlreadyBound();
    error UnauthorizedHub();

    event HubBound(address indexed hub);
    event DefaultMaximumSubmissionsUpdated(uint256 defaultMaximumSubmissions);
    event BountyMaximumSubmissionsUpdated(uint256 indexed bountyId, uint256 maximumSubmissions);
    event SubmissionSeatTaken(uint256 indexed bountyId, address indexed solver, uint256 seatsUsed);

    /// @notice Deploys a guard with its own ownership, independent of its Hub's: rotating the Hub owner does not move this guard, and this guard can be handed to a different operator without touching the Hub.
    /// @param initialOwner_ Address granted Ownable2Step ownership; expected to be the protocol owner.
    /// @param defaultMaximumSubmissions_ Day-zero seat count per bounty; must be nonzero.
    constructor(address initialOwner_, uint256 defaultMaximumSubmissions_) Ownable(initialOwner_) {
        _setDefaultMaximumSubmissions(defaultMaximumSubmissions_);
    }

    /// @notice Binds this guard to the one Hub it will ever serve. Callable once, by the owner, and irreversible. Until it is called every submission through this guard reverts, so a Hub pointed here before binding fails loudly rather than admitting anyone.
    /// @dev A setter rather than a constructor argument only because the Hub takes its guard's address at construction, so on a fresh deployment the guard has to exist first. Deploying a guard for a Hub that already exists passes that Hub straight in.
    /// @param hub_ The ElgoraHub this guard serves; must have code.
    function bindHub(address hub_) external onlyOwner {
        if (hub != address(0)) revert HubAlreadyBound();
        if (hub_.code.length == 0) revert InvalidHub();
        hub = hub_;
        emit HubBound(hub_);
    }

    /// @inheritdoc ISubmissionGuard
    /// @dev Writes at most two storage slots and runs no loop, so it adds a small constant to
    /// every Solver's submission gas. A guard that could grow unbounded here would make
    /// submissions progressively more expensive and eventually unsendable.
    function canSubmit(
        address submitter,
        SubmissionContext calldata context,
        uint256,
        bytes calldata
    ) external returns (bool) {
        // Also rejects every caller while unbound, since msg.sender is never the zero address.
        if (msg.sender != hub) revert UnauthorizedHub();

        uint256 bountyId = context.bountyId;
        if (holdsSubmissionSeat[bountyId][submitter]) return true;

        uint256 used = submissionSeatsUsed[bountyId];
        if (used >= maximumSubmissions(bountyId)) return false;

        // If the Hub reverts later in this same transaction, these writes revert with it, so
        // the seat count can never run ahead of the submissions actually accepted.
        holdsSubmissionSeat[bountyId][submitter] = true;
        uint256 usedAfter = used + 1;
        submissionSeatsUsed[bountyId] = usedAfter;
        emit SubmissionSeatTaken(bountyId, submitter, usedAfter);
        return true;
    }

    /// @notice Seats this bounty may fill: its own override when set, otherwise the live default.
    /// @param bountyId Id of the bounty on this guard's Hub.
    function maximumSubmissions(uint256 bountyId) public view returns (uint256) {
        uint256 bountyMaximum = bountyMaximumSubmissions[bountyId];
        return bountyMaximum == 0 ? defaultMaximumSubmissions : bountyMaximum;
    }

    /// @notice Seats still open on a bounty, for an operator reading the guard's state directly. A Solver already holding a seat may still submit at 0 remaining; see holdsSubmissionSeat.
    /// @param bountyId Id of the bounty on this guard's Hub.
    function remainingSubmissions(uint256 bountyId) external view returns (uint256) {
        uint256 maximum = maximumSubmissions(bountyId);
        uint256 used = submissionSeatsUsed[bountyId];
        return used >= maximum ? 0 : maximum - used;
    }

    /// @notice Owner sets the live default seat count; applies immediately, including to bounties already open.
    /// @param defaultMaximumSubmissions_ New seat count; must be nonzero.
    function setDefaultMaximumSubmissions(uint256 defaultMaximumSubmissions_) external onlyOwner {
        _setDefaultMaximumSubmissions(defaultMaximumSubmissions_);
    }

    /// @notice Owner overrides one bounty's seat count, or clears the override back to the default. Setting a maximum below the seats already taken stops further Solvers without evicting anyone.
    /// @param bountyId Id of the bounty on this guard's Hub.
    /// @param maximumSubmissions_ New seat count for this bounty; 0 clears the override.
    function setBountyMaximumSubmissions(uint256 bountyId, uint256 maximumSubmissions_)
        external
        onlyOwner
    {
        bountyMaximumSubmissions[bountyId] = maximumSubmissions_;
        emit BountyMaximumSubmissionsUpdated(bountyId, maximumSubmissions_);
    }

    function _setDefaultMaximumSubmissions(uint256 defaultMaximumSubmissions_) private {
        if (defaultMaximumSubmissions_ == 0) revert InvalidMaximumSubmissions();
        defaultMaximumSubmissions = defaultMaximumSubmissions_;
        emit DefaultMaximumSubmissionsUpdated(defaultMaximumSubmissions_);
    }
}
