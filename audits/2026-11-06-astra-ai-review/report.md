# Elgora AI-assisted security review — Astra

Review date: **6 November 2026 (UTC)**. [Scope](scope.md) · [Findings status](findings-status.md).

## Identity and assurance limits

Conducted for Elgora using Pashov's open-source skills, not by Pashov Audit Group.
The reviewer label is `astra`. The run records `gpt-6-astra` / High for the parent, X-ray helper and all twelve
specialist roles from host metadata. Backend routing is not independently visible.
This edited report incorporates a separately authorized local follow-up on
6 November 2026 and distinguishes its evidence from the original run.
Raw reports and working logs remain private and unchanged.

**No new vulnerability was confirmed by this review.** Two adverse economic
behaviors were already documented or tested. Two substantive leads remain
unverified. Completion of twelve specialist roles is not complete validation
or proof of bug freedom.

## Execution and evidence

One X-ray pass and one auditor pass completed. Build, 71 baseline tests and
coverage passed. The original four added gas-related tests failed at settlement
assertions. A shell wrapper's zero exit after printing output did not make them pass.
Platform restrictions and a subsequent reporting-only instruction interrupted
that initial validation.

A separately authorized technical follow-up completed **nine local regression
checks: nine passed, zero failed or skipped, actual Foundry exit code 0**. No
specialist or full audit was rerun, and no follow-up tool action was blocked.
The follow-up diagnosed a fixture error, established a successful settlement
control, measured bounded settlement costs, and reproduced guard-replacement
behavior. The original failed logs remain unchanged; they are not passing tests.
Neither lead is promoted to a confirmed vulnerability by these results.

## Findings and leads

| ID | Topic | Reviewer severity | Assessment | Resolution |
| --- | --- | --- | --- | --- |
| ASTRA-001 | Minority verdict payload may obstruct settlement | Not assigned | Unverified | Unresolved |
| ASTRA-002 | Submission-seat exhaustion | Medium, known admission risk | Duplicate of public evidence | Unresolved |
| ASTRA-003 | Junk submission changes fee waiver | Low, policy-dependent | Duplicate of public evidence | Unresolved |
| ASTRA-004 | Fresh guard lacks earlier seat history | Not assigned | Unverified | Unresolved |
| ASTRA-005 | Extreme fee multiplication overflow | Not assigned | Rejected for reference configuration | N/A |
| ASTRA-006 | Timeout refunds an unsettled award | Medium, known lifecycle risk | Duplicate of known issue | Unresolved |
| ASTRA-007 | Owner pauses then renounces ownership | Not assigned | Excluded admin-only candidate | N/A as scoped attacker finding |

## Known economic behaviors

**ASTRA-002:** [guard admission](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/CappedSubmissionGuard.sol#L75) gives
one seat per address; it does not establish independent participants or submission
quality. The passing [existing seat test](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/test/CappedSubmissionGuard.t.sol#L262)
already demonstrates exclusion and unsuccessful-bounty fees. The reviewer rated
the admission risk Medium. Winning is not guaranteed and live profitability was
not measured. No new admission experiment was needed.

**ASTRA-003:** [settlement fee rule](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L719) charges Guardian
fees after unsuccessful review when a submission was accepted. The
[existing junk-submission test](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/test/ElgoraHub.t.sol#L847) passed. This
follows documented policy, rather than bypassing fee authorization. A fee-sharing
beneficiary can have an adverse incentive; an outside submitter does not acquire
the fee simply by causing it. The review's Low rating is policy-dependent.
No risk acceptance or policy change is established.

## Unverified leads

**ASTRA-001:** Source review of [verdict recording](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L580)
and [tallying](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L739) identified repeated work involving
dynamic payout data. The hypothesis requires a Guardian role and a feasible
transaction/gas budget. Convergence by several agents does not prove feasibility.
The follow-up identified a mistake in the original test fixture: a getter
consumed the one-call impersonation before submission, so the test submitted
under the wrong account. The no-payload diagnostic and smallest original payload case
reproduced `NoActiveSubmission`, not a demonstrated out-of-gas failure.
All four original tests share that fixture defect; the three larger cases were
not rerun, so their exact revert data was not retrospectively established.

After correcting only the fixture, ordinary settlement and both bounded payload
cases settled the award and paid the winner. Measured settlement execution gas
rose from 127,795 for the control to 536,130 and 12,778,681 for the two payload
cases. These are local call-execution measurements under a generous 100-million
gas ceiling, not full transaction costs or evidence of network inclusion limits.
No timeout diversion was observed. The private evidence includes the test-only
patch, assertions, command logs and actual exit codes.

**Still unresolved:** whether a feasible verdict can prevent settlement under an
applicable transaction limit. Increased cost alone does not establish denial;
success under a generous local ceiling does not establish general safety.
No deployed gas rules, live configuration, failure threshold or profitability
were established. The vulnerability assessment remains **unverified**, with
no assigned severity. The original failed assertions must not be cited as
proof of gas exhaustion.

**ASTRA-004:** The Hub's [live guard setter](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L1130) can
select a guard whose local seat state lacks earlier admissions. Three follow-up
regression checks demonstrated the behavior during an authorized replacement:
existing holders can revise at capacity before replacement; a fresh guard does
not recognize their old seats; and filling the replacement with new accounts
can cause an old holder's revision to be rejected. Earlier Hub commitments remain
intact. The tests used a local cap of three, not a verified deployment setting.

**Still unresolved:** whether replacement must preserve existing seats and
revision rights. The [public protocol](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/docs/PROTOCOL.md#L47-L48)
identifies the guard as a live setting, and the
[existing owner-swap test](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/test/ElgoraHub.t.sol#L592)
permits a live guard to reject revisions. Neither settles continuity between
capped guard instances. The behavior is confirmed locally; its classification
as a security violation remains **unverified**, with no assigned severity.
No preservation requirement, risk acceptance or remediation is adopted here.

## Rejections and known lifecycle risk

**ASTRA-005:** The abstract multiplication-overflow candidate requires escrow and
token balances far beyond the reference script's configured amounts, together
with enlarged owner-selected limits. It was rejected for that scoped configuration;
this does not prove correctness for every alternative uint256 configuration.

**ASTRA-006:** [Known issues](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/KNOWN_ISSUES.md) already describes how missing
the settlement window can refund the Poster despite an unsettled award consensus.
The reviewer rated this known lifecycle risk Medium. No new live occurrence was
established. Documentation does not mean acceptance or automatic bounty exclusion.

**ASTRA-007:** Pause followed by ownership renunciation was excluded under the
skill's admin-action gate, not disproved. The publication table uses “excluded”
rather than implying the operational consequence is a false positive. No safe
recovery procedure was established. Pausing and redeployment are not automatic
remedies for escrow in an existing Hub.

## Classification and limitations

The raw assembler's two scored findings map to ASTRA-002 and ASTRA-003. Its five
function-specific leads map to four views of ASTRA-001 and one of ASTRA-004.
ASTRA-005 through ASTRA-007 preserve rejection/known-risk notes rather than inflate
new-finding counts. Private source-trace rejections of other proposed paths are
not certifications of whole-path security.

No fork/live-state checks, new Fizz campaign, off-chain workflow review or
successful gas-denial reproduction. The public source and original dependencies
remained unchanged. The original review was independent of Fabel; the later
combined index is editorial reconciliation, not additional audit coverage.
