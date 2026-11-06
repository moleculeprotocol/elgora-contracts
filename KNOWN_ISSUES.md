# Known behavior and security limitations

This document describes the source snapshot in [SOURCE.json](SOURCE.json).
It is not a complete security audit, a declaration that every listed risk has
been accepted, or a list of automatic bounty exclusions.

This file is the short overview. Evidence, severity reasoning and the current
status of each item live in the [security review index](audits/README.md).

## Settlement timeout can override an unsettled award consensus

An on-chain Guardian consensus is not a completed settlement. `settle()` must
succeed before the bounty's `settlementTimeoutAt`. At or after that timestamp,
`settle()` reverts. For an open bounty, `timeoutSettlement()` then changes the
status to `TimedOut` and queues the full escrow for the Poster, without tallying
Guardian Verdicts. The Poster still needs to claim the queued refund.

Consequently, a bounty can have matching Awarded Verdicts yet end with a full
Poster refund if settlement does not occur in time. That timeout allocates
neither a winner payout nor Guardian fees.

Factors that can prevent timely settlement include:

- No eligible caller successfully settles before the timeout.
- A late first consensus or a sufficiently long coordinator grace period leaves
  no permissionless settlement window before the timeout, and the coordinator
  does not settle. The coordinator itself can bypass its grace gate.
- A pause spans the remaining settlement window. Pausing does not extend the
  deadlines. Both settlement and timeout are paused; after unpausing past the
  deadline, the timeout path remains available but award settlement does not.

See [`settle`, `_checkCoordinatorGate`, and `timeoutSettlement`](src/ElgoraHub.sol)
and the timing described in [the contract overview](docs/PROTOCOL.md).
No contract behavior has been changed in this export.

This documents the missed-settlement-window outcome and the mechanisms above.
It does not establish acceptance of other ways an attacker might prevent
settlement. Report a new mechanism or additional impact privately through
[SECURITY.md](SECURITY.md). Any bounty exclusion must be explicit in that bounty's
committed terms before publication; this document alone does not change them.

## Behavior reproduced by the 6 November 2026 security reviews

Two independent AI-assisted reviews ran against this snapshot. One or both
reproduced each behavior below; each item names its review records. Each item is
documented here so researchers do not report it as new. Listing it is not
acceptance, a fix, or a bounty exclusion.

### The submission cap counts addresses, not participants

`CappedSubmissionGuard` admits one seat per Solver address until a bounty's cap
is reached, and a seat is never released. Nothing checks that different
addresses belong to different people or that a submission has content. Once the
cap is reached, later Solvers cannot submit for the rest of the submission
window. Raising the cap adds seats; it evicts nobody. See FABEL-001 and
ASTRA-002 in the [combined findings map](audits/README.md#combined-findings-map).

### The Guardian fee applies to a nonempty bounty even when no submission qualifies

`_settleOutcome` waives the Guardian fee only when a bounty received zero
accepted submissions. One accepted submission of any content removes the
waiver, so a NoValidSubmission settlement then allocates the Guardian fee and
the Poster's refund is the escrow minus that fee. This follows the documented
fee rule in [the contract overview](docs/PROTOCOL.md). Whether review of an
invalid submission should earn the fee is a product decision. See FABEL-002 and
ASTRA-003 in the [combined findings map](audits/README.md#combined-findings-map).

### An award Verdict committed before the submission deadline can go stale

`commitVerdict` has no lower time bound, so Guardians may name a winner and a
submission commitment while `submit()` is still open. The named Solver can then
replace that commitment. If the matching two-thirds quorum still names the
replaced commitment when judging closes at `judgingDeadlineAt`, `settle()`
reverts with `NoActiveSubmission` for the rest of the settlement window. A late
first-ever Verdict cannot form a second quorum, so only the timeout refund
described above remains. A single stale Verdict outside the quorum does not
block settlement. This is a second route to the timeout outcome, triggered by a
Solver action rather than by elapsed time. The review did not observe whether
Guardians vote before the submission deadline in practice. See FABEL-003 in the
[combined findings map](audits/README.md#combined-findings-map).

## Unresolved questions

Two leads from the same reviews are recorded but not established as
vulnerabilities: the settlement cost of large Verdict payout data (ASTRA-001),
and loss of seat history when the live submission guard is replaced
(ASTRA-004). Both are tracked in the
[Astra findings status](audits/2026-11-06-astra-ai-review/findings-status.md).

## Assurance limits

The repository includes tests and invariants, but passing tests do not establish
bug freedom. This export does not claim a professional third-party audit or
endorsement. Source correspondence is described precisely in [README.md](README.md).
