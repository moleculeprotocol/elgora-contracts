# Astra review scope and execution

Review date: 2026-11-06 UTC. Original review and bounded technical follow-up complete; two vulnerability
questions remain unresolved.

## Reviewed snapshot

- Repository: [moleculeprotocol/elgora-contracts](https://github.com/moleculeprotocol/elgora-contracts).
- Public commit: `744d1e17d8c509ae00c15fb1abf286c2f307290f`.
- Export source commit: `8d40270d617a63dd5a7a35045db0d9ea3ddd9093`, as recorded in [SOURCE.json](https://github.com/moleculeprotocol/elgora-contracts/blob/744d1e17d8c509ae00c15fb1abf286c2f307290f/SOURCE.json).
- Skills: [pashov/skills at the pinned commit](https://github.com/pashov/skills/tree/eacfc09b365d2697b83355909d0300607e596ffc); Solidity Auditor **4.1**, X-ray **2.1**.
- One X-ray pass, then one auditor pass; all twelve specialist roles returned,
  scheduled at up to three concurrently. No cross-review findings were shared
  before the independent reports were finalized.

## Auditor files

```
script/DeployElgoraHub.s.sol
script/DeployLocalDev.s.sol
src/CappedSubmissionGuard.sol
src/ElgoraHub.sol
src/IERC3009.sol
src/IPayoutScheme.sol
src/ISubmissionGuard.sol
src/PassThroughSubmissionGuard.sol
src/WinnerTakesAllPayoutScheme.sol
```

Tests, public documentation and pinned dependencies were supporting evidence,
not independent full audit targets. The public export history does not establish
the private project's development history.

## Toolchain and baseline

Foundry 1.5.1; Solidity 0.8.36; Cancun; optimizer 200; `via_ir=false`.
forge-std pin: `77041d2ce690e692d6e03cc812b57d1ddaa4d505`.
OpenZeppelin pin: `5fd1781b1454fd1ef8e722282f86f9293cacf256`.

Both commands passed in this run:

```sh
forge build
FOUNDRY_PROFILE=ci forge test --no-match-path 'test/fork/*'
```

The baseline had 71 passing tests. X-ray coverage also ran with fork tests
excluded. Coverage used different compiler instrumentation from the ordinary
build; it measures execution, not assertion quality or security assurance.
The whole-project coverage totals were 97.66% lines and 81.33% branches;
these totals include scripts and test helpers, not only production contracts.

## Common limitations

No fork tests, live chain reads, deployed configuration verification, live gas
costs/limits, issuer blacklist checks, off-chain Guardian behavior, frontend,
backend, cron jobs, private history or new Fizz campaign. Existing Foundry
invariants ran in the baseline; that is not a Fizz campaign.

The upstream macOS enumeration command encountered unsupported `grep -P`;
Python enumeration was substituted without modifying the skill snapshot.
Model-selection and concurrency adaptations were recorded. All outputs remained
private during the review. Hash verification passed for the original tracked
code and skill inputs; no contract remediation or deployment occurred.

## Model evidence and runtime deviations

The run records parent, X-ray helper and twelve specialists as `gpt-6-astra` /
High, using narrowly selected host metadata. Children had fresh context and
explicit model/effort settings. The publication editor retains this recorded
provenance; it does not independently certify internal provider routing.

X-ray source analysis covered four concrete implementation contracts. Interfaces
and deployment scripts were additional auditor scope. The original SVG was checked
structurally. A separate editorial follow-up rendered and visually inspected it;
that presentation check is not original-run security evidence. Native host tools replaced equivalent
upstream task, shell and agent APIs; the three-agent scheduling cap was explicit.

Generic memory and private-project instructions were initially injected into
the parent chat. The run records no reading of private monorepo files, sibling
reports or prior-audit memories, and no use of that context as findings evidence.
This qualification is retained instead of claiming perfect context isolation.

## Validation outcome and follow-up provenance

A bounded follow-up on 6 November 2026 used the same pinned inputs in an isolated copy. Validation used a corrected test fixture. It checked ordinary settlement, bounded settlement/claim behavior and admission changes after guard replacement. The final command was:

```sh
forge test --match-path test/AstraFollowup.t.sol -vv
```

**Nine checks passed; actual Foundry exit code 0.** Seven cover contract behavior and two check validation-harness consistency; the latter do not add contract-security findings.
The test-only file and logs remain private. No full audit, specialist, baseline
suite, coverage pass, fork or Fizz campaign was rerun.

MockUSDC, a local three-Guardian roster and a generous local call ceiling limit
the settlement-cost evidence. The guard tests used a local cap of three. These
checks do not establish production gas limits, live configuration or a binding
seat-continuity policy. ASTRA-001 and ASTRA-004 remain unverified as vulnerabilities.
See the [report](report.md) for demonstrated behavior and open questions.

Final pin verification passed. The follow-up integrity record reports all 983
original tracked files, including recursive dependencies, unchanged, and all 113
protected original evidence files matching their prior hashes. No contract fix,
mitigation or risk acceptance occurred. Original evidence remains private and unchanged; this report records the final assessed results.
