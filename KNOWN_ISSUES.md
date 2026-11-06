# Known behavior and security limitations

This document describes the source snapshot in [SOURCE.json](SOURCE.json).
It is not a complete security audit, a declaration that every listed risk has
been accepted, or a list of automatic bounty exclusions.

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

## Assurance limits

The repository includes tests and invariants, but passing tests do not establish
bug freedom. This export does not claim a professional third-party audit or
endorsement. Source correspondence is described precisely in [README.md](README.md).
