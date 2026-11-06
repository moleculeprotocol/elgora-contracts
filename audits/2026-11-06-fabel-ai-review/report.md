# Elgora AI-assisted security review — Fabel

Review date: **6 November 2026 (UTC)**. [Scope](scope.md) · [Findings status](findings-status.md).

## Identity and assurance limits

Conducted for Elgora with Pashov's open-source skills, not by Pashov Audit Group.
The reviewer label is `fabel`. The run recorded parent model `claude-fable-5-1` with High effort. Specialist
calls requested `model: fable`, `effort: high`; actual per-agent effort was not
independently observable afterward. Self-reported model names are not proof.

This is an edited publication report based on the completed private review.
The original report classified three findings as confirmed (one Medium, two Low).
The publication editor distinguishes confirmation of behavior from confirmation
of a new vulnerability. Original raw outputs remain unchanged and private.

This review did not identify a confirmed unauthorized-transfer or
escrow-conservation vulnerability. It does not establish that none exists.

## Execution and evidence

One X-ray and one twelve-role auditor pass completed. Baseline build and 71
CI-profile tests passed. The private reproduction log records three passing
mechanism tests after a test-helper correction; no contract was changed. The
publication editor inspected the final test and log but did not rerun them.
The raw four findings were consolidated into three records below; raw leads and
admin-only candidates are grouped separately. Live reachability was not checked.

## Findings summary

| ID | Topic | Original reviewer severity | Publication assessment | Resolution |
| --- | --- | --- | --- | --- |
| FABEL-001 | Submission-seat exhaustion | Medium | Reproduced known admission risk | Unresolved |
| FABEL-002 | Junk submission removes empty-bounty fee waiver | Low | Reproduced policy/incentive concern; no established spec violation | Unresolved |
| FABEL-003 | Early award verdict becomes stale after a revision | Low | Mechanism reproduced locally; production preconditions unverified | Unresolved |

## FABEL-001 — Submission-seat exhaustion

**Source:** [admission guard](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/CappedSubmissionGuard.sol#L75),
[submission path](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L527).
With the capped guard selected, a first submission consumes one seat per address.
An ordinary actor can use multiple addresses while seats and time remain. The
cap bounds addresses, not independent people or useful work. Later applicants
can be excluded. Raising the cap creates additional seats but does not guarantee
honest applicants obtain them; transaction ordering still matters.

The [protocol description](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/docs/PROTOCOL.md#L59) acknowledges junk seats.
The existing [seat-squatting test](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/test/CappedSubmissionGuard.t.sol#L262)
already demonstrates both exclusion and the fee consequence if all submissions
are rejected. These consequences are therefore not new discoveries of this run.

The added local test reproduces exclusion and a payout after the test supplies
an Awarded quorum for the seated Solver. **Seat exhaustion does not force
Guardians to award that Solver**; they may reject all submissions. The test does
not establish that weak work would win real judging.

The original Medium rating reflects denial of useful competition. Costs were
not measured against live Base prices, and current live guard configuration was
not read. Under the test assumptions of ten initial seats, 250 USDC escrow and
a 10% Guardian fee, the unsuccessful nonempty-bounty fee is 25 USDC. Those are
fixture/reference-default amounts, not verified current production limits.

Evidence: existing public test above and private
`test_sybilSeatExhaustionLocksOutRivalAndWinsUncontested`. No policy change,
acceptance, guard replacement or other remediation is established.

## FABEL-002 — Junk submission removes the empty-bounty fee waiver

**Source:** [NoValidSubmission settlement](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L719);
[existing junk-submission test](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/test/ElgoraHub.t.sol#L847).
A permitted account can change the submission count from zero to nonzero. If
Guardians subsequently agree NoValidSubmission and settlement succeeds before
timeout, the Guardian fee is allocated instead of waived. An ordinary submitting
account does not automatically receive that fee; benefit requires entitlement
or an arrangement with the fee recipient.

This follows the [documented compensation rule](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/docs/PROTOCOL.md#L23).
The original report's assertion that payment requires useful/reviewable work
is not an established contract guarantee. The reproduced incentive is relevant
to policy, but is not evidence of an unauthorized allocation or specification
violation. Its original Low rating is retained as reviewer judgment, not a
newly adjudicated vulnerability severity.

Private test `test_junkSubmissionMakesPosterPayGuardianFee` compares an empty
bounty with one containing an arbitrary commitment. It records a 25-USDC
allocation difference under its 250-USDC/10% fixture. The consequence can recur
across bounties; it is bounded per bounty, not globally. Whether compensation
for invalid submissions is acceptable remains a product decision.

## FABEL-003 — Early award verdict becomes stale after a revision

**Source:** [verdict recording](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L580),
[active submission update](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L560), and
[award commitment check](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L711).
The mechanism requires an Awarded quorum before submissions close, a subsequent
revision by the named Solver, and no adequate correction of the verdicts before
judging closes. After that point the agreed commitment can differ from the
Solver's active commitment, preventing award settlement and leaving the full
Poster-refund timeout path.

The private test `test_earlyVerdictThenResubmissionForcesTimeoutRefund` records
this local sequence. The existing
[exact-commitment settlement test](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/test/ElgoraHub.t.sol#L1098) already
asserts the stale-commitment revert; this review additionally follows the
sequence through timeout. Do not describe it as an entirely undisclosed primitive.
It is a specific mechanism related to the [known timeout outcome](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/KNOWN_ISSUES.md).

The original Low rating depends on early Guardian voting and the absence of a
correction during the remaining review window. Actual Guardian behavior was
outside scope; the test uses controlled Guardian accounts and local configuration.
The mechanism is locally reproduced, but production applicability and frequency
remain unverified. No patch or deployed mitigation has been validated.

## Leads and excluded candidates

Nine raw function-specific leads consolidate to seven topical entries:

| Topic | Assessment |
| --- | --- |
| Unbounded verdict payout data and settlement work | Gas-denial feasibility unverified; no confirmed severity |
| First-ever verdict after the revision deadline | Documented timing behavior; harmful outcome not established |
| Same commitment across Solver addresses | Harm depends on out-of-scope content attribution |
| Guardian submitting and voting | Depends on quorum and documented role trust |
| Unlimited revisions within an admitted seat | Off-chain cost not measured |
| Issuer blacklist preventing a claim | External issuer/operational risk; attacker trigger not established |
| Roster revocation not changing existing bounties | Documented roster pinning; policy concern |

Admin-only candidates consolidate into four operational topics: pause
followed by ownership renunciation, pending guard ownership acceptance, deployment
owner configuration, and an extremely short review window. They were excluded
under the skill's privileged-action gate, not proven harmless. Live ownership
and configuration were not checked. No recovery procedure or automatic fix is
endorsed by this report.

## Limitations and editorial changes

No fork or live-chain proof, new Fizz campaign, off-chain workflow review or
independent rerun of the added reproductions. A passing local mechanism test is
not proof of production exploitability or severity. The editorial pass corrected
novelty, fee-policy expectations, guaranteed-win wording and live-cost claims;
it did not modify source or the private raw report. See [scope](scope.md) for
runtime deviations and [status](findings-status.md) for resolution tracking.
