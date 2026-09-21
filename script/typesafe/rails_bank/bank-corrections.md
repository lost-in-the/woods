# Rails bank import audit

Catalog bank version: `2026-09-19.1`. Metadata interpretation version:
`2026-09-21.1`. Schema version: `1`. Import mode: `as_written`.

The [source snapshot](source-question-bank.md) is byte-for-byte identical to the
supplied, scrubbed question bank. SHA-256:
`41f293131e2d088e9efd53dd635cbd1e22b6bf8f7210fb5d38cef05b213d5c9b`.
The implementation handoff is not copied into this directory.

[The catalog](catalog.json) contains all 204 unique source IDs in original order:
185 Noul, 16 Score, and 3 Choice across 16 sections. There are 34 rows with an
explicit context marker. Every row records its original one-based source line,
complete Markdown row, complete question cell, and literal context prefix.

## Semantic corrections

None. `corrections` is an empty list. No question, level description, option name,
or direction has been replaced, broadened, narrowed, or clinically rephrased.
In particular, the unusual backticks and persistence wording in
`ar_skips_validations` remain exactly as supplied. This import does not establish
that every bank claim is correct for every Rails version. Observed wording or
Rails-premise problems belong in an audited subsequent version, not an invisible
runner special case.

Future semantic changes must retain this snapshot and catalog version, record the
question ID, original and revised instructions/criteria, reason, date, supporting
primary source or reproduction, and a new bank version. A corrected question arm
must be reported separately from this imported-as-written arm. Metadata changes
need a new interpretation version and an explicit audit entry even if provider
question text is unchanged.

## Transcription and interpretation decisions

The Purpose paragraph assigns a default kind and names broad exceptions without
annotating every row. The row-level kinds below are explicit implementation
interpretations, not claims that the source author supplied those individual
labels. Every row has `kind_basis.interpretation` and a reason. A default `defect`
label is not a confirmed defect; confirmation still requires an evidenced failure
mechanism. Convention findings must not be counted as confirmed defect findings.

### I001 — Purpose defaults

Unspecified rows keep the source Purpose default kind defect; this is a source classification, not confirmation that a finding is a bug. Source direction exceptions and unordered Choices are applied literally.

The only direction inversions are `test_regression_for_fix` (`yes_is_good`)
and `test_coverage_of_change` (`higher_is_better`). Choices are `unordered`.
The original higher-is-worse direction remains on visibility and other impact
Scores; a normalized Score is not a calibrated defect probability.

### I002 — Mostly-convention sections

Views, Batsov, and Codebase are not individually annotated. Explicit row-level interpretation assigns convention except documented Views and Batsov mechanism rows; all Codebase rows are convention.

Views:

- `convention`: `view_logic_placement`, `view_queries_model`, `view_instance_var_in_partial`, `view_business_logic`, `view_helper_returns_html`, `view_link_for_non_get`, `view_stimulus_business_logic`, `view_requires_js`, `view_no_strict_locals`.
- `defect`: `view_broadcast_unscoped`, `view_turbo_frame_mismatch`, `view_missing_a11y_basics`.

Batsov:

- `convention`: `ar_association_without_dependent`, `ar_reference_without_fk`, `ar_nullable_boolean`, `ar_default_scope`, `ar_enum_by_array`, `ar_order_by_id`, `ar_where_not_multi`, `ar_migration_uses_app_model`, `ar_sql_outside_model`, `ar_validates_id_not_object`, `time_zone_unaware`, `env_unchecked`, `mailer_path_helper`, `i18n_hardcoded_string`.
- `defect`: `ar_persistence_risk`, `ar_skips_validations`, `ar_unchecked_save`, `ar_callback_halts_silently`, `ar_before_destroy_not_prepended`, `ar_find_by_memoized`, `ar_ignored_columns_overwrite`, `ar_after_commit_collision`.

Codebase:

- `convention`: `repo_different_approach`, `repo_naming_drift`, `repo_wrong_layer`, `repo_reinvents_local_helper`, `repo_ignores_base_class`, `repo_inconsistent_error_handling`, `repo_inconsistent_return_shape`, `repo_fit`.

### I003 — Test structure facts

The Purpose calls test structure questions facts without enumerating them. Explicit row-level interpretations mark structural patterns and coverage/regression presence fact; remaining test rows retain default defect.

