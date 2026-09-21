# Rails bank comparison receipts

These are descriptive results from curated defect/control fixtures. The oracle establishes only each planted mechanism. Incidental signals are unverified, and control alarms are not automatically false positives.

Bank `2026-09-19.1`; metadata `2026-09-21.1`. High-signal threshold: 0.8; three expected repeats.

Priorities use the maximum median of eligible defect Nouls. Scores are display dimensions; Choices and conventions do not become defect probabilities. Compare rankings within each arm; the larger bank has more opportunities to produce an alarm.

Presentation interpretation `2026-09-21.2` was applied after capture. The initial summary and reports remain preserved; the question bank and numerical thresholds are unchanged. The metrics receipt includes the presentation audit and original-summary digest.

Not-applicable checks are counted separately from assessed and missing/unknown checks. Provider-answer and usage denominators still include every question that was actually requested.

Source-bank Observability section scope remains unresolved; its signals and any rankings they influence are provisional. They remain included under the fixed presentation policy.

## Target mapping audit (post hoc)

Source audit `2026-09-21.3-target-mapping` identifies two nominal-target mapping problems. The original nominal target-alarm count is preserved; it is not detection accuracy. Candidate alarms, priorities, rankings, questions, answers, thresholds, and holdout selection are unchanged.

- `extra-02` / default_scope: The query changes visibility by using unscoped while the model's default_scope declaration is unchanged. The scope question asks about adding or widening that declaration, and disposition requires missing siblings. Neither nominal target provides a valid mechanism target for this pair; this is not a Jev miss.
  Original `ar_default_scope`: Does the change add or widen a `default_scope`? Mapping status: not_applicable_target.
  Original `disposition`: What is the most useful next step for this change? Mapping status: required_evidence_missing.
- `schema` / schema: The original schema pair changes only the index; the model validation is unchanged. The nominal target asks whether the change adds a validation. Its absence is a target-mapping error, not a Jev miss.
  Original `db_validation_without_constraint`: Does the change add a model validation (presence, uniqueness, foreign key) with no matching database constraint or index? Mapping status: not_applicable_target.

## Train — 9 pairs

| Arm | Defect candidates with any alarm | Controls with any alarm | Nominal target alarms | Not applicable | Unassessed / applicable checks | Valid answers / expected |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | 7/9 | 0/9 | Not attributable | 0/108 | 0/108 | 324/324 |
| bank | 8/9 | 8/9 | 5/9 | 400/3672 | 541/3272 | 11015/11016 |

Post hoc mapping-audited subset: 5/7 nominal target alarms; 2 pairs excluded for source-mapping errors. This secondary denominator is not independent detection validation.

The nominal-target count preserves the original designated check alarms, not attributed detections or a model explanation. A missing, incomplete, or evidence-excluded check never counts as passed. Control counts above are alarm counts only.

| Arm | Requests attempted / expected | Input / output tokens known | Usage gaps | Estimated USD known | Sum request seconds | Median request seconds |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | 54/54 | 304848 / 9558 | 0 | $0.012804 | 25.31 | 0.45 |
| bank | 54/54 | 627372 / 232872 | 0 | $0.026350 | 36.73 | 0.66 |

Timing sums include concurrent requests and are not wall-clock time. Costs use the frozen $0.042/M input and $0/M output assumption; missing usage is excluded visibly.

| Arm | Top K | Expected planted defects [min–max] | Enrichment over scheduled prevalence | Boundary tie size |
| --- | --- | --- | --- | --- |
| baseline | 1 | 1.00 [1–1] | 2.00× | 1 |
| baseline | 3 | 3.00 [3–3] | 2.00× | 2 |
| baseline | 6 | 6.00 [6–6] | 2.00× | 2 |
| baseline | 12 | 8.00 [8–8] | 1.33× | 2 |
| baseline | 18 | 9.00 [9–9] | 1.00× | 1 |
| bank | 1 | 1.00 [1–1] | 2.00× | 3 |
| bank | 3 | 3.00 [3–3] | 2.00× | 3 |
| bank | 6 | 3.00 [3–3] | 1.00× | 3 |
| bank | 12 | 6.67 [6–7] | 1.11× | 3 |
| bank | 18 | 9.00 [9–9] | 1.00× | 1 |

## Holdout — 3 pairs

| Arm | Defect candidates with any alarm | Controls with any alarm | Nominal target alarms | Not applicable | Unassessed / applicable checks | Valid answers / expected |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | 3/3 | 0/3 | Not attributable | 0/36 | 0/36 | 108/108 |
| bank | 3/3 | 2/3 | 3/3 | 72/1224 | 180/1152 | 3672/3672 |

Post hoc mapping-audited subset: 3/3 nominal target alarms; 0 pairs excluded for source-mapping errors. This secondary denominator is not independent detection validation.

The nominal-target count preserves the original designated check alarms, not attributed detections or a model explanation. A missing, incomplete, or evidence-excluded check never counts as passed. Control counts above are alarm counts only.

| Arm | Requests attempted / expected | Input / output tokens known | Usage gaps | Estimated USD known | Sum request seconds | Median request seconds |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | 18/18 | 126306 / 3507 | 0 | $0.005305 | 8.26 | 0.45 |
| bank | 18/18 | 233052 / 77634 | 0 | $0.009788 | 12.47 | 0.68 |

