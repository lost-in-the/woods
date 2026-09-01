# 05. Low findings

69 findings. Grouped by layer. Compact format: files, one-paragraph mechanism, spec state, fix direction. Evidence label at the head of each entry.

None block release individually. Two clusters are worth batching: the block-keyword line-parser family (EXTB-1/2 mediums plus STO-3, EXTB-17) and the standalone-require family (STO-5, INF-8, INF-9, EXP-8, EXTB-13).

---

## Extraction core

### CORE-3 [executed]. The `extracted_at` write-skip mask also blanks a nested metadata timestamp
`extractor.rb:1503-1539`. The mask is a global gsub; a future extractor storing a nested `extracted_at` key makes that value invisible to the byte comparison, so a change to only it skips the write. Latent: no extractor emits one today. Spec covers the top-level skip only. Fix: anchor the mask to the document-final position.

### CORE-4 [traced]. Reader retention pin can busy-spin forever on a payload directory missing its manifest
`mcp/index_reader.rb:690-717`. The ENOENT retry loop has no sleep, cap, or fallthrough when the payload dir exists but `manifest.json` does not. Tampering-only, but the failure is a 100%-CPU hang of the request thread. Spec: none. Fix: bound the retry, then proceed unpinned.

### CORE-5 [executed]. ChangeSet normalization edges: trailing-slash root breaks `relativize`; doubled slashes bypass dispatch
`change_set.rb:74-86`. `root: "dir/"` makes every relative path miss dispatch rules; `app//models/x.rb` matches nothing. Current callers are safe. Fix: chomp the root, cleanpath in absolutize.

### CORE-6 [traced]. `Generation#payload_dir` bounds the pointer with expand_path, weaker than the B-134 realpath boundary
`generation.rb:147-156` vs `index_artifact.rb:162-177`. A symlink inside `payloads/` escapes the textual check; every payload reader resolves through this one point. Fix: realpath comparison, mirroring `validate_dump_dir!`.

---

## Extractors A

### EXTA-7 [traced]. Governed naming silently degrades on zeitwerk < 2.6.4 and classic-mode hosts
`source_nesting.rb:248-255, 414-433`. Without `cpath_expected_at` (zeitwerk < 2.6.4, Jan 2023) governance yields nothing, and the G-1 wrapper shape then aborts extraction with a misleading remedy. Rails 6-era lockfiles are realistic on the supported floor. Fix: decide fallback-vs-document; at minimum name the zeitwerk floor in UPGRADING_TO_2 and the collision message.

### EXTA-8 [executed]. CallbackAnalyzer false positives from strings and comments in method bodies
`callback_analyzer.rb:150-175`. `Rails.logger.info "self.status = pending"`, a commented-out write, and `self.email =~ /x/` all report a column write. Fix: run bodies through the existing quote-aware stripper; add `(?!~)`.

### EXTA-9 [traced]. ModelExtractor cannot inline concerns outside three hardcoded directories
`model_extractor.rb:385-392` vs `controller_extractor.rb:344-350`. Namespaced concerns (`app/models/library/sluggable.rb`) silently fail to inline; the controller extractor already solved this with `const_source_location`. Fix: same resolution, conventions as fallback.

### EXTA-10 [executed]. Job retry_config truncates namespaced error classes at `::`; the spec pins the bug
`job_extractor.rb:264` (`retry_on\s+(\w+)`) vs the correct sibling at `:317`. `ActiveRecord::Deadlocked` records as `ActiveRecord` and the wait/attempts tail parses nil. `job_extractor_spec.rb:329` asserts `eq('Net')`. Fix: flip the pin, use `(\w+(?:::\w+)*)`.

### EXTA-11 [executed]. Phantom parameters in perform_params/initialize_params for kwargs and comma-bearing defaults
`job_extractor.rb:291-310`, `shared_utility_methods.rb:294-310`. `perform(user_id, notify: true)` records params `user_id, notify, true`. Fix: consume kwarg defaults, or parse with Prism.

### EXTA-12 [executed]. Nested permit/expect keys captured inconsistently: parent keys dropped, nested leaves kept
`controller_extractor.rb:582-597` (`:(\w+)` only). `permit(:title, tags: [], meta: {seo: [:keyword]})` yields `title, keyword`. Fix: decide flat-vs-deep, capture `(\w+):` too. Adjacent to M2, distinct.

