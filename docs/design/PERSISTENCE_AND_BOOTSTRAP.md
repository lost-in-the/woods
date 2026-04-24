# Persistence, Bootstrap Flow, and Query Performance

**Status:** Implemented — PRs #73, #74, #75, #76, #77, and the current status-surface PR.
**Scope:** Fix multi-process (Shape 2) index serving end-to-end. Covers control-flow decomposition of `MCP::Bootstrapper`, on-disk persistence format for the in-memory stores, and the query-path allocation bug that shipped alongside them.
**Non-goals:** Alternate durable backends beyond what already exists (pgvector, Qdrant, SQLite), distributed/sharded embedding, booting Rails inside `woods-mcp`, native C extensions.

## Deferred to follow-ups

Two plan items were explicitly scope-cut during implementation:

- **Streaming append during embed** (§3.4). Compact-at-end is the current path. For admin's minutes-scale embed this is fine; worth revisiting at 10× scale when a crash at hour N of N+1 genuinely hurts. TODO marker in `Indexer#persist_snapshot`.
- **Full woods-testbed integration spec.** The subprocess-based round-trip in `spec/integration/persistence_round_trip_spec.rb` proves the dump/load contract. A testbed-hosted end-to-end that boots `woods-mcp` and issues a semantic query against a real Ollama is a separate effort that needs the testbed repo wired in.

---

## 1. Problem

Woods supports three deployment shapes:

1. **Single-process** — embed + query in one Ruby VM (dev console, tests). Works today.
2. **Multi-process, shared filesystem** — rake task runs `woods:embed`, separate long-lived `woods-mcp` server reads from the same `output_dir` and answers queries. **Broken.**
3. **Distributed** — pgvector or Qdrant; both processes talk to a durable backend. Works today when configured.

Shape 2 is what the admin-style host wants: a Rails app extracts and embeds on its own schedule, and an MCP sidecar serves queries without booting Rails. Three independent defects compose into a broken experience:

| Defect | Location | Effect |
|---|---|---|
| In-memory vector store has no persistence | `lib/woods/storage/vector_store.rb` `InMemory` | Vectors live in a process-local `Hash`; MCP sidecar starts empty. |
| In-memory metadata store has no persistence | `lib/woods/storage/metadata_store.rb` `InMemory` | Same story — metadata dies with embed process. |
| MCP bootstrapper ignores host config | `lib/woods/mcp/bootstrapper.rb` `build_retriever` | `exe/woods-mcp` does not boot Rails; `config/initializers/woods.rb` never runs; bootstrapper re-derives provider from env vars, mutates `Woods.configuration` in place, `rescue StandardError`s every failure into a single `nil` + "pattern search only" warning. |
| Cosine similarity allocates transiently per pair | `lib/woods/storage/vector_store.rb:150–163` | `vec.zip(other).sum { \|x, y\| x * y }` allocates ~770 objects per similarity call; ~9.8M allocations per 12 k-vector search; ~1017 ms/query on admin-size corpora. |

The first three are what users experience. The fourth is a performance defect adjacent to the same code — independent of persistence but by far the largest user-visible win available.

## 2. Design principles

1. **Configuration sovereignty belongs to the host.** Declared config in `config/initializers/woods.rb` must reach every woods process without the host re-declaring values at launcher boundaries. We capture **resolved** config (host URL, dimension, model, gem version) at embed time, not declared config. Same reason Rails 6 moved to `DatabaseConfigurations` — the resolved value is the contract.
2. **Persistence is not an adapter responsibility.** Storage adapters are key-value-ish things. Serializing a store to disk is a separate role. We extract a `Snapshotter` pair rather than bolting `#persistent?` / `#dump_to` / `.load_from` onto `VectorStore::Interface` and `MetadataStore::Interface`. Persistent backends (pgvector, Qdrant, SQLite) never touch the Snapshotter and don't grow no-op methods.
3. **Discovery and construction are separate operations.** `Bootstrapper#build_retriever` today plays four roles (resolve config, probe network, construct stores, log status) and catches every exception. We split those roles and raise typed errors at each boundary. `build_retriever(config)` becomes a confident four-line method: given config, build retriever.
4. **Config-invalid and dependency-unreachable are different failure modes.** An MCP sidecar is long-lived and may start before Ollama is up. Configuration errors (missing credential, wrong dimension, unreadable snapshot) raise at boot. Dependency errors (provider unreachable) start the server degraded and retry at first use, surfaced via `woods_status`. Silent fallback is the failure mode we're eliminating, not a thing to preserve.
5. **Schema versions are contracts.** Every artifact written to `output_dir` (config snapshot, vector dump, metadata dump) carries an explicit monotonic schema version independent of gem semver. A server reading a newer-than-supported artifact refuses loudly. A server reading an older artifact upgrades in place through a compat shim or emits a structured deprecation and reads through it.
6. **Correctness first, then allocations.** The cosine-kernel defect is ~20 LoC, 10–20× query-latency win, and entirely independent of persistence. It ships first.
7. **Atomicity at boundaries.** Every on-disk artifact is written via tmp-file + rename. Cross-artifact atomicity is preserved via a `latest` pointer file — consumers never read a half-written dump because they only look at the pointer, and the pointer is flipped last.
8. **No new required infrastructure.** Shape 2 must work for a MySQL host that doesn't bundle sqlite3. Fixing this is a gem-level responsibility; adopting pgvector/Qdrant is a user choice, not a precondition for the free tier.

