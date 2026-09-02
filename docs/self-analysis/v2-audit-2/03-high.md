# 03. High-severity findings

Two findings. Both executed, both re-verified independently by the synthesizing session.

---

## CORE-2. `woods:incremental` with no baseline silently publishes a near-empty index as generation 1

- **Severity**: High. **Evidence**: [executed], re-verified. **Spec coverage**: none.
- **Files**: `lib/woods/extractor.rb:638-650` (`prepare_incremental_run` loads the graph only `if graph_path.exist?`), `:760-785` (`begin_payload!` raises only when a published marker names a payload; an unpublished marker passes), `lib/tasks/woods.rake:370-416` (`woods:incremental` checks range and daemon coverage, never index existence).

### Mechanism

`extract_changed` against a virgin output directory computes an empty blast radius over the empty graph. It dispatches only the diffed paths. Then it **publishes generation 1** containing only those units.

Executed probe: two services on disk, one named in the diff, empty output dir. Result: `generation=1`, `services/_index.json = ["AlphaService"]`, manifest counts `{services: 1}`. No warning, no error. `raise_on_publication_failure!` passes.

### Why it matters

The documented CI chain is: restore the previous index from cache, run `woods:incremental` per merge (`docs/INCREMENTAL_EXTRACTION.md:40-42`). Three ordinary events produce the empty-baseline state:

- a failed or evicted cache restore
- a typo'd `WOODS_OUTPUT`
- a first run on a fresh runner

The git range still resolves, so the tail-M1 guard (exit 1 on unresolvable range) never fires. Readers, `woods:validate`, embedding, and retrieval all treat the one-unit index as the complete truth. **Nothing self-heals until someone runs a full extraction.** Every later incremental compounds the wrong baseline.

The invariant is already known and enforced elsewhere: the watch daemon treats a missing `generation.json` as "no index, run one full extraction" (`watch/daemon.rb:515-520`). The rake path has no such guard. The same file fails loudly for "the diff is unknown" and publishes silently for "the baseline is unknown", which is the strictly worse condition.

### Fix shape

Failing spec first, two levels:

1. `spec/extractor_spec.rb`: `extract_changed` over an output dir whose generation is unpublished and which holds no `dependency_graph.json` raises `Woods::ExtractionError` naming `woods:extract`.
2. A rake-level spec beside `spec/tasks/woods_rake_publication_spec.rb` asserting non-zero exit.

Code: in `prepare_incremental_run`, after `begin_payload!`, raise when `marker.number.zero? && !graph_path.exist?`. The daemon is unaffected: its catch-up already runs `extract_all` in that state. Verify the daemon path stays exempt.

- **Dedupe**: not in the backlog. Adjacent to tail-M1 (which fixed the unknowable-diff half of the same posture), distinct mechanism.

---

## CON-1. `console_query` alias collision onto an EAV header defeats redaction; the real secret returns in cleartext

- **Severity**: High. **Evidence**: [executed], re-verified. **Spec coverage**: none.
- **Requires**: `read_tools_enabled: true` (the `console_query` tool) plus `console_redacted_key_values` configured.
- **Files**: `lib/woods/console/embedded_executor.rb:1001-1016` (`refuse_redacted_select_alias!` refuses only when the aliased column is protected), `:910-940` (the orphan-EAV check skips aliased expressions), `lib/woods/console/redactor.rb:115-126` (`positional_kv_rules`: `columns.each_with_index.to_h`, duplicate headers collapse, last index wins).

### Mechanism

With `console_redacted_key_values: [{key_column: 'key', value_column: 'value', sensitive_keys: ['stripe_access_token']}]`:

```
console_query select: ["key", "value", "id AS value"]
```

All three expressions validate. `id` is unprotected, so aliasing it is permitted. The orphan-EAV check sees the real key+value pair and is satisfied. The result headers are `["key", "value", "value"]`. `positional_kv_rules` builds its index with `to_h`, so the aliased `id` column at index 2 overwrites the real value column at index 1.

Redaction masks index 2 (the harmless `id`). **The real secret at index 1 returns in cleartext.** Re-verified output:

```
{"columns"=>["key","value","value"],
 "rows"=>[["stripe_access_token", "sk_live_SECRET_VALUE_123", "[REDACTED]"], ...]}
```

The `id AS key` variant is worse: the key index points at the id column, whose values never match `sensitive_keys`, so no cell is masked at all.

### Why it matters

The round-2 remediation (#248, #265, #268) hardened every shape where a **protected** column is aliased, aggregated, or predicated. It never considered an **unprotected** column aliased onto a protected output header. The CredentialScanner backstop only catches credential-shaped values. EAV redaction exists precisely for values whose shape no pattern recognizes; those leak past both layers.

### Fix shape

Failing specs first:

1. `spec/console/embedded_executor_query_spec.rb` (EAV context): `select: ['key','value','id AS value']` refuses with a validation error.
2. `spec/console/redactor_spec.rb`: `columns: %w[key value value]` masks the real value cell.

Code, two independent layers:

- `refuse_redacted_select_alias!` (and the aggregate sibling) also refuse when the **alias name** equals any `redacted_columns` or EAV pair column, case-insensitively. An alias must not name a protected output header.
- `Redactor.positional_kv_rules` treats a duplicated header as ambiguous: mask every index whose header matches, and refuse to resolve an EAV pair when either header appears more than once.

- **Dedupe**: neighbouring shape of H2's closure; not in the backlog or CHANGELOG. The same last-index-wins hazard exists for plain `redacted_columns` duplicates and deserves the defensive redactor change too.