Timing sums include concurrent requests and are not wall-clock time. Costs use the frozen $0.042/M input and $0/M output assumption; missing usage is excluded visibly.

| Arm | Top K | Expected planted defects [min–max] | Enrichment over scheduled prevalence | Boundary tie size |
| --- | --- | --- | --- | --- |
| baseline | 1 | 1.00 [1–1] | 2.00× | 1 |
| baseline | 3 | 3.00 [3–3] | 2.00× | 1 |
| baseline | 6 | 3.00 [3–3] | 1.00× | 1 |
| bank | 1 | 0.67 [0–1] | 1.33× | 3 |
| bank | 3 | 2.00 [2–2] | 1.33× | 3 |
| bank | 6 | 3.00 [3–3] | 1.00× | 1 |

## All — 12 pairs

| Arm | Defect candidates with any alarm | Controls with any alarm | Nominal target alarms | Not applicable | Unassessed / applicable checks | Valid answers / expected |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | 10/12 | 0/12 | Not attributable | 0/144 | 0/144 | 432/432 |
| bank | 11/12 | 10/12 | 8/12 | 472/4896 | 721/4424 | 14687/14688 |

Post hoc mapping-audited subset: 8/10 nominal target alarms; 2 pairs excluded for source-mapping errors. This secondary denominator is not independent detection validation.

The nominal-target count preserves the original designated check alarms, not attributed detections or a model explanation. A missing, incomplete, or evidence-excluded check never counts as passed. Control counts above are alarm counts only.

| Arm | Requests attempted / expected | Input / output tokens known | Usage gaps | Estimated USD known | Sum request seconds | Median request seconds |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | 72/72 | 431154 / 13065 | 0 | $0.018108 | 33.57 | 0.45 |
| bank | 72/72 | 860424 / 310506 | 0 | $0.036138 | 49.19 | 0.66 |

Timing sums include concurrent requests and are not wall-clock time. Costs use the frozen $0.042/M input and $0/M output assumption; missing usage is excluded visibly.

| Arm | Top K | Expected planted defects [min–max] | Enrichment over scheduled prevalence | Boundary tie size |
| --- | --- | --- | --- | --- |
| baseline | 1 | 1.00 [1–1] | 2.00× | 1 |
| baseline | 3 | 3.00 [3–3] | 2.00× | 2 |
| baseline | 6 | 6.00 [6–6] | 2.00× | 2 |
| baseline | 12 | 10.00 [10–10] | 1.67× | 2 |
| baseline | 24 | 12.00 [12–12] | 1.00× | 1 |
| bank | 1 | 0.67 [0–1] | 1.33× | 3 |
| bank | 3 | 2.00 [2–2] | 1.33× | 3 |
| bank | 6 | 5.00 [5–5] | 1.67× | 3 |
| bank | 12 | 8.00 [8–8] | 1.33× | 1 |
| bank | 24 | 12.00 [12–12] | 1.00× | 1 |

## Pair receipts

Each bracket preserves every valid repeat. Scores and Choices are shown in their original units; they do not enter the defect priority.

### authorization — authorization (train)

- **baseline**: defect `89bb779b` priority 0.93; control `f96dcfec` priority 0.12; defect_higher.
  Defect checks: `correctness` [0.90, 0.91, 0.91] (defect; supplied; 3/3); `integrity` [0.37, 0.33, 0.37] (defect; supplied; 3/3); `security` [0.93, 0.93, 0.93] (defect; supplied; 3/3); `resources` [0.03, 0.03, 0.03] (defect; supplied; 3/3)
  Control checks: `correctness` [0.10, 0.11, 0.11] (defect; supplied; 3/3); `integrity` [0.07, 0.07, 0.07] (defect; supplied; 3/3); `security` [0.12, 0.11, 0.14] (defect; supplied; 3/3); `resources` [0.03, 0.03, 0.03] (defect; supplied; 3/3)
- **bank**: defect `89bb779b` priority 0.94; control `f96dcfec` priority 0.93; defect_higher.
  Defect checks: `sec_missing_authorization` [0.88, 0.86, 0.89] (defect; supplied; 3/3)
  Control checks: `sec_missing_authorization` [0.79, 0.76, 0.77] (defect; supplied; 3/3)

### callback — callback (train)

- **baseline**: defect `973a98d4` priority 0.9; control `8f9bf2f6` priority 0.21; defect_higher.
  Defect checks: `correctness` [0.90, 0.90, 0.90] (defect; supplied; 3/3); `integrity` [0.85, 0.85, 0.83] (defect; supplied; 3/3); `security` [0.06, 0.06, 0.06] (defect; supplied; 3/3); `resources` [0.06, 0.07, 0.06] (defect; supplied; 3/3)
  Control checks: `correctness` [0.23, 0.20, 0.21] (defect; supplied; 3/3); `integrity` [0.24, 0.21, 0.21] (defect; supplied; 3/3); `security` [0.04, 0.04, 0.04] (defect; supplied; 3/3); `resources` [0.07, 0.06, 0.06] (defect; supplied; 3/3)
- **bank**: defect `973a98d4` priority 0.89; control `8f9bf2f6` priority 0.84; defect_higher.
  Defect checks: `ar_skips_validations` [0.89, 0.89, 0.88] (defect; supplied; 3/3)
  Control checks: `ar_skips_validations` [0.08, 0.08, 0.08] (defect; supplied; 3/3)