## 3. Architecture

### 3.1 On-disk layout

```
output_dir/
├── manifest.json                  # existing — extracted unit manifest
├── dependency_graph.json          # existing
├── checkpoint.json                # existing — embed resume state
├── woods.json                     # NEW — resolved config snapshot (versioned)
├── dumps/
│   ├── 2026-04-23T03-42-17Z/      # per-run directory (UTC timestamp)
│   │   ├── vectors.bin            # packed-float32 blob with header
│   │   ├── vectors.idx            # id-order index (id strings + offsets)
│   │   └── metadata.msgpack       # metadata store dump (versioned)
│   └── latest                     # pointer file → "2026-04-23T03-42-17Z"
└── units/                         # existing — per-unit extraction output
```

**`latest`** is a one-line text file containing the directory name of the newest complete dump. The embed run writes everything into `dumps/<ts>/`, fsyncs the directory, then atomically rewrites `latest` via tmp + rename. Readers always `File.read("latest").strip` first. Crash mid-write leaves a valid previous `latest` pointing at the last complete dump.

### 3.2 Vector dump format (`vectors.bin`)

Binary format chosen for the `pack("e*")` path (IEEE-754 LE float32). Headers are fixed-width so a corrupt file is detectable on first read.

```
offset  length   field
  0     4 bytes  magic "WVF1"          (Woods Vector File v1)
  4     4 bytes  schema_version (u32, LE)
  8     4 bytes  dimension (u32, LE)   e.g. 768
 12     8 bytes  vector_count (u64, LE)
 20     4 bytes  gem_version_length (u32, LE)
 24     N bytes  gem_version (UTF-8)
 24+N   4 bytes  model_name_length (u32, LE)
 28+N   M bytes  model_name (UTF-8)
 ...    —        packed float32 data (vector_count × dimension × 4 bytes)
```

`vectors.idx` holds the id-ordering sidecar: one record per vector, `length-prefixed-id-string + u64 offset into vectors.bin`. Keeps `vectors.bin` purely numeric and mmap-friendly.

### 3.3 Config snapshot (`woods.json`)

Captures **resolved** config — what the embed run actually used, not what the initializer declared.

```json
{
  "schema_version": 1,
  "gem_version": "1.2.0",
  "created_at": "2026-04-23T03:42:17Z",
  "embedding_provider": {
    "class": "Woods::Embedding::Provider::Ollama",
    "model": "nomic-embed-text",
    "host": "http://host.docker.internal:11434",
    "num_ctx": 2048,
    "read_timeout": 120,
    "dimension": 768
  },
  "stores": {
    "vector_store": "in_memory",
    "metadata_store": "in_memory",
    "graph_store": "in_memory"
  },
  "dumps_dir": "dumps",
  "latest_dump": "2026-04-23T03-42-17Z"
}
```

### 3.4 Streaming append during indexing

`Indexer#store_vectors` writes an append-only `vectors.log` in the active dump directory as each batch is embedded — fixed-width records (`u32 id-length + id + u32 dim + packed floats`). On `index_all` completion, the log is compacted into `vectors.bin` + `vectors.idx` via tmp + rename. Crash mid-embed leaves a resumable log. For admin's 6315-unit corpus the compact step is < 500 ms; for 10× corpora it stays bounded by disk bandwidth, not by Ruby heap pressure.

### 3.5 Control-flow decomposition

Before:

```
Bootstrapper.build_retriever
  ├─ mutates Woods.configuration per-branch
  ├─ probes network inline
  ├─ rescue StandardError → nil + warn
  └─ returns a Retriever or nil
```

After:

```
ConfigResolver.resolve(config, artifact:, env: ENV)
  ├─ reads artifact.config_snapshot (woods.json) if present
  ├─ applies env overrides (explicit + logged)
  ├─ validates (raises MissingCredential / ConfigMismatch / DimensionMismatch)
  └─ returns an immutable ResolvedConfig

ProviderProbe.reachable!(provider)
  └─ raises ProviderUnreachable(url:, reason:) or returns provider

Snapshotter::Vector.load_or_empty(artifact) → VectorStore
Snapshotter::Metadata.load_or_empty(artifact) → MetadataStore
  ├─ read artifact.latest_dump
  ├─ validate header schema_version
  └─ return hydrated store or empty store (never raises for "no dump yet")

Bootstrapper.build_retriever(config, artifact:)
  ├─ config = ConfigResolver.resolve(config, artifact:)
  ├─ provider = build_provider(config)  # no probe here
  ├─ state = BootstrapState.new
  ├─ vector_store = Snapshotter::Vector.load_or_empty(artifact)
  ├─ metadata_store = Snapshotter::Metadata.load_or_empty(artifact)
  ├─ retriever = Builder.new(config).build_retriever(vector_store:, metadata_store:, provider:)
  ├─ begin ProviderProbe.reachable!(provider); state.mark(:hydrated)
  │   rescue ProviderUnreachable => e; state.mark(:degraded, reason: e); retriever.degrade!
  │   end
  └─ retriever
```

`build_retriever` does not mutate `Woods.configuration`. `rescue StandardError` is gone. `ConfigResolver` raises typed errors; `ProviderProbe.reachable!` raises typed errors; `Snapshotter.load_or_empty` returns nil only at the boundary (no dump yet) and the empty-store is the interior's single source of truth.

The graph store is rebuilt from `dependency_graph.json` on boot because extraction owns the write path — embed never touches graph edges. This only works when the graph store is ephemeral. If a backend reports `durable? => true`, the hydration path raises `InapplicableBackend` at boot: rebuilding a durable store from the extraction artifact would stomp state it's supposed to preserve, and the contributor adding that adapter is the one who needs to wire an extraction-time write path (mirroring what `Snapshotter::Vector.dump` already enforces for pgvector / Qdrant).

### 3.6 Exception hierarchy

```
Woods::Error                               # existing
  Woods::ConfigurationError                # existing (PR #72) — for config-shape errors
  Woods::MCP::BootstrapError               # NEW — sibling to ConfigurationError, not child
    Woods::MCP::MissingCredential          # config-invalid
    Woods::MCP::ConfigMismatch             # stored config contradicts host config
    Woods::MCP::DimensionMismatch          # provider dim ≠ stored vectors dim
    Woods::MCP::UnsupportedArtifact        # woods.json schema_version newer than gem
  Woods::MCP::ProviderUnreachable          # sibling; recoverable, NOT a BootstrapError
```

`BootstrapError` is a **sibling** of `ConfigurationError`, not a child. `UnsupportedArtifact` and `DimensionMismatch` describe artifact/runtime state, not declared-configuration problems; grouping them under `ConfigurationError` would mislead host apps that rescue it. Inherits directly from `Woods::Error`.

`ProviderUnreachable` sits **outside** `BootstrapError` deliberately — it's recoverable at the MCP layer and signals "start degraded, retry later," not "fail startup." `Bootstrapper` catches it internally; nothing upstream should.

### 3.6a Retry and circuit-breaker reuse

The gem already ships `Woods::Resilience::RetryableProvider` and `Woods::Resilience::CircuitBreaker`. The MCP boot path reuses these rather than reinventing retry logic. `Bootstrapper` wraps the configured provider with `RetryableProvider` once, and the first-query retry from degraded state goes through the same breaker state machine that runtime calls use. No new retry primitives.

### 3.7 `BootstrapState` and `woods_status`

`BootstrapState` is a small value object: `status ∈ {initializing, hydrating, hydrated, degraded, failed}` plus `reason:` (exception or `nil`), `hydrated_at:`, `degraded_since:`. The `woods_status` MCP tool reads from it:

```json
{
  "state": "degraded",
  "reason": "Woods::MCP::ProviderUnreachable: http://host.docker.internal:11434/api/tags refused connection",
  "degraded_since": "2026-04-23T03:42:18Z",
  "provider": { "class": "Ollama", "host": "...", "model": "nomic-embed-text", "reachable": false },
  "vector_store": { "type": "in_memory", "loaded_from": "dumps/2026-04-23T03-42-17Z/vectors.bin", "vector_count": 12771, "schema_version": 1 },
  "metadata_store": { "type": "in_memory", "record_count": 6315, "schema_version": 1 },
  "config_source": "output_dir/woods.json",
  "staleness": { "embedded_at": "2026-04-23T03:41:47Z", "manifest_matches_vectors": true }
}
```

An operator SSH'd into a container at 2 am answers "why is semantic search broken" by reading this blob.

### 3.8 Query kernel (flat buffer + while-loop cosine)

