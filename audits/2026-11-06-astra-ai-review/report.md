# Elgora AI-assisted security review — Astra

Review date: **6 November 2026 (UTC)**. [Scope](scope.md) · [Findings status](findings-status.md) · [Severity definitions](../README.md#severity-definitions).

This report presents assessed findings, supporting validation, recommendations and limitations. Proposed mitigations are untested directions, not reviewed patches.

## 1. Review identity and assurance limits

Reviewer: **astra**, 2026-11-06 UTC. Public snapshot: `744d1e17d8c509ae00c15fb1abf286c2f307290f`. One X-ray 2.1 pass and one Solidity Auditor 4.1 pass used the pinned skill commit `eacfc09b365d2697b83355909d0300607e596ffc`.

All twelve specialist roles completed. The parent, X-ray agent and twelve specialists were verified as `gpt-6-astra` with `high` effort through narrowly selected host session metadata. This is an AI-assisted review, not a professional audit or an endorsement by Pashov Audit Group. Completed role coverage does not mean complete validation or bug freedom.

**No new vulnerability was confirmed by this review.** Two adverse economic behaviors were already documented or tested in the public snapshot. The bounded follow-up completed nine local checks. ASTRA-001 remains unverified as settlement denial under an applicable transaction limit; ASTRA-004 remains unverified as a violation of the intended guard-replacement policy.

The work remained private and local apart from configured model inference and the authorized public repository/dependency fetch. No sibling review, private monorepo, prior audit or global audit-memory files were inspected. The parent chat initially included generic injected memory and private-project instructions; these were not independent findings evidence. Specialists received fresh bounded context. No comparison with another review occurred during the independent run. The later public index reconciles overlaps editorially; it does not add audit coverage.

## 2. Scope and execution summary

The auditor reviewed all nine named production/interface/deployment files: `script/DeployElgoraHub.s.sol`, `script/DeployLocalDev.s.sol`, `src/CappedSubmissionGuard.sol`, `src/ElgoraHub.sol`, `src/IERC3009.sol`, `src/IPayoutScheme.sol`, `src/ISubmissionGuard.sol`, `src/PassThroughSubmissionGuard.sol`, and `src/WinnerTakesAllPayoutScheme.sol`. Public README, SOURCE, SECURITY, KNOWN_ISSUES and PROTOCOL documents supplied context; tests and pinned dependencies supplied supporting evidence.

X-ray source analysis covered the four concrete implementation contracts, not the three interfaces or two deployment scripts. It reported 1,073 implementation nSLOC, 29 source-declared state-changing entrypoints plus six inherited ownership instances, 48 guards, 20 single-contract invariants, one cross-contract invariant and two economic invariants. These are structural observations, not proof of security.

Baseline `forge build` passed. `FOUNDRY_PROFILE=ci forge test --no-match-path 'test/fork/*'` passed **71 tests across four suites**, with no failures or skips. X-ray `forge coverage --no-match-path 'test/fork/*'` also passed 71 tests without an IR retry. Hub coverage was 99.50% lines and 93.42% branches. Coverage instrumentation disabled optimization and emitted anchor warnings; coverage is not assertion strength.

Validation used a corrected test fixture; all nine final follow-up checks passed. The ordinary control and bounded payload cases settled and paid the winner. Guard-replacement checks demonstrated admission changes. Section 8 records the setup, measurements, assertions and remaining limitations.

Final verification passed for the pinned skill files, code HEAD, full tracked inventory and dependency pins. All **983 original tracked files including recursive dependencies** matched the separate reproduction copy. Original tracked Git status was clean. No contract, tracked test, configuration, document or dependency was changed. No commit, push, deployment, broadcast, publication, upload, fork test or Fizz campaign occurred.

The [scope record](scope.md) documents commands, model provenance and execution limits. Original specialist outputs, assembled reports and the detailed judging ledger remain unchanged in the private evidence archive. This report includes their assessed conclusions and substantive rejected paths.

## 3. Findings summary

Severity reflects impact and likelihood, not the upstream confidence score. Unverified leads have no assigned vulnerability severity. “Duplicate” means the mechanism already exists in supplied public evidence; it does not mean accepted, fixed or excluded from a bounty.

| ID | Title | Severity | Assessment | Resolution | Evidence |
|---|---|---|---|---|---|
| ASTRA-001 | Minority verdict payload may obstruct settlement | Unrated — unverified | unverified | unresolved | Source hypothesis and section 8 bounded follow-up |
| ASTRA-002 | Fresh accounts can exhaust submission seats | Medium — known admission risk | duplicate | unresolved | economic specialist; baseline results |
| ASTRA-003 | Junk submission can remove the empty-bounty fee waiver | Low — policy-dependent incentive | duplicate | unresolved | economic specialist; baseline results |
| ASTRA-004 | Fresh capped-guard replacement loses prior seat history | Unrated — unverified | unverified | unresolved | Source hypothesis and section 8 three-case behavioral reproduction |
| ASTRA-005 | Extreme fee multiplication overflow | N/A — rejected in reference configuration | false positive | N/A | math lead |
| ASTRA-006 | Timeout refunds an unsettled award to the Poster | Medium — documented lifecycle risk | duplicate | unresolved | [KNOWN_ISSUES.md](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/KNOWN_ISSUES.md) |
| ASTRA-007 | Owner pauses then renounces ownership | N/A — excluded admin-only candidate | excluded admin-only candidate | N/A for scoped finding | access-control notes |

The upstream assembler contains two scored findings and five function-specific leads. Its findings are ASTRA-002 and ASTRA-003. Four of its leads map to ASTRA-001; the fifth maps to ASTRA-004. This assessment groups the shared gas root cause without editing the upstream report. ASTRA-005 is explicitly rejected in the separate ledger, not silently dropped. ASTRA-006 and ASTRA-007 preserve substantive notes rather than inflate new-finding counts.

## 4. Detailed findings

### ASTRA-002 — Fresh accounts can exhaust submission seats

**Evidence and location.** At the pinned SHA, [CappedSubmissionGuard.canSubmit](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/CappedSubmissionGuard.sol#L75) and [ElgoraHub.submit](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L527) allocate one permanent seat per admitted address. Raw origin: agent 03, `ECON-01`. The existing `testSeatsAreCheapToSquatAndRaisingTheCapEvictsNobody` passed in the baseline; its source is [existing seat test](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/test/CappedSubmissionGuard.t.sol#L262). The protocol already states that junk can consume seats.

**Preconditions and privileges.** The capped guard is selected, seats remain available, and the submission deadline has not passed. An ordinary account holder can use multiple addresses. No owner, Guardian or coordinator privilege is required. The reference script sets a cap of ten; its live deployment state was not checked.

**Reachable sequence.** Fresh accounts each submit a nonzero commitment. Identical content is not required to be distinct across accounts. Once the selected guard reaches capacity, a later honest Solver is rejected and cannot establish an active submission. Increasing the cap adds more seats that the attacker can also take. An already admitted Solver can still revise under the same guard.

**Expected versus actual.** The cap bounds admitted addresses, not independent humans or useful work. The implementation follows its documented rule; it does not provide Sybil-resistant admission. The adverse outcome is exclusion of later Solvers and loss of useful competition. If every accepted submission is invalid and Guardians settle NoValidSubmission, the nonempty-bounty fee rule can also reduce the Poster refund.

**Impact and severity.** Medium for cheap, repeatable admission denial against a scarce public resource. The attacker pays transaction gas but deposits no escrow tokens. Likelihood depends on ordering and the selected guard. This does not guarantee an attacker wins a bounty or receives any fee. Under the script's 250-USDC maximum and 10% Guardian fee, the failed-bounty fee can be 25 USDC; the baseline fixture instead demonstrates 0.35 USDC on a 10-USDC bounty.

**Reproduction.** The preflight CI-profile command above passed the exact existing characterization test (reported gas 884409). No new seat-exhaustion experiment was needed or run. This is local mocked evidence, not a live profitability claim.

**Known issue and resolution.** Duplicate of public protocol/test evidence; distinct from the settlement-timeout issue. No risk acceptance was supplied. Resolution remains unresolved. Authentication or a bond requires a product decision. Removing the cap trades away the workload bound; rejecting duplicate commitments does not establish independent identities. No patch was applied or represented as ready to ship.

### ASTRA-003 — Junk submission can remove the empty-bounty fee waiver

**Evidence and location.** [ElgoraHub._settleOutcome](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L719) bases the NoValidSubmission fee waiver on zero submissions; [ElgoraHub.claimFees](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L917) pays the live fee recipient. Admission uses [ElgoraHub.submit](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L527). Raw origin: agent 03, `ECON-02`; agent 11 separately notes that the compensation policy is explicit. [existing junk-submission test](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/test/ElgoraHub.t.sol#L847) already covers this behavior.

**Preconditions and privileges.** Positive Guardian fees, an available seat or pass-through guard, an otherwise empty bounty, an honest NoValidSubmission quorum and settlement before timeout. The submitting account needs no special authority. Financial benefit requires receiving or sharing the fee recipient's entitlement. An outsider can cause the refund reduction without receiving it.

**Reachable sequence.** The fee recipient or an affiliate submits a junk commitment. Honest Guardians judge that there is no valid submission. Settlement now charges the fee because the submission count is positive. The live recipient can collect the accrued fee through the normal fee claim path.

**Expected versus actual.** An empty bounty receives a full refund. An admitted junk submission changes it into compensable review under the existing rule, even if it provides no useful work. The contract follows that rule; the unresolved question is whether the resulting incentive is acceptable. It is not an unauthorized fee-claim or escrow-conservation bypass.

**Impact and severity.** Low as a bounded, policy-dependent incentive: the reference configuration transfers 10% of escrow to the Guardian fee pool after nonempty unsuccessful review. The rule can repeat across bounties, but successful extraction still requires quorum settlement and a fee-sharing beneficiary. For 250 USDC, the gross allocation difference is 25 USDC. Net profit, live costs and the value of legitimate review were not measured. The specialist's Medium label is retained in raw evidence; this assessment reduces severity because compensating failed review is an explicit rule, not an implementation deviation.

**Reproduction.** The baseline passed `testJunkSubmissionPreventsEmptyBountyFeeWaiver` (reported gas 644628). Its 500-USDC/350-bps fixture establishes a 17.5-USDC fee; those fixture values are not the production script defaults. Existing fee-claim tests separately cover collection. No new economic experiment was performed.

**Known issue and resolution.** Duplicate of an existing test and described compensation behavior; separate from ASTRA-002 because one submission suffices and no cap is required. Resolution remains unresolved; documentation is not acceptance. The original recommendation was to base the fee on authenticated compensable review or make junk submissions economically costly enough to prevent fee extraction. Either approach changes the compensation policy and requires deciding how legitimate unsuccessful review should be paid. Neither was implemented or validated as a fix.

## 5. Unverified leads and rejected candidates

### ASTRA-001 — Minority verdict payload may obstruct settlement

**Source and raw mapping.** [ElgoraHub.commitVerdict](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L580) accepts dynamic payout data. [ElgoraHub._tally](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L739) repeatedly compares tuple data through [tuple comparison](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L805) and the supporter path. Origins: `ECON-L01`, `EXEC-04-L1`, agent 05's unnumbered composite-function lead, `A07-L01`, `A08-L1`, `BOUNDARY-L1`, `AG11-L01`, and `AG12-L1`. Eight agents converging on a code pattern does not prove a feasible exploit.

**Hypothesized sequence and powers.** A member of the bounty's pinned Guardian roster supplies a large dissenting payload after an honest quorum has reached consensus. Later writes can skip immediate tally once the first-consensus timestamp exists. Settlement re-tallies, and equal scalar tuple fields cause payload hashing. A proposed resource imbalance could prevent a timely award, leaving the documented timeout refund. This requires Guardian access, suitable ordering and a feasible payload/gas budget; it is not an unprivileged public call.

**Validation and current status.** The bounded follow-up established successful settlement and award claims while measuring increased execution cost. The full results and remaining resource-limit question appear in section 8. Hash caching, payload bounds and roster resource bounds remain untested design suggestions; compatibility with payout schemes and the public verdict format must be assessed before adopting them.

### ASTRA-004 — Fresh capped-guard replacement loses prior seat history

**Source and privileges.** `CappedSubmissionGuard.canSubmit` stores seats locally. `ElgoraHub.setSubmissionGuard` changes the live guard for open bounties. The original periphery and flow-tracing specialists raised this independently. The scenario requires an authorized owner replacement followed by ordinary accounts taking fresh seats.

**Original hypothesis and updated evidence.** Prior active commitments remain in the Hub, but a replacement does not recognize old seats. Three later regression checks reproduced this behavior, including rejection of an earlier holder's revision after new accounts fill the replacement. Section 8 preserves the complete setup, assertions and policy analysis.

**Assessment and recommendation.** Unrated / unverified as a vulnerability / unresolved. Local behavior is established; whether replacement must preserve seats and revision rights remains unspecified. Per-bounty guard pinning or explicit migration would change policy and needs a decision. Importing the Hub's submission count as a seat count would be incorrect because it includes revisions. No fix or risk acceptance is recorded.

### ASTRA-005 — Extreme fee multiplication overflow

Raw `MATH-L01` identifies checked multiplication before division in `_settlementAmounts`. The abstract uint256 counterexample is valid, but requires an astronomical escrow and corresponding token balance plus a radically enlarged owner-selected escrow limit. The reference 250e6 maximum multiplied by 1000 is only 250e9. Agent 10 independently rejects practical reachability. No feasible source-configured threat was established. Assessment: **false positive for this scoped configuration**, resolution N/A. This is not a claim that arithmetic supports every arbitrary uint256 configuration. The raw unapplied `Math.mulDiv` suggestion is preserved; no change was made.

### ASTRA-007 and other rejected routes

Owner pause followed by inherited ownership renunciation can remove the only unpause authority. Raw agents 02, 04, 05, 06, 07 and 11 discuss the consequence. No unprivileged amplifier was found, so it is excluded under the skill's admin-action gate. Exclusion means this is not a scoped attacker finding; it does not deny the operational consequence. Redeployment does not recover old escrow, and pausing is not an automatic remedy.

Other saved rejected traces include unauthorized ERC-3009 funding, replay through a different caller, duplicated award claims, caller-selected fee recipients, callback privilege acquisition, and rounding-based escrow inflation. The corresponding guards or allocation checks interrupted the proposed paths in source review. These are not certifications of whole-path safety. Live fee-recipient rotation is an explicit role entitlement; arbitrary malicious owner-selected token/guard/scheme behavior is outside the demonstrated unprivileged paths. Detailed traceability is in gate and completeness ledger and the original specialist reports.

## 6. Known issues and duplicates

**ASTRA-006** preserves the explicitly supplied settlement-window risk. [settle](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L649) rejects at or after the timeout; [timeoutSettlement](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L831) can refund an open bounty in full without tallying. The Winner and Guardian fees receive no allocation from that timeout branch. A late consensus, coordinator withholding through a long grace window, or a pause spanning the deadline can lead to this outcome. The coordinator bypasses its own caller gate but does not bypass tally. Pausing freezes settlement and timeout without extending deadlines.

This is duplicate / unresolved, Medium for loss of an expected award when settlement does not complete in time. Source and existing lifecycle tests support the documented behavior; no new runtime test or live occurrence was established. [KNOWN_ISSUES.md](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/KNOWN_ISSUES.md) explicitly disclaims acceptance and automatic bounty exclusion. No risk has been accepted on the user's behalf.

ASTRA-002 and ASTRA-003 are also known through public documentation/tests, even though KNOWN_ISSUES.md does not enumerate them. ASTRA-001 would require independent mechanism proof before being called either a new vulnerability or a duplicate. ASTRA-004 concerns admission migration, not missed settlement.

## 7. Coverage gaps and next steps

All twelve specialist roles completed. The follow-up completed nine bounded local checks without rerunning specialists. ASTRA-001 still needs a justified transaction budget and deployment assumptions before a denial or severity claim. ASTRA-004 still needs a migration requirement before a security classification or fix can be selected. The known economic behaviors require explicit product/risk decisions, not automatic patching or acceptance.

No fork tests, live RPC state, actual gas limits/prices, live token issuer controls, deployed ownership/roster/guard state, frontend/backend/cron or private development history were checked. Mock authorization tests do not establish real USDC integration. The short public export history does not describe private development history. X-ray's SVG was structurally validated in the original run; a later gap check rendered and inspected it. This does not add contract validation.

Original evidence remains private and unchanged. No risk acceptance or remediation action is established by this report. Final input verification passed; no source deviation was found. Complete reporting does not imply exhaustive security validation.


## 8. Complete bounded follow-up — 6 November 2026

Nine regression checks passed, with actual Foundry exit code 0. This separately authorized work supplements the original review; it is not another specialist pass.

### Fixed inputs and method

Public snapshot: **744d1e17d8c509ae00c15fb1abf286c2f307290f**, `moleculeprotocol/elgora-contracts`. Existing skill pin: **eacfc09b365d2697b83355909d0300607e596ffc**, X-ray 2.1 / Solidity Auditor 4.1. No skill, specialist, full audit, baseline suite or coverage pass was rerun. No model substitution or delegation was used. This follow-up remained in the existing Astra session.

Foundry **1.5.1-stable**, Solidity **0.8.36**, Cancun, optimizer enabled with 200 runs, `via_ir=false`, using unchanged pinned configuration and dependencies. The copied fixture uses MockUSDC and a local three-Guardian roster. All new checks are in AstraFollowup.t.sol; the exact file addition is test-addition.patch. Production contracts and all original tracked inputs are unchanged.

The final suite passed **nine checks**, with Foundry exit code **0**. Seven checks covered the ordinary settlement control, bounded settlement/claim observations and guard replacement; two checked validation-harness consistency. The latter are not additional contract-security findings. No parameter search, failure-threshold search or larger-payload campaign occurred. The largest measured payload was 131,072 bytes.

The final suite command was:

```sh
forge test --match-path test/AstraFollowup.t.sol -vv
```

This command selects the added local test file and excludes fork tests. The executable test file and execution log are retained privately.

### ASTRA-001 — bounded cost observations

The ordinary control verifies the named Solver's active commitment, Awarded settlement, the correct winner and Guardian fee allocation. Production contract code was unchanged.

#### Measured local behavior

The bounded observations use fixed payload cases and the local submission fixture. Each test starts from its own initialized state. The ordinary control uses the two honest verdicts. Each payload case adds a first minority verdict after judging with matching scalar award fields and a different payload, then settles the honest award and claims it.

| Local case | Minority verdict execution gas | Settlement execution gas | Settlement and winner claim |
|---|---:|---:|---|
| Ordinary control; no minority verdict | N/A | 127,795 | passed |
| 4,096-byte payload | 433,312 | 536,130 | passed |
| 131,072-byte payload | 10,572,715 | 12,778,681 | passed |

Values are `vm.lastCallGas().gasTotalUsed`, after `vm.cool(address(hub))` before the measured Hub calls. They are **call execution gas**, not full transaction costs. No calldata intrinsic cost, access-list behavior, inclusion limit, network fee or deployed block/transaction gas rule is inferred. The calls use a generous local ceiling of 100,000,000 gas; that ceiling is not a claim about any network.

Each measured case asserts Awarded status, the proper winner, 2 USDC accrued Guardian fees on a 20-USDC escrow, an 18-USDC winner transfer and 2 USDC remaining in the Hub. No timeout/refund diversion is observed. The compiler and local fixture materially constrain what these measurements establish.

#### Assessment

The cost increase is real in this bounded local fixture and is consistent with repeated payload reads in [_tally](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L739) and [tuple comparison](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L805). [commitVerdict](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L580) can store later verdict data without immediately repeating tally after the first consensus timestamp exists. These source observations remain relevant, but do not themselves establish a feasible denial under a relevant transaction limit.

**ASTRA-001 remains unverified / unresolved as a vulnerability.** Successful settlement under a generous local ceiling does not rule out the broader lead. Deployment-specific feasibility and a justified resource-limit conclusion were not established; no gas threshold was searched for. No new severity, live-fund-loss claim or tested fix follows from this work.

### ASTRA-004 — demonstrated behavior and missing requirement

The three guard regression cases use a cap of three to expose state transitions with few accounts. This is a local test parameter, not a live-configuration claim. An authorized owner replaces one bound CappedSubmissionGuard with a fresh bound instance at the same cap while the bounty is open.

The checks establish:

1. Before replacement, three distinct Solvers fill the original guard. An existing holder can revise at capacity without consuming a fourth seat; a new account is rejected.
2. Immediately after replacement, old Hub commitments remain. The original guard still records old seats, while the replacement records zero. If an old holder revises while replacement capacity exists, the replacement charges a fresh seat.
3. If three new accounts fill the replacement first, the old holder's revision reverts with **SubmissionRejected**. Six distinct accounts retain active Hub commitments even though each guard counts only three. The Hub's submission count is seven because it includes one earlier revision. Rejection rolls back the attempted new commitment and count, preserving the prior commitment.

Relevant pinned source: [guard-local seat maps](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/CappedSubmissionGuard.sol#L39), [canSubmit](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/CappedSubmissionGuard.sol#L75), [Hub submission and rollback](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L527), and [live guard setter](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/src/ElgoraHub.sol#L1130). The three test names and PASS results are in the final log.

**The behavior is now confirmed locally; its security classification remains conditional.** [PROTOCOL seat reuse](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/docs/PROTOCOL.md#L14) says revisions reuse a seat, while [live settings](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/docs/PROTOCOL.md#L45) explicitly permits guard changes. The source defines a new guard's local state and does not migrate it. The supplied specification does not settle whether an owner replacement must preserve prior seats, counts, overrides and revision rights. Existing [owner-swap test](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/test/ElgoraHub.t.sol#L592) deliberately permits a live guard to reject revisions; it does not establish continuity between capped instances.

If continuity across same-policy replacement is a required guarantee, the demonstrated behavior violates it. If replacement intentionally resets admission policy, the outcome may be authorized behavior requiring operational care. No continuity requirement has been adopted by this review. This report chooses neither policy and accepts no risk. **ASTRA-004 remains unverified / unresolved as a vulnerability**, with the behavioral observation now supported by regression evidence. No contract patch or migration design was applied.

### Provenance, integrity and residual limits

The original review records, reproduction artifacts and execution logs remain private and unchanged. The public report records the final assessed results and their evidence limits.

The final verifier passed the original public HEAD/inventory/hashes/dependency pins and the skill pin/versions/hashes. A separate byte comparison confirmed **983 original tracked files including recursive dependencies** are identical in this follow-up copy. **113 protected original evidence files** matched the pre-follow-up manifest. Input and evidence integrity checks passed.

Fork tests, live-chain/RPC checks, broadcasts, exploit deployment and Fizz were excluded by the original brief and remain excluded. They are not unfinished required steps of this bounded follow-up. No new full audit or specialist pass ran. No publication, upload, commit, push, third-party disclosure or contract change occurred.

Passing mocked local tests do not establish live USDC behavior, current deployment configuration, an applicable transaction gas budget, general liveness, safety for arbitrary payload/roster combinations, or exhaustive absence of vulnerabilities. ASTRA-001's resource-limit question and ASTRA-004's normative policy question remain distinct. These results do not support describing the contracts as comprehensively clean.


## 9. Assembled-report coverage map

| Original entry | Assessed record | Evidence disposition |
| --- | --- | --- |
| Finding 1: seat exhaustion, confidence 90 | ASTRA-002 | Known behavior; public characterization test passed |
| Finding 2: junk-generated fees, confidence 90 | ASTRA-003 | Known policy; test establishes allocation, not net profitability |
| Lead: replacement guard / `canSubmit` | ASTRA-004 | Later behavior reproduced; continuity requirement unresolved |
| Lead: composite `commitVerdict/_tally` | ASTRA-001 | Common resource-cost hypothesis |
| Lead: later `commitVerdict` writes skip tally | ASTRA-001 | First-consensus ordering matters to write/read cost |
| Lead: `_tally` repeated work | ASTRA-001 | Bounded costs measured; settlement denial not established |
| Lead: `_verdictMatchesCandidate` payload reads | ASTRA-001 | Equal scalar fields reach hashing; differing fields short-circuit |

The raw confidence threshold was 75. Confidence 90 is a tool-assigned screening score, not a calibrated probability or severity. ASTRA-005/006/007 retain additional rejected, known-risk and administrative notes outside the raw assembler's two scored findings and five leads. No raw finding or lead is silently removed from the assessed record.