### extra-01 — nil_memoization (train)

- **baseline**: defect `54bf764b` priority 0.24; control `82f822b5` priority 0.24; tie.
  Defect checks: `correctness` [0.24, 0.25, 0.24] (defect; supplied; 3/3); `integrity` [0.12, 0.12, 0.12] (defect; supplied; 3/3); `security` [0.08, 0.08, 0.08] (defect; supplied; 3/3); `resources` [0.15, 0.18, 0.15] (defect; supplied; 3/3)
  Control checks: `correctness` [0.24, 0.23, 0.26] (defect; supplied; 3/3); `integrity` [0.12, 0.12, 0.13] (defect; supplied; 3/3); `security` [0.08, 0.08, 0.07] (defect; supplied; 3/3); `resources` [0.16, 0.14, 0.17] (defect; supplied; 3/3)
- **bank**: defect `54bf764b` priority 0.9; control `82f822b5` priority 0.88; defect_higher.
  Defect checks: `ar_find_by_memoized` [0.09, 0.10, 0.09] (defect; supplied; 3/3)
  Control checks: `ar_find_by_memoized` [0.05, 0.06, 0.06] (defect; supplied; 3/3)

### extra-02 — default_scope (train)

Target mapping audit (post hoc): The query changes visibility by using unscoped while the model's default_scope declaration is unchanged. The scope question asks about adding or widening that declaration, and disposition requires missing siblings. Neither nominal target provides a valid mechanism target for this pair; this is not a Jev miss.

- **baseline**: defect `eb4c2d3e` priority 0.9; control `d9c49ed5` priority 0.18; defect_higher.
  Defect checks: `correctness` [0.88, 0.90, 0.90] (defect; supplied; 3/3); `integrity` [0.64, 0.62, 0.66] (defect; supplied; 3/3); `security` [0.58, 0.58, 0.61] (defect; supplied; 3/3); `resources` [0.22, 0.21, 0.17] (defect; supplied; 3/3)
  Control checks: `correctness` [0.13, 0.14, 0.12] (defect; supplied; 3/3); `integrity` [0.12, 0.14, 0.12] (defect; supplied; 3/3); `security` [0.08, 0.09, 0.08] (defect; supplied; 3/3); `resources` [0.16, 0.19, 0.18] (defect; supplied; 3/3)
- **bank**: defect `eb4c2d3e` priority 0.81; control `d9c49ed5` priority 0.81; tie.
  Defect checks: `ar_default_scope` [0.03, 0.03, 0.03] (convention; supplied; 3/3); `disposition` [rework, rework, rework] (convention; not_supplied; 3/3)
  Control checks: `ar_default_scope` [0.04, 0.05, 0.05] (convention; supplied; 3/3); `disposition` [approve, approve, approve] (convention; not_supplied; 3/3)

### extra-03 — cache_invalidation (train)

- **baseline**: defect `8db92299` priority 0.82; control `c12bde6c` priority 0.79; defect_higher.
  Defect checks: `correctness` [0.82, 0.82, 0.81] (defect; supplied; 3/3); `integrity` [0.67, 0.72, 0.63] (defect; supplied; 3/3); `security` [0.05, 0.06, 0.05] (defect; supplied; 3/3); `resources` [0.53, 0.60, 0.56] (defect; supplied; 3/3)
  Control checks: `correctness` [0.79, 0.78, 0.81] (defect; supplied; 3/3); `integrity` [0.66, 0.62, 0.66] (defect; supplied; 3/3); `security` [0.06, 0.06, 0.06] (defect; supplied; 3/3); `resources` [0.55, 0.50, 0.55] (defect; supplied; 3/3)
- **bank**: defect `8db92299` priority 0.94; control `c12bde6c` priority 0.93; defect_higher.
  Defect checks: `perf_cache_without_invalidation` [0.94, 0.94, 0.94] (defect; supplied; 3/3)
  Control checks: `perf_cache_without_invalidation` [0.93, 0.93, 0.94] (defect; supplied; 3/3)

### extra-04 — unbounded_loading (train)

- **baseline**: defect `72ac3523` priority 0.83; control `f34dfb32` priority 0.28; defect_higher.
  Defect checks: `correctness` [0.83, 0.82, 0.85] (defect; supplied; 3/3); `integrity` [0.45, 0.45, 0.46] (defect; supplied; 3/3); `security` [0.08, 0.07, 0.08] (defect; supplied; 3/3); `resources` [0.81, 0.80, 0.79] (defect; supplied; 3/3)
  Control checks: `correctness` [0.27, 0.24, 0.27] (defect; supplied; 3/3); `integrity` [0.28, 0.26, 0.29] (defect; supplied; 3/3); `security` [0.07, 0.08, 0.07] (defect; supplied; 3/3); `resources` [0.19, 0.18, 0.19] (defect; supplied; 3/3)
- **bank**: defect `72ac3523` priority 0.85; control `f34dfb32` priority 0.8; defect_higher.
  Defect checks: `vm_unbatched_collection` [0.55, 0.58, 0.60] (defect; supplied; 3/3); `vm_memory_impact` [1.31, 1.30, 1.39] (defect; supplied; 3/3)
  Control checks: `vm_unbatched_collection` [0.03, 0.03, 0.03] (defect; supplied; 3/3); `vm_memory_impact` [0.60, 0.56, 0.51] (defect; supplied; 3/3)