### EXTA-13 [traced]. IGNORED_HELPER_PREFIXES drops navigation edges for real resources named file_*/image_*/video_*/log_*/download_*
`route_helper_resolver.rb:35-51, 106-111`. The ignore list also suppresses helpers that resolve in the live route map, i.e. provably real routes. Fix: consult the map first; ignore only unresolvable bases.

### EXTA-14 [executed]. Non-ASCII identifiers truncate (`Café` → `Caf`); `=begin/=end` blocks parsed as code
`source_nesting.rb:43, 522-529`. Fix: `[[:upper:]][[:word:]]*`; skip `=begin` blocks.

### EXTA-15 [traced]. MailerExtractor lacks the `defined?` guard and app-defined gate its peers got in #200
`mailer_extractor.rb:30, 47-81`. Without ActionMailer, construction raises and the run aborts; without ApplicationMailer, gem mailers index as empty units at fabricated convention paths: and being CLASS_BASED-protected, they persist. Fix: mirror #200.

---

## Extractors B, AST, graph

### EXTB-8 [executed]. GraphQL per-field complexity misattributed across fields
`graphql_extractor.rb:711-726`. The `/m` scan lets a field without complexity absorb the next field's. Fix: bound the match to one declaration.

### EXTB-9 [executed]. Namespaced string rake dependencies truncate to the last segment
`rake_task_extractor.rb:294-298`. `task deploy: 'assets:precompile'` records dependency `precompile`. Fix: scan quoted strings and widen to `[\w:]+`.

### EXTB-10 [executed]. `pagerank` raises NoMethodError on a graph restored with edges for a node-less identifier
`dependency_graph.rb:584-593`. `from_h` tolerates the shape elsewhere; `pagerank_step` does `scores[src] * n` with a nil score. Hand-corrupted artifacts only, but the failure is an unrescued crash in the incremental PageRank refresh. Fix: `scores.fetch(src, 0.0)`.

### EXTB-11 [executed]. `to_h`'s dup protection is shallow: callers can mutate the live graph through the returned edge arrays
`dependency_graph.rb:623-675`. The documented "callers can't pollute" contract is violated; current in-process consumers are read-only. Fix: deep-freeze or dup the memo.

### EXTB-12 [executed]. Whenever commands in single quotes are not recognized
`scheduled_job_extractor.rb:231-242` (double-quote-only regexes). `runner 'CleanupJob.perform_later'` yields `:unknown`, no job edge. Fix: `(['"])...\1`.

### EXTB-13 [executed]. FlowDocument uses `Time#iso8601` without requiring `time`
`flow_document.rb:3-4, 34`. Standalone require crashes. Part of the standalone-require batch.

### EXTB-14 [traced]. Stale fail-open YARD on FlowPrecomputer contradicts the fail-closed contract
`flow_precomputer.rb:130-139` vs `:63-64`. The log-and-skip branch it describes is dead code. Fix: correct the YARD, drop the unused parameter.

### EXTB-15 [executed]. Predicate-less `case` loses its first `when` branch and reports condition `"when"`
`ast/parser.rb:352-359`, `operation_extractor.rb:160-175`. Fix: positional case children, mirroring the L2 fix.

### EXTB-16 [executed]. Call sites in a block call's receiver chain are lost
`ast/call_site_extractor.rb:70-84`. `User.where(active: true).each { }` records no `where`. Same class as EXTB-5, distinct site. Fix: recurse into the send child's receiver.

### EXTB-17 [executed]. A blockless AASM event is dropped and can disable later event parsing
`state_machine_extractor.rb:279-312`. `event :noop` followed by `end` drives depth negative; all later events lost. Fix: emit blockless events immediately; clamp depth.

### EXTB-18 [traced]. `change_table` column additions invisible to migration extraction
`migration_extractor.rb:37-57, 349-383`. No `columns_added`, no `tables_affected` entry, no model edge. Fix: add `change_table` to the block scans.

### EXTB-19 [traced]. YAML schedule environment unwrapping picks the first environment, not the current one
`scheduled_job_extractor.rb:114-127` (`data.values.first`). A recurring.yml listing development first indexes the development schedule. Fix: prefer `Rails.env`, fall back to union.

---

## Index MCP

