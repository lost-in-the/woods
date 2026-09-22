# Full-bank publication validation, pass 2

Reviewed 2026-09-21. **No blocking content or privacy concern remains in the reviewed scope.** Final checksum regeneration and extracted-archive checks remain coordinator completion work; this pass does not claim that a not-yet-created archive passed.

## Scope and reviewer ownership

Reviewed the full-bank results report, experimental runner README, guide README, chapter 11, added trial-ledger section, evidence and examples runbooks, both export manifests, selected provider examples, metrics, presentation receipt, transfer probe receipts and posthoc reviewer addendum. No source or documentation was edited by this pass; this file is its only new artifact.

This reviewer previously authored `script/typesafe/rails_bank/test_runner.py` and the original, delivery-corrected and posthoc reviewer adjudications. Those contributions make this a separate review of the coordinator's report and exports, not wholly independent revalidation of this reviewer's tests or adjudication. The reviewer did not author the final report, guide chapter, fixture probe or metrics implementation. Existing adjudications remain preserved.

## Findings and disposition

1. The initial-six report said two reviewers reported truncation. Recorded events and the initial adjudication establish three: ordinary-0, ordinary-1 and bank-0. The coordinator corrected both the main report and its exported copy; the updated export digest matches.
2. Two historical original-source hashes in `evidence/source-manifest.json` differ from the current checkout: the September 16 development-evaluation source and `script/typesafe/README.md`. All thirteen exported report hashes match. The coordinator will retain historical original hashes and explicitly distinguish them from present-checkout verification in `VALIDATION.md`; changing historical hashes merely to match current files is unnecessary.
3. Two ignored Python bytecode files exist in the local examples cache. The coordinator confirmed checksum/archive generation excludes every `__pycache__` component and `.pyc`/`.pyo` file. Their local presence is not approval to include them in the archive. The earlier 40-entry checksum file is expected to be regenerated after review artifacts are included.

## Evidence checked

- All **198 frozen input files** match their recorded digests. All **144 request and response pairs** match the capture ledger. All 24 candidates have one shared state identity across both arms and all repeats.
- Independent ledger recount: 144 HTTP-200 responses; 143 valid and one partially invalid; 1,291,578 input and 323,571 output tokens; one credential lookup; zero unattempted requests or unknown-usage attempts; 21 distribution-rounding warnings. The per-arm totals, estimated input cost, 59,691-byte maximum request and 29,393-byte maximum state agree with receipts.
- Metrics preserve 14,687/14,688 valid bank answers and 432/432 baseline answers. Full-bank checks remain 472 not applicable, 3,703 assessed and 721 unassessed out of 4,896 candidate/question checks. The schema/default-scope target-mapping errors are disclosed separately from model misses, with the original 8/12 and secondary posthoc 8/10 denominators retained.
- The source bank, catalog, frozen protocol, post-capture applicability correction and raw answers remain distinct. Scores are dimensions; maximum-Noul priorities are exploratory navigation, not calibrated change-level probabilities. Controls retain only their original planted-contract labels. Observability and missing whole-app premises remain qualified.
- The original six reviewer sessions and six delivery-correction sessions are reported separately. Forty-six corrected helper outputs match expected recorded bytes; reported client truncation still limits model-visible delivery claims. Dismissed concerns are not counted as rejected candidate inspections. The additional stale-input finding is a separately confirmed conditional mechanism, not a retrospectively planted target or a proved causal bank advantage.
- Corrected-session aggregate usage and first-emission times agree with the preserved addendum. Cached input is a subset of input. The report does not claim unavailable tokens-to-first-finding measurements, treat aggregate counters as incremental counters, or invent reasoning-model dollar costs.
- The transfer result accurately describes preloaded stale instances and deterministic admissible read/commit ordering. It does not claim simultaneous-thread execution, an established real caller lifecycle or a complete concurrency fix. The original rollback oracle and source/database identities remain unchanged.
- All **20 full-bank manifest entries** have matching original and export hashes. The normalized run receipt changes the local checkout command prefixes and adds an explicit export note; runtime, source, database, probe and result fields remain unchanged. All **13 general report-export hashes** match. All **166 local Markdown links** checked in the guide resolve inside the portable guide.
- Scans found no real workstation paths, private-key markers, likely API-token literals, long literal credential assignments or non-placeholder 1Password references in publication content. The runner tests intentionally use synthetic private-path strings to verify omission. The archive's selected source is synthetic fixture evidence. Raw local transcripts, databases and full generated indexes are not claimed as bundled.

## External designs and validation limits

The current official TypeSafe model page supports the recorded price basis. The linked fan-out, intent-routing and composite-scoring pages support chapter 11's design descriptions. The screenshot's displayed values were confirmed by the coordinator from the user image; this pass does not independently establish its inputs or correctness. The community implementation sources were reviewed by the separate `bank_catalog` reviewer. Their new section clearly distinguishes inspected designs, author-reported metrics and an untested proposed investigation loop; it does not claim any external code was executed or add a completed trial.

The final Ruby log records 9,401 examples, zero failures and three pending; the final RuboCop completion log records 913 files and no offenses. The coordinator reports 45 offline harness checks and 28 portable example checks passing. This documentation/export pass did not rerun those suites, the provider, fixtures or reviewer inference. Native Windows, other Rails/database combinations, a general installed-application adapter and independent publication/provider attestation remain outside the evidence.

## Reviewed primary file identities

| Repository-relative file | SHA-256 |
| --- | --- |
| `docs/design/plans/2026-09-21-typesafe-full-bank-results.md` | `b4131aa7ed8370ae172562f5d3eeb11b68abc8175cb3d50b8feb1dd96eea8ad2` |
| `script/typesafe/rails_bank/README.md` | `24aa5eb8215bf920fbc522adce465f0f961deb8785d6858bae13a7647af6242b` |
| `docs/design/typesafe-agent-guide/11-full-bank-review-lessons.md` | `15e5c45f17394d1f33a63404f74b207494fbb23c363d778f6d06c01b9e6da714` |

Live documentation checked: [models](https://docs.typesafe.ai/models), [fan-out](https://docs.typesafe.ai/patterns/fan-out), [intent routing](https://docs.typesafe.ai/patterns/intent-routing), [composite scoring](https://docs.typesafe.ai/patterns/composite-scoring).