### extra-05 — association_preloading (train)

- **baseline**: defect `20b254d3` priority 0.75; control `17ead375` priority 0.24; defect_higher.
  Defect checks: `correctness` [0.75, 0.75, 0.71] (defect; supplied; 3/3); `integrity` [0.18, 0.19, 0.18] (defect; supplied; 3/3); `security` [0.06, 0.06, 0.06] (defect; supplied; 3/3); `resources` [0.72, 0.68, 0.64] (defect; supplied; 3/3)
  Control checks: `correctness` [0.24, 0.24, 0.22] (defect; supplied; 3/3); `integrity` [0.15, 0.14, 0.13] (defect; supplied; 3/3); `security` [0.05, 0.05, 0.05] (defect; supplied; 3/3); `resources` [0.13, 0.12, 0.12] (defect; supplied; 3/3)
- **bank**: defect `20b254d3` priority 0.94; control `17ead375` priority 0.93; defect_higher.
  Defect checks: `perf_n_plus_one` [0.94, 0.95, 0.94] (defect; supplied; 3/3); `perf_query_in_loop` [0.53, 0.61, 0.54] (defect; supplied; 3/3)
  Control checks: `perf_n_plus_one` [0.06, 0.06, 0.05] (defect; supplied; 3/3); `perf_query_in_loop` [0.08, 0.07, 0.07] (defect; supplied; 3/3)

### extra-06 — tenant_lookup (holdout)

- **baseline**: defect `e1e26df6` priority 0.86; control `5a805563` priority 0.32; defect_higher.
  Defect checks: `correctness` [0.86, 0.86, 0.87] (defect; supplied; 3/3); `integrity` [0.48, 0.54, 0.53] (defect; supplied; 3/3); `security` [0.81, 0.82, 0.83] (defect; supplied; 3/3); `resources` [0.07, 0.07, 0.08] (defect; supplied; 3/3)
  Control checks: `correctness` [0.38, 0.32, 0.31] (defect; supplied; 3/3); `integrity` [0.14, 0.14, 0.14] (defect; supplied; 3/3); `security` [0.12, 0.11, 0.11] (defect; supplied; 3/3); `resources` [0.09, 0.09, 0.09] (defect; supplied; 3/3)
- **bank**: defect `e1e26df6` priority 0.93; control `5a805563` priority 0.82; defect_higher.
  Defect checks: `sec_unscoped_lookup` [0.93, 0.93, 0.92] (defect; supplied; 3/3); `sec_worst_case_impact` [1.97, 1.96, 1.92] (defect; supplied; 3/3)
  Control checks: `sec_unscoped_lookup` [0.06, 0.06, 0.06] (defect; supplied; 3/3); `sec_worst_case_impact` [1.12, 0.95, 1.05] (defect; supplied; 3/3)

### extra-07 — test_effectiveness (holdout)

- **baseline**: defect `dfecd0a7` priority 0.83; control `8e269250` priority 0.17; defect_higher.
  Defect checks: `correctness` [0.84, 0.83, 0.80] (defect; supplied; 3/3); `integrity` [0.39, 0.38, 0.39] (defect; supplied; 3/3); `security` [0.03, 0.03, 0.03] (defect; supplied; 3/3); `resources` [0.05, 0.05, 0.05] (defect; supplied; 3/3)
  Control checks: `correctness` [0.18, 0.16, 0.17] (defect; supplied; 3/3); `integrity` [0.12, 0.11, 0.11] (defect; supplied; 3/3); `security` [0.03, 0.03, 0.03] (defect; supplied; 3/3); `resources` [0.05, 0.05, 0.05] (defect; supplied; 3/3)
- **bank**: defect `dfecd0a7` priority 0.97; control `8e269250` priority 0.59; defect_higher.
  Defect checks: `test_cannot_fail` [0.97, 0.97, 0.98] (defect; supplied; 3/3); `test_coverage_of_change` [1.01, 1.01, 1.01] (fact; supplied; 3/3)
  Control checks: `test_cannot_fail` [0.08, 0.08, 0.07] (defect; supplied; 3/3); `test_coverage_of_change` [1.97, 1.96, 1.97] (fact; supplied; 3/3)

### extra-08 — atomic_writes (holdout)

- **baseline**: defect `6ae10e81` priority 0.92; control `f9a470ec` priority 0.79; defect_higher.
  Defect checks: `correctness` [0.92, 0.92, 0.91] (defect; supplied; 3/3); `integrity` [0.80, 0.72, 0.78] (defect; supplied; 3/3); `security` [0.07, 0.06, 0.06] (defect; supplied; 3/3); `resources` [0.15, 0.18, 0.15] (defect; supplied; 3/3)
  Control checks: `correctness` [0.76, 0.79, 0.80] (defect; supplied; 3/3); `integrity` [0.51, 0.55, 0.54] (defect; supplied; 3/3); `security` [0.06, 0.07, 0.07] (defect; supplied; 3/3); `resources` [0.11, 0.12, 0.13] (defect; supplied; 3/3)