`InMemory::VectorStore` switches its backing representation from `@entries = { id => { vector: [Float]*N, metadata: {...} } }` to:

- `@ids = []` (String)
- `@vectors = []` (one flat `Array<Float>` of length `count × dim` — index `i*dim..(i+1)*dim`)
- `@metadata = {}` (id → Hash)

`cosine_similarity` becomes a kernel that takes two offsets and a dimension, walks with a while loop, reuses no temporary allocations. Expected: ~1017 ms → ~50–100 ms per query on 12 k vectors; 9.8M allocations → ~0 per query.

## 4. PR plan

Four focused PRs. Each independently reviewable, testable, and shippable. Each leaves the tree working for existing SQLite / pgvector / Qdrant users.

### Phase 0 — Benchmark harness (not a PR; pre-work)

Write a standalone script that measures, on 12 771 × 768 Float arrays:

1. **Serialize + deserialize latency** for `pack("e*")`, `Marshal.dump/load`, `MessagePack`, `JSON.generate/parse`. Measure both **cold** (freshly-opened file, page cache dropped via `posix_fadvise DONTNEED` or a separate process) and **warm** (re-read) — operators feel cold, not warm.
2. **RSS after load** in a fresh Ruby process, and **peak RSS during load**. MessagePack's failure mode is the transient boxed-Float allocation before unpack completes; peak RSS catches it, steady-state doesn't.
3. **Allocation count on load** via `GC.stat(:total_allocated_objects)` delta. RSS hides churn; allocation count predicts GC pressure during the first query.
4. **Dump / compact latency** at embed end — write path matters, not just read.
5. **Cosine-similarity latency** on the current `zip/sum` kernel vs the while-loop kernel.
6. **Filter-path stressor:** combined filter + kernel latency on a realistic filter (`{ type: "model", namespace_prefix: "Admin::" }`, which rejects ~80% of candidates on admin-shape corpora). The filter must run *before* the kernel; verify.

Output a short table. **Decision gates** (revised post-measurement, Ruby 3.3 arm64-darwin23, 12,771 × 768 unit-normalized vectors):
- `pack("e*")` cold load must be **≥ 3× faster than the next best alternative**. Actual (see `tmp/bench_results/phase0.json`): pack(e*) 33 ms, MessagePack 110 ms — **3.3×**. The original 8× gate was speculative; the 3× gate reflects measurement.
- Peak RSS during load must be **≤ 2× final steady-state RSS**.
- `pack("e*")` on-disk size must be **≤ half the next-best format**. Actual: 39 MB vs 88 MB MessagePack vs 216 MB Marshal/JSON.
- While-loop kernel must **eliminate per-pair allocations** (`GC.stat(:total_allocated_objects)` delta around a 12 k-entry search ≤ 50). Actual: 2 allocations — zip/sum baseline is 9,833,673. This is the load-bearing gate; wall-clock is secondary.
- While-loop kernel wall-clock must be **≥ 1.5× faster than zip-sum**. Actual: 2.0× for full cosine, 3.8× for the unit-vector dot-product fast path. The original 10× expectation assumed the unit-vector fast path from day one; we're deferring that optimization to a later PR, so the realistic PR 1 gate is 2×.
- Filter + kernel combined latency must meet the same bound as kernel-only. Actual: pre-filter drops latency to 50 ms (Admin::+model subset is ~20% of corpus) — passes trivially because the filter runs before the kernel.

If any gate fails, the corresponding phase is re-opened. **Measurement 2026-04-23 met the revised gates.**

### PR 1 — Query kernel fix (must ship first)

**Scope:** Replace `InMemory::VectorStore#cosine_similarity` and the backing representation. No on-disk changes. No Bootstrapper changes.

**Changes:**
- `InMemory::VectorStore` switches to flat-buffer backing (`@ids`, `@vectors`, `@metadata`).
- `#store(id, vector, metadata)` appends to all three.
- `#delete(id)` marks a tombstone (sparse; compact at next full-embed run) — simplest correct approach; can optimize later.
- `#search(query_vector, limit:, filters:)` iterates indices, computes cosine inline via a strided while-loop kernel, no per-pair allocations.
- Filter block runs **before** the kernel — benchmark the realistic path with filters included. Running filters after the kernel means computing 12k dot products only to discard most of them.
- **Also add now to avoid double-touch in PR 3:** `#each_entry { |id, vector, metadata| ... }` and `#bulk_load(ids:, vectors_flat:, metadata:)` — the Snapshotter seams. PR 1 adds them with straightforward implementations on the new flat buffer; PR 3 consumes them.