- `fact`: `test_coverage_of_change`, `test_private_method`, `test_asserts_internals`, `test_query_message_stubbed`, `test_duplicates_setup`, `test_regression_for_fix`, `test_multiple_behaviors`, `test_mocks_unowned`, `test_partial_mock`, `test_conditional_logic`, `test_name_describes_implementation`, `test_factory_cascade`, `test_jobs_inline`, `test_sleep`, `test_system_where_request_would_do`, `test_hidden_setup`, `test_travel_to_now`.
- `defect`: `test_brittle_to_refactor`, `test_time_dependent`, `test_order_dependent`, `test_cannot_fail`, `test_shared_state_mutated`, `test_live_external_call`, `test_time_not_restored`, `test_ddl_uncleaned`.

The fact assignment records a test pattern or coverage structure, without making
its undesirability into a demonstrated application failure. Remaining test rows
retain the source default; the catalog does not imply that this partition was
explicitly enumerated by the source author.

### I004 — Choice kinds

change_kind and primary_concern are explicit facts. disposition is interpreted as a convention/recommendation because it asks for a useful next step, not a defect assertion.

### I005 — Context inheritance

Apply section-level mandatory evidence in addition to inline markers: siblings for Codebase, callers and reference search for Blast, PR description or commit messages for Hygiene. A fix premise must be supplied independently of parallel question answers.

All rows include `diff` and `touched_source`. `explicit_context_requirements`
contains only the per-row marker requirements; `context_requirements` is the
ordered, deduplicated union of defaults, section requirements, and explicit
requirements. The top-level requirement registry describes each key.

- Codebase adds `siblings` to every row, including the local-helper-search row.
- Blast adds both `callers` and `reference_search` to every row.
- Hygiene adds `change_intent`, satisfied by `pr_description` or
  `commit_messages`. An inline requirement for one of them still requires that
  specific source. Alternatives are represented by `any_of` in the registry.
- `job_enqueued_inside_transaction` separately requires `rails_version`,
  `queue_adapter`, and `enqueue_after_transaction_commit`.
- `change_kind_fix` is an independently supplied premise. It cannot be supplied
  by the `change_kind` answer in the same parallel request.

Mark missing, capped, or unverified evidence as such. A relation name is not a
caller body; an empty search result without a known searched scope is not proof
that no references exist. These metadata rules do not fabricate evidence or add
provider instructions to the imported questions.

### I006 — Lossless API transcription

Remove only the literal context prefix from instructions and separate the Score/Choice suffix after the em dash into criteria. Keep all remaining wording, punctuation, code ticks, and escapes. Bare Choice labels have null descriptions. Original cells can be reconstructed exactly.

Score descriptions preserve their source order and casing, with their numeric
positions represented by list indexes. Choice keys preserve source order and
spelling. `primary_concern` has bare `security` and `performance` options; their
criteria descriptions are `null`, rather than invented prose. The original
instructions are the exact question body after removing the context prefix and,
for Score/Choice, the criteria suffix. Reconstructing those parts yields each
original cell exactly, including the atypical `**(ctx:** …)` formatting.

This representation follows the current [Score](https://docs.typesafe.ai/primitives/score.md)
and [Choice](https://docs.typesafe.ai/primitives/choice.md) API formats, checked
2026-09-21. This API transcription adds no semantic question corrections.

### I007 — Current mapping versus historical prose

The Purpose headline mapping is authoritative: Hygiene has no bar and Rollout user visibility is secondary/unweighted. Count current typed rows (Security 16), not the historical added-14 note.

The historical note that Security added 14 questions is preserved in the
snapshot; the actual current Security section contains 16. Older generic prose
about every section opening with a Score is also preserved. The catalog follows
the later explicit Purpose mapping: 15 primary bars, Rollout's second Score as
`secondary_unweighted`, and no Hygiene bar. No numeric weights are invented.

## Verification

```sh
python -m unittest script/typesafe/rails_bank/test_catalog.py
```

The offline tests bind the snapshot to the attachment digest, require all 204
unique source IDs and per-section counts, reconstruct every question cell from
instructions/criteria/context, verify direction and headline exceptions, verify
context inheritance and the 34 inline markers, and require audited kind bases.
The suite first failed because no catalog existed, then passed after import.
No provider request is needed for these checks.