- **bank**: defect `6ae10e81` priority 0.97; control `f9a470ec` priority 0.97; tie.
  Defect checks: `db_writes_not_atomic` [0.92, 0.92, 0.92] (defect; supplied; 3/3)
  Control checks: `db_writes_not_atomic` [0.06, 0.06, 0.06] (defect; supplied; 3/3)

### schema — schema (train)

Target mapping audit (post hoc): The original schema pair changes only the index; the model validation is unchanged. The nominal target asks whether the change adds a validation. Its absence is a target-mapping error, not a Jev miss.

- **baseline**: defect `7f4306b3` priority 0.8; control `6f07a67f` priority 0.28; defect_higher.
  Defect checks: `correctness` [0.80, 0.75, 0.80] (defect; supplied; 3/3); `integrity` [0.21, 0.24, 0.27] (defect; supplied; 3/3); `security` [0.02, 0.02, 0.03] (defect; supplied; 3/3); `resources` [0.05, 0.05, 0.05] (defect; supplied; 3/3)
  Control checks: `correctness` [0.27, 0.28, 0.28] (defect; supplied; 3/3); `integrity` [0.14, 0.14, 0.14] (defect; supplied; 3/3); `security` [0.02, 0.02, 0.03] (defect; supplied; 3/3); `resources` [0.04, 0.04, 0.04] (defect; supplied; 3/3)
- **bank**: defect `7f4306b3` priority 0.65; control `6f07a67f` priority 0.64; defect_higher.
  Defect checks: `db_validation_without_constraint` [0.04, 0.04, 0.04] (defect; supplied; 3/3)
  Control checks: `db_validation_without_constraint` [0.04, 0.04, 0.04] (defect; supplied; 3/3)

### transaction — transaction (train)

- **baseline**: defect `575abe3d` priority 0.82; control `162ea7c0` priority 0.34; defect_higher.
  Defect checks: `correctness` [0.79, 0.82, 0.83] (defect; supplied; 3/3); `integrity` [0.63, 0.63, 0.62] (defect; supplied; 3/3); `security` [0.04, 0.04, 0.04] (defect; supplied; 3/3); `resources` [0.45, 0.47, 0.40] (defect; supplied; 3/3)
  Control checks: `correctness` [0.34, 0.36, 0.34] (defect; supplied; 3/3); `integrity` [0.23, 0.23, 0.25] (defect; supplied; 3/3); `security` [0.03, 0.03, 0.03] (defect; supplied; 3/3); `resources` [0.13, 0.13, 0.15] (defect; supplied; 3/3)
- **bank**: defect `575abe3d` priority 0.84; control `162ea7c0` priority 0.84; tie.
  Defect checks: `job_enqueued_inside_transaction` [0.83, 0.83, 0.83] (defect; supplied; 3/3)
  Control checks: `job_enqueued_inside_transaction` [0.28, 0.33, 0.25] (defect; supplied; 3/3)

## Every high Noul signal, including excluded answers

A row appears when any valid repeat has raw yes ≥0.8 or direction-adjusted probability ≥0.8. Eligibility additionally requires all three repeats, supplied evidence, and defect kind. A high raw yes on a yes-is-good check is not a defect alarm. No incidental row has been independently confirmed by this module.

### 162ea7c0 / bank — planted-mechanism control, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.08, 0.08, 0.08 | unknown (change_kind_fix) | 3/3 | False | 0.92 |
| `job_assumes_record_exists` | incidental_unverified | defect / yes_is_bad | 0.84, 0.82, 0.84 | supplied | 3/3 | True | 0.84 |

### 6f07a67f / bank — planted-mechanism control, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.08, 0.07, 0.08 | unknown (change_kind_fix) | 3/3 | False | 0.92 |
| `blast_shared_data_write` | incidental_unverified | defect / yes_is_bad | 0.79, 0.81, 0.77 | not_supplied (callers, reference_search) | 3/3 | False | 0.79 |

### 89bb779b / baseline — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.90, 0.91, 0.91 | supplied | 3/3 | True | 0.91 |
| `security` | broad_domain_signal | defect / yes_is_bad | 0.93, 0.93, 0.93 | supplied | 3/3 | True | 0.93 |

### 89bb779b / bank — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.08, 0.07, 0.07 | unknown (change_kind_fix) | 3/3 | False | 0.93 |
| `sec_missing_authorization` | designated_target | defect / yes_is_bad | 0.88, 0.86, 0.89 | supplied | 3/3 | True | 0.88 |
| `repo_ignores_base_class` | incidental_unverified | convention / yes_is_bad | 0.80, 0.81, 0.78 | not_supplied (siblings) | 3/3 | False | 0.80 |
| `rollout_no_flag_for_risky_change` | incidental_unverified | defect / yes_is_bad | 0.88, 0.87, 0.85 | supplied | 3/3 | True | 0.87 |
| `hygiene_debug_artifacts` | incidental_unverified | defect / yes_is_bad | 0.94, 0.94, 0.93 | supplied | 3/3 | True | 0.94 |

### 575abe3d / baseline — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.79, 0.82, 0.83 | supplied | 3/3 | True | 0.82 |

### 575abe3d / bank — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.07, 0.07, 0.07 | unknown (change_kind_fix) | 3/3 | False | 0.93 |
| `job_enqueued_inside_transaction` | designated_target | defect / yes_is_bad | 0.83, 0.83, 0.83 | supplied | 3/3 | True | 0.83 |
| `job_assumes_record_exists` | incidental_unverified | defect / yes_is_bad | 0.84, 0.81, 0.85 | supplied | 3/3 | True | 0.84 |