### MCP-7 [traced]. Reload documentation drift: a removed method named in comments; `invalidate_pagerank_cache!` claims a caller that never calls it
`bootstrapper.rb:739-741`, `ranker.rb:80-91`. Pre-M7 breadcrumbs invite reintroducing in-place mutation. Fix: doc edit; remove or re-document the orphan API.

### MCP-8 [traced]. ToolContract crashes server build with a bare KeyError for any future integer parameter missing from INTEGER_BOUNDS
`tool_contract.rb:81-86`. Fail-closed is right; the failure is unlabeled and far from its cause. Fix: fetch with a raise naming the table.

### MCP-9 [traced]. `search` accepts arbitrary `fields` values; a typo returns a clean empty result
`server.rb:456-459`, `index_reader.rb:447-462`. Inconsistent with the otherwise strict enum policy. Fix: enum the schema items.

### MCP-10 [traced]. `woods-mcp-start` is documented "self-healing" but validates and execs once
`exe/woods-mcp-start:4-5, 60`; CLAUDE.md architecture table. No supervision exists (and no restart-storm surface either). Fix: rename to preflight wrapper, or implement a capped loop.

---

## Console

### CON-3 [executed]. Alias/aggregate redaction refusals compare case-sensitively, unlike every sibling refusal
`embedded_executor.rb:1005, 1011, 1032, 1038` vs `:630, 649`. Shielded today by the exact-match column validator; becomes the H2 leak again if column validation ever goes case-insensitive (the #268 direction). Fix: casecmp? in both refusals.

### CON-4 [executed]. `validate_scope_array!` strips noise with a fixed :postgres dialect
`embedded_executor.rb:1406`. A MySQL escape can hide a forbidden subquery from the template scan. Not reachable through the registered schema; defense-in-depth for direct callers. Fix: pass `dialect: sql_dialect`, or scan both strips.

### CON-5 [executed]. AuditLogger truncates before redacting; a secret straddling the 16 KiB boundary logs in cleartext
`audit_logger.rb:49-51`. Only the opt-in eval path writes entries, and only >16 KiB fields trigger it. Fix: redact before truncating.

---

## Storage and embedding

### STO-3 [executed]. `=begin/=end` blocks permanently corrupt chunker depth tracking
`chunking/semantic_chunker.rb:58-59, 99-116`. `=begin` matches the assignment-position `begin` branch; the enclosing method never closes and later methods merge into its chunk. Neighbour of #195. Fix: reject `=begin`/`=end` in `block_opener?`.

### STO-4 [executed]. `Snapshotter::Metadata` raises raw EOFError/NoMethodError on truncated or field-less dumps
`snapshotter/metadata.rb:81-96, 140-155`. The Vector twin got typed M3/M10 guards; the metadata twin breaks the same contract. Fix: mirror the typed guards.

### STO-5 [executed]. Standalone require broken for qdrant.rb, circuit_breaker.rb, cache_middleware.rb
`Woods::Error` referenced before definition; `cache_middleware` includes an interface it never requires. The repo has an explicit shim convention these three miss. Fix: add shims; extend load_order_spec into a require-in-isolation sweep.

### STO-6 [traced]. `Builder#vector_dimensions` crashes for injected providers without `#dimensions`
`builder.rb:145-148` unguarded, contradicting the #178 respond_to contract; the explicit `dimensions:` option fallback is unreachable. Also the B-108 shape via the Interface stub. Fix: guard like `safe_max_input_tokens`.

### STO-7 [executed]. `cache_key` single-part vs multi-part arity collision
`cache/cache_store.rb:27-35`. `cache_key(:d, '4:abc22:xy') == cache_key(:d, 'abc2', 'xy')`. Latent. Fix: length-prefix single parts.

### STO-8 [executed]. MetadataStore adapters diverge on non-string values; a spec pins the divergence under a parity title
`metadata_store.rb:240, 300-302`; `metadata_store_spec.rb:409-415` asserts InMemory's symbol round-trip while claiming the SQLite contract. Fix: shared examples over Hash-valued fields; deep-stringify InMemory.

### STO-9 [executed]. `type: ''` accepted where L22 made nil raise
`metadata_store.rb:352-354`. Fix: reject blank.

### STO-10 [traced]. `WOODS_OUTPUT` does not reach the SQLite metadata database path
`tasks.rb:63` vs `builder.rb:476-481`. Units/dumps land under WOODS_OUTPUT; `metadata.sqlite3` lands under `config.output_dir`: outside the swept index, potentially shared between worktrees. Fix: thread the resolved dir into `build_metadata_store`.

### STO-11 [traced]. Indexer prune guards test `respond_to?(:delete)` against the raising Interface stub (dead guard, B-108 shape)
`indexer.rb:746, 766` vs the `implements_own?` helper at `:923`. Fix: use the helper; gate `reconcilable?` too.

### STO-12 [traced]. Snapshotter doc claims Metadata Interface stubs that do not exist; a can-never-fail tolerance spec survives the M10 fix
`snapshotter.rb:18-24`; `vector_spec.rb:680-717` passes whether or not the load raises. Fix: correct the comment; make the spec assert the raise.

### STO-13 [executed]. `Util::UUID5.name_bytes` raises for BINARY-tagged non-ASCII names instead of hashing bytes
`util/uuid5.rb:79-83`. Contradicts its own transcoding doc; latent via caller error. Fix: pass through `.b` for ASCII-8BIT.

### STO-14 [traced, inference on impact]. One provider request can carry batch_size x chunks inputs; no per-request cap
`indexer.rb:465-472, 567-576, 661-665`. 32 heavily chunked units can exceed OpenAI's 2048-inputs limit: a hard 400 aborts the run. Fix: flush `to_embed` in slices.

### STO-15 [executed ancestry]. OpenAI in-adapter retry omits Net::ReadTimeout, asymmetric with Ollama
`openai.rb:166` vs `ollama.rb:391`. A read timeout escapes raw instead of typed. Fix: add it to the rescue.

---

## Daemon and infra

### INF-5 [executed]. JsonSnapshotStore: wrong-type valid JSON raises TypeError out of all four snapshot tools; a pruned file mid-listing raises ENOENT
`json_snapshot_store.rb:259-307`. `[]` in one snapshot file takes down find/list/diff/unit_history; the glob-read window races the unlocked retention prune. B-135 pinned the truncation shape only. Fix: require Hash, rescue SystemCallError.

### INF-6 [executed]. A corrupt pipeline_guard state file is a dead end `pipeline_repair` cannot clear; the spec pins reset-as-no-op
`operator/pipeline_guard.rb:43-53, 145-153`; `mcp/server.rb:1588-1594` answers "nothing was repaired" while diagnose says corrupt. Fix: let an explicit `reset!(:all)` rewrite corrupt state, or make the repair message honest.

### INF-7 [executed]. A write failure during `PipelineLock#acquire` leaves a fresh 0-byte lock blocking every writer for the stale window
`pipeline_lock.rb:74-84, 342-346`. The touch path was fixed to never create this artifact; acquire can still leave one. Fix: unlink the just-created path on a raised write.

### INF-8 [executed]. `redis_store.rb` standalone turns the documented missing-gem error into a NameError
`session_tracer/redis_store.rb:3-5, 58-60`. Fix: require or guard `SessionTracerError`. Standalone-require batch.

### INF-9 [executed]. `feedback/store.rb` never requires `time`
`feedback/store.rb:3-4, 41, 58`. Standalone-require batch.

### INF-10 [traced]. Catch-up trusts generation.json's mtime without checking the payload it points to exists
`watch/daemon.rb:600-604, 529-531`. A gutted index (marker survives, payload gone) reads "current at startup"; callers stand down over nothing. Fix: dangling pointer → no watermark → storm path.

### INF-11 [traced]. Startup-claim residuals: the no-hardlink fallback reopens the torn-read window; `release_claim` deletes without verifying ownership
`watch/daemon.rb:1010-1020, 1108-1114`. Fix: verify-before-delete, mirroring `reclaim_if_stale`.

### INF-12 [traced]. A missing git binary crashes `woods:incremental` with a raw Errno::ENOENT, bypassing the tail-M1 decision
`lib/tasks/woods.rake:244-253`. Safe direction (non-zero), wrong shape (backtrace; stand-down branch unreachable). Fix: rescue SystemCallError into the `[nil, failure]` shape.

### INF-13 [traced]. The P4 CHANGELOG entry overstates what the migration preserves
Migrated legacy members all score 0, so they evict lexicographically and before any post-migration session. "Eviction order is unchanged" is not true for the migrated cohort. Fix: one-line CHANGELOG correction.

---

## Exporters and evaluation

### EXP-5 [traced]. No exporter pins the reader generation; a concurrent publish mid-export produces a mixed-generation export
`notion/exporter.rb:96-172`, `unblocked/exporter.rb:98-130`, `obsidian/vault_exporter.rb:72-94`; the reader assigns pinning responsibility to direct callers (`index_reader.rb:152-154`). Self-healing next run; purge guards bound deletions. Fix: wrap sync bodies in `with_pinned_generation`.

### EXP-6 [executed]. Obsidian stale-note sweep silently disabled when the vault path contains glob metacharacters
`vault_exporter.rb:297-303`. `my [work] vault` matches nothing; stale notes accumulate forever. Fails safe. Fix: chdir-relative glob or Find-based walk.

### EXP-7 [executed]. `QuerySet.load`/`#save` are locale-dependent: non-ASCII query text raises untyped under LANG=C
`evaluation/query_set.rb:70, 87`; the sibling `baseline.rb:43` already passes the encoding. Part of the encoding family (see 04, INF-3). Fix: explicit UTF-8.

### EXP-8 [executed]. `ReportGenerator` missing `require 'time'` and `require 'fileutils'`
`evaluation/report_generator.rb:3, 35, 63`. Standalone-require batch.

### EXP-9 [executed with stubbed digest]. NameMapper's collision hash suffix is never re-checked; Windows reserved device names unsanitized
`obsidian/name_mapper.rb:79-91`. Hash-suffix collision needs a 2^-32 coincidence; `Aux.md` breaks Windows-synced vaults [inference]. Fix: loop-until-free; reserved-name prefixing.

### EXP-10 [traced]. `context_completeness` is definitionally identical to `recall`
`evaluation/evaluator.rb:113-115`, `metrics.rb:36-68`. The `required` subset the metric documents was never plumbed into QuerySet. Fix: add `required_units` or drop the metric.

### EXP-11 [traced]. A columns-only Notion configuration silently syncs nothing
`notion/exporter.rb:96-99`. Configured a database, got zero pages, no message. Fix: sync relation-less columns or warn.

---

## Reconciliation residuals (from Phase 1)

### R1-3 [executed]. `permitted_params` drops hash-style permit keys
`controller_extractor.rb:585`. `permit(:title, meta: [:a], ids: [])` loses `meta`/`ids` while leaking nested leaves. Same fix family as EXTA-12.

### R1-5 [traced]. Whitespace-only `OPENAI_API_KEY` is absent on one resolver path, present on the other
`config_resolver.rb:190` (no strip) vs `:321` (strip). Fix: strip-aware blank check on the artifact path.

### R1-6 [traced]. Select-side redaction refusals use exact config matching while predicate refusals use casecmp
Same divergence hazard as CON-3, reported independently by the reconciliation pass; one fix covers both.

### R2-2 [traced]. Seven deferred lows never received the promised backlog IDs
L3, L7, L12, L13, L14, L15, L21 have reasons only in the out-of-repo audit folder. Fix: seven one-line backlog entries.

### R2-3 [executed]. The P5 guard spec fails the default suite under a C locale
`spec/mcp/index_reader_spec.rb:1087-1091` reads gem source with a bare `File.read`, then regex-matches it: `ArgumentError: invalid byte sequence in US-ASCII`. Confirmed in this audit's full-suite baseline. Fix: read with explicit UTF-8 (gem source, not a Woods artifact).

### R2-4 [traced]. P5's ReDoS bound does not exist on the supported Ruby 3.0/3.1 floor
`index_reader.rb:883-889` gates the timeout on Ruby >= 3.2; older interpreters also lack the 3.2 regex memoization. CHANGELOG discloses it; the ledger row does not. Fix: coarse wall-clock deadline on < 3.2, or a release note.

### R2-5 [traced]. P4's ZSET migration is write-path-only: reads raise WRONGTYPE against an unmigrated legacy index
`redis_store.rb:100, 137` (zrange) vs migration only in `record`. Reader-only processes and mixed-version fleets are exposed. Fix: migrate or rescue on the read path.

### R2-6 [traced]. JSON snapshot retention can never prune a corrupt snapshot file
Victims come from parseable summaries only; corrupt files accumulate. Intersection of P8 and B-135. Fix: rank unreadable files as oldest victims.
