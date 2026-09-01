# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Performance

- **Controller and mailer chunk extraction parses each file once, not once per
  action (P1).** `AstSourceExtraction#extract_action_source` re-read and re-parsed
  the defining file for every action, so a 30-action controller cost 30 reads and
  30 parses of one source file. The defining file is now read and parsed once per
  extractor instance and every action is answered from that parse; per-action
  chunk output is byte-identical.

- **Event extraction reads each file once per run (P2).** `EventExtractor`
  re-read every publisher/subscriber file for every event that referenced it
  (once per event in pass 2, on top of the pass-1 scan), so a widely-shared file
  was read once per event. Both passes now share one read per path per run.

- **Rake task extraction reads and parses each `.rake` file once per run
  (P9a).** `all_definitions` — the sibling-definition index built on the first
  `sibling_definitions` call — re-read and re-parsed every `.rake` file the main
  extraction path had just handled. Both paths now share a memoized read+parse.

- **GraphQL model-reference scanning makes one pass per type file (P9c).** The
  constant follow-up check ran one full-source scan per unique capitalized
  constant; one combined scan now collects the constants followed by a model
  call. Emitted dependencies are unchanged.

- **Git metadata batching sends each pathspec once (P9d).** Multi-unit files
  repeated their path in every 500-path git log batch; `batch_git_data` now
  deduplicates before slicing. Output is keyed by relative path and unchanged.

- **User search regexes are time-bounded (P5).** `search` compiled the query as
  a raw Ruby regex with no time limit, so a pattern with catastrophic
  backtracking could stall the dispatch thread indefinitely. On Ruby 3.2+ the
  compiled pattern carries a 1s per-match limit; an overrun aborts the scan
  into a partial response with a note instead of hanging. Invalid patterns
  still fall back to an escaped literal match.

- **`dependency_graph.json` parses once per generation (P6).** The Index
  Server's `dependency_graph` and `raw_graph_data` each parsed the same file,
  holding two copies of a large graph per generation; the typed graph now
  builds from the single raw parse.

- **JSON temporal snapshots are pruned by retention (P8).** `snapshots/`
  wrote one file per SHA and never pruned, growing unboundedly on long-lived
  repos. Capture now keeps the newest `WOODS_PAYLOAD_RETENTION` snapshots
  (default 3, same variable and default as payload retention), and the bound
  holds even when the just-captured snapshot's timestamp ties or precedes
  older entries; `diff` and `unit_history` beyond the retention window
  return empty.

- **Redis session-tracer eviction uses a recency ZSET (P4).** `prune_sessions`
  read every candidate session's history on every record once `max_sessions`
  was reached (up to 1000 session reads per request). The `woods:sessions`
  index is now a ZSET scored by each request's timestamp, so eviction touches
  a bounded window and never reads session histories. A legacy SET index from
  a previous version migrates automatically on the first record through a
  single atomic server-side script, so concurrent writers racing the legacy
  index cannot erase each other's members or fail mid-migration; eviction
  order (oldest last request) is unchanged. Adds a live-Redis contract spec
  (`spec/session_tracer/redis_store_live_spec.rb`, `WOODS_RUN_LIVE_BACKENDS=1`).

### Fixed

- **The Index MCP `reload` tool no longer reports an empty success when the promoted dump's
  store configuration diverges from the live server (M2).** The live retriever was in-memory
  and the captured dump was complete and valid, but when the dump's embedded `woods.json`
  named a store type the live target cannot refresh (a re-embed ran with pgvector or Qdrant
  configured and promoted over the dump the server hydrated from), the reload-time resolver
  adopted the dump's store types, every candidate builder returned nil, and the tool answered
  `reloaded: true` with zero counts while nothing was swapped and no degraded condition was
  recorded. That divergence is now a degraded reload: the `reload` tool responds with the
  reload-phase `degraded_index` error naming both store types and the honest state (nothing
  was swapped, the previous generation is still served), and the condition surfaces additively
  through `woods_status` (`bootstrap.reload_failure`). A genuine empty dump still reloads
  successfully with zero counts.

- **Vector dump hydration fails closed on a truncated or mismatched `vectors.idx` (M3).** The
  idx parser read each record's length, id, and offset with no end-of-file guard: a dump
  truncated mid-record hydrated a garbage short id silently, an idx holding more records than
  the float blob crashed hydration with a bare `NoMethodError`, and an idx holding fewer
  silently hydrated fewer vectors than the dump header claims. Parsing now raises the same
  typed `UnsupportedArtifact` the bin side raises for a truncated float payload when a record
  would read past EOF, and the idx record count is cross-checked against the header's
  `vector_count` after parsing, naming both counts and prompting a re-run of `woods:embed` on
  mismatch.

- **Best-effort Git provenance and file-history probes are now quiet and rooted
  at the extracted application.** Expected failures in source copies without a
  `.git` directory no longer emit `fatal: not a git repository` on stderr, and
  extraction launched from another checkout can no longer attach that
  checkout's branch or file history to the Rails application.

- **Reloading the Index MCP server no longer opens an empty-store window, and a
  failed reload no longer leaves a misaligned index (M7).** The `reload` tool
  refreshed the live in-memory vector and metadata stores with `clear!` followed by
  `bulk_load`, so a concurrent `codebase_retrieve` could search an empty or
  half-loaded store (and the reader's caches were reloaded even when store
  hydration failed, pairing one generation's JSON index with another's vectors).
  The reload is now a transaction: candidate stores are built off-side against one
  captured generation marker and one captured promoted-dump identity, reading
  exclusively from those captured locations (config from the captured dump's
  embedded snapshot, vector/metadata from the captured dump directory, the graph
  from the captured payload), so a concurrent promotion can never mix vector and
  metadata halves from two dumps. Any candidate failure leaves the previous fully
  aligned generation untouched — the old retriever keeps answering and a distinct
  reload-phase `degraded_index` condition (with `phase: 'reload'` naming the
  generation still being served) is reported on the `reload` tool response and
  additively through `woods_status` (`bootstrap.reload_failure`), without flipping
  the boot degraded state. The commit acquires the same on-disk extraction
  PipelineLock every writer uses before rechecking both identities, so a writer
  cannot publish between the recheck and the one-assignment store-bundle swap; a
  promoted dump missing any required vector or metadata component also fails
  closed without replacing the healthy live bundle. Because the reload transaction
  takes the shared on-disk writer lock, the MCP process needs write access to the
  index directory when using `reload`. A
  generation movement fails the attempt with `ReloadGenerationMoved` and a
  promoted-dump movement (an embed promotes without bumping the generation file)
  with `ReloadDumpMoved` — the next `reload` is the recovery path. A successful
  reload clears the condition.

- **Incremental extraction no longer misses a class-based unit whose file
  moved with its constant unchanged (M1).** Moving `app/models/tag.rb` to
  `app/services/tag.rb` without renaming `Tag` pruned the model for the
  vanished old path, and the second reconciliation pass refused to re-add
  it, so one generation served an index with the unit missing until the
  next run. The pass now re-adds pruned class-based identifiers the active
  Zeitwerk loader still governs a changed file for — the constant path
  `cpath_expected_at` derives (its inflector, ignores, and root namespaces
  decide), gated on the file declaring it; a loader non-claim is
  authoritative, so an unmanaged path re-adds nothing. Another namespace's
  same-named file and a file that only mentions the class in a comment or
  string literal resurrect nothing; deletions (including deletions batched
  with unrelated additions) stay pruned exactly as before.
- **Incremental runs now refresh the flow artifact family, and both paths
  fail closed (M3).** With `precompute_flows` enabled, a controller
  re-extracted incrementally lost `metadata[:flow_paths]`,
  `flow_index.json` kept describing pre-change routes, and `flows/`
  documents for deleted or renamed controllers persisted across every
  generation. Incremental runs now recompute the run's controller delta,
  carry untouched controllers' entries forward, and sweep `flows/`
  documents nothing references through a dedicated flow-artifact sweep
  (separate from the unit sweep). Full and incremental extractions of the
  same tree produce equivalent flow artifacts. A failure anywhere in the
  family on either path — assembly, index write, annotation rewrite, or
  sweep — now aborts before the generation publish, so a partial flow
  index, stale prior flow artifacts alongside a new graph, or
  half-rewritten annotations can never be published; the preceding
  generation stays resolved and readable.
- **`woods:validate` no longer fails every flow-enabled index (G-2).** The
  validator treated `flows/` as a unit-type directory and demanded
  `_index.json` from it, so any index published with flow precomputation
  on reported "Missing _index.json in flows/". Type directories are now
  bounded by a shared allowlist derived from `Extractor::EXTRACTORS`, and
  the flow family is validated by its own rule: `flow_index.json` must
  parse and every entry must point at a flow document that exists and
  parses, with missing or malformed artifacts reported accurately.
- **Multi-line `strong params` declarations are captured (M2).** The
  `permit(...)`/`expect(...)` capture regexes could not cross newlines, so
  the common multi-line style produced an empty `metadata[:permitted_params]`.
- **A half-loaded model no longer aborts the models phase (L1).**
  `ModelExtractor.discoverable_classes` called `abstract_class?` unguarded;
  a descendant that raises on it (possible under the NameError fallback)
  escaped the scan and failed the whole extraction. The call is guarded the
  same way `ModelNameCache` already guarded its twin, keeping the class and
  letting per-class extraction handle failures.
- **`if nil` no longer misattributes conditional branches in flow analysis
  (L2).** The AST normalized `if` children with a `compact` that dropped a
  literal `nil` condition, so the else body landed in `then_ops`. `if`
  children are positional now; missing slots stay nil.
- **A hydration failure at boot no longer reports `:hydrated` over empty stores (M6).**
  A corrupt or unreadable dump left the in-memory vector/metadata stores empty behind
  only a stderr warning while `woods_status` reported a healthy `:hydrated` — a server
  that answered everything with nothing. The boot status is now derived from store
  health (`:degraded` plus a per-store `hydration_failures` report), and
  `codebase_retrieve` answers with a typed `degraded_index` error naming the affected
  stores instead of a clean empty result. Graph hydration reads through the
  encoding-safe atomic-file path, so a non-ASCII index stays healthy under `LANG=C`.
- **A metadata-store failure no longer produces misleading retrieval answers (M8).**
  Store errors were swallowed at three call sites: `types:` queries reported `:absent`
  for types that exist, the rank-within-type fallback short-circuited to empty, and
  exclusion filtering silently no-op'd. All store accesses now raise the shared
  `Woods::Retriever::StoreError`, which `codebase_retrieve` maps to the same typed
  degraded metadata instead of raising through the tool boundary.
- **A set-but-empty `OPENAI_API_KEY` behaves as absent (M9).** The truthiness check
  wired the OpenAI provider with a blank key, skipped the Ollama fallback a missing key
  gets, and then crashed boot with a raw backtrace. Blank keys now fall through to the
  Ollama probe (pattern-only when nothing is usable), and both executables catch
  `Woods::ConfigurationError` in their bootstrap rescue so an unusable embedding
  configuration prints the one-line operator message.
- **A non-`SystemCallError` guard failure no longer leaks the pipeline lock (L6).**
  `pipeline_extract`/`pipeline_embed` released the on-disk lock only for
  `SystemCallError`/`IOError` from the task-durability guard; any other raise blocked
  every later writer until the stale window expired. The release is now `ensure`-based
  for every pre-handoff exit path.
- **"find who calls X" routes to graph tracing (L8).** The query classifier's
  first-match ordering sent mixed locate/trace queries to keyword location handling;
  the `:trace` intent pattern now runs before `:locate`.

- **`woods_status` no longer reports a stale registry version alongside a newer
  install.** When the installed gem is ahead of RubyGems (for example while
  testing an unreleased release), `server.update.latest_version` now reports the
  newest known version — the installed one — instead of the raw published
  version, so the payload no longer pairs `current_version: 2.0.0` with
  `latest_version: 1.6.0` and `update_available: false`. `update_available`
  semantics and all key names are unchanged.
- A wrong-dimension query vector now raises the typed `Woods::Error` before the
  request leaves the process on both the pgvector and Qdrant search paths
  (previously a server-side `PG::DataException` or Qdrant 400).
- An OpenAI embedding request whose one retry also fails now raises the typed
  `RequestError` (as Ollama already did) instead of leaking a raw
  `Errno::ECONNRESET`. Persistent HTTP connections dropped on transport errors
  are closed promptly instead of waiting for GC.

- **A truncated vector dump now refuses to load instead of corrupting search (M10).**
  `vectors.bin` with a valid header but a short float payload used to unpack with nil
  padding: the nil-floated vectors loaded into the live store, crashed search with
  `TypeError`, and re-published as zeros on the next dump. Loading now raises
  `Woods::MCP::UnsupportedArtifact` pointing at the file; the remedy is a re-run of
  `woods:embed`.
- **Every atomic dump write now fsyncs its directory (M11).** The vector and metadata
  snapshotters and the index artifact writer skipped the containing-directory fsync
  `AtomicFile` performs, so a crash after the rename could leave a directory entry that
  a reboot drops — a "complete" generation that vanishes. The class contract that the
  dump directory is fully fsynced before the `latest` pointer flips now holds on every
  write path.
- **File permissions are explicit per artifact (O1).** `AtomicFile.write` takes a `mode:`
  parameter defaulting to the restrictive 0600 Tempfile already used. The one artifact
  with a cross-boundary consumer — the watch daemon's `watch_status.json`, read by
  host-side hooks through a bind mount — is written 0644 by design.
- **A second writer on the metadata SQLite database no longer raises
  `SQLite3::BusyException` immediately (O2).** The connection now sets a busy timeout at
  open and retries a contended write a bounded number of times, mirroring the temporal
  snapshot store.
- **Re-capturing an unchanged HEAD computes diff stats against real history (L20).**
  Both temporal stores resolved "previous" to the snapshot being captured, so the
  re-capture diffed against itself and zeroed every stat. Previous now excludes the SHA
  being captured.
- **Storing metadata without a type key raises instead of writing an empty type (L22).**
  The SQLite metadata adapter coerced an absent key to `""` in the column that backs
  `find_by_type`; it now raises `ArgumentError`.

- **Select aliasing no longer defeats console redaction.** `console_query` accepted
  `select: ["password_digest AS note"]`; the positional redactor masks by output
  header name, so the aliased column returned plaintext. Three select shapes are
  now refused: an alias over a `console_redacted_columns` column, an aggregate over
  one (aliased or bare), and an alias over either column of a
  `console_redacted_key_values` pair. Direct, unaliased selection of a redacted
  column is unchanged and stays masked. Aggregates over either column of a
  `console_redacted_key_values` pair are also refused: an aggregate such as
  `MAX(amount)` over the rows a sensitive key selects reads the redacted EAV value
  itself. Selecting an EAV value column without its paired key column is refused
  as well — the positional rule needs both headers, so a lone value column
  returned plaintext.
- **`console_query`'s having no longer leaks protected values.** `having` accepted
  aggregates over redacted or EAV-protected columns (`MAX(amount) > ?`) and bare
  predicates on redacted columns or EAV value columns; repeated guesses revealed
  the protected value from whether a row was returned. The same protected-column
  refusal used for `select` aggregates now runs on the having template and hash
  keys before any query executes. Structured scope predicates now apply the same
  rule to redacted columns and EAV value columns while preserving EAV key-column
  predicates.
- **Tier 1 and raw-SQL redaction shapes now fail closed.** `console_sample`,
  `console_find`, `console_pluck`, and `console_recent` refuse an EAV value column
  unless its paired key column is selected too; `console_aggregate` refuses either
  EAV pair column. Structured order/group inputs and legacy multi-bind scope arrays
  now apply the protected-predicate guard. `console_sql` accepts a protected
  identifier only as a direct, unaliased outer select column; aliases, aggregates,
  predicates, CTE shapes, and unpaired EAV values are rejected before execution.
- **A writable CTE past the first WITH entry no longer validates.** The writable-CTE
  check anchored its match to the statement leader, so
  `WITH a AS (SELECT 1), b AS (DELETE FROM users RETURNING *) SELECT * FROM b`
  passed validation and PostgreSQL executed the DELETE. Every `AS (...)` body in
  the statement is now inspected. A CTE list attached to top-level DML
  (`WITH a AS (SELECT 1) DELETE FROM users RETURNING *`) is also rejected; DELETE
  and UPDATE previously validated because the statement prefix is WITH and neither
  keyword is a body keyword (only the INSERT variant tripped a check, incidentally
  via INTO).