### 7f4306b3 / baseline — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.80, 0.75, 0.80 | supplied | 3/3 | True | 0.80 |

### 7f4306b3 / bank — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.06, 0.07, 0.07 | unknown (change_kind_fix) | 3/3 | False | 0.93 |

### 8f9bf2f6 / bank — planted-mechanism control, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.07, 0.07, 0.06 | unknown (change_kind_fix) | 3/3 | False | 0.93 |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.84, 0.85, 0.84 | supplied | 3/3 | True | 0.84 |
| `blast_shared_data_write` | incidental_unverified | defect / yes_is_bad | 0.92, 0.93, 0.93 | not_supplied (callers, reference_search) | 3/3 | False | 0.93 |
| `blast_race_condition` | incidental_unverified | defect / yes_is_bad | 0.79, 0.82, 0.79 | not_supplied (callers, reference_search) | 3/3 | False | 0.79 |
| `hygiene_commit_message_why` | incidental_unverified | defect / yes_is_bad | 0.80, 0.79, 0.79 | not_supplied (commit_messages) | 3/3 | False | 0.79 |

### 973a98d4 / baseline — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.90, 0.90, 0.90 | supplied | 3/3 | True | 0.90 |
| `integrity` | broad_domain_signal | defect / yes_is_bad | 0.85, 0.85, 0.83 | supplied | 3/3 | True | 0.85 |

### 973a98d4 / bank — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.07, 0.07, 0.07 | unknown (change_kind_fix) | 3/3 | False | 0.93 |
| `ar_skips_validations` | designated_target | defect / yes_is_bad | 0.89, 0.89, 0.88 | supplied | 3/3 | True | 0.89 |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.86, 0.87, 0.86 | supplied | 3/3 | True | 0.86 |
| `repo_ignores_base_class` | incidental_unverified | convention / yes_is_bad | 0.88, 0.89, 0.89 | not_supplied (siblings) | 3/3 | False | 0.89 |
| `blast_shared_data_write` | incidental_unverified | defect / yes_is_bad | 0.93, 0.93, 0.93 | not_supplied (callers, reference_search) | 3/3 | False | 0.93 |
| `blast_race_condition` | incidental_unverified | defect / yes_is_bad | 0.81, 0.81, 0.81 | not_supplied (callers, reference_search) | 3/3 | False | 0.81 |
| `hygiene_commit_message_why` | incidental_unverified | defect / yes_is_bad | 0.80, 0.81, 0.81 | not_supplied (commit_messages) | 3/3 | False | 0.81 |

### f96dcfec / bank — planted-mechanism control, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.06, 0.07, 0.06 | unknown (change_kind_fix) | 3/3 | False | 0.94 |
| `hygiene_debug_artifacts` | incidental_unverified | defect / yes_is_bad | 0.92, 0.93, 0.93 | supplied | 3/3 | True | 0.93 |

### f9a470ec / baseline — planted-mechanism control, holdout

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.76, 0.79, 0.80 | supplied | 3/3 | True | 0.79 |

### f9a470ec / bank — planted-mechanism control, holdout

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `metz_reaches_through` | incidental_unverified | defect / yes_is_bad | 0.84, 0.83, 0.83 | supplied | 3/3 | True | 0.83 |
| `metz_argument_order` | incidental_unverified | defect / yes_is_bad | 0.96, 0.97, 0.97 | supplied | 3/3 | True | 0.97 |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.19, 0.19, 0.17 | unknown (change_kind_fix) | 3/3 | False | 0.81 |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.91, 0.90, 0.90 | supplied | 3/3 | True | 0.90 |
| `job_read_modify_write` | incidental_unverified | defect / yes_is_bad | 0.77, 0.79, 0.83 | supplied | 3/3 | True | 0.79 |
| `blast_shared_data_write` | incidental_unverified | defect / yes_is_bad | 0.90, 0.90, 0.90 | not_supplied (callers, reference_search) | 3/3 | False | 0.90 |
| `blast_race_condition` | incidental_unverified | defect / yes_is_bad | 0.85, 0.85, 0.87 | not_supplied (callers, reference_search) | 3/3 | False | 0.85 |
| `hygiene_commit_message_why` | incidental_unverified | defect / yes_is_bad | 0.79, 0.78, 0.80 | not_supplied (commit_messages) | 3/3 | False | 0.79 |

### 8db92299 / baseline — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.82, 0.82, 0.81 | supplied | 3/3 | True | 0.82 |

### 8db92299 / bank — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `metz_reaches_through` | incidental_unverified | defect / yes_is_bad | 0.79, 0.78, 0.82 | supplied | 3/3 | True | 0.79 |
| `perf_unmeasured_optimization` | incidental_unverified | defect / yes_is_bad | 0.89, 0.88, 0.89 | supplied | 3/3 | True | 0.89 |
| `perf_cache_without_invalidation` | designated_target | defect / yes_is_bad | 0.94, 0.94, 0.94 | supplied | 3/3 | True | 0.94 |
| `perf_benchmark_not_shared` | incidental_unverified | defect / yes_is_bad | 0.83, 0.82, 0.83 | supplied | 3/3 | True | 0.83 |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.86, 0.85, 0.84 | supplied | 3/3 | True | 0.85 |
| `blast_shared_data_write` | incidental_unverified | defect / yes_is_bad | 0.84, 0.85, 0.85 | not_supplied (callers, reference_search) | 3/3 | False | 0.85 |

