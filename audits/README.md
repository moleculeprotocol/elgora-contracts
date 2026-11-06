# Security reviews

These are **AI-assisted security reviews conducted for Elgora using Pashov Audit
Group's open-source skills**. They are not professional audits, reviews performed
by Pashov staff, or endorsements by Pashov Audit Group. They do not prove the
absence of vulnerabilities.

The `audits/` directory contains security review records; each report identifies
whether it is an AI-assisted review or a professional audit.

| Review date (UTC) | Reviewer label — recorded host model (effort) | Audited public commit | Coverage and validation | Report |
| --- | --- | --- | --- | --- |
| 2026-11-06 | `fabel` — `claude-fable-5-1` (High) | `744d1e17d8c509ae00c15fb1abf286c2f307290f` | 12/12 roles; three local mechanism tests passed; live preconditions unchecked | [Fabel report](2026-11-06-fabel-ai-review/report.md) |
| 2026-11-06 | `astra` — `gpt-6-astra` (High) | `744d1e17d8c509ae00c15fb1abf286c2f307290f` | 12/12 roles; nine follow-up local checks passed; two vulnerability questions unresolved | [Astra report](2026-11-06-astra-ai-review/report.md) |

The independent runs used the same code and skill pins. The publication editor
compared their completed reports afterward. Model identifiers above are recorded host identifiers, not independently
verified vendor product names. High denotes the verified parent setting;
per-agent verification differs between hosts, as each scope record explains. Reviewed reports below preserve those limits and
identify editorial classification changes. Original raw reports and working logs
remain private; these are not verbatim tool transcripts. Astra’s separately
authorized technical follow-up on 6 November is incorporated with its provenance;
it did not rerun the independent review or resolve both vulnerability questions.

## Combined findings map

This table groups overlapping observations; it is not another audit or a count
of independently verified vulnerabilities. Reviewer-assigned severities are
shown in each report. No risk acceptance or deployed fix is recorded.

| Topic | Fabel record | Astra record | Reconciled evidence and status |
| --- | --- | --- | --- |
| Submission seat exhaustion | FABEL-001 | ASTRA-002 | Known admission risk demonstrated by public tests and Fabel's local test; unresolved |
| Junk submission changes fee waiver | FABEL-002 | ASTRA-003 | Documented fee policy and reproduced incentive concern; not an established specification violation; unresolved |
| Early award verdict becomes stale after revision | FABEL-003 | No separate finalized finding | Locally reproduced mechanism; production Guardian behavior not checked; unresolved |
| Verdict payload increases settlement work | Unscored lead | ASTRA-001 | Bounded local cost increase measured; tested settlement/claims pass; relevant-limit denial unverified/unresolved |
| New guard has no earlier seat history | No separate finalized finding | ASTRA-004 | Seat loss and revision rejection reproduced after authorized replacement; policy violation unverified/unresolved |
| Missed settlement window leads to refund | Known outcome; related to FABEL-003 | ASTRA-006 | Already documented in [known issues](../KNOWN_ISSUES.md); unresolved |

Neither review identified a confirmed unauthorized-transfer or escrow-conservation
vulnerability. This is a bounded review outcome, not proof that no such path
exists. Agreement between models is not independent runtime validation.

## Reading and updates

Read `report.md` for conclusions, `scope.md` for methods and limitations, and
`findings-status.md` for the latest assessment and resolution.

Reproduced
behavior, novelty, specification compliance and production reachability are
separate questions. Documentation of a risk is neither acceptance nor automatic
bounty exclusion. Append dated status changes with supporting evidence; identify
source fixes separately from changes to the deployed Hub.

Review dates describe when analysis occurred, not the age or state of a live
deployment. Report vulnerabilities through [SECURITY.md](../SECURITY.md).
