# Fabel review scope and execution

Review date: 2026-11-06 UTC. One-pass review completed; production preconditions remain unchecked.

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

## Model evidence and deviations

The run records parent `claude-fable-5-1` / High from host metadata. All twelve
specialist calls requested alias `fable` / High. There was no independent
post-hoc per-agent effort reading; self-identification was retained as data,
not verification. These are the run's recorded settings, not a certification
of the provider's backend routing by the publication editor.

X-ray enumerated seven src files; its treatment of interfaces differs from
Astra's four-implementation scope. The auditor covered all nine named files.
Counts across the reports should not be interpreted as conflicting coverage
measurements without accounting for scope. The SVG was not visually validated.

The session opened with its working directory in the private monorepo and an
automatically loaded memory index. The run states that no files in that checkout
were read and that memory was not used as evidence. This is a declared isolation
deviation; an absolute claim of a context-free review would be inaccurate.

Several specialists reported local proof experiments outside the audited
repository, which the skill permits. Their complete standalone test files and
patches were not retained in the review package, so those experiments cannot be
independently rerun from that package alone. This falls short of the brief's
proof-artifact recording requirement; it is not evidence of writes inside the
audited repository. The final orchestrator reproduction used a separate copy,
and its test file, hash and execution log were preserved. The tracked audited
inputs passed integrity checks.

## Added reproduction evidence

The recorded final run passed all three tests in `FabelReproduction.t.sol`, using a corrected test fixture. The source contracts were unchanged. The private test file SHA-256 is
`c397766677ba504458cbf74f126215849a50edb95d37aa65a76a8b897dea74bd`.
Its coordinator is disabled in the fixture; this is not a fork of the live Hub.
The logs and executable reproduction remain private pending disclosure review.
