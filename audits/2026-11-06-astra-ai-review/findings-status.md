# Astra findings status

Status date: **2026-11-06**. No fix, mitigation or risk acceptance is established.
“Duplicate” denotes public prior evidence, not a bounty exclusion. See [report](report.md).

| ID | Assessment | Resolution | Basis |
| --- | --- | --- | --- |
| ASTRA-001 | Unverified | Unresolved | Ordinary control and bounded payload cases settle and pay; no denial under an applicable transaction limit established |
| ASTRA-002 | Duplicate of public admission/test evidence | Unresolved | Existing test demonstrates seat exhaustion and fee consequence |
| ASTRA-003 | Duplicate; documented policy/incentive concern | Unresolved policy decision | Fee implementation follows documented rule |
| ASTRA-004 | Unverified | Unresolved | Seat loss and revision rejection confirmed locally; binding continuity requirement unestablished |
| ASTRA-005 | Rejected for reference configuration | N/A | Abstract arithmetic concern lacks feasible reference-configuration inputs |
| ASTRA-006 | Duplicate of known timeout issue (rated Medium in the report; shown separately from new findings in the review index) | Unresolved | Public known-issue documentation and lifecycle behavior |
| ASTRA-007 | Excluded admin-only candidate | N/A as scoped attacker finding | Operational hazard is not disproved; no unprivileged amplifier shown |

Append future dated changes with evidence and distinguish source remediation from deployed-contract status.

Follow-up on **2026-11-06**: nine local checks passed with actual Foundry exit code 0. Bounded settlement and claims succeeded; guard-replacement behavior was reproduced. Both vulnerability classifications remain unverified for the distinct reasons above.