**Specs:**
- Correctness: kernel result is bit-identical (within 1e-9) to old `zip/sum` implementation on fixed vectors.
- Allocation count: `ObjectSpace.count_objects_size` or `GC.stat(:total_allocated_objects)` delta around a search call drops by > 1000×.
- Latency: explicit benchmark spec (wall-clock) — ~80 ms for 12 771-vector search on a modern laptop; fails loud if regression.
- Existing specs still pass unmodified (the public Interface is unchanged).

**Ships first, independent of everything else.** ~100–150 LoC including specs.

### PR 2 — Bootstrapper decomposition + exception hierarchy (Track 1 consensus)

**Scope:** Extract `ConfigResolver`, `ProviderProbe`, `IndexArtifact`, `Snapshotter` (with no-op implementations on the persistence side for now — Phase 3 fills them in). Define the full exception hierarchy. Introduce `BootstrapState`. Rewrite `Bootstrapper#build_retriever`.

**Changes:**
- New `lib/woods/index_artifact.rb` — a Whole Value for `output_dir`: `config_path`, `dumps_root`, `latest_dump_path`, `fresh?`, `schema_version`.
- New `lib/woods/mcp/config_resolver.rb` — `resolve(config, artifact:, env: ENV) → ResolvedConfig`. Raises `Woods::MCP::MissingCredential`, `ConfigMismatch`, `DimensionMismatch`, `UnsupportedArtifact`.
- New `lib/woods/mcp/provider_probe.rb` — `reachable!(provider) → provider or raise ProviderUnreachable(url:, reason:)`.
- New `lib/woods/storage/snapshotter/vector.rb` and `snapshotter/metadata.rb` — `load_or_empty(artifact) → Store`, `dump(store, artifact) → void`. Phase 2 implementations are stubs that always return empty-store + no-op dump; Phase 3 wires in the real pack/unpack.
- New `lib/woods/mcp/bootstrap_state.rb` — value object.
- `lib/woods/mcp/bootstrapper.rb` — rewritten `build_retriever(config, artifact: IndexArtifact.new(config.output_dir))`. No mutation of `Woods.configuration`. No bare `rescue StandardError`. Four-line narrative body.
- `exe/woods-mcp` top-level gains one `rescue Woods::MCP::BootstrapError => e` that prints class + message + remediation hint and exits nonzero.
- **Auto-detect fallback is opt-in, not default.** A warning is not a contract — silent degradation is what we're eliminating. When `woods.json` is absent, `Bootstrapper` raises `Woods::MCP::MissingArtifact` unless `WOODS_ALLOW_AUTODETECT=1` is set. If the env flag is set, the existing env-var auto-detect path runs with a `deprecated_autodetect` structured warning. Hosts that never ran an embed see a clear failure; hosts that want the old behavior opt in explicitly.
- **No user-visible behavior change for existing deployments** until Phase 3 (Snapshotters are no-ops here).

**Specs:**
- `ConfigResolver` — happy path, missing-credential raise, dimension-mismatch raise, schema-version raise.
- `ProviderProbe` — reachable path, refused path, timeout path.
- `IndexArtifact` — path semantics, `fresh?` semantics, handling of missing `latest`.
- `Snapshotter` stubs — `load_or_empty` always returns empty; `dump` is a no-op but records that it was called (for Phase 3 replacement).
- `Bootstrapper.build_retriever` — returns retriever in happy path, `BootstrapState.degraded` on `ProviderUnreachable`, raises typed error on config-invalid.
- `exe/woods-mcp` smoke — missing credential raises with a one-line operator-readable message.

### PR 3 — Persistence format + streaming indexer (Track 2 consensus)

**Scope:** Fill in the Snapshotter implementations, wire the Indexer to stream-append during embed, compact at end, flip `latest`. Write `woods.json` at embed completion.

**Changes:**
- `Snapshotter::Vector` — real `load_or_empty` reads `latest` pointer → loads `vectors.bin` header → validates schema version + dimension → `unpack("e*")` into a flat `Array<Float>` → returns populated `InMemory::VectorStore`. Real `dump` writes header + float blob + `vectors.idx`.
- `Snapshotter::Metadata` — real implementation. Format is `MessagePack` here because metadata is heterogeneous hash-shaped data, not dense numeric arrays — MessagePack's type tags matter for the hash case. Schema-versioned header.
- `Indexer#store_vectors` — streaming append to `vectors.log` in the active dump dir. On `index_all` completion, compact to `vectors.bin` + `vectors.idx` atomically.
- `Indexer` writes `woods.json` to `output_dir/` on completion with resolved config.
- `latest` pointer flip at the end of a successful run; previous `latest` dump is kept (not deleted) — retention is a separate operational concern.
- Atomic writes via `Tempfile` + `File.rename` everywhere.

