# Elgora AI-assisted security review — Fabel

Review date: **6 November 2026 (UTC)**. [Scope](scope.md) · [Findings status](findings-status.md) · [Severity definitions](../README.md#severity-definitions).

This report presents assessed findings, supporting validation, recommendations and limitations. Proposed mitigations are untested directions, not reviewed patches.

## 1. Review identity and assurance limits

This is an AI-assisted review, not a professional audit and not an endorsement by Pashov Audit Group. It used Pashov's open-source x-ray (2.1) and Solidity Auditor (4.1) skills at pin `eacfc09b365d2697b83355909d0300607e596ffc`, run by one orchestrator session plus twelve specialist agents, with parent `claude-fable-5-1` / High verified in host metadata and specialists launched with `model: fable`, `effort: high` (per-agent backend effort is not independently observable; see [scope](scope.md)). Zero findings would not have proven safety, and the findings below do not prove the absence of others. This report offers no bounty reward or authorization to act on a live system.

Reviewed: public snapshot `moleculeprotocol/elgora-contracts` at `744d1e17d8c509ae00c15fb1abf286c2f307290f` (nine Solidity files). Not reviewed: the private monorepo, frontend, backend, crons, off-chain Guardian or Solver tooling, live chain state. All line numbers below are at the pinned SHA.

## 2. Scope and execution summary

| Step | Result |
| --- | --- |
| Pins | code and skill hashes PASS before and after the run ([scope](scope.md)) |
| Preflight | `forge build` ok; CI-profile tests 71/71 pass (fork tests excluded by brief) |
| x-ray | one pass, `src/` only (7 files); outputs retained privately; structural verdict ADEQUATE (a tool label, not security assurance); coverage 97.66% lines / 81.33% branches without fork tests |
| Solidity Auditor | one pass, `--loop 1 --file-output`, no memory, nine files named; 12/12 specialist roles returned, batches of three; raw assembled report: 4 findings, 9 leads |
| Orchestrator validation | private reproduction copy with one added test file (preserved test file), contracts unchanged; 3/3 tests pass (preserved command log) |
| Not done | Fizz campaign, fork tests, live chain reads, any commit or publication |

The skill report keeps two records for one root cause (its function-isolation rule); this assessment merges them as FABEL-001.

## 3. Findings summary

| ID | Title | Severity | Assessment | Resolution | Evidence |
| --- | --- | --- | --- | --- | --- |
| FABEL-001 | Free seats let one Solver lock every rival out of a bounty | Medium | reproduced known behavior | unresolved | raw #1 (`CappedSubmissionGuard.canSubmit`, 10 agents) + raw #2 (`ElgoraHub.submit`); reproduction test 1 |
| FABEL-002 | One junk submission makes the Poster pay the Guardian fee | Low | reproduced known behavior | unresolved | raw #3 (`ElgoraHub._settleOutcome`, 5 agents); reproduction test 2 |
| FABEL-003 | A verdict before the submission deadline lets a winner revision force a timeout refund | Low | confirmed (on-chain mechanism); precondition unverified | unresolved | raw #4 (`ElgoraHub.commitVerdict`, 7 agents) + lead `_settleOutcome`; reproduction test 3 |

Severity uses Critical/High/Medium/Low/Informational with impact and likelihood stated per finding. No Critical or High finding was established in this review. This does not prove that unauthorized transfers, escrow-conservation failures or excess claims cannot occur. Confidence numbers in the raw report are not severities.

## 4. Detailed findings

### FABEL-001 — Free seats let one Solver lock every rival out of a bounty

**Location and evidence**: [src/CappedSubmissionGuard.sol:75](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/CappedSubmissionGuard.sol#L75) (seat taken per `submitter` at 85-94, never released); [src/ElgoraHub.sol:527](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L527) (`submit` validates lifecycle, commitment and roster, then calls the selected admission guard); [src/ElgoraHub.sol:721](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L721) (Guardian fee waived only when `submissionCount == 0`); [script/DeployElgoraHub.s.sol:25](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/script/DeployElgoraHub.s.sol#L25) (`DEFAULT_MAXIMUM_SUBMISSIONS = 10`).

**Preconditions and attacker privileges**: none beyond gas; any set of fresh addresses. Reference deployment-script defaults are 10 seats, 1000 bps Guardian fee and escrow up to 250e6. Live configuration was not checked. The selected guard must be capped, seats must remain and submissions must still be open.

**Reachable sequence**: a Solver submits one real commitment, then nine throwaway addresses each call `submit` with any nonzero commitment. `submissionSeatsUsed` reaches the cap, so every later honest `submit` returns `false` from `canSubmit` and the Hub reverts `SubmissionRejected` until the deadline. The guard owner's cap-adjustment lever, `setBountyMaximumSubmissions`, adds seats that the attacker may also fill; nothing evicts a seat.

**Expected vs actual**: the cap exists so a roster never reviews an unbounded pile; actual behavior permits one party to capture admission by submitting first from multiple addresses.

**Impact**: (a) honest Solvers are excluded and the attacker controls the seated candidates Guardians can consider for an award (225e6 of a 250e6 bounty under deploy defaults); (b) if Guardians reject everything, the Poster still pays the Guardian fee (25e6 at the cap) because the junk seats raised `submissionCount`. Specialists reported local gas estimates, but no live Base transaction cost or profitability was verified. A winner payment still requires the necessary Guardian Awarded verdicts; excluding competitors does not guarantee a win.

**Severity rationale**: Medium. The admission sequence requires no privileged account, but likelihood and cost depend on transaction ordering, available seats and gas prices; no live price estimate is established. Impact bounded per bounty and does not move escrow outside the protocol's own allocation rules, so not High; the profit variant still needs Guardians to award a weak entry.

**Reproduction**: `test_sybilSeatExhaustionLocksOutRivalAndWinsUncontested` passes in the reproduction copy: rival reverts twice (before and after the cap is raised to 12), A claims 225e6, `guardianFeeClaimable == 25e6`.

**Known-issue relationship**: `docs/PROTOCOL.md` ("junk submissions can consume seats") and `test/CappedSubmissionGuard.t.sol::testSeatsAreCheapToSquatAndRaisingTheCapEvictsNobody` acknowledge the squat. `KNOWN_ISSUES.md` does not list it. The existing public seat test already demonstrates exclusion and an unsuccessful-bounty fee. The additional local award scenario illustrates a possible consequence conditional on Guardian agreement; it does not establish novelty or an automatic award. This is a product-level cost-of-entry question; the suggested fixes (a refundable per-seat deposit, a Poster allowlist, or seat release) are design choices, not patches to apply now.

### FABEL-002 — One junk submission makes the Poster pay the Guardian fee

**Location and evidence**: [src/ElgoraHub.sol:721](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L721) (`if (bountyStates[bountyId].submissionCount == 0) { posterRefund += guardianFeeAmount; guardianFeeAmount = 0; }`); [src/ElgoraHub.sol:557](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L557) (any accepted `submit` increments the count); [src/ElgoraHub.sol:923](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L923) (the live `guardianFeeRecipient` sweeps the pool).

**Preconditions and attacker privileges**: positive Guardian fees, an otherwise empty bounty, any address able to make one accepted `submit` before the deadline, a NoValidSubmission quorum, and settlement before timeout.

**Reachable sequence**: junk `submit` → `submissionCount == 1` → two-thirds `NoValidSubmission` → `settle` → the waiver branch is skipped; Poster receives `escrow - guardianFee`, `guardianFeeClaimable` grows by the fee.

**Expected vs actual**: the documented waiver distinguishes zero submissions from nonempty review. The implementation follows that policy even when the admitted commitment represents junk; whether compensable review should require useful work is an unresolved product question.

**Impact**: up to 25e6 per bounty moved from the Poster's refund to the Guardian fee pool; the only party with a direct gain is the fee recipient, an operator-aligned role.

**Severity rationale**: Low. Likelihood medium (trivial to trigger, but the gain lands on a protocol role). Impact is 10% per bounty under the reference defaults. It can repeat across bounties; the submitter does not receive the fee unless it is or shares proceeds with the fee recipient.

**Reproduction**: `test_junkSubmissionMakesPosterPayGuardianFee` passes: clean bounty refunds 250e6, junked bounty refunds 225e6, `guardianFeeClaimable == 25e6`.

**Known-issue relationship**: `test/ElgoraHub.t.sol::testJunkSubmissionPreventsEmptyBountyFeeWaiver` encodes this exact sequence as expected behaviour, so the mechanism was already public; `KNOWN_ISSUES.md` does not list it. Whether Guardians should earn a fee for reviewing junk is a product decision this review does not make.

### FABEL-003 — A verdict before the submission deadline lets a winner revision force a timeout refund

**Location and evidence**: [src/ElgoraHub.sol:580](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L580) (`commitVerdict` has no lower time bound; revisions refused at 608 once `judgingDeadlineAt` passes); `src/ElgoraHub.sol:536,560` (`submit` overwrites the active commitment until `submissionDeadline`); [src/ElgoraHub.sol:711](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L711) (`_settleOutcome` reverts `NoActiveSubmission` on a stale agreed commitment); `src/ElgoraHub.sol:653-654, 835` (settle opens exactly when revisions close; timeout at `settlementTimeoutAt`).

**Preconditions and attacker privileges**: two-thirds of the pinned roster commit `Awarded(S, c1)` before `submissionDeadline`, and no Guardian revises during the `guardianReviewWindow / 2` window (1.5 days at deploy defaults). Trigger: the named Solver S (unprivileged) resubmits `c2`.

**Reachable sequence**: early Awarded consensus → S resubmits → from `judgingDeadlineAt` every `settle` reverts `NoActiveSubmission`; revisions revert `JudgingDeadlinePassed`; a late first-ever verdict for `c2` cannot form a second reached tuple (at most one tuple reaches the threshold) → `timeoutSettlement` queues the full escrow to the Poster; Guardians earn nothing, the winner is unpaid.

**Expected vs actual**: Guardian verdict revisions remain open until judging closes, while Solver revisions end at the earlier submission deadline. An early award can become stale during the submission window. If Guardians do not correct it before judging closes, the frozen quorum can no longer be repaired by those voters.

**Impact**: a Poster who controls the named Solver keeps the Guardian fee (25e6 at the cap) after review work was done; an honest winner who revises late loses the award by accident. Adds a concrete stale-commitment trigger to the documented timeout outcome. The existing stale-commitment test already asserts the settlement revert; the added reproduction follows it through timeout.

**Severity rationale**: Low. The consequence affects one bounty's award and fees. Reachability depends on early Guardian voting and no corrective quorum before judging closes; the reference review half-window is 1.5 days, but actual time remaining depends on when the revision occurs. Production voting behavior was not observed.

**Reproduction**: `test_earlyVerdictThenResubmissionForcesTimeoutRefund` passes: consensus latched before the deadline, `settle` reverts twice, timeout refunds 250e6, `guardianFeeClaimable == 0`.

**Known-issue relationship**: extends the documented timeout-over-consensus behaviour with a new trigger; `test/ElgoraHub.t.sol::testAwardedSettlementRequiresWinnerStillHoldsExactCommitment` asserts the revert but not the follow-on timeout. A proposed lower bound in `commitVerdict` would reject voting before the submission deadline and address this early-voting sequence. It changes lifecycle policy and was not implemented, regression-tested or reviewed as a complete fix. Whether early verdicts are required remains a product decision.

## 5. Unverified leads and rejected candidates

Leads (kept, not scored; assessment = unverified unless stated):

| Lead | Where | What is unverified |
| --- | --- | --- |
| Large `payoutData` raises tally gas (4 agents on `_tally`, 2 on `commitVerdict`) | `ElgoraHub.sol:617, 739-827` | Source review identifies repeated storage-payload hashing in `_verdictMatchesCandidate` and `_verdictMatchesResult`, within the nested `_tally` comparisons (quadratic in roster size in the worst case). `commitVerdict` has no explicit payload-length bound. The pinned `WinnerTakesAllPayoutScheme` ignores payout data when calculating the winner claim; other schemes may need it. Specialists reported 9.6M gas of reads for a 69.6M write at 96 KiB (roster 3), about 33M per settlement with three 128 KB payloads on a roster of ten, and about 40M per honest verdict in that latter setup. Base block gas limit not read; no agent found a size that blocks `settle`. Guardian-only actor. These figures are specialist-reported measurements; their standalone harnesses were not preserved, so the final reproduction does not independently validate them. A length cap or cached hash is an untested mitigation direction with scheme/format compatibility implications. |
| Silent Guardian decides a split roster after the deadline | `ElgoraHub.sol:607-610` | A member with no verdict can vote after `judgingDeadlineAt` with full view of frozen votes. Design consequence of the "first-ever verdict" rule; no on-chain payer found. |
| Two Solvers can hold the same commitment | `ElgoraHub.sol:560` | `SubmissionRecorded` makes the commitment public, and the Hub does not require unique commitments across Solvers. It pays the address Guardians name. Misattribution depends on off-chain tooling crediting content by hash alone; that behavior was not reviewed. |
| A roster Guardian can submit and vote for itself | `ElgoraHub.sol:527, 591` | `submit` does not exclude roster members and a verdict may name its sender. It needs ceil(2n/3) agreement; a one-member roster therefore needs one vote. Live roster size was not read. Trusted-role collusion is a documented trust assumption. |
| Unbounded resubmissions per seat | `CappedSubmissionGuard.sol:85` | A holder can revise repeatedly before the submission deadline without another seat; neither the guard nor Hub imposes a per-holder revision count. The Guardian fee stays fixed. Any resulting off-chain review cost was not measured. |
| Blacklisted winner or Poster locks that balance in the Hub | `ElgoraHub.sol:850, 867` | External issuer action; no attacker trigger established. Claims may remain blocked while issuer restrictions apply; permanent loss was not proved, since an issuer could lift restrictions. No alternative recipient or sweep route was established. |
| Revoked Guardian keeps its vote on open bounties | `ElgoraHub.sol:1210-1232` | Removing or replacing a Guardian changes the live roster hash, not existing pinned membership. An already-open bounty retains a compromised key's vote. A two-member roster needs both votes, so one withholding key can prevent consensus and lead to timeout. This is documented pinning behavior; live roster size and an additional policy violation were not established. |

Rejected at the skill's admin-action gate (recorded so nothing is dropped silently; all need a privileged key acting against intent):

| Candidate | Where | Reason rejected | Note |
| --- | --- | --- | --- |
| `pause()` then `renounceOwnership()` leaves every claim blocked forever | `ElgoraHub.sol:1153-1175`, OZ `Ownable.renounceOwnership` | Owner-only sequence, no unprivileged amplifier | A real operational hazard: `disablePauseAuthority` and `renounceOwnership` do not check `pauseRequested`. Worth an owner runbook rule or a guard in a future version. |
| Guard ownership left pending acceptance after deployment | [script/DeployElgoraHub.s.sol:52](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/script/DeployElgoraHub.s.sol#L52) | Deployer key only | Verify on chain that `acceptOwnership` ran for the mainnet guard (not read here). |
| Hub owner set from one env value without acceptance | `script/DeployElgoraHub.s.sol:36, 50` | Deployment process | Verify the live owner (not read here). |
| Very short `guardianReviewWindow` may leave no usable settlement block | `ElgoraHub.sol:1273-1277, 488-489` | Owner misconfiguration; reference script default 3 days | A minimum compatible with timing policy is a proposed future safeguard, not a tested fix. |

## 6. Known issues and duplicates

- `KNOWN_ISSUES.md` settlement-timeout-over-consensus: not re-reported. FABEL-003 is an additional reproduced mechanism that reaches that outcome; the x-ray maps it as invariant I-13 / E-4 (On-chain=No).
- FABEL-001 and FABEL-002 share a root (a seat and a `submissionCount` increment cost only gas) but have different code-level fixes and victims, so they are kept separate. The raw report's findings #1 and #2 are one root cause split by the skill's function-isolation rule.
- The raw lead "A winner's revision after an early verdict locks settlement" (`_settleOutcome`) is the same mechanism as FABEL-003 seen from the settle side.

## 7. Coverage gaps and next steps

Gaps in this run:
- Fork tests (`test/fork/*`) not run; no live chain state read (coordinator, grace period, roster size, guard owner acceptance, token blacklist state, Base block gas limit). Reachability claims rest on the deploy script's defaults and README's addresses.
- x-ray examined `src/` only; `script/` and `test/` were read by the auditor agents and the orchestrator, not by x-ray. The enumeration fallback recomputed metrics after the local grep lacked `-P`; the execution scope records the Python adaptation; no SVG renderer was installed, so the architecture diagram was not visually validated.
- No Fizz or other fuzz campaign; the only stateful fuzzing is the repository's own three Foundry invariants, run once at CI depth in preflight.
- Per-agent effort is a request parameter; the host does not expose a post-hoc reading (see scope.md). Each agent self-reported `claude-fable-5-1`, which is not proof.
- The twelve-role audit is one pass; additional passes may find other issues, but no further coverage is claimed.

Suggested next steps (not applied fixes): decide seat-admission and fee-waiver policy; assess whether early verdicts are required; verify deployment assumptions before a live-risk claim; investigate resource bounds with preserved evidence; and document privileged pause/renounce hazards. No remediation or risk acceptance is recorded.


## 8. Evidence, raw-report mapping and recommendation limits

The final reproduction used a separate local copy, a mock token and a corrected test fixture, with unchanged production contracts. All three final reproduction tests passed, with Foundry exit code 0. The coordinator was disabled in the local fixture; these results do not establish production coordination behavior.

| Original assembled entry | Public record | Disposition |
| --- | --- | --- |
| Finding 1, `CappedSubmissionGuard.canSubmit`, confidence 85 | FABEL-001 | Same admission root cause as finding 2 |
| Finding 2, `ElgoraHub.submit`, confidence 85 | FABEL-001 | Merged without counting twice |
| Finding 3, `_settleOutcome`, confidence 75 | FABEL-002 | Reproduced documented fee behavior |
| Finding 4, `commitVerdict`, confidence 75 | FABEL-003 | Local stale-verdict and timeout mechanism reproduced |
| Lead: winner revision / `_settleOutcome` | FABEL-003 | Same mechanism seen at settlement |
| Leads: `_tally` hashing and unbounded `commitVerdict` payload | Section 5 gas lead | Two function-specific leads grouped into one topic; denial unverified |
| Leads: blacklist, late first vote, roster revocation, copied commitment, Guardian self-entry, repeated revisions | Six other section 5 topics | Retained separately, unscored |

The raw confidence threshold was 75. Confidence scores are the skill's own screening scores, not calibrated probabilities or vulnerability severities. Four raw findings become three assessed findings. Nine raw leads become seven additional lead topics after mapping the stale-verdict duplicate and grouping the gas pair. None of the seven additional topics has an assigned vulnerability severity. Administrative candidates are excluded separately, not included in Unrated counts.

The raw assembler offered illustrative code changes. Their design content is retained here without presenting incomplete snippets as deployable fixes:

- **Seat admission:** a refundable per-seat deposit, Poster allowlist, or admission release policy. The guard-side sketch introduces `ESCROW_TOKEN`, `seatDeposit` and allowlist state without implementing complete custody, refund, authorization or release rules. The Hub-side deposit sketch introduces `submissionDeposit` and suggests forfeiture on NoValidSubmission. Deposits on every `submit` could also charge revisions unless explicitly handled. Neither sketch establishes an adequate economic deterrent or a safe accounting design.
- **Fee waiver:** replace the zero-count check with a Guardian-agreed indication that reviewable work existed. The sketched `reviewableSubmissionExisted` field is not an implemented input. Defining, authenticating and committing that decision would change the verdict policy and format. It is not a one-line ready fix.
- **Early verdicts:** reject `commitVerdict` before `submissionDeadline`. This targets the reproduced sequence, but changes when Guardians may vote and requires product approval and regression validation.
- **Gas costs:** cache hashes, constrain payload size or constrain roster resource consumption only after evaluating payout-scheme data needs, compatibility and relevant transaction limits. No effective gas-denial remedy has been proved necessary or sufficient by this run.

The raw report's phrases “for cents”, automatic victory and permanent blacklist loss are not established conclusions. This edition preserves the underlying scenarios while qualifying ordering, Guardian agreement, issuer reversibility and live-state uncertainty. No finding has been fixed merely by documenting it.
