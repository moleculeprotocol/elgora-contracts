# Elgora contract overview

This is a researcher-facing explanation of the snapshot in [SOURCE.json](../SOURCE.json).
The [Solidity source](../src/ElgoraHub.sol) defines exact contract behavior; the
[tests](../test/) provide executable examples. This overview is not bounty terms.

## Escrow and outcomes

A Poster creates and funds a bounty in USDC. Funding uses either an ERC-20
allowance or a signed EIP-3009 authorization. The Hub checks that the exact
escrow amount arrived. USDC amounts use six decimals and integer arithmetic.

Solvers submit commitments. Submission contents are not stored in the contract.
The submission guard controls admission. The deployed CappedSubmissionGuard
counts distinct admitted Solver accounts per bounty; revisions reuse a seat.

Each bounty pins a Guardian roster. Guardians commit Verdicts, and settlement
requires a matching two-thirds threshold. The caller of `settle()` does not
supply a trusted result: the Hub tallies the recorded Verdicts itself.

Awarded settlement reserves the winner pool for `claimAward()` and accounts for
fees. WinnerTakesAllPayoutScheme is the payout scheme listed in the reference
deployment. A NoValidSubmission settlement refunds escrow less the Guardian fee
when there were accepted submissions; with no accepted submissions it queues a
full refund. A timeout queues the full escrow refund. Claims are separate calls;
a queued refund or allocation is not an immediate token transfer.

## Timing and the coordinator

Settlement opens at `judgingDeadlineAt` and closes at `settlementTimeoutAt`.
Existing Guardian Verdicts cannot be revised after judging closes, although a
Guardian's first-ever Verdict can still arrive later while the bounty is open.

A configured coordinator gets exclusive settlement access during its grace
period, measured from the later of first consensus and the judging deadline.
After the grace period, other callers can settle if the settlement window is
still open. The coordinator controls who calls first, not which outcome the tally
produces. A coordinator that never settles can still let the bounty time out.

Consensus alone does not reserve a winner payout. If settlement misses its
window, the full-refund timeout path can apply even with Awarded consensus.
Read [KNOWN_ISSUES.md](../KNOWN_ISSUES.md) for the precise limitation.

## Trust boundaries and configuration

The Hub is non-upgradeable. Its owner has administrative powers, including
pausing lifecycle operations and changing configuration. Some settings are
pinned per bounty; others, including the coordinator, its grace period, and the
submission guard, are live settings. Inspect the source and chain state when
an assessment depends on their values.

The Guardian roster administrator controls roster updates for future bounties;
an existing bounty retains its pinned roster. Guardian agreement is a trust
assumption: the contract verifies agreement, not the correctness of off-chain
judgment. Configuration and caller privileges are not permission to rewrite
queued balances or choose Guardian Verdicts.

The guard owner can adjust submission caps. The guard binds to one Hub once,
and only that Hub can consume admission seats. Admission does not establish
submission quality; junk submissions can consume seats.

### Actors and trust levels

| Actor | Trust level | What it controls |
| --- | --- | --- |
| Hub owner | Trusted; two-step transfer; no timelock | On open bounties: the submission guard, the coordinator and its grace period (no upper bound), and pause, which also blocks every claim. Fee recipients: a new recipient claims all fees already accrued. For new bounties only: fee rates, escrow and duration bounds, review window and payout scheme. Names the roster administrator. Can renounce ownership; renouncing while paused leaves claims blocked permanently (ASTRA-007) |
| Guardian roster administrator | Trusted for future bounties only | Roster membership; open bounties keep their pinned roster |
| Guardians on a pinned roster | Bounded by the two-thirds matching threshold | Outcome, winner and payout data of each bounty they judge |
| Coordinator | Trusted for settlement timing | Exclusive right to call `settle()` during its grace period. It cannot choose a different outcome, but if it does not settle and the grace period covers the rest of the settlement window, the bounty times out with a full Poster refund |
| Guard owner | Trusted for admission policy | Seat caps per bounty and the default cap; raising a cap adds seats but evicts none |
| Posters and Solvers | Untrusted | Their own escrow, submissions and claims only |
| Escrow token issuer (USDC) | External | Can pause or blacklist addresses; the Hub has no rescue path |

Replacing the submission guard on an open bounty starts seat counts from zero
in the new guard and can reject an existing Solver's revision (ASTRA-004). It
is not a remedy for exhausted seats.

Role holders are live chain state. Read them from the Hub (`owner()`,
`coordinator()`, `coordinatorGracePeriod()`, `guardianRosterAdmin()`,
`treasuryRecipient()`, `guardianFeeRecipient()`, `paused()`,
`pausingDisabled()`) and from the guard (`owner()`). Known behavior and the
status of each review finding are recorded in [KNOWN_ISSUES.md](../KNOWN_ISSUES.md)
and the [security review index](../audits/README.md).

Use local mocks or a local chain fork for research. State every privileged-role
assumption in a report. See [SECURITY.md](../SECURITY.md) for private reporting
and [README.md](../README.md) for deployment addresses and reproducible builds.