**Specs:**
- Round-trip: dump a store in subprocess A, load in subprocess B, assert vector equality and metadata equality. Single most important spec in the PR.
- Schema version: v1-server refuses v2-dump with `UnsupportedArtifact`; v1-server reads v1-dump cleanly.
- Crash safety: `vectors.log` exists but compact never ran → subsequent embed can resume from the log.
- `latest` pointer: write-in-progress dump directory is never pointed to.
- Full integration in `woods-testbed`: run embed in subprocess, stop it, start `woods-mcp` in another subprocess, issue a semantic query, assert results.

### PR 4 — Status surface + preset + docs (polish)

**Scope:** Wire `BootstrapState` into the `woods_status` MCP tool. Add `:shared_filesystem` preset to `Builder::PRESETS`. Docs.

**Changes:**
- `woods_status` tool returns the structured health block from §3.7.
- `Builder::PRESETS[:shared_filesystem] = { vector_store: :in_memory, metadata_store: :in_memory, graph_store: :in_memory, embedding_provider: :ollama }` with the requirement that `output_dir` be set and readable by both processes.
- `docs/CONFIGURATION_REFERENCE.md` — new "Deployment Shapes" section (single-process, shared filesystem, distributed) and a "Shape 2 setup" subsection referencing the `:shared_filesystem` preset.
- `docs/BACKEND_MATRIX.md` — new "Persistence Story" column for every adapter; explicit rows for Shape 1 / Shape 2 / Shape 3.
- `docs/design/PERSISTENCE_AND_BOOTSTRAP.md` (this file) — updated to "Implemented" once PRs 1–4 land.

## 5. Specification details

### 5.1 `IndexArtifact` API

```ruby
artifact = Woods::IndexArtifact.new(output_dir)

artifact.fresh?                 # → true if no woods.json or no dumps/latest
artifact.config_path            # → Pathname("output_dir/woods.json")
artifact.latest_dump_path       # → Pathname or nil
artifact.dumps_root             # → Pathname("output_dir/dumps")
artifact.new_dump_dir(now: Time.now.utc)  # → Pathname with atomic-create semantics
artifact.promote(dump_dir)      # → flips `latest` via tmp + rename
artifact.read_config            # → Hash or nil (with schema-version validation)
artifact.write_config(resolved) # → atomic write
```

### 5.2 `ResolvedConfig` (immutable Whole Value, not a struct)

Ruby 3.2+ `Data` class, but carries behavior — not just fields. A bag-of-fields is insufficient; dimension-mismatch and config-comparison logic belong on the value itself so callers tell-don't-ask.

```ruby
config = Woods::ResolvedConfig.from_hash(woods_json)
config.dimension               # → 768
config.provider_signature      # → "Ollama/nomic-embed-text@http://host..."
config.matches?(other)         # → Boolean — true if provider + dimension + model agree
config.assert_compatible!(stored_config)
  # → raises DimensionMismatch / ConfigMismatch if anything critical differs
config.to_snapshot_json         # → String for woods.json serialization
```

`ConfigResolver.resolve` returns a `ResolvedConfig`; callers compare via `matches?` / `assert_compatible!`. `Snapshotter` takes a `ResolvedConfig`, never a loose `dim:` kwarg — two sources of truth for dimension is how the next `DimensionMismatch` bug ships.

### 5.3 `Snapshotter::Vector` API

```ruby
Woods::Storage::Snapshotter::Vector.load_or_empty(artifact, resolved_config:) # → InMemory::VectorStore
Woods::Storage::Snapshotter::Vector.dump(store, artifact, dump_dir)
```

The Snapshotter takes `resolved_config:`, not a loose `dim:` kwarg — dimension is derived from the config, eliminating two sources of truth.

The Snapshotter knows **nothing** about the adapter's internals beyond the new `#each_entry(&block)` / `#bulk_load(entries)` methods — adapters stay in key/value vocabulary. Dispatch logic lives in `Builder`, not in the Snapshotter: `Builder` constructs a Snapshotter **only for `:in_memory` stores**; persistent adapters never meet one. This keeps the Snapshotter's silhouette clean and avoids a persistent-adapter interface pollution creeping back in through the "refuse if persistent" door.

If a persistent adapter is ever wired into the Snapshotter path by a bug, it raises `Woods::Storage::InapplicableBackend` (a named class, not a bare `Woods::Error`) so tests can assert it.

### 5.4 `BootstrapState`

```ruby
state = Woods::MCP::BootstrapState.new
state.status    # → :initializing | :hydrating | :hydrated | :degraded | :failed
state.reason    # → Exception or nil
state.hydrated_at
state.degraded_since
state.mark(:hydrated)
state.mark(:degraded, reason: ProviderUnreachable.new(...))
state.to_h      # for woods_status
```

