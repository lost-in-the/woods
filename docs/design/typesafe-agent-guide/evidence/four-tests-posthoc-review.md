> Portable evidence copy. Historical status and proposed commands are preserved; this is not a promise that the planned APIs were implemented. Links and the installed-skill location were normalized for portability. Raw ignored captures and external source snapshots are not included.

# Posthoc literal-search compatibility audit

This audit runs after the coordinator approved exact submitted patch hashes and the primary evaluator produced accepted checkouts. It does not change submissions, source files, frozen tests, or primary labels. Evidence is supplementary to the four-task comparison.

## Validation

All five accepted T004 submissions and the untouched correct baseline passed:

```text
bin/rspec spec/retrieval/search_executor_spec.rb spec/retrieval/ranker_spec.rb \
  --seed 20260917 --format progress
116 examples, 0 failures
```

That is six runs and 696 repeated validations, not 696 independent development tasks. Source hashes for the metadata store and search executor remained unchanged by the audit. Logs and exact commands are in each cell directory; `summary.json` consolidates them.

The two 1,000-token BM25 abstentions were not patched or tested. The five accepted cells were BM25 3,000 and 8,000, TypeSafe 1,000 draws 1 and 2, and TypeSafe 3,000. The BM25 8,000 submission, which arrived after the earlier read-only review, has the same relevant changes as TypeSafe 3,000: restore underscore escaping and narrow InMemory/SearchExecutor folding to ASCII.

## Observed compatibility differences

A bounded probe ran 19 search cases per adapter plus keyword-field attribution, using Ruby 4.0.6 and SQLite 3.53.2. It covered non-ASCII case pairs, strings with embedded NUL, Boolean/numeric/null/missing fields, empty queries, and structured values. Exact responses are retained in each `compatibility_probe.stdout.log`.

- All five repairs narrow InMemory non-ASCII matching. For example, `café_menu` no longer matches a field containing `CAFÉ_menu`. The baseline interface explicitly leaves non-ASCII folding backend-specific, so this is an observed behavior change rather than an established violation of the frozen ASCII contract. Primary successes remain unchanged.
- BM25 3,000, BM25 8,000, and TypeSafe 3,000 also narrow `SearchExecutor#matched_fields_for`. In a record with an uppercase-accented description and a matching lowercase-accented note, keyword attribution changes from both fields to the note only, and the score changes from 0.5 to 0.25. The two TypeSafe 1,000 repairs leave this helper unchanged. Existing retrieval/ranker tests pass in either case; this illustrates why generic edit permission needs changed-file review beyond the original focused oracle.
- The three `instr(lower(...), lower(?))` SQL rewrites (BM25 3,000 and both TypeSafe 1,000 draws) also eliminate the baseline NUL mismatch described below. The two underscore-only SQL fixes retain it. This was not part of the frozen acceptance and does not alter its scores.
- The numeric, null/missing, empty-query, and structured-value controls showed no new differences from the correct baseline in this probe set. This is a bounded compatibility check, not exhaustive equivalence or a performance benchmark.

## Two independently reproduced baseline defects

Both findings exist in untouched production source, separate from the seeded underscore mutation. The remote `main` commit is `55a74ea4f3a7c3e798493a92663003aab85a2301`; its metadata-store SHA-256 equals the local baseline: `7f81cb14175367b36db99f58605071921d782605fdb0d4ee87a3591e58db6711`. `upstream-verification.json` records the check.

1. **NUL violates literal matching.** With one field containing `"prefix\0suffix"` and another containing `"unrelated"`, a field-scoped `"\0"` query returns both records in SQLite and only the actual NUL record in InMemory. A `"suffix"` query returns the NUL-containing record in InMemory and nothing in SQLite. The public contract excludes no NUL input, while JSON storage accepts it. The report asks for consistent literal handling or explicit rejection instead of silent broadening. Narrow reproducer: `repro_nul.rb`; draft: `issue-nul.md`.
2. **Boolean field representation differs.** Searching Boolean fields for `true`/`false` matches InMemory but not SQLite; querying `1`/`0` reverses those results. This is the interaction of Ruby Boolean `to_s` and SQLite `json_extract`'s numeric Boolean representation. The report asks to choose and test a consistent representation, without assuming which adapter must change. Narrow reproducer: `repro_boolean.rb`; draft: `issue-boolean.md`.

Both narrow reproducers ran directly against the correct baseline. Their outputs are retained. All-state duplicate search covered 353 issue/PR records through GitHub REST; no matching issue was identified. The coordinator received the Markdown drafts and exact JSON request payloads for posting. This agent did not write to GitHub.

## Implication for the experiment and guide

The frozen tests correctly establish their declared task requirements, but do not prove all observable behavior is unchanged. Candidate selection can enable a broader valid rewrite or an additional-file edit. Before integrating a generated patch, inspect its complete scope, run tests covering each touched subsystem, and distinguish promised compatibility from deliberately unspecified behavior. The low selector price does not replace these checks. These observations strengthen the case for advisory context selection and reviewed development workflows, without changing the experiment's primary denominator or labels.