### dfecd0a7 / baseline — planted defect, holdout

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.84, 0.83, 0.80 | supplied | 3/3 | True | 0.83 |

### dfecd0a7 / bank — planted defect, holdout

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.20, 0.19, 0.19 | unknown (change_kind_fix) | 3/3 | False | 0.81 |
| `test_multiple_behaviors` | incidental_unverified | fact / yes_is_bad | 0.89, 0.89, 0.89 | supplied | 3/3 | False | 0.89 |
| `test_cannot_fail` | designated_target | defect / yes_is_bad | 0.97, 0.97, 0.98 | supplied | 3/3 | True | 0.97 |
| `blast_shared_data_write` | incidental_unverified | defect / yes_is_bad | 0.80, 0.82, 0.82 | not_supplied (callers, reference_search) | 3/3 | False | 0.82 |

### 5a805563 / bank — planted-mechanism control, holdout

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.82, 0.81, 0.82 | supplied | 3/3 | True | 0.82 |

### 17ead375 / bank — planted-mechanism control, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `metz_reaches_through` | incidental_unverified | defect / yes_is_bad | 0.93, 0.93, 0.93 | supplied | 3/3 | True | 0.93 |
| `metz_feature_envy` | incidental_unverified | defect / yes_is_bad | 0.81, 0.79, 0.78 | supplied | 3/3 | True | 0.79 |
| `vm_needless_dup` | incidental_unverified | defect / yes_is_bad | 0.83, 0.87, 0.87 | supplied | 3/3 | True | 0.87 |

### e1e26df6 / baseline — planted defect, holdout

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.86, 0.86, 0.87 | supplied | 3/3 | True | 0.86 |
| `security` | broad_domain_signal | defect / yes_is_bad | 0.81, 0.82, 0.83 | supplied | 3/3 | True | 0.82 |

### e1e26df6 / bank — planted defect, holdout

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `dhh_speculative_generality` | incidental_unverified | defect / yes_is_bad | 0.84, 0.84, 0.81 | supplied | 3/3 | True | 0.84 |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.87, 0.87, 0.86 | supplied | 3/3 | True | 0.87 |
| `sec_unscoped_lookup` | designated_target | defect / yes_is_bad | 0.93, 0.93, 0.92 | supplied | 3/3 | True | 0.93 |

### 20b254d3 / bank — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `metz_reaches_through` | incidental_unverified | defect / yes_is_bad | 0.93, 0.95, 0.94 | supplied | 3/3 | True | 0.94 |
| `metz_feature_envy` | incidental_unverified | defect / yes_is_bad | 0.82, 0.84, 0.82 | supplied | 3/3 | True | 0.82 |
| `perf_n_plus_one` | designated_target | defect / yes_is_bad | 0.94, 0.95, 0.94 | supplied | 3/3 | True | 0.94 |
| `vm_needless_dup` | incidental_unverified | defect / yes_is_bad | 0.87, 0.88, 0.88 | supplied | 3/3 | True | 0.88 |
| `hygiene_can_optimize` | incidental_unverified | defect / yes_is_bad | 0.85, 0.88, 0.86 | not_supplied (siblings) | 3/3 | False | 0.86 |

