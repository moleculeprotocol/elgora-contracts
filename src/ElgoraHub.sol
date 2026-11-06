// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3009} from "./IERC3009.sol";
import {IPayoutScheme} from "./IPayoutScheme.sol";
import {ISubmissionGuard} from "./ISubmissionGuard.sol";

/// @title ElgoraHub
/// @notice Escrow, lifecycle, submission, settlement, and claim authority for Elgora v0.
contract ElgoraHub is Ownable2Step {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_TOTAL_FEE_BPS = 1_000;
    uint8 public constant ESCROW_TOKEN_DECIMALS = 6;

    enum Status {
        Open,
        Awarded,
        NoValidSubmission,
        TimedOut
    }

    enum Outcome {
        NoValidSubmission,
        Awarded
    }

    /// @notice Immutable definitions snapshotted when a bounty is created.
    /// @param specCommitment keccak256 of the poster's exact approved spec Markdown bytes, derived off-chain; checked non-zero on-chain only.
    /// @param escrowAmount Amount of ESCROW_TOKEN, in its base units, deposited for this bounty and split out at settlement or timeout.
    /// @param guardianRosterHash Snapshot of guardianRosterHash (keccak256(abi.encode(...roster))) at creation; submissions must echo it back or revert as stale, commitVerdict() checks the caller against this pinned hash's membership, and settle() tallies over its members, regardless of later roster rotations.
    /// @param poster Address that created the bounty and receives timeout refunds and no-valid-submission payouts.
    /// @param submissionDeadline Unix timestamp (seconds) after which submit() stops accepting new submissions.
    /// @param judgingDeadlineAt Unix timestamp (seconds): submissionDeadline plus half the guardianReviewWindow at creation; commitVerdict() accepts revisions of an existing verdict only before this, though a Guardian's first-ever verdict is still accepted after it.
    /// @param treasuryFeeBps Protocol treasury fee snapshotted at creation, in basis points (parts per BPS_DENOMINATOR) of escrowAmount.
    /// @param guardianFeeBps Guardian fee snapshotted at creation, in basis points (parts per BPS_DENOMINATOR) of escrowAmount.
    /// @param settlementTimeoutAt Unix timestamp (seconds): submissionDeadline plus the guardianReviewWindow at creation; settle() reverts after this, timeoutSettlement() opens up.
    /// @param payoutScheme Payout scheme contract snapshotted at creation; the only scheme this bounty ever settles through — no verdict can name a different one, see commitVerdict.
    /// @param treasuryRecipient Recipient configured for the treasury fee at settlement; informational only, the accrued pool is claimed by whoever is the live treasuryRecipient, see claimFees.
    /// @param guardianFeeRecipient Recipient configured for the guardian fee at settlement; informational only, the accrued pool is claimed by whoever is the live guardianFeeRecipient, see claimFees.
    struct BountyParameters {
        bytes32 specCommitment;
        uint256 escrowAmount;
        bytes32 guardianRosterHash;
        address poster;
        uint64 submissionDeadline;
        uint64 judgingDeadlineAt;
        uint16 treasuryFeeBps;
        uint16 guardianFeeBps;
        uint64 settlementTimeoutAt;
        address payoutScheme;
        address treasuryRecipient;
        address guardianFeeRecipient;
    }

    /// @notice Mutable state advanced only by ElgoraHub lifecycle transitions.
    /// @param status Current lifecycle stage; gates which functions may act on the bounty.
    /// @param winner Winning solver once settled Awarded; zero address otherwise.
    /// @param submissionCount Running count of accepted submissions, passed to the submission guard as context.
    /// @param consensusReachedAt Unix timestamp (seconds) the bounty's tally first crossed the two-thirds threshold on any outcome; 0 if it never has. The coordinator-exclusive window starts no earlier than judgingDeadlineAt; later verdict changes never move this timestamp, even if the tally later disagrees and re-agrees.
    /// @param awardedPayoutData Guardian-agreed payout data forwarded to the pinned payout scheme, copied from the winning verdict tuple once settled Awarded; empty otherwise. See commitVerdict and claimAward.
    struct BountyState {
        Status status;
        address winner;
        uint256 submissionCount;
        uint64 consensusReachedAt;
        bytes awardedPayoutData;
    }

    /// @notice One on-chain Guardian identity and encryption recipient.
    /// @param name Human-readable display name, carried in GuardianRosterHashUpdated and used for off-chain roster display.
    /// @param account Guardian's on-chain address, tracked in the roster membership index.
    /// @param encryptionPublicKey Unpadded base64url encoding (43 chars) of the guardian's 32-byte X25519 HPKE public key, used off-chain to encrypt delivery material to them.
    struct Guardian {
        string name;
        address account;
        string encryptionPublicKey;
    }

    /// @notice Append-only snapshot of the ordered roster's member accounts at the moment guardianRosterHash last changed; a bounty pins the hash and looks its members up here rather than duplicating them.
    /// @param members Ordered Guardian accounts live when this hash was current; see guardianRoster for the full struct at the current roster.
    struct RosterSnapshot {
        address[] members;
    }

    /// @notice One Guardian's recorded outcome for one bounty; see commitVerdict.
    /// @param committed Whether this Guardian has ever recorded a verdict for this bounty; distinguishes an explicit Outcome.NoValidSubmission(0) from never having voted.
    /// @param outcome Awarded or NoValidSubmission, as this Guardian sees it.
    /// @param winner Solver this Guardian names as winner; zero unless outcome is Awarded.
    /// @param awardedSubmissionCommitment Submission commitment this Guardian is awarding; zero unless outcome is Awarded.
    /// @param reportCommitment keccak256 of this Guardian's exact evaluation Markdown bytes, derived off-chain; checked non-zero on-chain only.
    /// @param payoutData Data this Guardian is forwarding to the bounty's pinned payout scheme once settled; interpreted entirely by that scheme (e.g. a merkle root), never by ElgoraHub itself; must be empty unless outcome is Awarded. Part of the same match-exactly tuple as winner and awardedSubmissionCommitment, so no Guardian, individually or as part of a quorum, can supply payout data the others didn't also agree on.
    struct Verdict {
        bool committed;
        Outcome outcome;
        address winner;
        bytes32 awardedSubmissionCommitment;
        bytes32 reportCommitment;
        bytes payoutData;
    }

    /// @notice In-memory result of _tally; a struct rather than a wide return tuple to keep stack pressure low without via_ir. See _tally.
    struct TallyResult {
        bool reached;
        Outcome outcome;
        address winner;
        bytes32 submissionCommitment;
        bytes payoutData;
        address[] supporters;
        bytes32[] reportCommitments;
    }

    /// @notice One signed EIP-3009 escrow authorization; see createBountyWithAuthorization and IERC3009.receiveWithAuthorization for each field.
    struct EscrowAuthorization {
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Deployment-time seed for the mutable config state variables below; see those for field meanings.
    struct InitialConfig {
        address guardianRosterAdmin;
        uint64 guardianReviewWindow;
        address treasuryRecipient;
        address guardianFeeRecipient;
        uint16 treasuryFeeBps;
        uint16 guardianFeeBps;
        uint256 minimumEscrowAmount;
        uint256 maximumEscrowAmount;
        uint64 minBountyDuration;
        uint64 maxBountyDuration;
        address submissionGuard;
        address payoutScheme;
        address coordinator;
        uint64 coordinatorGracePeriod;
    }

    /// @notice Escrow ERC-20 for every bounty on this Hub; decimals() had to equal ESCROW_TOKEN_DECIMALS at construction.
    IERC20 public immutable ESCROW_TOKEN;

    /// @notice Address that alone may add, remove, or replace Guardians on the roster; snapshotted per bounty at creation as an informational record only, not checked by settle(). Formerly named guardianSettlementSigner; see protocol.md for the rename note.
    address public guardianRosterAdmin;
    /// @notice Duration in seconds, added to a new bounty's submissionDeadline (a Unix timestamp) to get its settlementTimeoutAt.
    uint64 public guardianReviewWindow;
    /// @notice Address entitled to claim the entire accrued treasuryFeeClaimable pool via claimFees(); whoever holds this role live gets it all, past and present.
    address public treasuryRecipient;
    /// @notice Address entitled to claim the entire accrued guardianFeeClaimable pool via claimFees(); whoever holds this role live gets it all, past and present.
    address public guardianFeeRecipient;
    /// @notice Treasury fee in basis points (parts per BPS_DENOMINATOR = 10_000) applied to bounties created after this is set.
    uint16 public treasuryFeeBps;
    /// @notice Guardian fee in basis points (parts per BPS_DENOMINATOR = 10_000) applied to bounties created after this is set.
    uint16 public guardianFeeBps;
    /// @notice Lower bound on a new bounty's escrowAmount, in escrow-token base units (6 decimals).
    uint256 public minimumEscrowAmount;
    /// @notice Upper bound on a new bounty's escrowAmount, in escrow-token base units (6 decimals).
    uint256 public maximumEscrowAmount;
    /// @notice Minimum seconds a new bounty's submissionDeadline must sit beyond the createBounty call's block.timestamp.
    uint64 public minBountyDuration;
    /// @notice Maximum seconds a new bounty's submissionDeadline may sit beyond the createBounty call's block.timestamp; bounds how long a bounty can stay open.
    uint64 public maxBountyDuration;
    /// @notice Live submission-guard contract called on every submit(); not snapshotted, so a swap applies to open bounties too.
    ISubmissionGuard public submissionGuard;
    /// @notice Payout scheme snapshotted into new bounties at creation; parameter-free settle(bountyId) always uses the bounty's own pinned snapshot.
    IPayoutScheme public payoutScheme;
    /// @notice keccak256(abi.encode(guardianRoster)) over the current ordered roster; snapshotted per bounty at creation and doubles as the lookup key into guardianRosterSnapshots/isGuardianAtRosterHash for that bounty's pinned membership.
    bytes32 public guardianRosterHash;
    /// @notice Address that alone may call settle() during its grace period; the period starts at the later of first consensus and judgingDeadlineAt, and settlement is permissionless immediately when unset.
    address public coordinator;
    /// @notice Seconds after the later of a bounty's consensusReachedAt and judgingDeadlineAt before settle() opens to any caller, not just coordinator.
    uint64 public coordinatorGracePeriod;
    /// @notice Total bounties ever created; doubles as the id assigned to the next bounty.
    uint256 public bountyCount;

    mapping(uint256 bountyId => BountyParameters parameters) private bountyParameters;
    mapping(uint256 bountyId => BountyState state) private bountyStates;
    mapping(address guardian => uint256 indexPlusOne) private guardianIndex;
    Guardian[] private guardianRoster;
    /// @notice Ordered member snapshot for each past and current roster hash; see RosterSnapshot and guardianRosterHash.
    mapping(bytes32 rosterHash => RosterSnapshot snapshot) private guardianRosterSnapshots;
    /// @notice O(1) membership check: was `guardian` on the roster identified by `rosterHash`; see guardianRosterSnapshots for the ordered form.
    mapping(bytes32 rosterHash => mapping(address guardian => bool isMember)) public
        isGuardianAtRosterHash;
    /// @notice Each Guardian's recorded outcome for a bounty; one slot per (bountyId, guardian), overwritten by revision; see commitVerdict.
    mapping(uint256 bountyId => mapping(address guardian => Verdict verdict)) public verdicts;

    /// @notice Each solver's latest accepted submissionCommitment for a bounty (keccak256 of their off-chain envelope); a resubmit overwrites, it does not append.
    mapping(uint256 bountyId => mapping(address solver => bytes32 commitment)) public
        activeSubmissionCommitment;
    /// @notice Token amount, in escrow-token base units, each recipient may pull via claim()/claimMany() for a given bounty; excludes treasury/guardian fees, see treasuryFeeClaimable/guardianFeeClaimable, and excludes an Awarded bounty's winner pool, see claimAward.
    mapping(uint256 bountyId => mapping(address recipient => uint256 amount)) public claimable;
    /// @notice Cumulative amount already paid out from an Awarded bounty's winner pool via claimAward(); never exceeds that bounty's winner pool, see claimAward.
    mapping(uint256 bountyId => uint256 amount) public winnerPoolClaimed;
    /// @notice Total treasury fee accrued across every Awarded bounty; only the live treasuryRecipient may claim it, via claimFees().
    uint256 public treasuryFeeClaimable;
    /// @notice Total guardian fee accrued across every bounty ever settled; only the live guardianFeeRecipient may claim it, via claimFees().
    uint256 public guardianFeeClaimable;

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private reentrancyStatus = NOT_ENTERED;
    bool private pauseRequested;
    bool public pausingDisabled;

    error InvalidAddress();
    error InvalidContract();
    error InvalidBounty();
    error InvalidCommitment();
    error InvalidDeadline();
    error InvalidEscrowAmount();
    error InvalidEscrowBounds();
    error InvalidDurationBounds();
    error InvalidStatus();
    error InvalidWinner();
    error InvalidGuardian();
    error GuardianAlreadyExists();
    error GuardianNotFound();
    error InvalidTokenDecimals(uint8 decimals);
    error DeadlinePassed();
    error DeadlineNotPassed();
    error SettlementWindowExpired();
    error NotGuardianRosterAdmin();
    error NoActiveSubmission();
    error StaleGuardianRoster();
    error SubmissionRejected();
    error InvalidPayout();
    error NothingToClaim();
    error TransferFromFailed();
    error ReentrantCall();
    error InvalidFeeConfig();
    error ContractPaused();
    error PauseUnavailable();
    error NotRosterGuardian();
    error InvalidVerdict();
    error JudgingDeadlinePassed();
    error ConsensusNotReached();
    error NotCoordinator();

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed poster,
        bytes32 specCommitment,
        bytes32 guardianRosterHash,
        uint256 escrowAmount,
        uint64 submissionDeadline,
        uint64 judgingDeadlineAt,
        uint64 settlementTimeoutAt,
        address guardianRosterAdmin,
        address payoutScheme,
        address treasuryRecipient,
        address guardianFeeRecipient,
        uint16 treasuryFeeBps,
        uint16 guardianFeeBps
    );
    event SubmissionRecorded(
        uint256 indexed bountyId,
        address indexed solver,
        bytes32 submissionCommitment,
        bytes32 guardianRosterHash,
        uint256 submissionCount
    );
    event VerdictCommitted(
        uint256 indexed bountyId,
        address indexed guardian,
        Outcome outcome,
        address winner,
        bytes32 awardedSubmissionCommitment,
        bytes32 reportCommitment,
        bytes payoutData
    );
    event ConsensusReached(
        uint256 indexed bountyId, Outcome indexed outcome, address winner, address payoutScheme
    );
    event Settled(
        uint256 indexed bountyId,
        Status indexed status,
        address indexed winner,
        address payoutScheme,
        address[] supportingGuardians,
        bytes32[] reportCommitments
    );
    event ClaimQueued(uint256 indexed bountyId, address indexed recipient, uint256 amount);
    event SettlementTimedOut(uint256 indexed bountyId, address indexed poster, uint256 amount);
    event Claimed(uint256 indexed bountyId, address indexed claimant, uint256 amount);
    event FeesClaimed(address indexed recipient, uint256 treasuryAmount, uint256 guardianAmount);
    /// @notice Carries its own preimage: the ordered roster the hash was computed over, so an off-chain reader transcribes a roster instead of replaying add/remove logs and guessing at their order.
    event GuardianRosterHashUpdated(bytes32 indexed guardianRosterHash, Guardian[] roster);
    event GuardianRosterAdminUpdated(address indexed guardianRosterAdmin);
    event CoordinatorUpdated(address indexed coordinator);
    event CoordinatorGracePeriodUpdated(uint64 coordinatorGracePeriod);
    event FeeConfigUpdated(
        address indexed treasuryRecipient,
        address indexed guardianFeeRecipient,
        uint16 treasuryFeeBps,
        uint16 guardianFeeBps
    );
    event GuardianReviewWindowUpdated(uint64 guardianReviewWindow);
    event EscrowBoundsUpdated(uint256 minimumEscrowAmount, uint256 maximumEscrowAmount);
    event BountyDurationBoundsUpdated(uint64 minBountyDuration, uint64 maxBountyDuration);
    event SubmissionGuardUpdated(address indexed submissionGuard);
    event PayoutSchemeUpdated(address indexed payoutScheme);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event PauseAuthorityDisabled(address indexed account);

    /// @notice Deploys one immutable Hub bound to one escrow token, seeded with initial config and Guardian roster.
    /// @param escrowToken_ ERC-20 to escrow for every bounty; decimals() must equal ESCROW_TOKEN_DECIMALS.
    /// @param initialOwner_ Address granted Ownable2Step ownership; see the owner-only setters below.
    /// @param config Initial values for the mutable config state variables; see InitialConfig.
    /// @param initialGuardianRoster Guardian roster to seed at deployment; must be nonempty.
    constructor(
        IERC20 escrowToken_,
        address initialOwner_,
        InitialConfig memory config,
        Guardian[] memory initialGuardianRoster
    ) Ownable(initialOwner_) {
        address tokenAddress = address(escrowToken_);
        if (tokenAddress == address(0) || tokenAddress.code.length == 0) revert InvalidAddress();
        uint8 tokenDecimals = IERC20Metadata(tokenAddress).decimals();
        if (tokenDecimals != ESCROW_TOKEN_DECIMALS) {
            revert InvalidTokenDecimals(tokenDecimals);
        }
        ESCROW_TOKEN = escrowToken_;

        _setGuardianRosterAdmin(config.guardianRosterAdmin);
        _setGuardianReviewWindow(config.guardianReviewWindow);
        _setFeeConfig(
            config.treasuryRecipient,
            config.guardianFeeRecipient,
            config.treasuryFeeBps,
            config.guardianFeeBps
        );
        _setEscrowBounds(config.minimumEscrowAmount, config.maximumEscrowAmount);
        _setBountyDurationBounds(config.minBountyDuration, config.maxBountyDuration);
        _setSubmissionGuard(config.submissionGuard);
        _setPayoutScheme(config.payoutScheme);
        _setCoordinator(config.coordinator);
        _setCoordinatorGracePeriod(config.coordinatorGracePeriod);

        if (initialGuardianRoster.length == 0) revert InvalidGuardian();
        for (uint256 i = 0; i < initialGuardianRoster.length; i++) {
            Guardian memory guardian = initialGuardianRoster[i];
            _addGuardian(guardian.name, guardian.account, guardian.encryptionPublicKey);
        }
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() internal {
        if (reentrancyStatus == ENTERED) revert ReentrantCall();
        reentrancyStatus = ENTERED;
    }

    function _nonReentrantAfter() internal {
        reentrancyStatus = NOT_ENTERED;
    }

    modifier bountyExists(uint256 bountyId) {
        _bountyExists(bountyId);
        _;
    }

    /// @dev poster is required nonzero at creation and never cleared, so its zero-ness alone
    /// distinguishes a real bounty id from one never created, with no separate exists flag.
    function _bountyExists(uint256 bountyId) internal view {
        if (bountyParameters[bountyId].poster == address(0)) revert InvalidBounty();
    }

    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    function _whenNotPaused() internal view {
        if (paused()) revert ContractPaused();
    }

    modifier onlyGuardianRosterAdmin() {
        _onlyGuardianRosterAdmin();
        _;
    }

    function _onlyGuardianRosterAdmin() internal view {
        if (msg.sender != guardianRosterAdmin) {
            revert NotGuardianRosterAdmin();
        }
    }

    /// @notice Poster opens a bounty: escrows funds from their allowance and snapshots current protocol config for its whole lifecycle.
    /// @param specCommitment keccak256 of the exact approved spec Markdown; see BountyParameters.specCommitment.
    /// @param escrowAmount Amount of ESCROW_TOKEN to escrow, in base units; must fall within [minimumEscrowAmount, maximumEscrowAmount].
    /// @param submissionDeadline Unix timestamp (seconds); must sit between minBountyDuration and maxBountyDuration beyond now, inclusive.
    /// @return bountyId Id assigned to the new bounty, used in every other bounty-scoped call.
    function createBounty(bytes32 specCommitment, uint256 escrowAmount, uint64 submissionDeadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 bountyId)
    {
        _checkBountyTerms(specCommitment, escrowAmount, submissionDeadline);
        uint256 balanceBefore = ESCROW_TOKEN.balanceOf(address(this));
        ESCROW_TOKEN.safeTransferFrom(msg.sender, address(this), escrowAmount);
        _checkExactEscrowReceived(balanceBefore, escrowAmount);
        bountyId = _openBounty(specCommitment, escrowAmount, submissionDeadline);
    }

    /// @notice Same bounty, funded by one signed EIP-3009 authorization instead of a standing allowance, so a Poster signs once and sends one transaction rather than approving first.
    /// @dev The authorization's signer is always msg.sender: this entry point takes no `from`, so nobody else can spend a Poster's authorization and no relay exists to front-run. That is also why a plain random nonce is enough and no term binding is needed — an authorization is only ever usable by the wallet that signed it, in a transaction that wallet sent. createBounty stays exactly as it is beside this: a Safe or any other contract wallet keeps funding through its allowance.
    /// @param specCommitment keccak256 of the exact approved spec Markdown; see BountyParameters.specCommitment.
    /// @param escrowAmount Amount of ESCROW_TOKEN to escrow, in base units; must equal the authorization's value exactly and fall within [minimumEscrowAmount, maximumEscrowAmount].
    /// @param submissionDeadline Unix timestamp (seconds); must sit between minBountyDuration and maxBountyDuration beyond now, inclusive.
    /// @param authorization The caller's signed EIP-3009 authorization over exactly escrowAmount to this Hub; see EscrowAuthorization.
    /// @return bountyId Id assigned to the new bounty, used in every other bounty-scoped call.
    function createBountyWithAuthorization(
        bytes32 specCommitment,
        uint256 escrowAmount,
        uint64 submissionDeadline,
        EscrowAuthorization calldata authorization
    ) external nonReentrant whenNotPaused returns (uint256 bountyId) {
        _checkBountyTerms(specCommitment, escrowAmount, submissionDeadline);
        uint256 balanceBefore = ESCROW_TOKEN.balanceOf(address(this));
        // receiveWithAuthorization, never transferWithAuthorization: the transfer variant can be
        // redeemed by anyone calling the token directly, which would deposit escrow into this
        // Hub with no bounty created and no way to attribute it. This one requires the token's
        // caller to be the recipient, so the only way to spend the authorization is through
        // this function, which creates the bounty in the same transaction or reverts entirely.
        IERC3009(address(ESCROW_TOKEN))
            .receiveWithAuthorization(
                msg.sender,
                address(this),
                escrowAmount,
                authorization.validAfter,
                authorization.validBefore,
                authorization.nonce,
                authorization.v,
                authorization.r,
                authorization.s
            );
        _checkExactEscrowReceived(balanceBefore, escrowAmount);
        bountyId = _openBounty(specCommitment, escrowAmount, submissionDeadline);
    }

    function _checkBountyTerms(
        bytes32 specCommitment,
        uint256 escrowAmount,
        uint64 submissionDeadline
    ) private view {
        if (specCommitment == bytes32(0)) revert InvalidCommitment();
        if (escrowAmount < minimumEscrowAmount || escrowAmount > maximumEscrowAmount) {
            revert InvalidEscrowAmount();
        }
        if (
            block.timestamp > type(uint64).max - minBountyDuration
                || submissionDeadline < block.timestamp + minBountyDuration
                || submissionDeadline > block.timestamp + maxBountyDuration
                || submissionDeadline > type(uint64).max - guardianReviewWindow
        ) revert InvalidDeadline();
    }

    /// @dev Prevents creation of bounties with fee-on-transfer tokens, and holds every funding
    /// path to the same rule: this Hub's balance rose by exactly the declared escrow, or the
    /// whole transaction reverts.
    function _checkExactEscrowReceived(uint256 balanceBefore, uint256 escrowAmount) private view {
        uint256 received = ESCROW_TOKEN.balanceOf(address(this)) - balanceBefore;
        if (received != escrowAmount) revert TransferFromFailed();
    }

    /// @dev Records the bounty once its escrow is in hand. msg.sender is the Poster on every
    /// funding path, since neither entry point accepts a caller-supplied Poster address.
    function _openBounty(bytes32 specCommitment, uint256 escrowAmount, uint64 submissionDeadline)
        private
        returns (uint256 bountyId)
    {
        uint64 snapshotSettlementTimeoutAt = submissionDeadline + guardianReviewWindow;
        uint64 snapshotJudgingDeadlineAt = submissionDeadline + guardianReviewWindow / 2;

        bountyId = bountyCount;
        bountyCount = bountyId + 1;

        BountyParameters memory parameters = BountyParameters({
            poster: msg.sender,
            specCommitment: specCommitment,
            escrowAmount: escrowAmount,
            submissionDeadline: submissionDeadline,
            judgingDeadlineAt: snapshotJudgingDeadlineAt,
            settlementTimeoutAt: snapshotSettlementTimeoutAt,
            guardianRosterHash: guardianRosterHash,
            payoutScheme: address(payoutScheme),
            treasuryRecipient: treasuryRecipient,
            guardianFeeRecipient: guardianFeeRecipient,
            treasuryFeeBps: treasuryFeeBps,
            guardianFeeBps: guardianFeeBps
        });
        bountyParameters[bountyId] = parameters;
        bountyStates[bountyId] = BountyState({
            status: Status.Open,
            winner: address(0),
            submissionCount: 0,
            consensusReachedAt: 0,
            awardedPayoutData: ""
        });

        _emitBountyCreated(bountyId, parameters);
    }

    /// @notice Solver records or replaces their active submission commitment for an open bounty.
    /// @param bountyId Id of the target bounty; see getBounty.
    /// @param submissionCommitment keccak256 of the solver's off-chain submission envelope; see activeSubmissionCommitment.
    /// @param submittedGuardianRosterHash Must equal the bounty's snapshotted guardianRosterHash or the call reverts as stale.
    /// @param extraData Opaque bytes forwarded to the live submissionGuard's canSubmit() admission check.
    /// @dev canSubmit is not a STATICCALL — a guard may keep admission state of its own — so
    /// this is nonReentrant and writes its own state before calling out. See ISubmissionGuard.
    function submit(
        uint256 bountyId,
        bytes32 submissionCommitment,
        bytes32 submittedGuardianRosterHash,
        bytes calldata extraData
    ) external nonReentrant whenNotPaused bountyExists(bountyId) {
        BountyParameters storage parameters = bountyParameters[bountyId];
        BountyState storage state = bountyStates[bountyId];
        if (state.status != Status.Open) revert InvalidStatus();
        if (block.timestamp >= parameters.submissionDeadline) revert DeadlinePassed();
        if (submissionCommitment == bytes32(0)) revert InvalidCommitment();
        if (submittedGuardianRosterHash != parameters.guardianRosterHash) {
            revert StaleGuardianRoster();
        }

        ISubmissionGuard.SubmissionContext memory context = ISubmissionGuard.SubmissionContext({
            bountyId: bountyId,
            poster: parameters.poster,
            specCommitment: parameters.specCommitment,
            escrowAmount: parameters.escrowAmount,
            submissionDeadline: parameters.submissionDeadline,
            settlementTimeoutAt: parameters.settlementTimeoutAt,
            guardianRosterHash: parameters.guardianRosterHash,
            payoutScheme: parameters.payoutScheme
        });

        // Checks-effects-interactions: canSubmit is a real CALL into a swappable contract, so
        // record this submission before asking and let a rejection revert the whole
        // transaction. A guard that calls back into submit() therefore observes post-write
        // state, and correctness does not rest on the nonReentrant modifier alone.
        uint256 countBefore = state.submissionCount;
        uint256 countAfter = countBefore + 1;
        state.submissionCount = countAfter;
        activeSubmissionCommitment[bountyId][msg.sender] = submissionCommitment;

        // countBefore, not countAfter: the guard is deciding about this very submission, so it
        // sees how many were accepted ahead of it.
        if (!submissionGuard.canSubmit(msg.sender, context, countBefore, extraData)) {
            revert SubmissionRejected();
        }

        emit SubmissionRecorded(
            bountyId, msg.sender, submissionCommitment, submittedGuardianRosterHash, countAfter
        );
    }

    /// @notice A member of the bounty's pinned roster records or revises its verdict; one slot per (bountyId, msg.sender), a second call overwrites the first. A verdict decides outcome, winner, and payout data only — the payout scheme that executes on Awarded is always the bounty's own pinned parameters.payoutScheme; no Guardian, individually or as a quorum, can name a different one.
    /// @param bountyId Id of the target bounty; caller must be a member of its snapshotted guardianRosterHash.
    /// @param outcome Awarded (winner_ becomes eligible to claim the winner pool via claimAward) or NoValidSubmission (pool queues back to the poster), as this Guardian sees it.
    /// @param winner_ Solver this Guardian names as winner; must be nonzero for Awarded, must be the zero address otherwise.
    /// @param awardedSubmissionCommitment Submission commitment this Guardian is awarding; must be nonzero for Awarded, must be zero otherwise.
    /// @param reportCommitment keccak256 of this Guardian's exact canonical evaluation Markdown; see Verdict.reportCommitment.
    /// @param payoutData Data this Guardian is forwarding to the pinned payout scheme once settled; must be empty for NoValidSubmission; see Verdict.payoutData.
    function commitVerdict(
        uint256 bountyId,
        Outcome outcome,
        address winner_,
        bytes32 awardedSubmissionCommitment,
        bytes32 reportCommitment,
        bytes calldata payoutData
    ) external whenNotPaused bountyExists(bountyId) {
        BountyParameters storage parameters = bountyParameters[bountyId];
        BountyState storage state = bountyStates[bountyId];
        if (state.status != Status.Open) revert InvalidStatus();
        if (!isGuardianAtRosterHash[parameters.guardianRosterHash][msg.sender]) {
            revert NotRosterGuardian();
        }
        if (reportCommitment == bytes32(0)) revert InvalidCommitment();
        if (outcome == Outcome.Awarded) {
            if (winner_ == address(0) || awardedSubmissionCommitment == bytes32(0)) {
                revert InvalidVerdict();
            }
        } else if (
            winner_ != address(0) || awardedSubmissionCommitment != bytes32(0)
                || payoutData.length != 0
        ) {
            revert InvalidVerdict();
        }

        Verdict storage verdict = verdicts[bountyId][msg.sender];
        bool isFirstEver = !verdict.committed;
        if (!isFirstEver && block.timestamp >= parameters.judgingDeadlineAt) {
            revert JudgingDeadlinePassed();
        }

        verdict.committed = true;
        verdict.outcome = outcome;
        verdict.winner = winner_;
        verdict.awardedSubmissionCommitment = awardedSubmissionCommitment;
        verdict.reportCommitment = reportCommitment;
        verdict.payoutData = payoutData;

        emit VerdictCommitted(
            bountyId,
            msg.sender,
            outcome,
            winner_,
            awardedSubmissionCommitment,
            reportCommitment,
            payoutData
        );

        if (state.consensusReachedAt == 0) {
            _maybeRecordConsensus(bountyId, parameters, state);
        }
    }

    /// @dev Only called by commitVerdict while state.consensusReachedAt is still 0, so a later
    /// tally that disagrees and re-agrees can never overwrite the first-consensus timestamp.
    function _maybeRecordConsensus(
        uint256 bountyId,
        BountyParameters storage parameters,
        BountyState storage state
    ) private {
        TallyResult memory result = _tally(bountyId, parameters);
        if (!result.reached) return;
        state.consensusReachedAt = uint64(block.timestamp);
        emit ConsensusReached(bountyId, result.outcome, result.winner, parameters.payoutScheme);
    }

    /// @notice Anyone settles an open bounty once its pinned roster's verdicts agree two-thirds on one outcome; needs nothing from the caller beyond the bounty id. Waits for judgingDeadlineAt so every Guardian's revision window has actually closed before anything can become final.
    /// @param bountyId Id of the target bounty.
    function settle(uint256 bountyId) external nonReentrant whenNotPaused bountyExists(bountyId) {
        BountyParameters storage parameters = bountyParameters[bountyId];
        BountyState storage state = bountyStates[bountyId];
        if (state.status != Status.Open) revert InvalidStatus();
        if (block.timestamp < parameters.judgingDeadlineAt) revert DeadlineNotPassed();
        if (block.timestamp >= parameters.settlementTimeoutAt) revert SettlementWindowExpired();

        _checkCoordinatorGate(parameters, state);
        _applySettlement(bountyId, parameters, state);
    }

    /// @dev Re-tallying never happens here — settle() always re-derives the outcome itself, so
    /// this only ever gates *who* may call, never *what* gets settled.
    function _checkCoordinatorGate(BountyParameters storage parameters, BountyState storage state)
        private
        view
    {
        address liveCoordinator = coordinator;
        if (liveCoordinator == address(0) || msg.sender == liveCoordinator) return;
        uint256 graceStartsAt = state.consensusReachedAt;
        if (parameters.judgingDeadlineAt > graceStartsAt) {
            graceStartsAt = parameters.judgingDeadlineAt;
        }
        if (block.timestamp < graceStartsAt + coordinatorGracePeriod) revert NotCoordinator();
    }

    /// @dev Re-tallies fresh rather than trusting whatever was true when consensusReachedAt was
    /// first set, so a payout always reflects the current agreed outcome, never a stale one.
    function _applySettlement(
        uint256 bountyId,
        BountyParameters storage parameters,
        BountyState storage state
    ) private {
        TallyResult memory result = _tally(bountyId, parameters);
        if (!result.reached) revert ConsensusNotReached();

        Status finalStatus = _settleOutcome(bountyId, parameters, result);
        state.status = finalStatus;
        state.winner = result.winner;

        emit Settled(
            bountyId,
            finalStatus,
            result.winner,
            parameters.payoutScheme,
            result.supporters,
            result.reportCommitments
        );
    }

    /// @dev Guarantees the full escrowAmount is accounted for across fees plus winner pool or
    /// refund; re-checks the winner still holds the agreed submission, in case it changed since.
    function _settleOutcome(
        uint256 bountyId,
        BountyParameters storage parameters,
        TallyResult memory result
    ) private returns (Status finalStatus) {
        (uint256 treasuryAmount, uint256 guardianFeeAmount, uint256 winnerPool) = _settlementAmounts(
            parameters.escrowAmount, parameters.treasuryFeeBps, parameters.guardianFeeBps
        );

        if (result.outcome == Outcome.Awarded) {
            if (activeSubmissionCommitment[bountyId][result.winner] != result.submissionCommitment)
            {
                revert NoActiveSubmission();
            }
            bountyStates[bountyId].awardedPayoutData = result.payoutData;
            treasuryFeeClaimable += treasuryAmount;
            emit ClaimQueued(bountyId, parameters.treasuryRecipient, treasuryAmount);
            finalStatus = Status.Awarded;
        } else {
            uint256 posterRefund = winnerPool + treasuryAmount;
            if (bountyStates[bountyId].submissionCount == 0) {
                posterRefund += guardianFeeAmount;
                guardianFeeAmount = 0;
            }
            claimable[bountyId][parameters.poster] += posterRefund;
            emit ClaimQueued(bountyId, parameters.poster, posterRefund);
            finalStatus = Status.NoValidSubmission;
        }

        guardianFeeClaimable += guardianFeeAmount;
        emit ClaimQueued(bountyId, parameters.guardianFeeRecipient, guardianFeeAmount);
    }

    /// @notice Finds the first outcome/winner/submission/payoutData tuple with at least ceil(2 * rosterSize / 3) agreeing verdicts among the bounty's pinned roster, and the supporters behind it. The payout scheme contract itself is never part of the tuple Guardians agree on — it is always the bounty's own pinned parameters.payoutScheme; see commitVerdict.
    /// @dev "First" doubles as "only": two distinct tuples can never both clear a two-thirds
    /// threshold at once, since that would need over the full roster's worth of verdicts.
    /// @param bountyId Id of the target bounty.
    /// @param parameters The bounty's storage parameters; passed in to avoid a second SLOAD lookup at call sites that already hold it.
    function _tally(uint256 bountyId, BountyParameters storage parameters)
        private
        view
        returns (TallyResult memory result)
    {
        address[] storage members = guardianRosterSnapshots[parameters.guardianRosterHash].members;
        uint256 rosterSize = members.length;
        uint256 threshold = (2 * rosterSize + 2) / 3;

        for (uint256 i = 0; i < rosterSize; i++) {
            Verdict storage candidate = verdicts[bountyId][members[i]];
            if (!candidate.committed) continue;

            uint256 agreeing = _countAgreeing(bountyId, members, candidate);
            if (agreeing < threshold) continue;

            result.reached = true;
            result.outcome = candidate.outcome;
            result.winner = candidate.winner;
            result.submissionCommitment = candidate.awardedSubmissionCommitment;
            result.payoutData = candidate.payoutData;
            (result.supporters, result.reportCommitments) =
                _collectSupporters(bountyId, members, result, agreeing);
            return result;
        }
    }

    /// @dev Requires every field of the tuple to match exactly.
    function _countAgreeing(uint256 bountyId, address[] storage members, Verdict storage candidate)
        private
        view
        returns (uint256 count)
    {
        uint256 rosterSize = members.length;
        for (uint256 j = 0; j < rosterSize; j++) {
            if (_verdictMatchesCandidate(verdicts[bountyId][members[j]], candidate)) {
                count++;
            }
        }
    }

    /// @dev count comes from _countAgreeing's pass over the same members, so it sizes these
    /// arrays exactly — the second loop here can only ever fill them, never overrun or underfill.
    function _collectSupporters(
        uint256 bountyId,
        address[] storage members,
        TallyResult memory result,
        uint256 count
    ) private view returns (address[] memory supporters, bytes32[] memory reportCommitments) {
        uint256 rosterSize = members.length;
        supporters = new address[](count);
        reportCommitments = new bytes32[](count);

        uint256 k = 0;
        for (uint256 j = 0; j < rosterSize; j++) {
            Verdict storage v = verdicts[bountyId][members[j]];
            if (_verdictMatchesResult(v, result)) {
                supporters[k] = members[j];
                reportCommitments[k] = v.reportCommitment;
                k++;
            }
        }
    }

    /// @dev The sole definition of "agrees" used to count toward threshold; _verdictMatchesResult
    /// mirrors it for the later supporter-collection pass so the two can never disagree.
    function _verdictMatchesCandidate(Verdict storage v, Verdict storage candidate)
        private
        view
        returns (bool)
    {
        if (!v.committed) return false;
        return v.outcome == candidate.outcome && v.winner == candidate.winner
            && v.awardedSubmissionCommitment == candidate.awardedSubmissionCommitment
            && keccak256(v.payoutData) == keccak256(candidate.payoutData);
    }

    /// @dev Compares against a finalized TallyResult instead of a live Verdict; see
    /// _verdictMatchesCandidate, whose equality rule this must stay identical to.
    function _verdictMatchesResult(Verdict storage v, TallyResult memory result)
        private
        view
        returns (bool)
    {
        if (!v.committed) return false;
        return v.outcome == result.outcome && v.winner == result.winner
            && v.awardedSubmissionCommitment == result.submissionCommitment
            && keccak256(v.payoutData) == keccak256(result.payoutData);
    }

    /// @notice Anyone may time out an open bounty once its settlementTimeoutAt has passed, refunding the poster in full.
    /// @param bountyId Id of the target bounty; see getBounty.
    function timeoutSettlement(uint256 bountyId) external whenNotPaused bountyExists(bountyId) {
        BountyParameters storage parameters = bountyParameters[bountyId];
        BountyState storage state = bountyStates[bountyId];
        if (state.status != Status.Open) revert InvalidStatus();
        if (block.timestamp < parameters.settlementTimeoutAt) revert DeadlineNotPassed();

        state.status = Status.TimedOut;
        claimable[bountyId][parameters.poster] += parameters.escrowAmount;
        emit SettlementTimedOut(bountyId, parameters.poster, parameters.escrowAmount);
    }

    /// @notice Pulls the caller's entire queued balance for a bounty (fee, refund, or winner payout); see claimable.
    /// @param bountyId Id of the bounty to claim against.
    function claim(uint256 bountyId) external nonReentrant whenNotPaused bountyExists(bountyId) {
        if (bountyStates[bountyId].status == Status.Open) revert InvalidStatus();
        uint256 amount = claimable[bountyId][msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimable[bountyId][msg.sender] = 0;
        ESCROW_TOKEN.safeTransfer(msg.sender, amount);
        emit Claimed(bountyId, msg.sender, amount);
    }

    /// @notice Pulls the caller's share of an Awarded bounty's winner pool, as resolved right now by the bounty's own pinned payout scheme; unlike claim(), the amount is never pre-queued at settlement — it is asked for fresh on every call, so a scheme that resolves claims over time (e.g. verifying a merkle proof per claimant) can be paid out lazily, one claimant at a time, rather than needing every recipient enumerated in one settle() transaction.
    /// @dev The caller is always the recipient — the scheme decides only how much, never to whom — so a scheme can never misdirect funds to an address other than its own caller; ElgoraHub separately guarantees the running total across every claimant can never exceed winnerPool, so a scheme cannot over-pay even by accident.
    /// @param bountyId Id of the target bounty; must be Awarded.
    /// @param proof Caller-supplied material the payout scheme may need to resolve the caller's share (e.g. a merkle proof); meaningless to ElgoraHub itself, forwarded verbatim.
    function claimAward(uint256 bountyId, bytes calldata proof)
        external
        nonReentrant
        whenNotPaused
        bountyExists(bountyId)
    {
        if (bountyStates[bountyId].status != Status.Awarded) revert InvalidStatus();

        uint256 amount = _resolveAwardClaim(bountyId, proof);
        ESCROW_TOKEN.safeTransfer(msg.sender, amount);
        emit Claimed(bountyId, msg.sender, amount);
    }

    /// @dev Split out of claimAward to keep its stack shallow enough to compile without via_ir.
    function _resolveAwardClaim(uint256 bountyId, bytes calldata proof)
        private
        returns (uint256 amount)
    {
        BountyParameters storage parameters = bountyParameters[bountyId];
        BountyState storage state = bountyStates[bountyId];
        (,, uint256 winnerPool) = _settlementAmounts(
            parameters.escrowAmount, parameters.treasuryFeeBps, parameters.guardianFeeBps
        );
        uint256 remaining = winnerPool - winnerPoolClaimed[bountyId];
        if (remaining == 0) revert NothingToClaim();

        amount = IPayoutScheme(parameters.payoutScheme)
            .claimAmount(
                bountyId, state.winner, winnerPool, state.awardedPayoutData, msg.sender, proof
            );
        if (amount == 0) revert NothingToClaim();
        if (amount > remaining) revert InvalidPayout();
        winnerPoolClaimed[bountyId] += amount;
    }

    /// @notice Pulls the caller's queued balance across many bounties in one transfer; skips ids with nothing queued.
    /// @param bountyIds Bounty ids to claim against, caller-provided and unvalidated; an id with nothing queued is skipped, not reverted.
    /// @return total Combined amount transferred across every id.
    function claimMany(uint256[] calldata bountyIds)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 total)
    {
        for (uint256 i = 0; i < bountyIds.length; i++) {
            uint256 bountyId = bountyIds[i];
            uint256 amount = claimable[bountyId][msg.sender];
            if (amount == 0) continue;
            claimable[bountyId][msg.sender] = 0;
            total += amount;
            emit Claimed(bountyId, msg.sender, amount);
        }
        if (total == 0) revert NothingToClaim();
        ESCROW_TOKEN.safeTransfer(msg.sender, total);
    }

    /// @notice The live treasuryRecipient and/or guardianFeeRecipient pulls its entire accrued fee pool in one transfer, with no bounty id needed. Whoever currently holds a fee role claims everything accrued under it, past and present; ElgoraHub does not track or split by earlier role-holders.
    /// @return treasuryAmount Treasury-fee portion paid out; nonzero only if the caller is the live treasuryRecipient.
    /// @return guardianAmount Guardian-fee portion paid out; nonzero only if the caller is the live guardianFeeRecipient.
    function claimFees()
        external
        nonReentrant
        whenNotPaused
        returns (uint256 treasuryAmount, uint256 guardianAmount)
    {
        if (msg.sender == treasuryRecipient) {
            treasuryAmount = treasuryFeeClaimable;
            if (treasuryAmount != 0) treasuryFeeClaimable = 0;
        }
        if (msg.sender == guardianFeeRecipient) {
            guardianAmount = guardianFeeClaimable;
            if (guardianAmount != 0) guardianFeeClaimable = 0;
        }
        uint256 total = treasuryAmount + guardianAmount;
        if (total == 0) revert NothingToClaim();

        ESCROW_TOKEN.safeTransfer(msg.sender, total);
        emit FeesClaimed(msg.sender, treasuryAmount, guardianAmount);
    }

    /// @notice Reads a bounty's immutable parameters and mutable lifecycle state together.
    /// @param bountyId Id of the bounty to read.
    /// @return parameters Definitions snapshotted at creation; see BountyParameters.
    /// @return state Current lifecycle state; see BountyState.
    function getBounty(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (BountyParameters memory parameters, BountyState memory state)
    {
        return (bountyParameters[bountyId], bountyStates[bountyId]);
    }

    /// @notice Shortcut read for just a bounty's lifecycle stage; see BountyState.status.
    /// @param bountyId Id of the bounty to read.
    function status(uint256 bountyId) external view bountyExists(bountyId) returns (Status) {
        return bountyStates[bountyId].status;
    }

    /// @notice Shortcut read for a bounty's winner; see BountyState.winner.
    /// @param bountyId Id of the bounty to read.
    /// @return Winning solver, or the zero address if not (yet) Awarded.
    function winner(uint256 bountyId) external view bountyExists(bountyId) returns (address) {
        return bountyStates[bountyId].winner;
    }

    /// @notice Shortcut read for a settled bounty's agreed payout data; see BountyState.awardedPayoutData.
    /// @param bountyId Id of the bounty to read.
    function awardedPayoutData(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (bytes memory)
    {
        return bountyStates[bountyId].awardedPayoutData;
    }

    /// @notice Shortcut read for a bounty's settlement deadline; see BountyParameters.settlementTimeoutAt.
    /// @param bountyId Id of the bounty to read.
    function settlementTimeoutAt(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (uint64)
    {
        return bountyParameters[bountyId].settlementTimeoutAt;
    }

    /// @notice Shortcut read for a bounty's judging deadline; see BountyParameters.judgingDeadlineAt.
    /// @param bountyId Id of the bounty to read.
    function judgingDeadlineAt(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (uint64)
    {
        return bountyParameters[bountyId].judgingDeadlineAt;
    }

    /// @notice Returns the current ordered Guardian roster; see Guardian and guardianRosterHash.
    /// @return Current roster, in the order guardianRosterHash is computed over.
    function getGuardianRoster() external view returns (Guardian[] memory) {
        return guardianRoster;
    }

    /// @notice Returns the ordered member accounts of a past or current roster; see RosterSnapshot and guardianRosterHash. Reverts on an unrecognized hash implicitly by returning an empty array, since a hash nothing was ever snapshotted at has no entry.
    /// @param rosterHash Roster hash to read, typically a bounty's snapshotted guardianRosterHash.
    function getGuardianRosterAtHash(bytes32 rosterHash) external view returns (address[] memory) {
        return guardianRosterSnapshots[rosterHash].members;
    }

    /// @notice Number of agreeing verdicts a bounty's pinned roster needs to settle; ceil(2 * rosterSize / 3).
    /// @param bountyId Id of the bounty to read.
    function guardianThreshold(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (uint256)
    {
        uint256 rosterSize =
            guardianRosterSnapshots[bountyParameters[bountyId].guardianRosterHash].members.length;
        return (2 * rosterSize + 2) / 3;
    }

    /// @notice The guardian roster admin alone appends one Guardian to the live roster; only future bounties see it. Bounties already open keep judging against the roster hash pinned when they were created.
    /// @param name Human-readable display name; see Guardian.name.
    /// @param account Guardian's on-chain address; must not already be on the roster.
    /// @param encryptionPublicKey Guardian's X25519 HPKE public key; see Guardian.encryptionPublicKey for its exact encoding.
    function addGuardian(string calldata name, address account, string calldata encryptionPublicKey)
        external
        onlyGuardianRosterAdmin
    {
        _addGuardian(name, account, encryptionPublicKey);
    }

    /// @notice The guardian roster admin alone removes one Guardian from the live roster; the roster may never go empty. Bounties already open keep judging against the roster hash pinned when they were created.
    /// @param account Guardian's on-chain address to remove.
    function removeGuardian(address account) external onlyGuardianRosterAdmin {
        uint256 indexPlusOne = guardianIndex[account];
        if (indexPlusOne == 0) revert GuardianNotFound();
        if (guardianRoster.length == 1) revert InvalidGuardian();

        uint256 index = indexPlusOne - 1;
        uint256 last = guardianRoster.length - 1;
        for (uint256 i = index; i < last; i++) {
            guardianRoster[i] = guardianRoster[i + 1];
            guardianIndex[guardianRoster[i].account] = i + 1;
        }
        guardianRoster.pop();
        delete guardianIndex[account];

        _recordGuardianRosterSnapshot();
    }

    /// @notice The guardian roster admin alone swaps one Guardian for another in a single roster mutation — one transaction, one guardianRosterHash update, roster size unchanged — instead of a separate removeGuardian then addGuardian. The replaced Guardian keeps its roster position; newAccount may equal oldAccount to update a Guardian's name or encryption key in place. Bounties already open keep judging against the roster hash pinned when they were created.
    /// @param oldAccount Guardian's on-chain address to replace; must currently be on the roster.
    /// @param name New Guardian's human-readable display name; see Guardian.name.
    /// @param newAccount New Guardian's on-chain address; must not already be on the roster unless equal to oldAccount.
    /// @param encryptionPublicKey New Guardian's X25519 HPKE public key; see Guardian.encryptionPublicKey for its exact encoding.
    function replaceGuardian(
        address oldAccount,
        string calldata name,
        address newAccount,
        string calldata encryptionPublicKey
    ) external onlyGuardianRosterAdmin {
        uint256 indexPlusOne = guardianIndex[oldAccount];
        if (indexPlusOne == 0) revert GuardianNotFound();
        if (
            bytes(name).length == 0 || newAccount == address(0)
                || bytes(encryptionPublicKey).length == 0
        ) revert InvalidGuardian();
        if (newAccount != oldAccount && guardianIndex[newAccount] != 0) {
            revert GuardianAlreadyExists();
        }

        uint256 index = indexPlusOne - 1;
        guardianRoster[index] =
            Guardian({name: name, account: newAccount, encryptionPublicKey: encryptionPublicKey});
        delete guardianIndex[oldAccount];
        guardianIndex[newAccount] = indexPlusOne;

        _recordGuardianRosterSnapshot();
    }

    /// @notice Owner rotates the live guardianRosterAdmin; only future bounties snapshot the new address.
    /// @param guardianRosterAdmin_ New admin address; must be nonzero.
    function setGuardianRosterAdmin(address guardianRosterAdmin_) external onlyOwner {
        _setGuardianRosterAdmin(guardianRosterAdmin_);
    }

    /// @notice Owner rotates fee recipients and rates together; only future bounties snapshot the new values.
    /// @param treasuryRecipient_ New treasury fee recipient; must be nonzero.
    /// @param guardianFeeRecipient_ New guardian fee recipient; must be nonzero.
    /// @param treasuryFeeBps_ New treasury fee in basis points; combined with guardianFeeBps_ must not exceed MAX_TOTAL_FEE_BPS.
    /// @param guardianFeeBps_ New guardian fee in basis points.
    function setFeeConfig(
        address treasuryRecipient_,
        address guardianFeeRecipient_,
        uint16 treasuryFeeBps_,
        uint16 guardianFeeBps_
    ) external onlyOwner {
        _setFeeConfig(treasuryRecipient_, guardianFeeRecipient_, treasuryFeeBps_, guardianFeeBps_);
    }

    /// @notice Owner sets the live guardianReviewWindow; only future bounties snapshot it into settlementTimeoutAt.
    /// @param guardianReviewWindow_ New duration in seconds; must be nonzero.
    function setGuardianReviewWindow(uint64 guardianReviewWindow_) external onlyOwner {
        _setGuardianReviewWindow(guardianReviewWindow_);
    }

    /// @notice Owner sets the live [minimumEscrowAmount, maximumEscrowAmount] range applied to new bounties.
    /// @param minimumEscrowAmount_ New lower bound, in escrow-token base units; must be nonzero.
    /// @param maximumEscrowAmount_ New upper bound, in escrow-token base units; must be at least the minimum.
    function setEscrowBounds(uint256 minimumEscrowAmount_, uint256 maximumEscrowAmount_)
        external
        onlyOwner
    {
        _setEscrowBounds(minimumEscrowAmount_, maximumEscrowAmount_);
    }

    /// @notice Owner sets the live [minBountyDuration, maxBountyDuration] range a new bounty's submissionDeadline must fall within, measured from createBounty's call time; bounds how long a bounty can stay open.
    /// @param minBountyDuration_ New lower bound in seconds; must be nonzero.
    /// @param maxBountyDuration_ New upper bound in seconds; must be at least the minimum.
    function setBountyDurationBounds(uint64 minBountyDuration_, uint64 maxBountyDuration_)
        external
        onlyOwner
    {
        _setBountyDurationBounds(minBountyDuration_, maxBountyDuration_);
    }

    /// @notice Owner swaps the live submissionGuard; applies immediately to every open bounty's next submit() call.
    /// @param submissionGuard_ New submission-guard contract address; must have code.
    function setSubmissionGuard(address submissionGuard_) external onlyOwner {
        _setSubmissionGuard(submissionGuard_);
    }

    /// @notice Owner swaps the live payoutScheme; only future bounties snapshot it, open bounties keep their own.
    /// @param payoutScheme_ New payout-scheme contract address; must have code.
    function setPayoutScheme(address payoutScheme_) external onlyOwner {
        _setPayoutScheme(payoutScheme_);
    }

    /// @notice Owner rotates the live coordinator; applies immediately, including to bounties already open. The zero address makes settle() permissionless from the start, the natural end state after renouncing ownership.
    /// @param coordinator_ New coordinator address, or the zero address for immediate permissionless settlement.
    function setCoordinator(address coordinator_) external onlyOwner {
        _setCoordinator(coordinator_);
    }

    /// @notice Owner sets the live coordinatorGracePeriod; applies immediately to open bounties, measured from the later of first consensus and judgingDeadlineAt.
    /// @param coordinatorGracePeriod_ New duration before settle() opens to any caller after settlement first becomes legal with consensus.
    function setCoordinatorGracePeriod(uint64 coordinatorGracePeriod_) external onlyOwner {
        _setCoordinatorGracePeriod(coordinatorGracePeriod_);
    }

    /// @notice Owner blocks createBounty/submit/commitVerdict/settle/timeoutSettlement/claim/claimMany/claimFees until unpause(); reverts once pause authority is disabled.
    function pause() external onlyOwner {
        if (pausingDisabled) revert PauseUnavailable();
        pauseRequested = true;
        emit Paused(msg.sender);
    }

    /// @notice Owner clears an active pause; always available regardless of pause authority.
    function unpause() external onlyOwner {
        pauseRequested = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Owner permanently and irreversibly gives up the ability to ever call pause() again.
    function disablePauseAuthority() external onlyOwner {
        if (pausingDisabled) revert PauseUnavailable();
        pausingDisabled = true;
        emit PauseAuthorityDisabled(msg.sender);
    }

    /// @notice Whether lifecycle calls are currently blocked by an active pause.
    function paused() public view returns (bool) {
        return pauseRequested;
    }

    /// @dev winnerPool is a subtraction, not its own bps calculation, so rounding dust from the
    /// two fee divisions always lands with the winner pool rather than vanishing.
    function _settlementAmounts(
        uint256 escrowAmount,
        uint16 bountyTreasuryFeeBps,
        uint16 bountyGuardianFeeBps
    ) private pure returns (uint256 treasuryAmount, uint256 guardianFeeAmount, uint256 winnerPool) {
        treasuryAmount = (escrowAmount * bountyTreasuryFeeBps) / BPS_DENOMINATOR;
        guardianFeeAmount = (escrowAmount * bountyGuardianFeeBps) / BPS_DENOMINATOR;
        winnerPool = escrowAmount - treasuryAmount - guardianFeeAmount;
    }

    /// @dev guardianIndex stores index+1, so a stored 0 unambiguously means "not on the roster"
    /// rather than colliding with a real index-0 member.
    function _addGuardian(string memory name, address account, string memory encryptionPublicKey)
        private
    {
        if (
            bytes(name).length == 0 || account == address(0)
                || bytes(encryptionPublicKey).length == 0
        ) revert InvalidGuardian();
        if (guardianIndex[account] != 0) revert GuardianAlreadyExists();

        guardianRoster.push(
            Guardian({name: name, account: account, encryptionPublicKey: encryptionPublicKey})
        );
        guardianIndex[account] = guardianRoster.length;
        _recordGuardianRosterSnapshot();
    }

    /// @dev Guarantees each distinct roster hash is recorded exactly once: a later mutation that
    /// reproduces an earlier hash (e.g. add then remove the same Guardian) reuses that snapshot
    /// instead of appending a duplicate copy of every member.
    function _recordGuardianRosterSnapshot() private {
        Guardian[] memory roster = guardianRoster;
        bytes32 newHash = keccak256(abi.encode(roster));
        guardianRosterHash = newHash;
        // The event carries the exact array that was just hashed, so a reader can recompute the
        // digest from the log alone. Add and remove provenance stays derivable by diffing two
        // consecutive roster events, which replaying per-Guardian events could never do:
        // replaceGuardian writes in place, and its log sequence was indistinguishable from a
        // remove-then-add that appends at the end.
        emit GuardianRosterHashUpdated(newHash, roster);

        // members.length is never 0 once a hash has been recorded, since the roster itself can
        // never go empty — so an empty length here unambiguously means "first time seeing this
        // hash".
        RosterSnapshot storage snapshot = guardianRosterSnapshots[newHash];
        if (snapshot.members.length == 0) {
            for (uint256 i = 0; i < roster.length; i++) {
                address member = roster[i].account;
                snapshot.members.push(member);
                isGuardianAtRosterHash[newHash][member] = true;
            }
        }
    }

    function _setGuardianRosterAdmin(address guardianRosterAdmin_) private {
        if (guardianRosterAdmin_ == address(0)) revert InvalidAddress();
        guardianRosterAdmin = guardianRosterAdmin_;
        emit GuardianRosterAdminUpdated(guardianRosterAdmin_);
    }

    function _setCoordinator(address coordinator_) private {
        coordinator = coordinator_;
        emit CoordinatorUpdated(coordinator_);
    }

    function _setCoordinatorGracePeriod(uint64 coordinatorGracePeriod_) private {
        coordinatorGracePeriod = coordinatorGracePeriod_;
        emit CoordinatorGracePeriodUpdated(coordinatorGracePeriod_);
    }

    /// @dev Caps the two fees' combined bps below MAX_TOTAL_FEE_BPS, guaranteeing a bounty's
    /// winner pool is never fully consumed by fees, however both are configured.
    function _setFeeConfig(
        address treasuryRecipient_,
        address guardianFeeRecipient_,
        uint16 treasuryFeeBps_,
        uint16 guardianFeeBps_
    ) private {
        if (treasuryRecipient_ == address(0) || guardianFeeRecipient_ == address(0)) {
            revert InvalidAddress();
        }
        if (uint256(treasuryFeeBps_) + uint256(guardianFeeBps_) > MAX_TOTAL_FEE_BPS) {
            revert InvalidFeeConfig();
        }
        treasuryRecipient = treasuryRecipient_;
        guardianFeeRecipient = guardianFeeRecipient_;
        treasuryFeeBps = treasuryFeeBps_;
        guardianFeeBps = guardianFeeBps_;
        emit FeeConfigUpdated(
            treasuryRecipient_, guardianFeeRecipient_, treasuryFeeBps_, guardianFeeBps_
        );
    }

    function _setGuardianReviewWindow(uint64 guardianReviewWindow_) private {
        if (guardianReviewWindow_ == 0) revert InvalidDeadline();
        guardianReviewWindow = guardianReviewWindow_;
        emit GuardianReviewWindowUpdated(guardianReviewWindow_);
    }

    function _setEscrowBounds(uint256 minimumEscrowAmount_, uint256 maximumEscrowAmount_) private {
        if (minimumEscrowAmount_ == 0 || maximumEscrowAmount_ < minimumEscrowAmount_) {
            revert InvalidEscrowBounds();
        }
        minimumEscrowAmount = minimumEscrowAmount_;
        maximumEscrowAmount = maximumEscrowAmount_;
        emit EscrowBoundsUpdated(minimumEscrowAmount_, maximumEscrowAmount_);
    }

    function _setBountyDurationBounds(uint64 minBountyDuration_, uint64 maxBountyDuration_)
        private
    {
        if (minBountyDuration_ == 0 || maxBountyDuration_ < minBountyDuration_) {
            revert InvalidDurationBounds();
        }
        minBountyDuration = minBountyDuration_;
        maxBountyDuration = maxBountyDuration_;
        emit BountyDurationBoundsUpdated(minBountyDuration_, maxBountyDuration_);
    }

    function _setSubmissionGuard(address submissionGuard_) private {
        if (submissionGuard_.code.length == 0) revert InvalidContract();
        submissionGuard = ISubmissionGuard(submissionGuard_);
        emit SubmissionGuardUpdated(submissionGuard_);
    }

    function _setPayoutScheme(address payoutScheme_) private {
        if (payoutScheme_.code.length == 0) revert InvalidContract();
        payoutScheme = IPayoutScheme(payoutScheme_);
        emit PayoutSchemeUpdated(payoutScheme_);
    }

    function _emitBountyCreated(uint256 bountyId, BountyParameters memory parameters) private {
        emit BountyCreated(
            bountyId,
            parameters.poster,
            parameters.specCommitment,
            parameters.guardianRosterHash,
            parameters.escrowAmount,
            parameters.submissionDeadline,
            parameters.judgingDeadlineAt,
            parameters.settlementTimeoutAt,
            // Not snapshotted onto BountyParameters: nothing ever reads it back after this same
            // call, unlike treasuryRecipient/guardianFeeRecipient below, which claimFees() reuses
            // at settlement time. The live value at this point in the transaction is the only one
            // that will ever exist for this bounty's creation record.
            guardianRosterAdmin,
            parameters.payoutScheme,
            parameters.treasuryRecipient,
            parameters.guardianFeeRecipient,
            parameters.treasuryFeeBps,
            parameters.guardianFeeBps
        );
    }
}
