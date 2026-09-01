# v2.0 pre-release audit, round 2

Generated: 2026-09-01. Audited HEAD: `79c156d` (main, post PR #272).
Prior audit: `v2-prerelease-audit/` at `c31683c` (2026-08-27), 172 remediation commits ago.

## How to read this folder

One topic per file. The finding IDs carry the auditing slice as a prefix.

| File | Contents |
|---|---|
| [01-ledger-reconciliation.md](01-ledger-reconciliation.md) | Every prior-audit ledger row, with a verdict. The completeness claim for the remediation. |
| [02-contracts-verified.md](02-contracts-verified.md) | Contracts attacked that held. |
| [03-high.md](03-high.md) | 2 high findings, both executed. |
| [04-medium.md](04-medium.md) | 31 medium findings. |
| [05-low.md](05-low.md) | 69 low findings. |
| [06-coverage-and-ci.md](06-coverage-and-ci.md) | Suite baseline, specs that pin bugs, lanes that never ran here. |
| [07-suggested-fixes.md](07-suggested-fixes.md) | Grouped PR plan. Every finding has a disposition. |
| [08-method-and-limits.md](08-method-and-limits.md) | What ran, what was only read, what could not be verified. |

## Finding counts

| Severity | Count | Executed | Traced |
|---|---|---|---|
| High | 2 | 2 | 0 |
| Medium | 31 | 22 | 9 |
| Low | 69 | ~38 | ~31 |

Ledger reconciliation: **58 of 62 prior rows closed-verified.** 1 closed-weak (M2). 4 still open with no disposition record (G-3, L9, L10, L11: the planned PR-2b never shipped).

## The release-blocking set, in attack order

1. **CORE-2**: `woods:incremental` against an output directory with no baseline silently publishes a near-empty index as generation 1. The documented CI flow (restore cache, run incremental) hits this on any failed cache restore. Executed.
2. **CON-1**: `console_query` aliasing an unprotected column onto an EAV header name makes the redactor mask the wrong cell. The real secret returns in cleartext. Executed.
3. **R1-4**: the remediation plan's own go/no-go criterion 1 is currently false. Four ledger rows (G-3, L9, L10, L11) have neither a PR nor a backlog entry.

Strong candidates to join them (judgment call, see 07):

- **EXTB-4**: every flow document inverts `unless` semantics. Executed.
- **EXTA-2**: namespaced service/job/mailer dependency edges dangle after the G-1 identifier change. Blast radius includes incremental re-extraction.
- **STO-1**: a genuine pre-rename database permanently wedges `Migrator#migrate!`. The regression spec pins a fixture that never existed in the field.

## Evidence legend

Same as the prior audit:

- **[executed]**: a probe ran against the real code at HEAD and confirmed the behavior. Every executed High and Medium was re-run by the synthesizing session, not just by the reporting agent.
- **[traced]**: verified by reading code paths and specs; not executed.
- **[inference]**: mechanism is fact; the impact or likelihood claim is judgment.

Spec coverage per finding: **pins the bug** (a spec asserts the wrong behavior), **covers the area**, or **none**.

## What changed since round 1

The remediation was real and largely well-tested. Round 2 findings cluster differently:

- Round 1 found defects in mature code. Round 2 finds them mostly in **the neighbourhood of the fixes**: the shape next to the pinned input (EXTA-5, CON-1, CON-2, MCP-1, MCP-2, INF-3, EXP-2, STO-4).
- The **LANG=C encoding family** was fixed for `IndexReader` but not swept: session tracer, feedback store, evaluation, and one new spec still break under the C locale.
- Seven **specs pin bugs** (asserted wrong behavior): see 06.