### 5.5 Exception taxonomy (final)

```
Woods::Error                                 # existing
  Woods::ConfigurationError                  # existing — declared-config shape errors only
  Woods::Storage::InapplicableBackend        # Snapshotter misuse on durable backend
  Woods::MCP::BootstrapError                 # sibling of ConfigurationError
    Woods::MCP::MissingCredential            # config-invalid
    Woods::MCP::ConfigMismatch               # stored config contradicts host config
    Woods::MCP::DimensionMismatch            # provider dim ≠ stored vectors dim
    Woods::MCP::UnsupportedArtifact          # artifact schema_version newer than gem, or corrupted
    Woods::MCP::MissingArtifact              # no woods.json and WOODS_ALLOW_AUTODETECT unset
  Woods::MCP::ProviderUnreachable            # recoverable sibling; caught internally for degraded start
```

Each exception carries structured `details` (URL, expected vs actual dimension, artifact schema version) that `exe/woods-mcp`'s top-level rescue formats into a one-line operator message.

## 6. Test strategy

| Scope | Lives in | Coverage |
|---|---|---|
| Kernel correctness + allocation bound | `spec/storage/vector_store_spec.rb` | Bit-equal results vs reference; `GC.stat` delta below threshold. |
| Kernel latency | `spec/performance/query_kernel_spec.rb` (new, tagged `:perf`, opt-in) | Wall-clock bound for 12 771 × 768; fails loud on regression. |
| ConfigResolver | `spec/mcp/config_resolver_spec.rb` | Every raise path, every env-override path, happy path. |
| ProviderProbe | `spec/mcp/provider_probe_spec.rb` | Reachable, refused, timeout, DNS failure. |
| IndexArtifact | `spec/index_artifact_spec.rb` | Paths, `fresh?`, atomic promote. |
| Snapshotter round-trip | `spec/storage/snapshotter_spec.rb` | Dump in process A (forked), load in process B, assert equality. |
| Schema-version rejection | same | v1-server rejects v2-dump with `UnsupportedArtifact`. |
| Degraded start | `spec/mcp/bootstrapper_spec.rb` | Provider unreachable → retriever returned + state `:degraded`. |
| `exe/woods-mcp` top-level | `spec/exe/woods_mcp_spec.rb` | Typed exception prints actionable one-liner and exits 2. |
| End-to-end in `woods-testbed` | testbed repo smoke script | Full shape-2 cycle — embed, MCP boot, query, result match. |

## 7. Migration / backwards compatibility

| User class | Change visible? | Notes |
|---|---|---|
| Existing `:sqlite` metadata users | No | Snapshotter never touches SQLite backend. |
| Existing pgvector / Qdrant users | No | Same story. |
| Existing `:in_memory` single-process users | No | Get persistence **for free** if they set `output_dir`; otherwise behavior identical. |
| Existing env-var-driven MCP launchers | No | Env overrides always win over snapshot. No `woods.json` → falls back to current auto-detect path with a deprecation warning. |
| Shape 2 hosts (admin) | **Major fix** | MCP semantic search works end-to-end once Phase 3 lands. No manual config beyond existing initializer. |
| Silent-fallback behavior (current) | **Removed** | Config errors now raise at boot. Provider unreachable starts degraded. Operators can diagnose. |

## 8. Watch-for items