### 8e269250 / bank — planted-mechanism control, holdout

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_asserts_internals` | incidental_unverified | fact / yes_is_bad | 0.78, 0.78, 0.80 | supplied | 3/3 | False | 0.78 |
| `blast_shared_data_write` | incidental_unverified | defect / yes_is_bad | 0.88, 0.88, 0.88 | not_supplied (callers, reference_search) | 3/3 | False | 0.88 |

### c12bde6c / baseline — planted-mechanism control, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.79, 0.78, 0.81 | supplied | 3/3 | True | 0.79 |

### c12bde6c / bank — planted-mechanism control, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `metz_reaches_through` | incidental_unverified | defect / yes_is_bad | 0.81, 0.79, 0.82 | supplied | 3/3 | True | 0.81 |
| `perf_unmeasured_optimization` | incidental_unverified | defect / yes_is_bad | 0.88, 0.88, 0.89 | supplied | 3/3 | True | 0.88 |
| `perf_cache_without_invalidation` | designated_target | defect / yes_is_bad | 0.93, 0.93, 0.94 | supplied | 3/3 | True | 0.93 |
| `perf_benchmark_not_shared` | incidental_unverified | defect / yes_is_bad | 0.83, 0.83, 0.83 | supplied | 3/3 | True | 0.83 |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.84, 0.86, 0.85 | supplied | 3/3 | True | 0.85 |
| `blast_shared_data_write` | incidental_unverified | defect / yes_is_bad | 0.84, 0.86, 0.84 | not_supplied (callers, reference_search) | 3/3 | False | 0.84 |
| `hygiene_commit_message_why` | incidental_unverified | defect / yes_is_bad | 0.78, 0.79, 0.80 | not_supplied (commit_messages) | 3/3 | False | 0.79 |

### 72ac3523 / baseline — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.83, 0.82, 0.85 | supplied | 3/3 | True | 0.83 |
| `resources` | broad_domain_signal | defect / yes_is_bad | 0.81, 0.80, 0.79 | supplied | 3/3 | True | 0.80 |

### 72ac3523 / bank — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `dhh_speculative_generality` | incidental_unverified | defect / yes_is_bad | 0.83, 0.82, 0.83 | supplied | 3/3 | True | 0.83 |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.81, 0.80, 0.82 | supplied | 3/3 | True | 0.81 |
| `blast_race_condition` | incidental_unverified | defect / yes_is_bad | 0.79, 0.81, 0.79 | not_supplied (callers, reference_search) | 3/3 | False | 0.79 |
| `hygiene_dead_code` | incidental_unverified | defect / yes_is_bad | 0.85, 0.85, 0.84 | supplied | 3/3 | True | 0.85 |
| `hygiene_can_optimize` | incidental_unverified | defect / yes_is_bad | 0.81, 0.82, 0.81 | not_supplied (siblings) | 3/3 | False | 0.81 |

### eb4c2d3e / baseline — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.88, 0.90, 0.90 | supplied | 3/3 | True | 0.90 |

### eb4c2d3e / bank — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `perf_missing_index` | incidental_unverified | defect / yes_is_bad | 0.81, 0.81, 0.81 | supplied | 3/3 | True | 0.81 |

### 6ae10e81 / baseline — planted defect, holdout

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `correctness` | broad_domain_signal | defect / yes_is_bad | 0.92, 0.92, 0.91 | supplied | 3/3 | True | 0.92 |
| `integrity` | broad_domain_signal | defect / yes_is_bad | 0.80, 0.72, 0.78 | supplied | 3/3 | True | 0.78 |

### 6ae10e81 / bank — planted defect, holdout

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `metz_reaches_through` | incidental_unverified | defect / yes_is_bad | 0.88, 0.89, 0.86 | supplied | 3/3 | True | 0.88 |
| `metz_argument_order` | incidental_unverified | defect / yes_is_bad | 0.97, 0.97, 0.97 | supplied | 3/3 | True | 0.97 |
| `test_regression_for_fix` | incidental_unverified | fact / yes_is_good | 0.18, 0.18, 0.17 | unknown (change_kind_fix) | 3/3 | False | 0.82 |
| `db_writes_not_atomic` | designated_target | defect / yes_is_bad | 0.92, 0.92, 0.92 | supplied | 3/3 | True | 0.92 |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.91, 0.91, 0.92 | supplied | 3/3 | True | 0.91 |
| `job_not_idempotent` | incidental_unverified | defect / yes_is_bad | 0.84, 0.85, 0.83 | supplied | 3/3 | True | 0.84 |
| `job_read_modify_write` | incidental_unverified | defect / yes_is_bad | 0.84, 0.88, 0.86 | supplied | 3/3 | True | 0.86 |
| `blast_shared_data_write` | incidental_unverified | defect / yes_is_bad | 0.92, 0.92, 0.92 | not_supplied (callers, reference_search) | 3/3 | False | 0.92 |
| `blast_race_condition` | incidental_unverified | defect / yes_is_bad | 0.92, 0.92, 0.92 | not_supplied (callers, reference_search) | 3/3 | False | 0.92 |
| `hygiene_commit_message_why` | incidental_unverified | defect / yes_is_bad | 0.80, 0.79, 0.79 | not_supplied (commit_messages) | 3/3 | False | 0.79 |

### 82f822b5 / bank — planted-mechanism control, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `perf_benchmark_not_shared` | incidental_unverified | defect / yes_is_bad | 0.84, 0.83, 0.85 | supplied | 3/3 | True | 0.84 |
| `avdi_nil_on_some_paths` | incidental_unverified | defect / yes_is_bad | 0.88, 0.88, 0.89 | supplied | 3/3 | True | 0.88 |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.82, 0.82, 0.81 | supplied | 3/3 | True | 0.82 |

### d9c49ed5 / bank — planted-mechanism control, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `perf_missing_index` | incidental_unverified | defect / yes_is_bad | 0.81, 0.79, 0.81 | supplied | 3/3 | True | 0.81 |

### 54bf764b / bank — planted defect, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `perf_benchmark_not_shared` | incidental_unverified | defect / yes_is_bad | 0.84, 0.84, 0.84 | supplied | 3/3 | True | 0.84 |
| `avdi_nil_on_some_paths` | incidental_unverified | defect / yes_is_bad | 0.90, 0.90, 0.91 | supplied | 3/3 | True | 0.90 |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.81, 0.81, 0.82 | supplied | 3/3 | True | 0.81 |

### f34dfb32 / bank — planted-mechanism control, train

| Question | Role | Kind / direction | Raw yes repeats | Evidence | Repeats | Eligible defect check | Median directed value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `avdi_unguarded_input` | incidental_unverified | defect / yes_is_bad | 0.80, 0.80, 0.80 | supplied | 3/3 | True | 0.80 |

## Limits

Small curated paired fixtures, reused development cases, correlated questions, and unequal question counts do not establish general review quality, AUC success, or downstream effort savings.

The JSON receipt includes every displayed signal, target answer, Score/Choice dimension, request status, validation error count, missing-usage count, and tie-aware ranking. Source bodies, local application paths, credentials, and coordinator-only metadata are not copied here.
