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
still open. The coordinator controls who calls first, not which outcome wins.

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

Use local mocks or a local chain fork for research. State every privileged-role
assumption in a report. See [SECURITY.md](../SECURITY.md) for private reporting
and [README.md](../README.md) for deployment addresses and reproducible builds.