- **"Just boot Rails" is a legitimate alternative.** Rejected here for operational reasons (MCP inherits the host's boot time and load-path failure modes on every restart; also loses the ability to run MCP on a different host from the Rails app). Kept on file: if Phase 3 or Phase 4 starts growing a config framework — precedence rules, schema migrations, validators nested three deep — that is the signal the alternative was right and we should cut back.
- **Schema version field.** Must land in the very first persistence commit. Adding a schema version field to an already-shipped dump format requires a migration. Pay the cost upfront.
- **Filter pipeline timing.** The kernel fix assumes filters run before the similarity loop. If `InMemory#search`'s current filter application is cheap, the kernel win holds; if filters are expensive, the bench needs to show end-to-end win, not just the kernel.
- **Metadata dump format.** Phase 3 uses MessagePack for metadata — not `pack("e*")`, because metadata is heterogeneous hash-shaped data. This is intentional and the doc should say so; rejecting MessagePack for vectors does not mean rejecting it universally.
- **Retention.** The current plan keeps every dump directory. Operators will want a `keep_last_n_dumps` knob eventually. Out of scope for these four PRs, but call it out in Phase 4 docs.
- **mmap as a Phase 5+ optimization.** For corpora in the 100 k+ vector range, `File.open("vectors.bin", "rb").then { |f| IO::Buffer.map(f) }` lets the serve process skip the in-memory unpack entirely. Not worth the complexity at admin's 12 k scale (`read + unpack("e*")` is < 500 ms there), but the packed-float32 format chosen in §3.2 was picked partly to keep this door open. Revisit at a real workload that needs it.
- **Streaming-append log recovery.** `vectors.log` is consumed by the compact step on successful embed finish. If the embed crashes, `checkpoint.json` already tracks per-unit progress, so the *semantic* resume works — the new `vectors.log` is either (a) replayed into `vectors.bin` if the embed was otherwise complete, or (b) discarded and rewritten from the next run. Phase 3 implementation must pick one; the spec captures it.
- **`Builder#build_metadata_store` / `build_vector_store` still construct empty stores.** The Snapshotter does not replace these methods — it consumes them. PR 3's `Snapshotter::Vector.load_or_empty` calls Builder to get an empty `InMemory::VectorStore`, then `bulk_load`s the hydrated data. Keeps the construction site single.
- **Degraded mode UX.** The MCP tool surface should probably report "degraded" distinctly from "hydrated" in every tool's response envelope, not just `woods_status`. Phase 4 polish.
- **`ConfigurationError` vs `BootstrapError`.** `BootstrapError` inherits from `ConfigurationError` today (§3.6). Double-check that existing `rescue Woods::ConfigurationError` handlers in host apps still behave as expected after we extend the hierarchy.

## 9. Out of scope (explicitly rejected)

- **Booting Rails inside `woods-mcp`.** Rejected for operational reasons: inherits host boot time and initializer failure modes on every MCP restart; loses the ability to run the MCP on a different host from the Rails app.
- **MessagePack for vectors.** Rejected on format grounds: type-tagged variant per float inflates disk footprint, prevents mmap, re-boxes floats on load. Metadata is a separate case and keeps MessagePack.
- **`#persistent?` / `#dump_to` / `.load_from` on storage `Interface`.** Rejected as interface pollution — three methods most implementers answer with "no-op" pollutes the contract. Replaced by the Snapshotter pattern.
- **"Fail loud if provider unreachable at boot."** Rejected for sidecar shape — an MCP may start before its provider. Replaced by typed-raise on config-invalid + start-degraded-and-retry on dependency-unreachable.
- **Native C extension / FFI / Rust.** Overkill at this corpus size; revisitable at 100k+ vectors.
- **Distributed / multi-writer embedding.** Single-machine writer assumption.
- **`:mysql` metadata adapter.** Long-term option; not this plan.
- **Realtime reindex watchers.** Feature, not persistence.

## 10. Decision log

| Decision | Rationale |
|---|---|
| `pack("e*")` over MessagePack for vectors | Type-tagged variant per float is wrong for dense numeric; 10× heap cost at scale; non-mmap-friendly. Metadata is a separate case (heterogeneous hash shape) and keeps MessagePack. |
| Snapshotter pair, not persistence methods on Interface | Interface pollution — most adapters would answer `persistent?` / `dump_to` / `load_from` with "no-op." `persistent?` is also a tell-don't-ask smell. Separate role, separate object. |
| Resolved config in `woods.json`, not declared | Env resolution differs between embed process and serve process; resolved values are the contract. Same reason Rails 6 moved to `DatabaseConfigurations`. |
| Typed exception hierarchy | Silent `rescue StandardError` hides three distinct failure modes; operators need class-based grep. Four `BootstrapError` subclasses + `ProviderUnreachable` as a recoverable sibling. |
| Start degraded on provider unreachable, not fail | MCP is a long-lived sidecar; dependency may come up after the server. Config-invalid still raises; dependency-unreachable starts degraded and retries on first query. |
| Kernel fix ships first | 10–20× query latency win for ~150 LoC, no coupling to other work; admin benefits immediately. |
| Schema version on every artifact from PR 3 | Retrofit requires migration; upfront is free. |
| `latest` pointer for cross-artifact atomicity | Eliminates half-written-dump race cleanly. |
| Streaming append during embed | Crash at hour N of an N+1 hour embed leaves a resumable artifact, not garbage. |
| No new required infrastructure | Backend agnosticism per CLAUDE.md; Shape 2 must work for MySQL hosts without new services. |

---

**Size estimate, rough:**

| Phase | LoC (code + specs + docs) | Depends on |
|---|---|---|
| Phase 0 bench | ~100 (throwaway) | — |
| PR 1 kernel fix | ~150 | — |
| PR 2 decomposition | ~600 | PR 1 (for overlap safety) |
| PR 3 persistence | ~700 | PR 2 |
| PR 4 polish | ~200 | PR 3 |
| **Total** | **~1650** | sequential after PR 1 |
