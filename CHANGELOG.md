# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