- **Row-lock clauses are rejected.** `SELECT ... FOR UPDATE`, `FOR NO KEY UPDATE`,
  `FOR SHARE`, `FOR KEY SHARE` (with `NOWAIT`/`SKIP LOCKED`), and MySQL
  `LOCK IN SHARE MODE` validated as reads but took live row locks for the duration
  of the rolled-back transaction. The check is adapter-aware: `console_sql`
  validates with the active adapter's dialect (MySQL and PostgreSQL quote/comment
  grammars differ; MySQL double-quoted strings/backtick identifiers and PostgreSQL
  quoted identifiers/E-strings are tracked faithfully), while scanning
  both normalizations when the adapter is unknown, and every view is checked under
  both MySQL executable-comment (`/*!...*/`) semantics — `#` comments and
  version-guarded comments can no longer split a lock clause apart.

- **Index MCP reads no longer break under a C/US-ASCII host locale.** The
  Index Server read manifest.json, per-type `_index.json` files, and
  SUMMARY.md with bare `Pathname#read`, which tags the bytes with the host's
  default external encoding. Under a C locale that tag is US-ASCII, so any
  non-ASCII content in an index artifact (a branch like `feature/café`, a
  unit identifier, summary prose) made `JSON.parse` raise
  `Encoding::InvalidByteSequenceError`, surfacing search, lookup,
  dependencies, dependents, framework, and recent_changes results as
  misleading `corrupt_artifact` errors and degrading structure and
  `woods_status`. All `IndexReader` artifact reads now go through one
  UTF-8-forcing binary read (the mode unit loading already used), so an
  index is read correctly regardless of host locale. No re-index needed.

## [2.0.0] - 2026-08-20

### Upgrade Notes

