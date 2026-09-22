# Evidence included in this portable guide

These are normalized copies of research reports and reviews, exported after the four-test experiment was completed. They preserve failed approaches, original outcomes, limitations, and proposed-but-unimplemented work. The chapters in the parent directory are the recommended reading path; the long original plan is a historical design record rather than a list of currently supported commands.

| File | Use |
| --- | --- |
| [Full-bank comparison](2026-09-21-typesafe-full-bank-results.md) | Faithful 204-question import, twelve pairs, costs, specific useful checks, composition limits, separate reviewer comparisons and posthoc lost-update verification |
| [Full-bank artifacts](full-bank/README.md) | Catalog/source, metrics, request examples, provenance and executable probe evidence |
| [Booted review follow-up](2026-09-21-typesafe-booted-review-results.md) | Known-fix replay failures, eight booted app cases, index-assisted ranking, four downstream reviewer runs, actual usage and limits |
| [Development design and early trials](2026-09-16-typesafe-development-evaluation.md) | Reviewed target architecture, assertion/claim/configuration experiments, failed large request, compact retry, and cost interpretation |
| [Initial review record](2026-09-16-typesafe-development-evaluation-review.md) | How successive plan reviews corrected evidence, oracle, failure, and evaluation rules |
| [Historical evidence audit](typesafe-guide-history-audit.md) | Earlier assertion results and implemented/planned distinctions absent from some durable summaries |
| [Retrieval experiment](2026-09-16-typesafe-retrieval-evaluation.md) | Canopy relevance, ranking/filter losses, packing, cost, stale-review coverage, and Woods self-scan |
| [Method-context experiment](2026-09-16-typesafe-span-evaluation.md) | Sixteen coding attempts, exact outcomes, actual author telemetry, and filename-coercion compatibility gap |
| [Final prospective protocol](2026-09-16-typesafe-four-tests-plan.md) | Frozen choices before the 28-author follow-up |
| [Final four-test report](2026-09-16-typesafe-four-tests-evaluation.md) | Discovery, budgets, genuine features, repeats, fallback, usage, and confirmed issues |
| [Posthoc compatibility audit](four-tests-posthoc-review.md) | SearchExecutor coverage, Unicode scope, and actual baseline NUL/Boolean bugs |
| [Final aggregate metrics](four-tests-metrics.json) | Per-arm and per-task results, raw-counter aggregates, repeated-test counts, and author-repeat observations |
| [Implemented tooling runbook](source-tooling-readme.md) | Exact offline reader/replay contracts, implementation limits, and historical run status |
| [Guide validation pass 1](guide-validation-pass1.md) | Complete coverage review, independent result recount, cost checks, and resolved portability finding |
| [Guide validation pass 2](guide-validation-pass2.md) | Four reproduced client defects, corrections, independent adversarial rechecks, and platform limits |
| [Source manifest](source-manifest.json) | Original report paths and SHA-256 values, plus hashes of normalized evidence copies |

Original local `tmp/typesafe-*` references describe where the research artifacts lived. Those paths are not expected to exist on another machine. Complete generated indexes, temporary source checkouts, private acceptance corpora, raw author event logs, credentials, and personal machine configuration are intentionally not in this distribution. The guide therefore transfers implementation knowledge and evidence summaries; it is not an exact historical-run replay dataset.

The export normalizes relative report links to this directory and external canonical documentation links to the audited Woods commit. It replaces the personal installed-skill location with a generic placeholder. It does not revise numerical results or turn old proposals into implemented features. [Top-level validation](../VALIDATION.md) records the two guide validation passes; [examples](../examples/README.md) supplies a separate synthetic runnable reference.

Two shorthand phrases remain in the frozen prospective four-test plan. Its exclusion of “task/reference/test bytes” means private task metadata, reference implementations, and acceptance oracles; the public task description was supplied to selectors and authors. Its description of BM25 as “stronger” was a design expectation, not a measured comparison with the earlier lexical baseline. The completed report and current chapters use the precise interpretation. The historical plan is preserved unchanged.