This is a major release: the full-gem review (#210) corrected how several extractors
derive unit identifiers, which changes the index format's observable contract.

- **Unit identifiers have changed shape.** Namespaces are now derived correctly by a
  position-aware nesting parser (#174), abstract-model and mixin-module artifacts no
  longer leak into names, and GraphQL inner classes are no longer folded into
  identifiers (#194). Concretely: a state machine that indexed as `Payment::aasm` is now
  `Billing::Payment::aasm`; a service that indexed as bare `IssueInvoice` is now
  `Billing::IssueInvoice`; concern units are no longer misnamed `ClassMethods`.
  **Anything that cached the old identifiers will miss**: saved retrieval queries,
  external notes, exported Notion pages and Unblocked documents, MCP clients holding
  identifier lists.
- **The remedy is one clean re-index**: `woods:clean` followed by `woods:extract`
  (then `woods:embed` if you embed, and a re-export if you sync Notion/Obsidian/
  Unblocked — the exporters reconcile renamed units as delete-plus-add).
- **Durable vector stores are now reconciled against extraction output** (#211). The
  first `woods:embed` / `woods:embed_incremental` after upgrading will **delete** vectors
  for units the extraction no longer produces — including every unit the identifier
  renames moved. Deleting more than 30% of the store (or purging into an empty load) is
  refused with an explanation; `WOODS_ALLOW_PURGE=1` overrides after you've confirmed the
  deletion is intentional. On a rename-heavy index, expect to need it once.
- **An embedding-dimension mismatch now refuses to embed up front** (#214).
  `woods:embed` compares the provider's dimension against what the store actually holds
  (pgvector's column type, Qdrant's collection config) before embedding anything, raising
  `Woods::MCP::DimensionMismatch` with both widths — instead of embedding everything and
  failing per-row on insert. If you changed `embedding_model` at some point and it
  "worked", this check may now surface the latent mismatch; the remedy is a full re-embed
  into a store created at the new width.
- **New environment variables**: `WOODS_ALLOW_PURGE` (override the vector purge guard,
  above) and `WOODS_NOTION_FORCE` (bypass the Notion sync manifest for one run, forcing
  a full re-push).

### Added

- **MCP 2026-07-28 support** (B-111–B-114). The gemspec now requires `mcp >= 1.2, < 2.0`,
  the release that added the 2026-07-28 protocol revision.
  - **Stateless Streamable HTTP by default.** `woods-mcp-http` no longer mints
    `Mcp-Session-Id`, so restarting it (gem upgrade, machine sleep, worktree rebuild) is
    invisible to connected clients instead of invalidating every session, and several
    instances can serve one volume-mounted index without sticky routing. Set
    `WOODS_MCP_HTTP_STATELESS=0` for a client that still needs sessions, the GET SSE
    stream, or DELETE teardown — a transitional escape hatch, since all three are gone
    from the specification.
  - **Tasks extension** (`io.modelcontextprotocol/tasks`). `pipeline_extract` and
    `pipeline_embed` return a durable task handle to clients that declare the extension:
    poll with `tasks/get`. Cancellation is not advertised: `tasks/cancel` returns
    `Method not found` because Woods cannot safely stop work already holding the
    pipeline lock or prevent it from publishing. Records live on disk under
    `<index_dir>/tasks/`, so a run reports real success or failure, a client that drops
    mid-run can reconnect — even to a restarted server — and collect the result, and a
    task whose owning process died resolves to `failed` instead of leaving an agent
    polling forever. Clients that do not declare the extension get the previous
    fire-and-forget behaviour, unchanged.
  - **Cache hints and deterministic tool ordering.** List and read results carry
    `ttlMs` (default 10s, `WOODS_MCP_CACHE_TTL_MS`) and `cacheScope: "private"`, and tools
    are advertised in sorted order so a host with optional integrations wired presents the
    same tool block as one without.
  - **`server/discover`** is answered, advertising supported versions, capabilities and
    the Tasks extension.

### Changed

- **Dead code removed.** The unwired formatting adapters (Claude, GPT, Generic),
  console job/cache adapters, `StubBridge`, `HealthCheck`, `Instrumentation`,
  `Notion::Mapper`, and a dozen spec-only methods are gone. `config.add_gem`
  now warns like `config.extractors`: accepted, not implemented.
- **Docs rewritten for readability**: shorter sentences, tables for
  comparisons, no em-dashes, one owner per fact. The MCP 2026 handoff document
  was folded into the strategy ADR.

- **The packaged gem ships only user-facing files.** Internal release machinery
  (`lib/tasks/release_v2.rake`, `lib/woods/release_v2/`) and non-user-facing
  documentation subdirectories are excluded from the package; the repo keeps
  them for CI. Historical build-phase design documents were removed from
  `docs/` for the release and remain in git history.
- **The Claude plugin releases with the gem.** `plugin.json` is 2.0.2.
- **`config.extractors` warns when set.** The knob is accepted for forward
  compatibility but extractor selection is not implemented; all extractors run.
  Docs no longer teach it as a live setting. The unused `log_level` accessor
  is removed.
- **`woods-mcp-start` no longer pins the MCP protocol version.** It defaulted
  `MCP_PROTOCOL_VERSION` to `2024-11-05` — the oldest revision there is — which silently
  opted every user out of four protocol revisions. The SDK server is dual-era, answering
  `initialize` for legacy clients while serving `server/discover` and per-request metadata
  for modern ones, so the unpinned server is the *more* compatible one. The variable
  remains as an escape hatch and now announces itself on stderr when set.
  **No action required:** legacy clients keep working, and no re-extraction or re-embedding
  is implied — no on-disk artifact format changed.

### Fixed

- **Wrapper-nested classes no longer collide on one identifier.** A file under
  a managed autoload path is now named for the constant its path spells
  (Zeitwerk-governed naming): `app/services/domain/container/parser.rb`
  declaring `module Domain; class Container; class Parser` indexes as
  `Domain::Container::Parser` instead of the wrapper `Domain::Container`.
  Previously every sibling under the same wrapper indexed as the wrapper and
  same-type dedup silently dropped all but one. The source parser remains the
  fallback for unmanaged or unconventional paths, and extraction now aborts
  naming both file paths when one type+identifier is still derived from two
  different files. **Re-extract after upgrading** — embeddings, exports, and
  saved queries keyed by the old identifiers need regeneration.

- **Console stdio setup now explains production token validation.** Stdio clients do
  not send the HTTP bearer token, but Rails still requires a 32-character-or-longer
  `console_mcp_token` at production boot whenever Console MCP is enabled. The upgrade,
  direct, Docker, FAQ, and agent setup paths now state that boundary explicitly.

- **Console SQL gate no longer has MySQL comment and dollar-quote blind spots.**
  `SqlNoiseStripper` did not know `#` line comments or `/*! ... */` executable
  comments (both live SQL on MySQL), and treated a `$` inside a PostgreSQL
  identifier as a dollar-quote opener, so a blocked table could be hidden from
  `TableGate`. The `TABLE name` statement form was never scanned at all. All
  four are closed, with the `#` rule gated on the MySQL dialect.
- **Redacted columns are refused as query inputs, not only masked on output.**
  `console_aggregate(column:)`, scope keys (including `_matches`), `find(by:)`,
  and `recent(order_by:)` accepted `console_redacted_columns`, which gave a
  plaintext aggregate or a comparison oracle over a secret.
- **The MySQL console timeout no longer leaks into the host's connection pool.**
  `SET max_execution_time` is session-scoped and survives rollback; the prior
  value is now read and restored in `ensure`.
- **Console SQL validation stops rejecting columns named `do`, `start`,
  `lock`, `release`, or `handler`.** Forbidden statement keywords now match only
  at a statement-leader position. `EXPLAIN ANALYSE` (the PostgreSQL spelling) is
  rejected like `ANALYZE`. `console_association_count` gates the rendered SQL, so
  a blocked `through` table is refused.
- **Long-running MCP tasks no longer expire the moment they complete.** Terminal
  task ttl is measured from the terminal transition, not from creation. A task
  minted under a different boot identity (a container) is left alone by a host
  reader instead of being marked failed.
- **Extractor accuracy batch.** `permitted_params` no longer leaks across method
  bodies (and reads Rails 8 `params.expect`); GraphQL complexity is read from a
  real match; per-file GraphQL classification agrees with the runtime pass;
  `form_action` edges stop at `do`/`end`; `SourceNesting` pops on `end.freeze`;
  `render :partial => 'x'` resolves the real partial; a rake task whose name
  contains `do` no longer swallows its neighbours; inline-namespaced migrations
  are extracted; mounted engines are unwrapped from `Mapper::Constraints` so
  `mounted_path` is populated, and `Rails::Application` is no longer reported as
  an engine.
- **An empty vector dump no longer refuses to boot.** `woods:embed` over an empty
  payload wrote `dimension = 0` and every later boot raised `DimensionMismatch`.
- **Storage hardening.** Interface stubs are no longer probed with `respond_to?`
  (B-108) in the retryable provider, builder, indexer, and ranker; Notion
  read-only POSTs retry on a network failure; the watch daemon's stale-claim
  reclaim checks the claim inode before removing it and falls back to an
  exclusive create where `File.link` is unsupported; `InMemory#delete_by_filter`
  honours array filters like `#search`.
- **Task orphan detection compares pid namespaces, not only boot ids.** Docker
  on Linux shares the host kernel boot id, so a host reader could judge a
  container's task by an unrelated host pid. The producer identity now carries
  `/proc/<pid>/ns/pid`, and a task from another namespace is left alone.
- **Daemon claim reclaim runs under an `flock`.** A byte comparison before the
  delete still left a read-then-unlink window where two starters could both
  end up as claim owners; the whole reclaim-and-create loop is now one
  critical section on a sidecar lock file, released by the kernel on death.
- **Snapshot capture retries a locked SQLite database.** SQLite skips the busy
  handler in its deadlock-avoidance case, so two concurrent captures could
  fail at `BEGIN IMMEDIATE` despite `busy_timeout`. Three bounded attempts.
- **`woods:clean` and `woods:validate` no longer raise `NameError` in a host
  app.** `woods.rake` reached `Woods::Generation` through the extractor, which
  those tasks never load. Caught by every woods-testbed variant.
- **The daemon's stale-claim race guard compares bytes, not the inode.** Linux
  reuses a freed inode for the next file in the directory, so the inode check
  let a just-replaced live claim be deleted. Failed on CI, passed on macOS.
- **Routes that differ only by constraint are all indexed.** The identifier is
  `VERB /path`, qualified by request constraints when the route has any:
  `GET /users [subdomain=api]`, `GET /users [format=json]`, `constraint=proc`
  for a callable. Routes that still collide are numbered in route order
  (`GET /users #2`) instead of being dropped. Unconstrained routes keep their
  old identifier; a constrained one changes, so the clean re-index above
  covers it.
- **A rake task reopened in two `.rake` files is one unit**, the way Rake sees
  it: its source carries every definition, `metadata.defined_in` lists the
  files, and a per-file incremental run produces the same merged unit as a
  full run. Previously the second file overwrote the first.
- **`woods:validate` and `Resilience::IndexValidator` are one implementation.**
  The task now runs the class, which gained the task's manifest-count,
  unit-file, file-path, and dependency-graph checks (`app_root:` opts into
  the file-path check).
- **`EXPLAIN (FORMAT JSON) SELECT` is accepted.** The option list was read as
  a call to a function named `EXPLAIN`. `EXPLAIN ANALYZE` in any form is
  still refused.
- **Class names are position-aware in every file-scanning extractor.** Jobs,
  serializers, decorators, policies, Pundit policies, managers, and validators
  took the first `class` token in the file, so `module Billing; class ChargeJob`
  indexed as bare `ChargeJob` (and the class-based second pass then added a
  duplicate `Billing::ChargeJob`), while the decorator scanner joined every
  `module` token, including helpers nested inside the class. All of them now
  go through `SourceNesting#qualified_first_class_name` (#174).
- **Policy `evaluated_models` no longer invents models from parameter syntax.**
  `def initialize(order, user = nil, strict: false)` produced `Nil`, `Strict`,
  and `False` model edges; only bare positional parameters are read now.
- **The release gate requires the booted-extraction matrix.**
  `script/validate-release-run` did not list the `rails-matrix` CI job, so a
  red Rails 6.0 to 8.1 row could not block a release.
- **Spec order no longer leaks a nil `Woods.configuration`.** Four spec files
  nil it out in `after` hooks; `spec_helper` now restores whatever each example
  started with, which fixes two seed-dependent failures in `extractor_spec`.

- **Every MCP entry point boots a payload-layout index.** The #226 layout moved
  `manifest.json` into `payloads/gen-<N>/`, but `woods-mcp`, `woods-mcp-http`,
  `woods-mcp-start`, the retriever's graph hydration, and the operator status
  reporter still looked for root-level artifacts: a fresh 2.0 extract was refused
  at boot with "Run `rake woods:extract` first", the retriever's graph store
  hydrated empty (silent loss of PageRank and graph expansion), and status read
  `:not_extracted`. All five now resolve through the generation pointer, with the
  legacy flat layout still accepted.
- **MCP `reload` no longer crashes the stdio server on pgvector/Qdrant.** The
  reload metadata backfill guarded on `respond_to?(:each_entry)`, which the
  vector-store interface answers true for while raising `NotImplementedError`
  (the B-108 anti-pattern); on stdio that unwound the transport loop and killed
  the process. The guard is now an ownership check.
- **Wholesale replacement prunes by `(identifier, type)`.** The #225 typed-graph
  work missed one call site: a factories (or any wholesale) re-run removing a
  vanished unit deleted every type sharing the identifier, so a same-named
  Scenic view's node and JSON file vanished from the index until a full run.
  Colliding identifiers also now serialize dependents on every sharing unit and
  carry each type's own git metadata instead of one type's history.
- **Incremental runs abort instead of publishing a collapsed index.** When
  payload creation failed over a payload-born index, the degrade path published
  a near-empty flat root and redirected readers to it. Incremental and refresh
  runs now raise without bumping the generation; full runs keep the flat
  fallback (their write set is complete). Payload seeding also gained the
  cross-device copy fallback, and payload pruning survives a restarted
  generation counter.
- **Woods artifacts are read encoding-safely everywhere.** Twelve remaining bare
  `File.read` sites (extractor incremental path, rake validate/stats/flow, the
  index validator) crashed with `Encoding::InvalidByteSequenceError` under
  `LANG=C` (the documented daemon container environment) on any multibyte byte.
  All now use `AtomicFile.read`.
- **Extraction-family rake tasks honor `config.output_dir`.** They hardcoded
  `tmp/woods` while the embed and export families used the configured
  directory, so a host that set `output_dir` split its index in two silently.
- **The watch daemon captures files changed during startup catch-up.** The
  watcher started only after catch-up finished, so a save during a long
  catch-up extraction was lost until the next edit. The watcher now starts
  first. A dead container daemon's startup claim also no longer blocks a
  host-side daemon forever (host identity is compared before trusting pid
  liveness), and a lock-release failure after a successful cycle no longer
  relabels the cycle as a lock failure.
- **Retrieval ranking and budgeting defects.** RRF source merging demoted
  strong cross-source hits into the supporting section; the framework partition
  never fired for real graph-expansion candidates; empty metadata could shadow
  real metadata; `:within_type_fallback` was reported for types the fallback
  never returned; an empty supporting section stranded ~35% of the token budget;
  keyword scores encoded arbitrary database row order as the dominant ranking
  signal. All fixed; keyword scores now derive from matched-field counts.
- **Console SQL validation stops rejecting English.** Body keyword scans ran
  over string literals, so `WHERE body = 'please update the record'` was refused
  as an UPDATE; scans now run over noise-stripped SQL while comment-hidden
  injections stay caught. `MERGE` joined the forbidden set, recursive writable
  CTEs get the specific error, and the stdio transport passes the table map so
  qualified `table.column` references validate like they do over HTTP.
- **Exporter clients treat ambiguous 503s honestly.** A 503 for a
  non-idempotent create (Notion `create_page`, Unblocked `create_collection`)
  can arrive from an intermediary after the origin committed, so those now
  raise the ambiguous-outcome error instead of retrying into a duplicate; 429
  and idempotent requests retry as before. Notion's `query_all` gained the
  nil-cursor loop guard, and the two clients' retry budgets now agree.
- **Session tracer fairness and hygiene.** The Redis store evicted arbitrary
  sessions at the cap (now oldest-first, matching the file store), and
  client-controlled header values are escaped before landing in the
  session-context document served to agents.
- **Storage edge paths.** Dump-capability detection uses ownership checks
  (typed `InapplicableBackend` instead of a bare `NotImplementedError`), the
  in-memory metadata search no longer matches on injected timestamps, dump
  pruning can never delete the just-promoted dump after a backward clock step,
  and the tasks store sweeps corrupt records older than the TTL.
- **A generation's payload is published atomically (#226).** `generation.json` was
  bumped atomically and last, but it named the output root — a directory of
  independently-written files — so a reader refreshing mid-publish could load a
  unit from generation N+1 beside a manifest from N. Extraction now publishes
  into `payloads/gen-<N>/` and names that directory from `generation.json`, so
  the single atomic write of that file commits the whole payload; a reader sees
  one generation whole, including artifacts it had not read yet. Incremental
  runs seed their directory from the published one with hardlinks, so an
  unchanged artifact costs a directory entry rather than a copy. Three
  generations are retained by default (`WOODS_PAYLOAD_RETENTION`).
  **This changes the on-disk layout.** No re-index is required — the first run
  after upgrading publishes a payload and reading is unaffected, since every
  Woods reader resolves the pointer — but anything outside Woods that reads
  `tmp/woods/manifest.json`, `tmp/woods/dependency_graph.json` or
  `tmp/woods/<type>/*.json` directly must now read `generation.json`, take its
  `payload` value, and resolve relative to the index directory. Files left at
  the root by a pre-2.0 run are stale from the first payload publish onward;
  `woods:clean` removes them.
- **Units of different types no longer collapse onto one graph node (#225).** A Scenic
  view `reports` and a factory `reports` are two units and the index has always written
  them to two files, but `DependencyGraph` keyed nodes on the bare identifier, so
  registering the second destroyed the first's reverse edges, `file_map` entry and
  `type_index` entry. Both now coexist as typed nodes. Deleting one type's source file
  removes that type's node and its JSON only; incremental re-extraction, git enrichment
  and the `dependents` rewrite fan out over every type an identifier names; and the MCP
  traversal tools follow both units' edges and report `types` when an identifier is
  ambiguous instead of picking one silently. **No re-index is required** — the persisted
  graph is unchanged for any index with no shared identifier, and identifiers that are
  shared add a `variants` array that older graphs simply do not carry.
- **Release-hardening batch (2026-08-07, #211–#218, #220):**
  - *Embedding durability:* every pgvector/Qdrant embed run crashed at the very end and
    discarded its work — `Indexer#persistable?` asked `respond_to?(:each_entry)`, which
    the storage interface answers true for by definition; it now asks which module owns
    the method (B-108, #220). Durable stores are reconciled against extraction output on
    full and incremental runs, with the purge guard shared with the dump path (#211).
    Checkpoint hits on durable backends are verified against the store, so switching
    `vector_store` from `:local` to pgvector/Qdrant no longer strands unchanged units
    (#211). Qdrant mutating point operations pass `wait=true`, so a delete is readable
    as deleted (#220). Dimension mismatches are detected before embedding, not per-row
    after (#214).
  - *Extraction fidelity:* blockless factories (`factory :admin, parent: :user`) are
    extracted; abstract models no longer enter the model-name scan (which inflated
    `ApplicationRecord`'s PageRank); `private def` methods are no longer reported
    public; `EventExtractor` no longer mints phantom events from non-Wisper `.on(:sym)`
    calls; `ManagerExtractor` resolves multi-word models (`order_item` → `OrderItem`,
    not `Order_item`) (#215).
  - *Flow/graph determinism:* `find_node_by_suffix` is memoized (was a full-graph scan
    per call) and resolves ambiguous short names deterministically; `case` predicates
    are no longer misattributed as branch operations; `domain_clusters` output no longer
    depends on registration order; vector dumps record the embedding model in the WVF1
    header (#216).
  - *Export hardening:* the Unblocked client redacts its bearer token in error paths and
    describes its per-run (not "daily") budget honestly; `Retry-After` is capped at 120s
    in both export clients; Unblocked citations use the ref recorded in the manifest
    rather than hardcoded `blob/main`, with path segments percent-encoded; Notion aborts
    fast on 401/403 instead of spending the whole cold sync failing per-unit (#217).
  - *Retrieval/observability residuals:* ranking signals no longer go neutral on chunked
    corpora (the ranker now strips chunk suffixes like every other consumer); metadata
    keyword search is case-insensitive on both adapters with the contract pinned by
    shared examples; `IndexReader`'s LRU is thread-safe under the HTTP transport;
    `GapDetector` counts queries, not keyword occurrences; `RedisStore#sessions` returns
    recent sessions rather than arbitrary ones (#218).
  - *MCP:* the `pipeline_extract` tool loads the extractor lazily, so it works in a
    standalone `woods-mcp` process instead of dying in the background with
    `NameError: uninitialized constant Woods::Extractor` (B-110).
- **The evaluation harness is runnable** (#212). `woods:evaluate` existed on no host (its
  rake file was never loaded by the railtie), called accessors that had never existed, and
  no adapter implemented `all_identifiers` for the baselines. It now loads, builds stores
  through the MCP bootstrapper so evaluation reads the same persisted index that semantic
  search serves, and ships an offline end-to-end smoke on the `:fake` provider. The
  ground-truth taxonomy now *is*
  `QueryClassifier::INTENTS`/`SCOPES`, so annotations compare against what the pipeline
  actually classified (#218's open item, closed here).

- **Full-gem review batch (2026-07-30): 30 defects fixed** (#183–#209 and pre-existing
  #149, #150, #169, #170, #174–#178; see each issue for the full analysis). Highlights,
  grouped by blast radius:
  - *Host-app safety:* enabling the documented console-MCP mode no longer 401s the entire
    host application (guards are path-scoped, enablement is decided at request time), and
    the enable flags now work from `config/initializers/woods.rb` (#183).
  - *Retrieval correctness:* type-filtered `codebase_retrieve` no longer returns empty on
    every booted server (symbol-keyed vector metadata on boot and reload, #150); the
    weighted ranking layer actually ranks (live keyword signal, normalized RRF, assembler
    honors ranked order, PageRank memo invalidated on reload, #185); classifier-derived
    target types no longer hard-filter vector search on common English words (#184);
    framework units are no longer duplicated across context sections (#186).
  - *Extraction fidelity:* concern inlining works for compact-style class declarations and
    concern-defined callbacks now yield side effects, for models and (new) controllers
    (#193, #175); a shared position-aware nesting parser fixes namespace derivation in five
    source-parsing extractors (#174); polymorphic associations, ApplicationController
    discovery, cache-call attribution, GraphQL inner classes, YAML anchors, Whenever
    blocks, label-form rake tasks, and `RSpec.describe Klass, type:` test mapping all
    parse correctly (#194, #199–#204, #176); full extraction sweeps orphaned unit files
    so reused output dirs stop over-reporting (#177).
  - *Pipeline integrity:* `rails_source`/`gem_source` route through the real write pipeline
    as a Gemfile.lock-keyed whole-app extractor and `include_framework_sources` genuinely
    gates it (#169); every index writer — `woods:clean`, the embed tasks, MCP
    `pipeline_extract` — now takes the pipeline lock (#170); incremental extraction cannot
    prune units on a failed extractor construction or a degraded eager-load boot (#198);
    the write-skip optimization actually fires (#208).
  - *Embedding durability:* a mis-pointed `woods:embed_incremental` can no longer wipe the
    vector index (30% purge guard + empty-load refusal, #191); non-ASCII identifiers stop
    re-embedding forever (WVF1 ids hydrate as UTF-8, #192); a single 429 no longer aborts
    an embed run — providers are wrapped in the previously-unwired resilience layer with
    Retry-After honored (#188); pgvector works via the documented setup path and dedupes
    in-batch ids (#187, #181); PageRank keeps rank mass for duplicate/unresolvable edges
    (#205); temporal snapshots stop leaking a unit set per same-SHA re-capture (#206).
  - *Robustness:* the embed pipeline, Unblocked manifest, StatusReporter, and flow layer
    survive `LANG=C` and torn files (`AtomicFile` everywhere, #189, #190); flow artifacts
    are portable (relative paths, #190); a standing-down watch daemon no longer clobbers
    the live daemon's status, and the lock heartbeat cannot resurrect a released lock
    (#196, #197); Notion/Unblocked clients no longer retry non-idempotent POSTs on read
    timeout (#150); Notion multi-model sync no longer corrupts the Columns database
    (qualified `table.column` titles with legacy-page adoption, #149); metadata search
    validates field names and escapes LIKE metacharacters (#209).

- **`woods:embed_incremental` no longer discards the vectors it embeds** (B-059, #148). On the
  `:local` and `:shared_filesystem` presets the vector store is in-memory and the dump under
  `dumps/` is the *only* durable copy — but `Indexer#index_incremental` never called
  `persist_snapshot`, while `process_units` advanced `checkpoint.json` regardless. Each
  incremental run therefore embedded changed units into a store that died with the process,
  wrote nothing to `dumps/`, and left a checkpoint claiming the work was done, so no later
  incremental run would ever produce those vectors again: unrecoverable without a full
  re-embed, and silent — stats reported `processed: 1`. An incremental run now hydrates the
  store from `dumps/latest` before embedding and dumps afterwards, so the dump it writes is
  cumulative. The invariant now enforced is that **`checkpoint.json` never advances over a
  unit whose vector was not durably stored**: on the dump-backed path the checkpoint is
  written only after the dump is on disk and the `latest` pointer is flipped (the interval
  checkpoints are suppressed there — a dump is a whole-store snapshot, so there is no partial
  durability for them to record), and a checkpoint hit is honoured only when the hydrated
  artifact actually holds a vector for that unit. A checkpoint that ran ahead of its dump —
  an older gem with this bug, an interrupted promote, a store swap — self-heals into a
  re-embed and says so on stderr. A dump that cannot be read (corrupt file, dimension
  mismatch after a model switch) warns and falls back to re-embedding everything, which is
  the documented remedy for both. Durable backends (pgvector, Qdrant) are unaffected: their
  `store_batch` *is* the durable write, so they keep the interval checkpoints and never
  hydrate.

- **Woods' own JSON artifacts are read as UTF-8, not as the process locale** (#164 review,
  round 4). `AtomicFile.write` uses `binmode` so bytes land verbatim, but a plain `File.read`
  tags the result with the default *external* encoding — US-ASCII in a container with no
  locale set, which is a plain Docker image and exactly where the watch daemon is documented
  to run. The daemon writes status reasons containing em dashes, so one ordinary lock
  contention under `LANG=C` raised `Encoding::InvalidByteSequenceError` out of
  `Watch::Status#read` (which rescued `JSON::ParserError` and `SystemCallError`, neither of
  which that is), taking `woods:watch_status`, the hook sync's daemon-deference check and the
  `woods_status` tool down with it until something rewrote the file with an ASCII-only reason.
  New `AtomicFile.read` is the counterpart to `.write`; `Status`, `Generation`, the daemon's
  pending/graph reads and `woods_status` all go through it, and `Status#read` now also rescues
  `EncodingError`.
- **A cycle that writes an index without publishing a generation now reports degraded**
  (#164 review, round 4). `Extractor#publish_generation` rescues its own failures so a good
  index is not discarded over an unwritable marker — right, but the marker *is* the freshness
  contract, so readers kept serving the previous index while the daemon reported `running`,
  and the next incremental could be a no-op that bumped nothing either. The daemon now
  cross-checks that the number moved when units were written, carries the paths forward, and
  logs at error rather than warn.
- **`graph_analysis.json` no longer depends on registration order** (#164 review, round 4).
  `orphans` and `dead_ends` were emitted in graph-registration order and `cycles` started its
  DFS from the same, so a full and an incremental extraction of one tree published different
  analysis — the opposite of what the docs claimed. The differential harness could not see it:
  its oracle `deep_sort`ed both sides of that file before comparing. Sorting there and
  asserting determinism here cannot both be load-bearing; the analyzer is now genuinely
  order-independent and the oracle compares the file exactly. Guarded by a registration-order
  rotation in `spec/graph_analyzer_spec.rb`.
- **The harness oracle keys units by filename, not by their own contents** (#164 review,
  round 4). `unit_snapshot` keyed on the identifier *inside* each document, so a stale file
  whose identifier a newly-written file also carried collapsed onto one entry with
  last-write-wins — a leftover unit read as no difference at all — and content written under
  the wrong name compared equal while the directories plainly were not.
- **A class removed from a file that still exists is now pruned** (#164 review, round 4).
  Deletion keyed on the source file being gone, which cannot see this: two models in one `.rb`
  with one deleted leaves no missing path, and class-based units register a *convention* path
  derived from the constant name, so the second class was never attributed to the file it
  actually lived in. Nothing in the run removed it, so it outlived every subsequent
  incremental — a permanent divergence from a full extraction. Class-based reconciliation now
  runs in both directions, with removal gated on the eager load having completed: on the
  documented NameError fallback the discovery sets are known-partial, and deleting by the type
  is a far worse failure than a stale unit. The booted harness cannot cover this — Zeitwerk
  unloads only a file's expected constant, so the side-effect class survives the reload and
  the in-process full extraction the oracle compares against emits it too.
- **`RailsReloader#reload!` no longer carries an unreachable interlock wrapper** (#164 review,
  round 4). The call was guarded by `interlock.respond_to?(:done)`, and
  `ActiveSupport::Dependencies::Interlock` has never had a `#done` — so the guard was false on
  every Rails version, the wrapper never ran, and the comment above it described locking that
  was not happening. It is also not needed: `reload!` takes the unload lock itself via
  `class_unload!` → `require_unload_lock!`. Found by writing the first test that drives the
  real reloader instead of a double; it was stubbed in every spec and so ran on zero of the
  seven matrix rows.
- **New GraphQL files are indexed incrementally** (#164 review, round 3). `app/graphql` had no
  `PathDispatcher` rule and GraphQL types are not class-discoverable, so a created type,
  mutation or resolver routed nowhere and never entered the index, and a rename lost the unit
  entirely — #164 gap 1 verbatim, in the one corner the gap-1 fix missed. The coverage guard
  missed it too: `GRAPHQL_TYPES` is its own constant, so deriving the expectation from
  `FILE_BASED` left a hole exactly the size of the bug. The guard now works by subtraction —
  every unit type must be reachable per file, wholesale, or by class discovery, with
  `rails_source` the one stated exception.
- **`resolve_head_sha` no longer folds git's stderr into the SHA** (#164 review, round 3). The
  same `capture2e` hazard as the working-tree probe one method over: a warning on an otherwise
  successful `rev-parse` was concatenated into the value and then compared against the manifest
  as if it were a SHA. The status spec's git stub had also gone dead when the working-tree
  probe moved to `capture3`, so real git was running against `/tmp` in those examples.
- **Startup catch-up now notices deletion-only downtime** (#164 review, round 2). The
  reconciliation scanned mtimes of files that exist, so a file deleted while no daemon was
  running left no trace: the daemon logged "index is current at startup" and the ghost units
  survived until the next unrelated event. Catch-up now also checks the graph's registered
  paths for files gone from disk and, if any, runs one cycle with an *empty* change set — the
  extractor's bounded sweep reaches the ghosts, with the bounds that keep nominal paths
  (Rails < 7.1 `SchemaMigration`) safe from authoritative deletion.
- **The drain guard is an atomic test-and-set** (#164 review, round 2). The re-entrancy guard
  was a check-then-act boolean — the exact race it guarded against: two `listen` callback
  threads could both read `false` before either wrote `true` and run two overlapping drain
  loops. It is now `Mutex#try_lock`; the refused caller's paths are already in the pending set,
  so the winning loop picks them up and nothing is lost.
- **`IndexReader` freshness bookkeeping is safe under a threaded transport** (#164 review,
  round 2). The generation check-and-reload was unguarded check-then-act, and the pin was a
  boolean — under `woods-mcp-http`, whose tool handlers run on the Rack server's request
  threads, two concurrent reads could double-reload or drop each other's caches mid-sequence,
  and the first of two overlapping `with_pinned_generation` blocks to finish unpinned the
  reader for both. The check-and-reload now runs under a per-reader mutex and pins are
  refcounted: invalidation resumes when the *last* pin releases.
- **A cycle that can't land its work no longer loses it** (#164 review). Lock contention
  already carried its paths into the next cycle; a *failed reload* did not. Saving a valid
  `post.rb` while `user.rb` sat half-typed produced one app-wide reload failure covering both,
  and when `user.rb` was fixed the event named only `user.rb` — so `post.rb`'s change never
  reached the index at all. Failed reloads and raising extractions now carry forward too, and
  the drain lives inside `Daemon#process`, so an embedded host gets the same retry behaviour
  `#run` does.
- **A quiet daemon is no longer declared dead** (#164 review). `Status#alive?` disbelieves a
  record older than 15 minutes and only cycle boundaries wrote one, so a healthy daemon
  watching a worktree nobody was typing in read as stopped — and every caller that stands down
  for a live daemon started contending for its lock instead. A heartbeat now re-stamps the
  last published record every 5 minutes, republishing `degraded` as `degraded` rather than
  claiming recovery.
- **The daemon reconciles changes that predate it** (#164 review). It only ever reacted to
  events it personally witnessed, so the documented hook pattern — start a daemon, then sync —
  stood the sync down over changes the fresh daemon had never seen. `Daemon#run` now
  reconciles against the index's own watermark (`generation.json`'s mtime) before waiting for
  its first event. `woods:incremental` also no longer stands down for a *degraded* daemon:
  alive but not updating is not coverage.
- **`woods:refresh` serializes with the other writers** (#164 review). It rewrites the whole
  dependency graph and took no lock, so a refresh racing a daemon cycle silently discarded the
  other's work and then bumped the generation over it — atomic writes don't help, because each
  write is individually intact and the *set* is not. It now runs under `PipelineLock` like
  `woods:extract` and `woods:incremental`, and records its own generation reason instead of
  masquerading as an incremental run.
- **The polling watcher no longer loses a same-second write** (#164 review). Snapshots
  truncated mtime with `to_i`, so a second write inside the same second was invisible
  permanently — there is no later event to catch it — and save-then-formatter at the default
  1s interval is entirely ordinary. Snapshots now carry full-resolution mtime plus size.
- **`IndexReader` no longer misses a same-size generation bump** (#164 review). The freshness
  signature was `[mtime, size]`, and equal size is the daemon's steady state (reason
  `"incremental"` every cycle). On a coarse-mtime filesystem — including the volume-mounted
  Docker deployment the Index Server is documented for — two bumps in one tick were
  indistinguishable and the reader served a stale index indefinitely. The inode is now part of
  the signature, which `AtomicFile`'s rename-per-write guarantees moves.
- **A clean working tree no longer reports dirty** (#164 review). `resolve_working_tree_status`
  used `capture2e`, folding git's stderr into the porcelain output — so any warning on an
  otherwise successful run (a stale `index.lock` notice, `core.fsmonitor` chatter) read as
  uncommitted changes, and the fingerprint tracked the warning rather than the code.
- **Index artifacts are written atomically.** `dependency_graph.json`, `manifest.json`,
  `_index.json` and every per-unit file went through plain `File.write`. With a resident daemon
  writing while resident MCP readers read, a reader could catch a truncated file mid-write;
  all of them now route through `Woods::AtomicFile`.
- **A class-based file moved between autoload directories is no longer dropped for a run**
  (#164 review). Reconciliation ran before pruning, so a file moved with its constant unchanged
  still looked "known" and was not re-extracted, then was pruned for its vanished path.
  `extract_changed` now reconciles once more after pruning.
- The `listen` backend degrades instead of dying: only its setup is wrapped in the
  `WatcherError` rescue, so a failure raised once it is merely parked (including from the
  extraction inside a callback) is no longer relabelled "failed to start", and inotify
  exhaustion falls back to polling. Both watchers also honour a `stop` that races startup.
- The storm threshold counts only paths the reload policy considers actionable — sixty edited
  markdown files plus one model is a one-model change, not a storm.

- **Token estimates now describe the file that is written.** `ExtractedUnit#estimated_tokens`
  measured `metadata.to_json`, which with ActiveSupport loaded applies HTML-safe escaping (`>`
  becomes `\u003e`), while the unit file is written with `JSON.generate`. Any unit whose
  metadata contained a lambda scope was therefore indexed with a token count that described a
  document that was never written — and differed depending on whether a full or an incremental
  run last touched it. Both sides now measure `JSON.generate`.

- **Incremental extraction is now equivalent to a full extraction** (#164, phase 0). Five
  confirmed correctness gaps in `woods:incremental` are closed. They mattered most in an
  incremental CI chain, where the previous graph is restored and `woods:incremental` runs per
  merge: a missed unit propagated forward run over run instead of being erased by the next
  full rebuild.
  - **New files are indexed.** Changes routed only through `DependencyGraph#affected_by`,
    which resolves a path via the graph's file map — populated only from already-registered
    units — so a file that did not exist at the last extraction routed nowhere and was
    silently ignored. A new `Woods::PathDispatcher` supplies the missing direction, path →
    extractor, for file-based types; class-based types (models, controllers, mailers,
    components, channels) are reconciled against each extractor's own runtime discovery set,
    now exposed as `#discoverable_classes`.
  - **Deleted files no longer leave ghosts.** Units whose source file has vanished are pruned
    — unit JSON removed, graph node unregistered, reverse edges withdrawn, type index
    regenerated. Deletions named in the change set are authoritative; a sweep over registered
    paths catches callers whose change set omits them. A rename resolves to delete-plus-add.
  - **Files defining several units reconcile as a whole.** `DependencyGraph`'s file map is now
    multi-valued (`path => Set<identifier>`), so a task removed from a multi-task `.rake` file
    is dropped rather than left behind. Graphs written before this load unchanged.
  - **Whole-app unit types refresh.** `route`, `middleware`, `engine`, `scheduled_job`,
    `state_machine`, `factory`, `event`, and `database_view` are re-run wholesale when their
    trigger paths change, instead of being skipped while the run still rewrote the manifest
    and zeroed `staleness_seconds`. A routes change also re-extracts the types that embed the
    route table (controllers, mailers, components, view templates).
  - **Derived data no longer drifts.** Incremental runs recompute `graph_analysis.json`, and
    refresh each affected unit's `dependents` list and `metadata.git` — all previously
    full-extraction-only. A run that extracts nothing now leaves the manifest timestamp alone
    rather than reporting the index as freshly synced.

### Added

- **`embedding_provider = :fake`** — the deterministic bag-of-words provider is now a
  first-class citizen (promoted from spec support), and `Builder` also accepts an injected
  provider object responding to `#embed`/`#embed_batch`. `woods:embed` → `woods:retrieve`
  now runs fully offline; `woods:retrieve` resolves all four backends through the
  configuration instead of hardcoding Ollama + in-memory stores (#178).
- **Notion sync manifest** — unchanged pages cost zero API calls on re-sync; changed pages
  update by cached page id without a title query; `WOODS_NOTION_FORCE=1` bypasses for one
  run (#207).
- **`woods:validate`** warns for units whose `file_path` resolves neither as written nor
  under `Rails.root` (#169).

- **`rake woods:watch` — a resident extraction daemon** (#164, phase 2). Watches the app and
  keeps the index current as files change, instead of as-fresh-as-the-last-explicit-run. One
  cycle is watch → debounce → classify → reload if needed → extract → publish. Freshness was
  pull-based because every sync from a cold process pays a full Rails boot; a process that
  stays booted removes that tax without giving up runtime-true extraction. Development only —
  it adds no network listener. See `docs/WATCH_DAEMON.md`.
  - **Restart triggers, Spring-style.** A change to `Gemfile.lock`, `config/**`, or the schema
    stops the daemon with a degraded status and exit `75` for a supervisor, because Rails'
    reloader re-runs none of it.
  - **Failure posture.** A failed reload (the mid-edit syntax error) publishes a degraded
    status naming the reason and leaves the index intact at its last good generation. The
    daemon never crash-loops, never publishes a partial write, and never advances the
    generation over work that didn't land.
  - **Storm handling.** Above a changed-file threshold (default 50) a branch switch falls back
    to one full extraction rather than N incremental steps.
  - **Two watcher backends.** The `listen` gem when the host has it; a dependency-free polling
    scan otherwise — which is also the right choice inside a container, where native FS events
    don't cross bind mounts reliably.
- **Multi-instance operation across worktrees** (#164, phase 4). Worktrees stay disjoint by
  construction (own `Rails.root`, own `tmp/woods`), so the work is within one worktree: the
  daemon, a manual `woods:extract`, and a hook-triggered `woods:incremental` now share the
  existing `PipelineLock`. The daemon yields to another writer and carries its paths into the
  next cycle rather than losing them; manual runs wait up to 30 s and then proceed with a
  warning rather than hanging a terminal; and `woods:incremental` skips entirely when a live
  daemon is already watching the tree (`WOODS_IGNORE_WATCH=1` overrides). New
  `rake woods:watch_status` exits 0 when a daemon is alive, so a worktree hook can revive one
  without parsing anything. `Woods::Watch::Daemon`'s `idle_timeout` (off by default) stops a
  daemon in a dormant slot so it stops holding a booted app's memory.
- **An MCP freshness contract** (#164, phase 3). `woods_status` now reports the index
  `generation` (number, when it moved, what moved it), whether the **working tree** is dirty
  plus a fingerprint of it, and the watch daemon's state (`running` / `degraded` + reason /
  `stopped` / `absent`). `git_sha_matches_head` only ever saw *committed* HEAD, so an agent
  forty uncommitted edits deep was told the index matched while every answer described the
  tree before those edits.
- **`IndexReader` self-refreshes on a generation change**, making the MCP `reload` tool an
  optimization rather than a correctness requirement. A long-lived server used to hold
  whatever it read at boot, so an agent working alongside a running extraction silently got
  answers describing the tree as of the last server start. The check costs one `File.stat` of
  a ~100-byte file per read. `IndexReader#with_pinned_generation` extends it across a sequence
  of reads. Indexes with no generation file behave exactly as before.
- **`Woods::Generation`** — a monotonic marker for "which version of the index is on disk",
  written atomically as the last step of a successful run by *every* extraction mode (full,
  incremental, targeted refresh, daemon cycle). Never advanced by a run that failed or changed
  nothing, so staleness stays honest.
- **`Extractor#refresh(*keys)` and `rake "woods:refresh[routes]"`** (#164, phase 1). Re-runs
  named extractors wholesale against an already-booted app, replacing every unit of the types
  they own. The unit types with no per-file entry point — routes, middleware, engines,
  scheduled jobs, state machines, factories, events, database views — were only reachable by
  full extraction from a cold boot, which was an artifact of the boot cost rather than
  anything inherent: in a booted process re-running one extractor takes seconds. A routes
  refresh cascades to the extractors that embed the route table. Any extractor key is
  accepted, so `refresh(:models)` is a legitimate way to re-derive models after a schema
  change.
- **`Woods::ReloadPolicy`** — the reload-trigger inventory (#164). Classifies a changed path
  as `:ignore`, `:reextract` (Woods reads bytes; no Rails involvement), `:reload` (an
  autoloaded constant changed) or `:restart` (boot-captured state changed — initializers,
  `config/**`, `Gemfile.lock`, schema). Consumed by `Watch::Daemon` on every cycle, and
  tested against the `railties >= 6.0` support matrix. `spec/reload_policy_spec.rb` derives
  its samples from the `PathDispatcher` rules themselves, so the two cannot drift apart
  silently.
- **Differential test harness for incremental extraction**
  (`spec/integration/incremental_equivalence_spec.rb`, tagged `:booted_app`). Applies
  randomized create/modify/delete/rename sequences to a booted fixture app and asserts, at
  every step, that the incrementally-maintained index matches a cold full extraction: same
  units, same unit content, same graph, PageRank recomputed. Tune with `WOODS_DIFF_OPS` and
  `WOODS_DIFF_SEEDS`; runs in CI on every Rails-matrix row.
- `Woods::ChangeSet` — one normalization of "what changed" (absolutize, de-duplicate, split
  present from vanished) shared by every entry point, so the git-diff caller and the watch
  daemon can't drift apart.

### Changed

- `woods:watch_status` no longer depends on `:environment`. It reads one small JSON file, and
  the point is that a worktree hook can call it *before* deciding whether to do real work —
  paying a full Rails boot to find out cost more than the sync it exists to avoid.
- `WOODS_WATCH_POLL=1` forces the polling backend. `docs/WATCH_DAEMON.md` told container hosts
  watching a bind mount to do this; nothing exposed it. `WOODS_WATCH_IDLE_TIMEOUT` and
  `WOODS_WATCH_CATCH_UP` are exposed on the rake task for the same reason.
- The debounce window now genuinely coalesces. The watcher callback merges into a pending set
  and returns, so a save, the formatter's rewrite and the linter's touch become one cycle
  rather than three — previously `settle` only delayed the first of the three.
- `spec/reload_policy_spec.rb` derives its samples from the `PathDispatcher` rules rather than
  a hand-written list, so a rule added for a new extractor is covered without editing the
  spec. `spec/support/index_comparison.rb` compares PageRank *values* (to 6 dp) rather than
  just keys — comparing keys alone said nothing about the modify-only operations most likely
  to leave scores stale.
- `GraphAnalyzer` output is now a pure function of graph content. `hubs` breaks ties on
  identifier instead of graph-insertion order, and `bridges` samples from a sorted node list,
  so two extractions of the same tree publish the same analysis.

### Testing

- The verifying-double sweep: 102 string-named `instance_double`s — which verify nothing
  when the constant isn't loaded — now either reference the real constant (26) or are
  honest plain doubles (76) (#219). `PhlexExtractor` went from 3 examples/~38% line
  coverage to 39 examples/99% (#219). Every spec directory now passes standalone; nine
  spec files only passed in the company of the full suite because earlier files loaded
  their constants first (B-109). Two order-dependent flakes fixed: `wait_for_threads`
  now fails loudly on a hung thread, and `tasks_spec` no longer leaks a mutated global
  configuration (#215, #216).
- **CI** (#220): workflows run on pushes to `main` as well as PRs (a bad merge previously
  went green by absence of a run); the unit axis adds Ruby 3.4 and the booted matrix adds
  Rails 8.1 rows; a new `live-backends` lane runs storage-adapter contract specs against
  real PostgreSQL+pgvector and Qdrant service containers plus an offline embed→retrieve
  round trip — every other storage spec drives doubles, which is how #181 shipped. The
  lane found B-108 on its first run.

## [1.6.1] - 2026-07-22

### Fixed

- **Incremental extraction crash on multi-unit files.** `woods:incremental` raised
  `NoMethodError: undefined method 'identifier' for an instance of Array` when re-extracting a
  unit whose extractor returns several units from one file (a `.rake` file defining multiple
  tasks; i18n, migration, and lib files are shaped the same way). `Extractor#re_extract_unit`
  now normalizes the extractor result to an array and registers and writes each unit, matching
  how full extraction already handles per-type results. Full extraction was unaffected.

## [1.6.0] - 2026-07-16

### Added

- **MCP update awareness.** A new `Woods::UpdateCheck` module performs a best-effort,
  24h-cached RubyGems lookup for a newer `woods` release (disable with
  `WOODS_NO_UPDATE_CHECK=1`). The Index Server's `woods_status` tool now reports
  `server.update` (`current_version` / `latest_version` / `update_available`), and a call to a
  tool the installed gem doesn't define now returns version-aware guidance ("not available in
  the installed Woods vX — run `bundle update woods`") instead of a bare "Tool not found". This
  keeps agents that follow a newer guide skill from silently failing against an older gem.
- **Claude Code plugin.** The three user-facing guide skills (`woods-setup`,
  `woods-mcp-config`, `woods-diagnose`) are now packaged as the `woods-plugin`, distributed
  from the [`lost-in-the/plugins`](https://github.com/lost-in-the/plugins) marketplace suite
  via a `git-subdir` source (installs fetch only the `plugin/` subtree, not the whole gem).
  Install with `/plugin marketplace add lost-in-the/plugins` then
  `/plugin install woods-plugin@lost-in-the-plugins`. Each skill gained a **Version Preflight**
  step so agents operate only against the installed Woods version (≥ 1.5.0) instead of
  suggesting tools or tasks an older gem lacks.

### Changed

- The user-facing guide skills moved from `docs/skills/` to `plugin/skills/` to form a valid
  Claude Code plugin root (`plugin/.claude-plugin/plugin.json`). In-repo dev-workflow skills
  under `.claude/skills/` are unaffected and remain undistributed.

### Security

- **Console `sample`/`recent` tools now validate `columns` against the model's
  real columns.** They passed the raw array to ActiveRecord's `.select`, which
  treats string args as SQL fragments — a crafted column could smuggle a
  subquery into the SELECT list, bypassing TableGate and column redaction
  (`pluck` already validated; `sample`/`recent` didn't).
- **`trace_flow` sanitizes the entry point before building the flow file path.**
  Only `::`→`__` was applied, so `/` and `..` in a client-supplied entry point
  could traverse outside the `flows/` directory (a file-read oracle over the
  HTTP transport). Both path segments now go through the `FilenameUtils`
  allow-list.
- **TableGate's SQL table detector no longer misses tables on PostgreSQL.** It
  hardcoded MySQL literal-stripping, so on PostgreSQL (`standard_conforming_strings`)
  the MySQL `\'` rule could over-strip and swallow a real `FROM <blocked>`
  clause. It now strips under both dialects and unions the identifiers.
- **TableGate no longer misses a table hidden behind a comment marker inside a
  string literal.** `SqlNoiseStripper` stripped comments *before* literals, so
  `SELECT '-- ' FROM blocked` had its real `FROM blocked` swallowed as a line
  comment and slipped past the gate. Comment- and literal-stripping now run in a
  single combined left-to-right pass (`SqlNoiseStripper.strip_noise`) — a
  comment marker inside a literal, and a quote inside a comment, are each
  protected by whichever opens first. `SqlValidator` and the scope-template
  guard route through the same pass.
- **`EvalGuard` rejects `%x` shell literals with any delimiter — including
  whitespace.** The delimiter check excluded `\s`, but a newline is a valid `%x`
  delimiter (`%x\ncmd\n` compiles and executes), so it slipped through to
  `instance_eval`. The check now matches any non-word delimiter (`[^\w]`).
- **`PipelineLock` no longer allows two processes to hold the lock.** Both the
  stale-lock takeover and the release path had TOCTOU windows: a process that
  passed the staleness check could rename away — or a plain read-then-unlink
  release could delete — a competitor's *fresh* lock, so both would "hold" it.
  Takeover now re-verifies the retired file is still stale (restoring it and
  backing off if a competitor already took over), and release renames the file
  aside and re-checks its ownership token before deleting.

### Fixed

- **Incremental extraction no longer corrupts the index.** `rake woods:incremental`
  overwrote `manifest.json` with zero counts, captured an empty temporal snapshot
  (making the diff report every unit as deleted), wrote absolute file paths into
  the index, and re-indexed affected units with a null `estimated_tokens`.
- **Retrieval ranking signals work on real backends again.** Recency, importance,
  type-match, and diversity read metadata with symbol keys, but every store
  returns string keys — so all four scored every unit at their neutral fallback
  in production. The ranker now reads both key forms.
- **The embedding cache is now scoped to the provider model.** The cache key was
  `SHA256(text)` with no model, so a persistent shared backend served the
  previous model's vector after a model switch. `model_name` is now part of the
  key — a plain attribute rather than `dimensions`, whose Ollama implementation
  is a live `embed('test')` probe (keying on it made every cache lookup, hits
  included, depend on the provider being reachable, and defeated the cache while
  the backend was down).
- **`callback_count` reports real counts.** It called the nonexistent
  `CallbackChain#size`, which raised and left the count silently at 0 for every
  model; switched to `#count`.
- **`ResolvedConfig` is now deeply immutable.** Nested strings in
  `embedding_provider`/`stores` stayed mutable, so the frozen snapshot could be
  corrupted in place.
- **Model dependency edges are correct for nested and re-registered units.** The
  `ModelNameCache` alternation matched a prefixed parent (`Library::Book` for
  `Library::Book::Chapter`); `DependencyGraph#register` left stale reverse edges
  on re-registration, inflating incremental blast radius.
- **Precomputed request flows are no longer empty/stale.** `FlowPrecomputer` ran
  before unit JSON was written to disk; it now runs after `write_results`.
- **`trace_flow` resolves precomputed flows again.** The reader allow-listed the
  entry point but the writer left the action name raw, so a flow for an action
  outside `[A-Za-z0-9_-]` was written under one filename and looked up under
  another (silently falling back to live assembly). Both sides now derive the
  filename from the shared `FilenameUtils.flow_filename`.
- **Flow annotation no longer resurrects deleted units.** On a full extraction
  with `precompute_flows`, refreshing a type's `_index.json` rebuilt it from a
  disk glob of the never-wiped output dir, re-adding unit files for classes
  deleted from the app since the last run. The index is now rebuilt from the
  in-memory `@results` (the incremental path, which only holds changed units,
  still rebuilds from disk).
- **`FlowAssembler` no longer reports DAG diamonds as cycles**, and
  `IndexArtifact#promote` no longer accepts sibling directories that merely
  share a name prefix with `dumps/`.
- **`implicit_belongs_to` metadata is accurate.** It was flagged on every
  ActiveRecord presence validator; it now keys on `belongs_to` reflections.
- **Dependency scanning ignores commented references consistently** across all
  three passes (a commented `Library::Book` still produced a ghost edge), while
  keeping references that follow a `#` *inside a string literal* (`link_to "Tag
  #ruby", Article.recent`). Comment-stripping is string-literal-aware — a plain
  `#…` regex ate the rest of such lines and dropped the real edge.
- **`pipeline_extract(incremental: true)` requires `changed_files`** instead of
  silently re-extracting nothing while reporting success.
- **`pipeline_diagnose` classifies by the supplied error class** (it built a bare
  `StandardError`, so every `Timeout`/`Net::`/`Errno` error came back
  `:unknown`).
- **`notion_sync` honors the `NOTION_API_TOKEN` env var**, matching the gate that
  registers the tool (ENV-only hosts previously saw the tool but every call
  failed). A *blank* env var (docker-compose `${NOTION_API_TOKEN}` interpolation
  of an unset host variable) is now treated as absent rather than masking a
  configured token or passing through as a blank bearer. All four resolution
  sites (exporter, `notion_wired?` gate, tool handler, rake task) share
  `Woods.resolve_notion_token`.
- **Embedded documents include the `dependencies:` line again** — the indexer
  leaves dependency hashes string-keyed and the text preparer only read symbol
  keys.
- The MCP CLI integration spec no longer fails under a POSIX/C locale (UTF-8
  subprocess output is normalized before regex matching).
- **`CircuitBreaker` admits only a single probe in `half_open`.** It let every
  concurrent call through while half-open (a thundering herd against a
  recovering service), and a slow probe's success could wipe failures recorded
  by an overlapping probe. Concurrent probes are now rejected with
  `CircuitOpenError`, and an optional `success_threshold` requires N consecutive
  successful probes to close (default 1). Recovery accounting is also keyed to
  the per-call probe flag, not the shared state: a stale call admitted while the
  circuit was *closed* that completes after the transition to `half_open` no
  longer counts as the probe (it could otherwise close the circuit — or clear a
  concurrent probe's slot — while the service was still down).
- **`Retry-After` honors the HTTP-date form.** The Notion and Unblocked clients
  parsed the header with `.to_f`, turning an HTTP-date into `0.0` and retrying
  immediately against a throttling server. A shared `Woods::RetryAfter` helper
  now handles both the delta-seconds and HTTP-date forms.
- **The MCP pipeline lock is no longer racy under the HTTP transport.** The
  `@pipeline_mutex ||= Mutex.new` lazy init let two concurrent handlers create
  separate mutexes and run two pipelines of the same kind; the mutex is now
  eagerly initialized.

### Changed

- Directory globbing and dependency deduplication across the extractor fleet are
  centralized in `SharedUtilityMethods#find_files_in_directories` and
  `SharedDependencyScanner#consolidate_dependencies` (behavior-preserving).

### Documentation

- Added an in-container Index Server section to `DOCKER_SETUP.md` (#139),
  corrected stale tool counts, corrected backend config examples that referenced
  nonexistent adapters (#83), and listed the previously-undocumented rake tasks.

## [1.5.0] - 2026-06-23

### Added

- **Rails 6.0 support: the `railties` floor is lowered from `>= 6.1` to `>= 6.0`**
  (#135). Woods runs cleanly on the Rails 6.0 series — extraction and index-MCP
  serving need no 6.1-only API. The only 6.1-introduced calls touched
  (`connection_db_config`, `has_many_inversing`) are `respond_to?`-guarded and
  degrade on 6.0; a regression spec locks that in.
- **CI now runs a Rails version matrix plus a booted-app extraction test** (#136).
  `Appraisals` + `gemfiles/rails_*.gemfile` exercise Rails 6.0, 6.1, 7.0, 7.1,
  7.2, and 8.0; the matrix excludes invalid Ruby×Rails pairs (e.g. Rails 6.0 only
  on Ruby 3.0) and adds a **Ruby 4.0** lane. A new booted-app test
  (`spec/integration/booted_extraction_spec.rb`, against the minimal `spec/dummy`
  app) boots Rails in-process and runs a real end-to-end extraction, asserting a
  non-zero unit count and the expected models/associations — gating the
  version-sensitive introspection path the unit suite (which stubs Rails) can't.

### Changed

- **The Index Server now boots in pattern-only mode by default when no embedding
  index is present** (#138). Since 1.3.0, `woods-mcp` raised `MissingArtifact` at
  boot unless `woods.json` existed or `WOODS_ALLOW_AUTODETECT=1` was set — which
  surprised the most common setup: `rake woods:extract` with no embedding
  provider, where pattern/regex/structural search works perfectly. The server now
  auto-detects by default: it serves all always-on tools (`lookup`, `search`,
  `dependencies`, `structure`, `graph_analysis`, `pagerank`, …) with no env var,
  and `codebase_retrieve` (semantic search) activates automatically once an
  embedding provider is configured. Set `WOODS_REQUIRE_INDEX=1` to restore
  fail-closed behavior (raise `MissingArtifact` when `woods.json` is absent).
  `WOODS_ALLOW_AUTODETECT` is retained as a no-op for backward compatibility.

### Fixed

- **`manifest.json` no longer reports a stale `git_branch`/`git_sha` in a git
  worktree** (#137). In a linked worktree, `.git` is a file pointing at the real
  git directory (often an absolute host path). When that directory couldn't be
  resolved — e.g. inside a container where the host path isn't mounted — git
  enrichment failed silently and the branch/SHA fell back to a baked
  `GIT_BRANCH`/`GIT_SHA` build arg, reporting an unrelated branch. A new
  `Woods::GitProvenance` resolves provenance with worktree-aware plumbing
  (`git -C <root> rev-parse`), and emits `"unknown"` when a `.git` is present but
  the ref can't be resolved (the worktree case) rather than a misleading value.
  The `GIT_BRANCH`/`GIT_SHA` env vars are honored only when there is **no** `.git`
  at the root at all (a non-repo checkout — e.g. a Docker `COPY` that excludes
  `.git` — with build args supplying the SHA) or git is unavailable. Temporal
  snapshots skip an `"unknown"` SHA so it can't key or collide a snapshot.

## [1.4.1] - 2026-06-10

### Fixed

- **Unblocked sync: multiple units sharing one file no longer collide on a single
  URI** (#130). A document's URI derives from `file_path`, so a file defining
  several extracted units (nested/namespaced classes, STI subclasses, multiple
  classes in one `.rb`) mapped every unit to the same URI — the remote document
  was overwritten per unit (only the last survived) and, under the content-hash
  manifest, those units re-pushed on every run. The exporter now detects files
  shared by more than one synced unit and disambiguates: the lexically-first
  identifier keeps the bare blob URL, siblings get a `?unit=<identifier>` suffix.
  Solo files (the overwhelming majority) are untouched. Sibling of the
  no-`file_path` guard shipped in 1.4.0.

## [1.4.0] - 2026-06-10

### Added — Incremental Unblocked sync (PR #128)

- **`woods:unblocked_sync` is now incremental.** A new `Woods::Unblocked::SyncManifest`
  (JSON at `<output_dir>/unblocked_sync_manifest.json`) records the content hash and
  remote document id of everything last pushed. Each run skips unchanged documents,
  pushes only new/changed ones, and deletes documents whose source unit disappeared.
  A missing manifest (first run / CI cache miss) degrades to a correct full re-push
  that rebuilds it; steady state on an unchanged codebase costs ~0 API calls (was
  ~800–1200 per run). Persist the manifest across CI runs via your provider's cache —
  see `docs/UNBLOCKED_INTEGRATION.md`.
- **Deletion safety.** Orphan purging is skipped when the daily API budget exhausts
  mid-run, and a mass-deletion guard refuses to delete more than 30% of a ≥10-entry
  manifest in one run (`UNBLOCKED_FORCE_PURGE=1` overrides) — protection against
  syncing a partial index. `UNBLOCKED_FORCE_FULL_SYNC=1` re-pushes everything (use
  after a document-format change). Both flags parse `1`/`true`/`yes` (case-insensitive).
- **`Client#list_documents` / `#all_documents`** — paginated document listing with
  client-side collection filtering, used to reconcile remote document ids when the
  manifest is missing. Cursors are URL-encoded and a page without a cursor id stops
  pagination rather than looping against the rate budget.
- **`Woods::Unblocked::ApiError`** (subclass of `Woods::Error`) carries the required
  HTTP `status` of failed API calls; a 404 on delete is treated as already-gone.
  **`Woods::Unblocked::BudgetExhaustedError`** (also a `Woods::Error` subclass) is
  raised by the rate limiter, so budget detection no longer depends on message text.
- **CI-visible failures.** `woods:unblocked_sync` exits non-zero when the sync
  recorded errors (delete failures are now surfaced in the error list too). The one
  tolerated shape is budget exhaustion with partial progress — the expected
  cold-start outcome, which converges on the next run. Reconcile aborts loudly on
  auth failures (401/403) instead of burning the budget on doomed calls.
- **Deterministic document bodies.** `DocumentBuilder` sorts every rendered collection
  (associations, dependents, routes, enums, scopes, concerns, callbacks) so an
  unchanged unit always produces byte-identical output — the precondition for
  hash-based change detection.
- **`Client#create_collection` defaults `iconUrl`** to the repo-hosted Woods mark.
  The live API rejects collection creation without an `iconUrl` despite the API docs
  marking it optional (documented quirk).
- **Branding.** Tree Rings logo set under `assets/` (marks, wordmark lockups, PNG
  exports); README wordmark.

### Fixed

- `Client#list_collections` no longer raises `TypeError` on the live API's bare-array
  response.
- API error messages now surface RFC7807 `title`/`detail` fields (previously
  "Unknown error").
- `require 'woods/unblocked/client'` works standalone (previously needed `woods`
  loaded first).
- Units without a `file_path` are skipped instead of synced. Previously every
  such unit fell back to the bare repo URL as its document URI — and since URIs
  are the upsert key, they silently overwrote each other in the collection
  (and would have ping-ponged the new manifest hash every run).

### Build

- The suite now installs and runs on Ruby 4.0: the optional `tokenizers` gem (whose
  native extension cannot build against the Ruby 4.0 ABI) is gated behind
  `install_if (Ruby < 4.0)`, and `benchmark` (no longer a default gem in 4.0) is
  declared explicitly. Lockfile unchanged.

## [1.3.0] - 2026-05-13

### Upgrade Notes

Two behavior changes are worth pre-reading before you bump:

- **The MCP Index Server (`woods-mcp`, `woods-mcp-http`) no longer silently degrades to pattern-only search when it can't find a real index.** Hosts that ran 1.2.0 without writing `woods.json` got an empty-store retriever that quietly served degraded results. After this release, the bootstrapper raises `Woods::MCP::MissingArtifact` at boot unless one of these is true: (a) you've run `rake woods:embed` against this checkout (writes `woods.json` + dumps under `output_dir`), or (b) you explicitly opt into the legacy env-var auto-detect path with `WOODS_ALLOW_AUTODETECT=1`. The Shape-2 ("shared filesystem") preset documented under `docs/CONFIGURATION_REFERENCE.md#deployment-shapes` is the supported way to ship pre-built indices alongside a separate MCP process.
- **Console MCP is opt-in.** The Index Server is unaffected. Hosts that mounted `Woods::Console::RackMiddleware` in 1.2.0 already saw it short-circuit at the entry points (Console MCP was disabled in 1.2.0 after an audit). To re-enable it under the new five-layer defense stack, set `config.console_mcp_enabled = true` in your Woods initializer and review the threat-model walkthrough in `docs/CONSOLE_MCP_SETUP.md`. No host automatically re-enables Console MCP on upgrade.

The `mcp` runtime gem is now pinned to `>= 0.9.2` (was `~> 0.6`) — see the `### Security` block below.

### Added — `console_eval` opt-in (backlog B-053, issue #87)

- **Embedded `console_eval` is now opt-in and runs the full five-control contract.** Previously refused unconditionally at dispatch. Opting in requires `WOODS_CONSOLE_UNSAFE_EVAL=true` (or `config.console_unsafe_eval_enabled = true`) AND a `Woods::Console::Confirmation` collaborator AND a JSONL audit-log path. Any missing collaborator raises `Woods::ConfigurationError` at boot — fail-closed by design. The flag still refuses to boot in `Rails.env.production?`.
- **Execution path: EvalGuard → Confirmation → SafeContext → Timeout → AuditLogger.** `EmbeddedExecutor#handle_eval` invokes each control in order. `EvalGuard.check!` refuses credential/reflection/shell/network payloads before parsing completes. `Confirmation#request_confirmation` delegates to the host-provided callback. The code runs inside the `SafeContext` rolled-back transaction and is wrapped in `Timeout.timeout(1..30s)`. Every outcome (guard-refused, denied, ok, error) writes exactly one audit entry with `CredentialScanner`-redacted params.
- **New config attrs.** `Woods.configuration.console_unsafe_eval_confirmation` and `console_unsafe_eval_audit_log_path` — host-level defaults for the two required collaborators. Explicit kwargs on `Server.build_embedded` / `Woods::Console::RackMiddleware` take precedence.
- **Updated operator banner.** The stderr banner now reads "console_eval is LIVE on this process" (previously said "scaffolding is active. Execution is STILL NOT IMPLEMENTED") — it reflects that execution is wired.

### Added — Persistence & Bootstrap arc (PRs #73–#79)

- **Shape-2 (shared filesystem) support.** A new `:shared_filesystem` preset makes the "rake embed writes to `output_dir`, separate `woods-mcp` server reads from disk" shape a first-class deployment option. All stores in-memory at runtime; persistence is handled by the Snapshotter's atomic dumps. No `sqlite3` gem required — works on MySQL- and Postgres-only hosts. See `docs/CONFIGURATION_REFERENCE.md#deployment-shapes` and `docs/BACKEND_MATRIX.md#persistence-story`.
- **Typed MCP exception hierarchy.** `Woods::MCP::BootstrapError` with subclasses `MissingCredential`, `MissingArtifact`, `ConfigMismatch`, `DimensionMismatch`, `UnsupportedArtifact`. `Woods::MCP::ProviderUnreachable` lands as a sibling (recoverable, caught internally for degraded start). `Woods::Storage::InapplicableBackend` signals Snapshotter misuse on durable backends. Host apps rescuing `Woods::Error` continue to catch everything; `ConfigurationError` only catches declared-config-shape problems.
- **On-disk dump format.** `output_dir/dumps/<ISO8601>/` directories with atomic `latest` pointer flipped last. Vectors are packed float32 in a `WVF1` binary format (magic + schema_version + dimension + vector_count + gem_version + model_name header, followed by the float blob and a `vectors.idx` sidecar). Metadata is streaming MessagePack in a `WMD1` format. Both formats are schema-versioned and refuse newer-than-supported artifacts with `UnsupportedArtifact`.
- **`output_dir/woods.json` resolved config snapshot.** The embed run writes the resolved provider (class, model, host, dimension, gem_version) so the MCP server boots against the same config without re-reading env vars. `Woods::ResolvedConfig` validates schema_version on load and exposes `#matches?`, `#assert_compatible!` for drift detection.
- **`Woods::Storage::Snapshotter::Vector` / `::Metadata`.** Dump/load seams that the Indexer calls on embed completion and the Bootstrapper calls at MCP boot. `Snapshotter` is its own namespace so persistence stays off the `Storage::*::Interface` contracts — pgvector / Qdrant / SQLite adapters remain persistence-free.
- **`Woods::IndexArtifact`** — Whole Value wrapping `output_dir` path semantics: `config_path`, `dumps_root`, `latest_dump_path`, `fresh?`, `new_dump_dir`, `promote`, atomic `write_config`. Centralises previously-scattered path knowledge.
- **`Woods::MCP::ConfigResolver`** — extracted resolver that reads `woods.json` (if present), validates compatibility against the live host config, or raises `MissingArtifact` when no snapshot exists and `WOODS_ALLOW_AUTODETECT=1` isn't set. Returns `(config, source)` where source is `:snapshot`, `:host_config`, `:autodetect`, or `:none`.
- **`Woods::MCP::ProviderProbe.reachable!`** — pure predicate raising `ProviderUnreachable` on Ollama / OpenAI probe failure. Carries `url` and `reason` (e.g. `"connection_refused"`, `"timeout"`, `"unauthorized"`) for grep-friendly diagnosis.
- **`Woods::MCP::BootstrapState`** — thread-safe `:initializing → :hydrating → :hydrated | :degraded | :failed` state machine. Exposed by the `woods_status` MCP tool under a new `bootstrap:` block so operators can answer "why is semantic search disabled?" with one tool call.
- **`Configuration#dump_retention_count`** — number of `dumps/<ISO8601>/` directories to keep after a successful embed. Default 3. Older dumps are removed; the directory currently referenced by `latest` is always preserved.
- **`WOODS_ALLOW_AUTODETECT=1`** — opt-in env flag for the legacy env-var auto-detect path when `woods.json` is absent. Without the flag (and without a snapshot), the MCP server raises `MissingArtifact` at boot rather than silently degrading.
- **`exe/woods-mcp` / `exe/woods-mcp-http` top-level rescue.** Typed `BootstrapError` subclasses are caught and printed as `<ClassName>: <message>` to stderr before `exit 2`. Grep-friendly for ops dashboards.
- **`msgpack` added as a runtime gem dependency** (required for `WMD1` metadata serialization). Only loaded when the Snapshotter's metadata path is reached; pgvector / Qdrant users don't pay the load cost.
- **`bench/vector_query_and_serialization.rb`** — standalone Phase-0 benchmark harness measuring cosine kernel latency + allocation count and serialization round-trip for pack("e*") vs Marshal vs MessagePack vs JSON. Writes `tmp/bench_results/phase0.json`.
- **`spec/performance/vector_search_latency_spec.rb`** — opt-in (`:perf` tag) wall-clock regression guard for the kernel. Excluded from the default suite; runs via `rspec --tag perf` or `WOODS_RUN_PERF_SPECS=1`.
- **`docs/design/PERSISTENCE_AND_BOOTSTRAP.md`** — full design doc for the arc. Documents decision log (MessagePack rejected for vectors, `persistent?` on Interface rejected, fail-loud vs degraded-start split, streaming append deferred) and explicit out-of-scope items.

### Changed — Persistence & Bootstrap arc

- **`VectorStore::InMemory` flat-buffer backing.** `@ids` + `@vectors_flat` (single contiguous `Array<Float>`) + `@metadata` + `@id_to_index` + `@tombstones`, replacing the old hash-of-hashes. Strided cosine access; tombstone-based deletes preserve iteration stability across dumps. First-store sets dimension; subsequent stores assert compatibility.
- **Cosine kernel is now a while loop over Array indices** rather than `zip.sum`. Per-query allocations drop from ~9.8M to 2 on a 12k-vector corpus; wall-clock halves. Bit-equal correctness guarded against the reference `zip/sum` implementation (1e-12 tolerance).
- **`VectorStore::Interface` + `MetadataStore::Interface`** gain `#each_entry` and `#bulk_load`. The Snapshotter consumes these; durable backends (pgvector, Qdrant, SQLite) aren't required to implement them — they never see the Snapshotter path.
- **`Builder.build_retriever` accepts `vector_store:` / `metadata_store:` kwargs** so the Bootstrapper can inject hydrated stores. Default behaviour (no kwargs) is unchanged — fresh empties are constructed from config.
- **`Builder.build_metadata_store` / `build_graph_store` are now public** (already-public `build_vector_store` had been the odd one out). Tasks.build_embed_indexer now wires them through.
- **`Builder.build_embedding_provider` strips `SNAPSHOT_ONLY_KEYS` from `embedding_options`** before splatting into the provider constructor. `:dimension` lives in `embedding_options` for `ResolvedConfig`'s sake but isn't part of the Ollama/OpenAI API — without the filter, any config declaring a dimension raised `ArgumentError` at boot.
- **`Bootstrapper#build_retriever` no longer silently degrades.** Missing config + no `WOODS_ALLOW_AUTODETECT=1` now raises `MissingArtifact`. Unreachable provider starts the server in the `:degraded` state (retries on first query), visible in `woods_status`. Silent fallback to pattern-based search is gone — it was the core failure mode the arc set out to eliminate.
- **`MetadataStore::InMemory` stringifies symbol keys on store** so `Snapshotter::Metadata` round-trips (MessagePack doesn't preserve Ruby Symbol type on deserialization).
- **`Bootstrapper` hydrates `VectorStore::InMemory` metadata from the `MetadataStore` after load** — `vectors.bin` carries only the float blob to stay mmap-friendly; per-vector metadata lives in `metadata.msgpack`. The back-fill step keeps `VectorStore#search`'s filter predicates working after a dump/reload cycle.

### Fixed — Persistence & Bootstrap arc

- **`Tasks.build_embed_indexer` now wires `resolved_config`, `metadata_store`, `dump_retention_count`.** Without these, `Indexer#persist_snapshot` wrote `vectors.bin` + `latest` but never wrote `woods.json` — breaking the standalone `woods-mcp` boot path entirely. The spec suite missed this because Indexer specs used doubles for the Snapshotter.
- **`Bootstrapper` hydrates the retriever from Snapshotter dumps at boot** (PR #79). The previous stub returned a retriever with empty stores regardless of the dumps on disk — the entire Shape-2 payoff was unrealized until this fix landed.
- **`ConfigResolver.populate_from_stored` reads `OPENAI_API_KEY` from env** when the stored config says OpenAI. `woods.json` deliberately omits credentials; without this lookup, the MCP server crashed with a raw `ArgumentError: missing keyword: api_key` that the top-level `BootstrapError` rescue didn't catch. Now raises typed `MissingCredential` with an actionable message.
- **`Snapshotter::Vector` header parsing raises `UnsupportedArtifact` on truncated files** rather than the `NoMethodError: undefined method 'unpack' for nil` it produced on a 21-byte file that passed the old 20-byte guard. Minimum-length check raised to 28 bytes plus incremental checks before each unpack.
- **`ResolvedConfig.from_hash` schema-version check uses `<=` not `==`** to match the binary Snapshotters. A future `schema_version = 1` file loaded by a `SUPPORTED_SCHEMA_VERSION = 2` gem now loads cleanly. `schema_version = 0` is still rejected (positive-version guard).
- **`Bootstrapper.hydrated_vector_store` / `hydrated_metadata_store` propagate `ArgumentError`** from Snapshotter dump_dir validation instead of silently returning nil. Misconfigured `output_dir` is a config bug, not a transient I/O issue — operators need to see it.

### Fixed — Ollama embedding (PRs #68–#72)

- **Ollama embedding no longer fails with `400 "the input length exceeds the context length"`.** Two issues compounded into a single runtime failure when indexing real Rails codebases against Ollama: (a) the provider hard-coded `num_ctx = 8192` for every model, but Ollama's `/api/embed` enforces each model's *native* context length regardless of `options.num_ctx` ([ollama/ollama#14186](https://github.com/ollama/ollama/issues/14186)) — `nomic-embed-text`'s native ceiling is 2048, and any request larger than that was rejected outright; (b) the indexer's "does this unit need chunking?" check was based on a chars/token estimate that under-counts dense Ruby source (CamelCase constants, callback DSLs, symbol-heavy code), so chunks that looked safe by char count still exceeded the token budget.

### Added

- **Per-model context-length registry (`Woods::Embedding::Provider::Ollama::MODEL_CONTEXT_LENGTHS`).** `num_ctx` is now auto-selected from the configured model name: `nomic-embed-text` → 2048, `bge-m3` → 8192, `snowflake-arctic-embed2` → 8192, `mxbai-embed-large` → 512, `snowflake-arctic-embed` → 512, `all-minilm` → 256. Unknown models fall back to 2048 (Ollama's embedding default). Explicit `num_ctx:` overrides continue to win when set. `Provider::Ollama#max_input_tokens` reports the selected value so the chunker can size inputs correctly.
- **`Woods::Embedding::TokenCounter` — optional exact-token accounting via the `tokenizers` gem.** Loads the `bert-base-uncased` WordPiece tokenizer (the base every BERT-family embedding model uses) and re-verifies every chunk client-side. Catches the 10–20% gap between char-based estimates and Ollama's internal count on dense Ruby source. Falls back to a 1.5 chars/token ratio when the gem isn't installed, so Woods works unchanged without it — `gem 'tokenizers', '~> 0.5'` is recommended for any Ollama setup.
- **Token-aware `Indexer#needs_chunking?`.** When a `TokenCounter` is present, the indexer consults it before deciding to chunk — a char-count-safe but token-count-over-budget unit now gets split instead of sent to Ollama and rejected.
- **New `docs/EMBEDDING_MODELS.md`** — comparison of the five supported Ollama embedding models (context, dimensions, disk size), instructions for switching models (including the dimension-change re-index requirement), a walkthrough of the `num_ctx` regression and how Woods works around it, and the procedure for adding a new model to the context-length registry.

### Changed

- **Ollama embedding configuration — `base_url:` keyword corrected to `host:` in user docs.** `Woods::Embedding::Provider::Ollama#initialize` has always accepted `host:` (never `base_url:`), but several doc examples showed `base_url:` — following them would raise `ArgumentError` on boot. `CONFIGURATION_REFERENCE.md`, `TROUBLESHOOTING.md`, `FAQ.md`, `GETTING_STARTED.md`, and top-level `README.md` snippets are corrected. No code change — this is documentation catching up to long-standing code.
- **`BACKEND_MATRIX.md`** — Ollama section expanded to a full model table with native context, dimensions, and disk weights for each supported model; adds a "Self-hosted + large units" selection-guidance row pointing to `bge-m3`.

### Security

- **`mcp` gem bumped from `~> 0.6` to `>= 0.9.2, < 1.0` to close [CVE-2026-33946](https://github.com/anthropics/mcp/security/advisories) (HIGH).** The vulnerability is in the upstream `mcp` gem's STDIO transport, not in Woods' use of it, but every Woods install transitively depended on the affected versions. Hosts running `bundle update woods` will pick up the fixed `mcp` release automatically; Gemfile.lock pins on older `mcp` versions need to be regenerated. No API change required in host code.
- **Console MCP re-enabled behind a five-layer defense-in-depth stack.** The feature was previously disabled at its entry points after an audit flagged a Stripe Connect credential leak via the `authorizations` EAV table. It now ships gated on a new `console_mcp_enabled` config flag (default `false`) and runs through five independent safety layers, so a single misconfigured layer cannot leak secrets:
  - **Layer 0 — feature gate.** `exe/woods-console-mcp`, `exe/woods-console`, and `Woods::Console::RackMiddleware` all short-circuit with a helpful "disabled" notice (stderr + exit 1 for stdio, `410 Gone` with JSON body for HTTP) when `Woods.configuration.console_mcp_enabled` is false. Hosts that have mounted the middleware see no change in behavior until they opt in.
  - **Layer 1 — blocked tables (`console_blocked_tables`).** Rejects a tool call at dispatch time — before the executor is invoked — when any `:model`, `:table`, or `:sql` argument resolves to a configured blocked table. Built on `Woods::Console::TableGate`. Embedded transports now pass a `model_tables` registry so model-scoped tools (`console_find`, `console_sample`, etc.) can resolve model names to their tables without a database round-trip.
  - **Layer 2 — credential scanner.** `Woods::Console::CredentialScanner` walks the final response tree and replaces credential-shaped substrings (Stripe `sk_live_*` / `sk_test_*`, AWS `AKIA*`, GitHub `ghp_*` / `github_pat_*`, GCP service-account private keys, generic high-entropy tokens) with `[REDACTED]`. This catches leaks regardless of where the value landed in the response shape — a row, a sub-hash, a positional array — and regardless of whether the column name looked sensitive. Individual rules can be disabled per-deployment via `console_disabled_scanner_patterns` (array of pattern symbols). Pass `%i[all]` to disable the scanner entirely.
  - **Layer 3 — column + EAV redaction (`console_redacted_columns`, `console_redacted_key_values`).** Identity-based redaction for columns and key/value rows. Preserved verbatim from the prior release. See the two entries below for the shape-aware descent logic and EAV pattern contract.
  - **Layer 4 — SqlValidator deny-list + SafeContext rollback.** Unchanged from prior releases. `console_sql` still rejects DML/DDL at the string level before any database interaction, and every request runs inside a transaction that is always rolled back.
  - **Observability.** Layer 1 rejections emit a `console.table_gate.rejected` structured log line (level `warn`, includes tool name and model). Layer 2 hits emit `console.credential_scan.hits` with per-pattern counts, so operators can see when the net caught something rather than relying on in-band MCP response metadata. The logger is pluggable through `Woods::Observability::StructuredLogger` — operator logging pipelines can consume it without parsing the MCP wire format.
  - **Upgrade path.** Hosts running on the disabled release that mounted `Woods::Console::RackMiddleware`: set `config.console_mcp_enabled = true` in your Woods initializer once you've configured the layers that apply to your threat model. The flag is opt-in by design — no host automatically re-enables the feature on upgrade. See `docs/CONSOLE_MCP_SETUP.md` for the full posture walkthrough and per-layer tuning guidance.
  - **Scope.** The Index MCP server (`woods-mcp`, `woods-mcp-http`) and every extraction workflow remain unaffected — they were never in scope for the audit and ship unchanged.

- **`console_redacted_columns` now covers every tool that returns row data.** Redaction previously only walked top-level hash keys, so `console_sample`, `console_recent`, `console_find`, `console_pluck`, `console_sql`, and `console_query` returned configured credential columns in the clear — records were nested under `records` / `record`, and rows were positional arrays under `rows` / `values`. The server-level redaction pass is now shape-aware: it descends into `record` / `records` hashes and uses the `columns` header to redact positional rows. `console_pluck` now also includes a `columns` field in its response so positional redaction can key off of it. Affects every transport (stdio, Rack, bridge).
- **`console_redacted_key_values` for EAV (key-value) credential storage.** Column-name redaction cannot protect tables that store sensitive values in a generically named column (e.g. a Stripe Connect `authorizations` row of `{key: "stripe_access_token", value: "sk_live_..."}`): adding `value` to `console_redacted_columns` over-redacts every unrelated row. The new `console_redacted_key_values` config accepts one or more `{key_column:, value_column:, sensitive_keys: []}` patterns — when a row's `key_column` cell matches one of `sensitive_keys`, the same row's `value_column` cell is replaced with `[REDACTED]`. Applies across every response shape (`record`, `records`, positional `rows` / `values`) and every transport. Empty by default — configure it in `Woods.configure` to cover the EAV credential tables specific to your app.
- **TableGate now resolves `joins:` and `association:` arguments through model reflections.** `console_query` (via `joins:`) and `console_association_count` (via `association:`) previously bypassed Layer 1 entirely — an agent could reach `authorizations` rows by joining through a non-blocked model. The gate now accepts a `model_reflections` registry (association name → target table, built at boot from `reflect_on_all_associations`) and rejects any join or association whose target is on `console_blocked_tables`. Polymorphic and reflection-raising associations are skipped gracefully. Exposed via new `TableGate#check_joins!` and `#check_association!` entry points.
- **TableGate now catches ANSI-89 comma-joins.** `SELECT * FROM users, authorizations WHERE …` previously slipped past the gate because the old regex only matched the first identifier after `FROM` and explicit `JOIN` tokens. The gate now walks every `FROM` clause, splits on top-level commas (parenthesis-depth aware, so subqueries don't mislead it), and rejects a blocked table in any position of the list. Case, schema prefix, and quoted identifiers (`"authorizations"`, `` `authorizations` ``) are all handled.
- **TableGate now catches blocked tables inside CTE bodies, UNION branches, and FROM-clause subqueries.** The non-greedy `FROM_CLAUSE` regex previously terminated on `WHERE`/`JOIN`/`;`/`)` — but not on a nested `FROM` — so `SELECT * FROM (SELECT * FROM authorizations) AS a`, `WITH a AS (SELECT * FROM authorizations) SELECT * FROM a`, and `SELECT id FROM users UNION SELECT id FROM authorizations` would consume the outer clause and never re-scan the inner table. Treating `\bFROM\b` as a terminator makes every `FROM` occurrence its own independent `.scan` match, closing the H-3 bypass. Specs cover all three shapes.
- **Safer-by-default column redaction list.** `console_redacted_columns` previously defaulted to `[]`, so a host that enabled Console MCP without configuring Layer 3 got zero column redaction. The gem now seeds `console_redacted_columns` with a curated list of ~30 credential columns that appear across Devise, Doorkeeper, Rodauth, has_secure_password, devise-two-factor, and hand-rolled auth code: `password`, `password_digest`, `encrypted_password`, `crypted_password`, `salt`, `otp_secret`, `encrypted_otp_secret`, `two_factor_secret`, `backup_codes`, `reset_password_token`, `confirmation_token`, `unlock_token`, `remember_token`, `invitation_token`, `access_token`, `refresh_token`, `auth_token`, `api_token`, `api_key`, `bearer_token`, `client_secret`, `webhook_secret`, `signing_secret`, `session_secret`, `private_key`, `encrypted_private_key`, `key_hash`, `token`, `secret`, plus `password_salt`/`consumed_timestep`. Exposed via `Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS` so hosts can extend (`Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS + %w[extra]`) or override (`%w[only these]`). Intentionally excludes `key` (ActiveStorage blob keys, EAV key columns) and PII columns (org-specific compliance).
- **CredentialScanner ships with 8 additional gateway patterns.** The Layer 2 content scanner now catches `github_pat_` fine-grained PATs, SendGrid API keys (`SG.xxx.yyy`), Mailgun API keys (`key-<32 hex>`), Anthropic API keys (`sk-ant-api**-***`), OpenAI API keys (`sk-` and `sk-proj-`), Shopify access tokens (`shpat_`, `shpca_`, `shpss_`, `shppa_`), Square access tokens (`sq0xxx-***`), and PayPal access tokens (`access_token$production$…$…`). Pattern order is specific-before-generic so Anthropic hits increment `:anthropic_api_key` rather than falling through to `:openai_api_key`. Total active patterns: 17.
- **TableGate now strips PostgreSQL dollar-quoted literals before scanning.** `SELECT $tag$FROM authorizations$tag$ …` would previously trigger a false match on the literal's contents; the gate now collapses `$…$…$…$` and `$tag$…$tag$` pairs to an empty string in the same pre-scan pass as SQL comments and single-quoted strings. Stripping order matters: dollar-quotes are removed before single-quotes so a stray apostrophe inside a dollar-quoted literal cannot fool the single-quote scanner.
- **One-time observability warning when the structured logger fails.** `Woods::Console::Server` previously swallowed every `StructuredLogger` exception silently — an operator misconfiguring the log sink would see no signal that Layer 1 rejections and Layer 2 hits were being lost. The first failure now prints a single `[woods-console]` warning to stderr naming the exception class and message; subsequent failures remain silent so a broken sink cannot flood the log. Behavior on a working logger is unchanged.
- **Credential scanner docstring uses an obvious placeholder.** The `@example` block in `Woods::Console::CredentialScanner` previously contained a Stripe-shaped value that matched its own pattern. Replaced with a clearly synthetic example so the doc cannot be mistaken for a real token during audits.
- **TableGate now catches blocked tables written as quoted schema-qualified identifiers.** `SELECT * FROM "public"."authorizations"` and `` SELECT * FROM `app`.`authorizations` `` previously slipped past Layer 1 because the regex captured only the first quoted segment (`"public"`) and the second (`"authorizations"`) was discarded. Both `LEAD_IDENT` and `JOIN_REFERENCE` now capture an optional quoted-schema prefix separately, and the joined `schema.table` form is passed to `#blocked?` so a configured entry of either `"authorizations"` (bare) or `"public.authorizations"` (qualified) matches as the operator expects. Closes a TableGate bypass on PostgreSQL and MySQL.
- **TableGate now recognizes MySQL `STRAIGHT_JOIN` as a join keyword.** `SELECT * FROM users STRAIGHT_JOIN authorizations …` previously slipped past Layer 1 because the `\bJOIN` boundary in `JOIN_REFERENCE` doesn't fire inside the `STRAIGHT_JOIN` token (the `_J` boundary is between two word characters). The join scanner now matches `\b(?:STRAIGHT_)?JOIN`, and `STRAIGHT_JOIN` is added to the `FROM_CLAUSE` terminator alternation so the FROM clause stops before it instead of swallowing the joined table. Closes a TableGate bypass on MySQL.
- **`blocked_tables` now treats schema-qualified entries symmetrically.** Configuring `blocked_tables: ["audit.authorizations"]` previously matched nothing because `#blocked?` schema-stripped *incoming* identifiers but never the configured set. Bare entries (`"authorizations"`) continue to behave as a wildcard across every schema; schema-qualified entries (`"audit.authorizations"`) now match only references that carry the same schema prefix — including quoted variants `"audit"."authorizations"` and `` `audit`.`authorizations` ``. A reference to `public.authorizations` is *not* blocked when only `audit.authorizations` is on the list, so operators can scope blocks to a specific schema.
- **TableGate now catches blocked tables behind PostgreSQL `FROM ONLY` and mixed-quoting schema prefixes.** `FROM ONLY authorizations` and `JOIN ONLY authorizations` previously evaded Layer 1 because the `ONLY` inheritance opt-out keyword sat between the join keyword and the table identifier — the regex captured `ONLY` as the table name and the actual table was discarded. Mixed-quoting forms `FROM public."authorizations"` and `` JOIN `app`."authorizations" `` slipped past for the same reason in reverse: the schema-prefix branch in `LEAD_IDENT` and `JOIN_REFERENCE` only recognized fully quoted (`"public"."authorizations"`) or fully bare (`public.authorizations`) prefixes, so a bare-then-quoted combination fell through to the table-only branch and the schema chunk hid the identifier. `JOIN_REFERENCE` now consumes an optional `(?:ONLY\s+)?` after the join keyword and adds a `(?<jschema_bare>\w+)` alternative; `LEAD_IDENT` strips a leading `ONLY ` via the new `ONLY_PREFIX` constant before matching and adds a `(?<schema_bare>\w+)` alternative. Closes two more TableGate bypasses on PostgreSQL and MySQL.
- **SafeContext statement timeout is now transaction-scoped on PostgreSQL.** The previous `SET statement_timeout = '5000ms'` was a session-level setting that survived the rolled-back transaction and bled into the next consumer of the pooled connection — a host app web request or background job picking up the same connection would inherit the Console MCP timeout. Switched to `SET LOCAL statement_timeout` so the value is scoped to the surrounding transaction and discarded on rollback (which `SafeContext` always does). MySQL's `SET max_execution_time` is left as-is — it already applies only to the next SELECT and doesn't need a `LOCAL` equivalent.
- **SafeContext now leases a fresh connection from the pool per request.** Construction-time connection capture (`SafeContext.new(connection: ActiveRecord::Base.connection)`) reused the same connection across every Console MCP request for the lifetime of the embedded server, defeating the point of `with_connection` and risking cross-request state leakage in multi-DB / sharded hosts. `SafeContext` now accepts an optional `pool:` kwarg; when set, every `#execute` call wraps the body in `pool.with_connection { |conn| … }` so the connection is leased for the duration of the rolled-back transaction and returned immediately after. The leased connection is published to `Thread.current[:woods_console_leased_connection]` so dispatch handlers (`EmbeddedExecutor#active_connection`) thread it through without re-leasing. The `connection:` form remains for tests and callers managing their own lifecycle. Resolves the `WOODS-CONSOLE-PERREQ-CONN` follow-up tracked alongside the Rails 8.0 deprecation fix below.
- **`Woods::Console::EvalGuard` — parse-time refusal layer for `console_eval`.** A new checked-method class that walks the normalized `Woods::Ast::Parser` tree of every proposed eval payload and raises `ForbiddenExpressionError` when the snippet reaches a credential or reflection escape. Hardcoded denials (no DSL) cover `Rails.application.credentials.*`, `Rails.application.secrets.*`, `Rails::Secrets.*`, `Devise.secret_key`, every `ENV` form (`ENV['x']`, `ENV.fetch`, bare `ENV`), reflection escapes (`eval`, `instance_eval`, `class_eval`, `module_eval`, `send`, `public_send`, `const_get`, `binding`), and credential-file reads (`File.read` / `IO.read` / `Pathname.new` whose argument source contains `master.key`, `credentials.yml.enc`, `credentials/`, `secrets.yml`, `secrets.yml.enc`). Refuses on parse failure too — a payload that won't parse can't be reasoned about. Adds `prism ~> 1.4` as a runtime dependency (stdlib on Ruby 3.3+, gem on 3.0–3.2) so the AST path is available across the support matrix.
- **`EvalGuard` is now wired into `console_eval` dispatch.** `Woods::Console::Server.define_eval` instantiates an `EvalGuard` (gated on a new `console_credential_defense_enabled` config flag, default `true`) and passes it to `Tools::Tier4.console_eval` as `guard:`. Forbidden payloads raise `ForbiddenExpressionError` *before* the bridge request is built, and `define_console_tool` now rescues that alongside `SqlValidationError` so the LLM sees a clean MCP error response (`error: true`, message in `text`) instead of a transport-level exception. Hosts can opt out by setting `config.console_credential_defense_enabled = false` in their Woods initializer if the parse-time layer ever interferes with a legitimate workflow — the bridge-side enforcement remains in place either way.
- **`Woods::Console::CredentialIndex` — boot-time index of the host app's actual secrets.** A new value object that walks `Rails.application.credentials.config` once at server boot, collects every string leaf with length ≥ 12, and holds them in a frozen `Set` plus a precompiled `Regexp.union` for one-pass `gsub` substitution. The pattern-based `CredentialScanner` only catches *known credential shapes*; this index closes the gap for hand-rolled HMAC secrets, Twilio auth tokens, third-party webhook signing keys, and any other value whose format the scanner doesn't recognize but whose exact contents Rails already knows. `match?(str)`, `redact(str)`, and `empty?` are the only public API surface. `.build(rails_app:)` catches `ActiveSupport::EncryptedConfiguration::MissingKeyError`, `ActiveSupport::EncryptedFile::MissingKeyError`, and `ActiveSupport::MessageEncryptor::InvalidMessage` *by class name* (no constant references) so apps without `config/master.key` still boot — the index just stays empty and the other defense layers continue to apply.
- **CredentialScanner ships with 13 additional Tier 1 gateway patterns.** Layer 2 now catches Stripe Connect account IDs (`acct_*` — PII per Stripe ToS), Klaviyo private API keys (bare `pk_<34 alnum>`, which previously slipped past the Stripe publishable regex and grant full Klaviyo tenant access), Salesforce session/access tokens (`00D<15-org-id>!<base64 payload>`), LaunchDarkly SDK keys (`sdk-<UUID>`) and mobile keys (`mob-<UUID>`), HubSpot private app tokens (`pat-<region>-<UUID>`), Brevo API keys (`xkeysib-<64 hex>-<16 alnum>`) and SMTP keys (`xsmtpsib-…`), Kit (ConvertKit) API keys (`kit_*`), and three Twilio identifier shapes (`AC` account SIDs, `SK` API key SIDs, `VA` Verify service SIDs). Also extends the existing `shopify_access_token` alternation with `shprt_` (refresh) and `shpua_` (user-access) prefixes, both previously missed. Order is specific-before-generic — the Klaviyo regex sits after `stripe_publishable_key` so a real `pk_live_*` Stripe key still increments `:stripe_publishable_key` rather than falling through to `:klaviyo_private_key`. Total active patterns: 30 (was 17). Closes documented critical misses from the credential-leakage research brief.
- **`CredentialIndex` is now wired into `CredentialScanner` and the Console MCP server.** `CredentialScanner.new` accepts an optional `secret_index:` kwarg; when set, every scanned string runs through the index *before* the shape-pattern pass, and matched substrings are replaced with `[REDACTED:credential]` (a marker distinct from the pattern scanner's `[REDACTED]` so audit output can tell which layer caught a leak). Counts emit under a new `:credential_index` key alongside the per-pattern counters. `Woods::Console::Server.build_response_context` lazy-builds the index from `Rails.application` whenever `console_credential_defense_enabled` is true and a Rails application is reachable — non-Rails specs and CI environments without a `master.key` continue to work unchanged. Multi-DB / sharded hosts are explicitly out of scope: the index reflects only the credentials available to the Rails process that boots the Console MCP server. Use Layer 3 (`console_redacted_columns` / `console_redacted_key_values`) for credentials stored in a separate database.

### Changed

- **`console_credential_scanning_enabled` removed; `:all` sentinel in `console_disabled_scanner_patterns` takes its place.** The boolean flag added earlier on this unreleased branch is gone — one knob instead of two, no divergent ways to turn off the same layer. Hosts that want the scanner fully disabled now set `config.console_disabled_scanner_patterns = %i[all]`; per-pattern opt-outs continue to work as before (`%i[stripe_publishable_key]`, etc.). No migration needed for anyone on v1.2.0 — the flag never shipped. `Woods::Console::Server.build_response_context` skips constructing the scanner entirely when `:all` is present, so there's no per-response overhead from the disabled path.
- **`Woods::Console::ResponseContext` is now a Parameter Object + Null Object.** Previously a plain `Struct` data-bag, `ResponseContext` now exposes tell-don't-ask commands — `enforce!(args)`, `redact(result)`, `scan(value)`, `present?` — that bundle the three response-safety layers the Console MCP server threads through every tool call. `.build` returns a `NullResponseContext` singleton (same public surface, no-op bodies) when every layer is absent, so dispatch sites no longer need `ctx&.` safe-navigation chains. The column + EAV redaction logic moves to a new `Woods::Console::Redactor` module — pure, stateless, and unit-testable without constructing a server. `Server#send_to_bridge`, `#scan_for_credentials`, and the tool-dispatch block lose three `ctx&.<layer>` guards and ~80 lines of inline redaction plumbing. No behavior change; the server's `apply_redaction` class-level entry point is retained as a thin delegate to `Redactor.apply` so existing spec calls still work.
- **`Woods::Console::DispatchPipeline` owns the per-tool dispatch flow.** The integer coercion, Layer 1 gate enforcement, bridge/executor send, Layer 3 redaction, Layer 2 credential scanning, and MCP response rendering that previously lived inline in `Server.register` — wired together through four `method(:send_to_bridge)`-style captures closing over module-level methods — now live on a single per-tool object. Each `define_tool` block is a one-liner that calls `pipeline.call(args)`. Table-gate rejection and credential-scan-hit logging happen inside the pipeline against a pluggable `logger:` (the `StructuredLogger` in production). No behavior change; the refactor collapses the server's dispatch surface enough to make the pipeline a first-class thing to test — see `spec/console/dispatch_pipeline_spec.rb`.
- **Console `check_*!` / `validate_*!` / `request_confirmation` / `EvalGuard#check!` methods are now commands, not predicates.** Per Avdi Grimm's Confident Ruby guidance, bang methods that enforce a precondition should either complete or raise — they shouldn't return a truthy value callers are tempted to branch on. `TableGate#check_sql!`, `#check_table!`, `#check_joins!`, `#check_association!`, `SqlValidator#validate!`, `ModelValidator#validate_columns!`, `Confirmation#request_confirmation`, and `EvalGuard#check!` now return `nil` on success (unchanged raise behavior on failure). Removed the eight `# rubocop:disable Naming/PredicateMethod` pragmas that were silencing the cop. Specs that asserted `.to be(true)` on return values have been rewritten to use `expect { … }.not_to raise_error`. Internal callers already used these for side effects only — no behavioral change.

- **`CredentialScanner#walk` now scans Hash keys as well as values.** Previously, only Hash values were checked for credential shapes; keys were passed through untouched. In EAV row shapes where the key column itself carries the credential name (e.g. `{"sk_live_51..." => "some_value"}`), a credential-shaped key would slip through Layer 2. The scanner now coerces each key to String, runs the pattern and index pass, and restores the original key type — a Symbol key that carries a credential shape is emitted as a Symbol after redaction (e.g. `:"[REDACTED]"`); String keys stay Strings; non-String/non-Symbol keys (Integer, etc.) are untouched. Closes backlog item `credential-scanner-hash-keys-not-scanned` (PR #34 review low #5).

- **`CredentialIndex` documents restart-required behavior and exposes a rebuild hook.** The boot-time credential index has always been built once at process start and held for the lifetime of the MCP process — rotating Rails credentials without restarting left the old secrets in the index. This is now documented explicitly in `CredentialIndex.build`'s YARD doc and in `docs/CONSOLE_MCP_SETUP.md`. Two new capabilities close the gap:
  - **`Woods::Console::Server.rebuild_credential_index(rails_app:)`** — rebuilds the index from fresh Rails credentials and hot-swaps it into the active scanner without restarting the process. Returns the new `CredentialIndex`, or `nil` when credential defense is disabled or no server has been built yet. Existing callers of `Server.build` / `Server.build_embedded` are unaffected (additive API, no required signature changes).
  - **Boot-time rotation warning** — at server build time, Woods checks whether any credentials file (`config/credentials.yml.enc`, `config/credentials/<env>.yml.enc`) was modified after the process started. If so, it emits a `console.credential_index.stale` warn-level structured log line (file path, mtime, process start, and a hint). Opt out with `config.console_credential_rotation_warning = false`.
  Closes backlog item `credential-index-rebuild-on-rotation` (PR #34 review low #8).

### Fixed

- **Console MCP middleware boots cleanly on Rails 8.0.** Replaced `ActiveRecord::Base.connection` with `ActiveRecord::Base.connection_pool.with_connection { |conn| … }` in `RackMiddleware#build_embedded_server` and the `EmbeddedExecutor#active_connection` fallback. `ActiveRecord::Base.connection` is deprecated in Rails 7.2 and removed in 8.0; `with_connection` is the supported cross-version API (works 6.1 → 8.x). Single-pool behavior is preserved — converting `SafeContext` to per-request connection acquisition (multi-DB / sharded hosts) is tracked separately as `WOODS-CONSOLE-PERREQ-CONN`.
- **Console renderer no longer collapses row data to `"N items"`.** `ConsoleResponseRenderer#render_hash` was summarizing every Array-valued key to a count, which silently elided the actual data from `console_sql`, `console_query`, `console_pluck`, `console_sample`, `console_recent`, and `console_find` responses — the MCP payload carried the rows, but the rendered text agents see only named the shape. Array values now recurse through `render_array` (Array<Hash> → Markdown table, scalar array → bullet list). When `rows` or `values` appears alongside a sibling `columns` array, the renderer emits a positional Markdown table using the columns as headers so sql / query / pluck output is scannable. Metadata-shaped responses (`count`, `aggregate`, `schema`, etc.) are unchanged.
- **MCP `search` tool no longer destroys regex patterns.** `index_reader` was wrapping queries in `Regexp.escape`, turning `User|Account` into a literal-only match. Now compiles raw with `IGNORECASE` and falls back to the escaped form only on `RegexpError`.
- **Auto-detect Ollama probe reliability.** The bootstrapper now probes `GET /api/tags` (the documented list-models endpoint) instead of `HEAD /`, which returned 404 on some Ollama versions. Any non-5xx response now marks Ollama as reachable.
- **`WOODS_SEARCH_MAX_SCAN=""` no longer disables phase-2 search.** Empty and whitespace-only values fall back to the default cap of 500 instead of coercing to 0.
- **Self-describing error for unsupported tools in embedded mode.** `console_sql` / `console_query` rejections now point at `embedded_read_tools: true` and the setup doc. Other Tier 2–4 rejections still point at the bridge architecture. Replaces the generic "Not yet implemented in embedded mode" message.
- **`console_embedded_read_tools` configuration flag.** Flows through `Woods.configure` to both the Rack middleware (Option C) and the stdio transports (Options A and B) — previously only the Rack mount accepted `embedded_read_tools:` directly, so stdio deployments had no way to unlock `console_sql` / `console_query` without patching the executable.

### Added

- **Ollama auto-detection in the MCP bootstrapper.** When no embedding provider is configured and no `OPENAI_API_KEY` is present, the bootstrapper probes `OLLAMA_BASE_URL` (default `http://localhost:11434`) and auto-enables semantic search if reachable. A one-line STDERR banner at startup reports the active provider.
- **`WOODS_SEARCH_MAX_SCAN` env var.** Caps phase-2 scan volume during `search`. Default 500.
- **Ransack-style scope predicates** for console data tools — `scope` hashes in `console_count`, `console_sample`, `console_pluck`, `console_aggregate`, `console_association_count`, and `console_recent` now accept suffixed keys (`_eq`, `_not_eq`, `_gt`, `_gteq`, `_lt`, `_lteq`, `_in`, `_not_in`, `_null`, `_not_null`, `_present`, `_blank`, `_matches`). Column names are validated before Arel predicates are built — no string interpolation, no SQL injection surface.
- **`count` function in `console_aggregate`** — the `column` argument is optional when `function: "count"`, making it easy to count rows matching a scope in a single tool call.
- **`embedded_read_tools` flag** on `Woods::Console::RackMiddleware` — opts `console_sql` and `console_query` into the embedded executor, with `SqlValidator` + `SafeContext` rollback + per-request connection pooling enforcing read-only safety.
- **MCP worktree setup guide** (`docs/MCP_WORKTREE_SETUP.md`) — multi-worktree MCP configuration for simultaneous Claude Code sessions across branches.
- **`pg_query` spike doc** (`docs/PG_QUERY_SPIKE.md`) — evaluation of an optional `pg_query`-backed AST identifier extractor alongside the existing regex `SqlTableScanner`. PostgreSQL hosts that opt into the gem would get AST-grade table extraction; MySQL and gem-less hosts continue on the regex path unchanged. Design-only — no implementation yet.

### Changed

- **MCP `search` response shape.** `search` now returns `{ results: [...], note?: String, partial?: Boolean }` instead of a bare `Array`. `note` flags broad patterns (>50% of a directory matched). `partial: true` indicates the phase-2 scan cap was reached — set `WOODS_SEARCH_MAX_SCAN` to raise it.
- **MCP `search` and `codebase_retrieve` descriptions** rewritten in Figma-MCP style (purpose → example → returns → when to use alternatives → gotchas). Fallback message for `codebase_retrieve` now includes exact fix commands.
- **Scope tool descriptions** updated to reference the supported predicate suffixes, so agents discover the richer filtering surface without reading the cookbook.
- **Tool descriptions for `console_sql` and `console_query`** rewritten in Figma-MCP-style (purpose → safety → requirement → alternatives) so agents understand when to reach for each and how to enable them.
- **Docs:** `docs/CONSOLE_MCP_SETUP.md` now covers `embedded_read_tools: true` as an alternative to switching to the bridge architecture, and the Troubleshooting entry for Tier 2–4 tools distinguishes the two read tools from everything else.

### Documentation

- **MySQL vector-pairing constraint surfaced where readers actually hit it** (#83 docs subset, PR #122). `docs/BACKEND_MATRIX.md` gains a "Database compatibility" subsection at the top of `## Vector Stores` with a MySQL-first table mapping primary database → supported vector stores, and a one-paragraph explanation of why MySQL stacks must pair with Qdrant / Pinecone / FAISS. `docs/TROUBLESHOOTING.md` gains "Configuring vector search on MySQL" under Embedding Problems, showing the MySQL + Qdrant initializer first and the Postgres + pgvector equivalent below for contrast. The `:mysql_qdrant` preset and dedicated integration spec from #83 remain open as post-1.3.0 follow-ups.

### Dependencies

- **Runtime gems added.**
  - `msgpack` (`>= 1.5`) — required for the `WMD1` streaming metadata snapshot format introduced by the Persistence & Bootstrap arc. Only loaded on the Snapshotter's metadata path; pgvector / Qdrant users don't pay the load cost.
  - `prism` (`~> 1.4`) — backs `Woods::Console::EvalGuard`'s AST inspection. Ships in stdlib on Ruby 3.3+; the gem dependency guarantees the Prism path on 3.0–3.2 so the guard's behavior stays consistent across the support matrix.
- **Runtime gem version constraint tightened.**
  - `mcp`: `~> 0.6` → `>= 0.9.2, < 1.0` (CVE-2026-33946 HIGH; see `### Security` above).
- **GitHub Actions bumps.**
  - `ruby/setup-ruby` 1.295.0 → 1.307.0 (PRs #91 + #121).
  - `softprops/action-gh-release` 2.2.2 → 3.0.0 (PR #21 — Node 24 runtime; GitHub-hosted runners support this today).
  - `rubygems/configure-rubygems-credentials` 1.0.0 → 2.0.0 (PR #120 — internal-only changes, no `with:` keys affected).

## [1.2.0] - 2026-03-27

### Added

- **Unblocked Documents API exporter** — sync extraction data to an Unblocked collection for code review and Q&A context
  - `Woods::Unblocked::Client` — REST client with retry and daily budget rate limiting
  - `Woods::Unblocked::DocumentBuilder` — type-specific Markdown formatters optimized for review context (blast radius, entry points, associations, side effects)
  - `Woods::Unblocked::Exporter` — full/partial sync orchestrator with priority ordering
  - `Woods::Unblocked::RateLimiter` — daily budget tracking (1000 calls/day)
  - New rake tasks: `woods:unblocked_sync` (alias: `woods:relay`)
  - New config: `unblocked_api_token`, `unblocked_collection_id`, `unblocked_repo_url`
  - Integration guide: `docs/UNBLOCKED_INTEGRATION.md`
- **Domain cluster detection** in `GraphAnalyzer` — groups code units into semantic domains using namespace prefixes and graph connectivity
  - `GraphAnalyzer#domain_clusters` — hybrid namespace + graph clustering with hub identification, entry point detection, and boundary edge mapping
  - New MCP tool: `domain_clusters` with `min_size` and `types` filters
  - New renderer: `render_domain_clusters` in MarkdownRenderer

## [0.3.1] - 2026-03-04

### Fixed

- **Gemspec version** now reads from `version.rb` instead of being hardcoded — prevents version mismatch during gem builds
- **Release workflow** replaced `rake release` (fails on tag-triggered detached HEAD) with `gem build` + `gem push`

## [0.3.0] - 2026-03-04

### Added

- **Redis/SolidCache caching layer** for retrieval pipeline with TTL, namespace isolation, and nil-caching
- **Engine classification** — engines tagged as `:framework` or `:application` based on install path (handles Docker vendor paths)
- **Graph analysis staleness tracking** — `generated_at` timestamp and `graph_sha` for detecting stale analysis
- **Docker setup guide** (`docs/DOCKER_SETUP.md`) — split architecture, volume mounts, bridge mode, troubleshooting
- **Context7 documentation suite** — 10 new user-facing docs optimized for AI retrieval: FAQ, Troubleshooting, Architecture, Extractor Reference, WHY Woods, MCP Tool Cookbook, and 3 Context7 skills
- **`context7.json`** configuration for controlling Context7 indexing scope

### Fixed

- **Vendor path leak** in source file resolution across 9 extractors — framework gems under `vendor/bundle` no longer produce empty source
- **Prism cross-version compatibility** — handle API differences between Prism versions
- **`schema_sha`** now supports `db/structure.sql` fallback (not just `db/schema.rb`)
- **ViewComponent extractor** skips framework-internal components with no resolvable source file
- **HTTP connection reuse** and retry handling in embedding providers
- **DependencyGraph `to_h`** returns a dup to prevent cache pollution
- **MCP tool counts** corrected across all documentation (27 index / 31 console)
- **TROUBLESHOOTING.md** corrected: `config.extractors` controls retrieval scope, not which extractors run

### Changed

- **README streamlined** from 620 to 325 lines — added Quick Start, Documentation table; removed verbose sections in favor of links to dedicated docs
- **Internal rake tasks** (`retrieve`, `self_analyze`) hidden from `rails -T`
- **Estimated tokens memoization** removed to prevent stale values after source changes
- **Simplification sweep** — dead code removal, shared helper extraction, bug fixes across caching and retrieval layers

### Performance

- Critical hotspots fixed across extraction, storage, and retrieval pipelines
- `fetch_key` optimization for falsy value handling in cache layer

## [0.2.1] - 2026-02-19

### Changed

- Switch release workflow to RubyGems trusted publishing

## [0.2.0] - 2026-02-19

### Added

- **Embedded console MCP server** for zero-config Rails querying (no bridge process needed)
- **Console MCP setup guide** (`docs/CONSOLE_MCP_SETUP.md`) — stdio, Docker, HTTP/Rack, SSH bridge options
- **CODEOWNERS** and issue template configuration

### Fixed

- MCP gem compatibility and symbol key handling in embedded executor
- Duplicate URI warning in gemspec

## [0.1.0] - 2026-02-18

### Added

- **Extraction layer** with 13 extractors: Model, Controller, Service, Job, Mailer, Phlex, ViewComponent, GraphQL, Serializer, Manager, Policy, Validator, RailsSource
- **Dependency graph** with PageRank scoring and GraphAnalyzer (orphans, hubs, cycles, bridges)
- **Storage interfaces** with InMemory, SQLite, Pgvector, and Qdrant adapters
- **Embedding pipeline** with OpenAI and Ollama providers, TextPreparer, resumable Indexer
- **Semantic chunking** with type-aware splitting (model sections, controller per-action)
- **Context formatting** adapters for Claude, GPT, generic LLMs, and humans
- **Retrieval pipeline** with QueryClassifier, SearchExecutor, RRF Ranker, ContextAssembler
- **Retriever orchestrator** with degradation tiers and RetrievalTrace
- **Schema management** with versioned migrations and Rails generators
- **Observability** with ActiveSupport::Notifications instrumentation, structured logging, health checks
- **Resilience** with CircuitBreaker, RetryableProvider, IndexValidator
- **MCP Index Server** (21 tools) for AI agent codebase retrieval
- **Console MCP Server** (31 tools across 4 tiers) for live Rails data access
- **AST layer** with Prism adapter for method extraction and call site analysis
- **RubyAnalyzer** for class, method, and data flow analysis
- **Flow extraction** with FlowAssembler, OperationExtractor, FlowDocument
- **Evaluation harness** with Precision@k, Recall, MRR metrics and baseline comparisons
- **Rake tasks** for extraction, incremental indexing, framework source, validation, stats, evaluation
