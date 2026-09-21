# Retrieval Guide

Woods retrieval combines semantic search (vector similarity), keyword search (identifier/text matching), and graph traversal (dependency edges), fusing results with Reciprocal Rank Fusion (RRF) before assembling them into a token-budgeted context string. This is distinct from `search` (exact name/pattern lookup) or `lookup` (direct identifier fetch): retrieval is designed for natural-language questions about behavior, relationships, or concepts that span multiple code units.

---

## The Pipeline at a Glance

```
query
  └─▶ QueryClassifier        classify intent, scope, target type
        └─▶ SearchExecutor   select strategy, run parallel search
              ├── vector search     (semantic similarity)
              ├── keyword search    (identifier/text matching)
              └── graph traversal  (dependency edges)
                └─▶ Ranker         RRF fusion + weighted signal scoring
                      └─▶ ContextAssembler  token-budgeted context string
                            └─▶ RetrievalResult
```

| Stage | Class | Responsibility |
|-------|-------|----------------|
| Classification | `Woods::Retrieval::QueryClassifier` | Detects intent, scope, target type, and framework context from the query text |
| Search | `Woods::Retrieval::SearchExecutor` | Maps classification to a strategy (`:vector`, `:keyword`, `:graph`, `:hybrid`, `:direct`) and executes it |
| Ranking | `Woods::Retrieval::Ranker` | Applies RRF across sources, then weighted signal scoring (semantic, keyword, recency, importance, type match, diversity) |
| Assembly | `Woods::Retrieval::ContextAssembler` | Fills a token budget with ranked units, sectioned into structural / primary / supporting / framework blocks |
| Orchestration | `Woods::Retriever` | Coordinates all four stages; returns a `RetrievalResult` with `context`, `sources`, `strategy`, `tokens_used`, and `trace` |

### PageRank importance

When a graph store supplies PageRank, ranking converts its scores to ordinal
percentiles: the highest-ranked unit receives 1.0 and the lowest receives 1/n,
where n is the number of entries in the PageRank map.
Equal PageRank scores are ordered lexically by identifier before assigning
percentiles. This preserves distinct ordinal weights while making ties independent
of graph insertion order and Ruby version. It does not assign equal importance
weights to tied units. Missing graph entries retain the metadata-based fallback.

### Search strategies

`SearchExecutor` selects one of five strategies based on query classification:

| Strategy | When selected | What it does |
|----------|--------------|-------------|
| `:vector` | `understand`, `debug`, `implement` intents | Embeds query, searches vector store by cosine similarity |
| `:keyword` | `locate`, `reference` intents; `framework` queries | Searches metadata store by extracted keywords |
| `:graph` | `trace` intent | Finds seed identifiers, then walks forward and reverse dependency edges |
| `:hybrid` | `comprehensive` or `exploratory` scope | Runs vector + keyword + graph expansion, deduplicates |
| `:direct` | `locate`/`reference` + `pinpoint` scope | Looks up identifiers directly in metadata store; falls back to keyword |

Graph queries preserve identifier spelling and namespaces: `trace Billing::Invoice`,
`trace ReviewAssignment`, and `trace review_assignment` resolve the subject before
traversing its dependencies and dependents. An exact identifier takes precedence;
an unqualified name without an exact match can seed up to three namespace matches
in storage-identifier order. Use the qualified name to disambiguate. A missing
qualified identifier does not fall back to a different namespace. For unqualified
prose, metadata fallback searches subject terms without instructions such as
`trace`, `follow`, or `who calls`.

Keyword results are scored by how many distinct fields matched (identifier, source, metadata), not by the store's result order. Each matched field adds 0.25, capped at 1.0, so a result matching on identifier and source scores higher than one matching source alone.

---

## Configuring Retrieval

Semantic retrieval requires an embedding provider and a vector store. Configure these in `config/initializers/woods.rb` before embedding. For provider-free ranked retrieval over extraction output, use [explicit lexical mode](#embedding-free-lexical-retrieval) in the MCP process environment instead.

### Presets (recommended)

Four named presets cover the supported deployment scenarios:

```ruby
# Local development: in-memory vectors + SQLite metadata + Ollama.
# Requires sqlite3, a running Ollama service, and a pulled embedding model.
Woods.configure_with_preset(:local)

# Separate embed/query processes sharing output_dir. No sqlite3 gem.
# Requires a running Ollama service and a filesystem visible to both processes.
Woods.configure_with_preset(:shared_filesystem)

# PostgreSQL: pgvector + SQLite metadata + OpenAI.
# Requires pgvector, sqlite3, and an OpenAI API key.
Woods.configure_with_preset(:postgresql) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = { connection: ActiveRecord::Base.connection }
end

# Production: Qdrant + SQLite metadata + OpenAI.
# Requires Qdrant, sqlite3, and an OpenAI API key.
Woods.configure_with_preset(:production) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = {
    url: ENV.fetch('QDRANT_URL'),
    collection: ENV.fetch('WOODS_QDRANT_COLLECTION', 'woods'),
    allow_private_hosts: true # only when QDRANT_URL is deliberately private
  }
end
```

Presets accept a block for overrides:

```ruby
Woods.configure_with_preset(:local) { |config| config.max_context_tokens = 12_000 }
```

### Manual configuration

**MySQL host app (Qdrant required. MySQL has no native vector extension):**

```ruby
Woods.configure do |config|
  config.vector_store         = :qdrant
  config.vector_store_options = {
    url: ENV.fetch('QDRANT_URL'),
    collection: 'myapp',
    allow_private_hosts: true # required for trusted localhost/RFC1918 URLs
  }
  config.metadata_store       = :sqlite
  config.embedding_provider   = :openai
  config.embedding_options    = { api_key: ENV['OPENAI_API_KEY'] }
  config.embedding_model      = 'text-embedding-3-small'
end
```

**PostgreSQL host app (pgvector, all-in-one):**

```ruby
Woods.configure do |config|
  config.vector_store         = :pgvector
  # pgvector takes a live PostgreSQL connection object, not a URL.
  config.vector_store_options = { connection: ActiveRecord::Base.connection }
  config.metadata_store       = :sqlite
  config.embedding_provider   = :openai
  config.embedding_options    = { api_key: ENV['OPENAI_API_KEY'] }
  config.embedding_model      = 'text-embedding-3-small'
end
```

After configuring, generate embeddings before running retrieval:

```bash
bundle exec rake woods:extract
bundle exec rake woods:embed
```

### Input integrity and source-empty units

Embedding validates a native published generation's manifest, type listings and
unit payloads before changing vector storage, metadata or checkpoints. A missing,
corrupt or mismatched listed unit raises `Embedding input incomplete`; repair the
extraction (or run a full `woods:extract`) before retrying embedding.
`WOODS_ALLOW_PURGE=1` permits intentional mass deletion; it does not bypass this
integrity check. Corpus reads hold one generation pin while collecting the input.

Legacy flat indexes retain arbitrary unit filenames and do not require a manifest
or type listing. A `payloads/` directory requires a valid publication pointer;
missing or null pointers refuse embedding even when stale flat files remain.
Malformed JSON now refuses embedding instead of silently dropping
that file. Without an authoritative listing, a missing legacy file still denotes
a deletion; regenerate extraction into the native publication layout for stronger
completeness checks.

When a current unit has no source text to embed, Woods retains its metadata and
removes its superseded vectors, including old chunks. It records the current
source hash without calling the provider; later incremental runs verify that the
unit still prepares no text before accepting a matching no-vector checkpoint.
Empty-vector reconciliation waits until all batches succeed, so a later provider
failure does not retire those old vectors.

---

## Embedding-free lexical retrieval

Opt into ranked retrieval over an extract-only published index:

```bash
WOODS_RETRIEVAL_MODE=lexical bundle exec woods-mcp-start ./tmp/woods
```

For a Ruby-built retriever, set `config.retrieval_mode = :lexical` and supply a
populated metadata store to `Builder#build_retriever`. The packaged MCP server
loads published unit JSON itself; it does not boot Rails or read current source
files. Neither path constructs an embedding provider or vector adapter. If a
no-provider error suggests only OpenAI, Ollama or `search`, explicit lexical
mode is still available from `2.0.0.beta3`: set the variable in the MCP client
configuration and restart that server. Confirm `woods_status.retriever.mode`
is `lexical`; setting it only in a Rails initializer does not configure a
separate MCP process. The
existing `:semantic` mode remains the default; provider failures never switch
modes automatically. A Rails initializer is not loaded by the standalone MCP
process, so set the environment variable in that process's client configuration.

Lexical results use field-aware BM25 scoring over identifiers, source paths,
published source and selected runtime metadata (including callbacks, associations
and validations). Exact full identifiers rank first, with ambiguous typed owners
retained. Other ties are deterministic. Responses name the lexical mode and
matching fields/terms; runtime-field hits include the selected published runtime
values. Lexical Ruby results leave the semantic-only `type_rank_context` table
`nil`; they do not report a global vector rank or vector fallback. The top 20
eligible positive matches form the candidate shortlist for the output budget.
The lexical header reports `sources included`, `candidates considered`, and
`candidate limit: 20`. Included sources count the actual returned entries;
considered candidates count the shortlist after filtering and the limit, not
all matches or all documents examined. This is ranked discovery, not an
exhaustive match listing. Explicit
`types` filters override default exclusions, as in semantic retrieval, and apply
before that limit. A query with no lexical evidence returns no matches; unrelated
graph hubs are never added. Query-seeded graph ranking is evaluation-only.

The budget covers headers, matching explanations and truncation notices using a
labelled character-based estimate, not an exact provider tokenizer. Full source
remains available through `lookup`. Count text is charged before source selection;
final counts do not trigger a second selection pass. Very small budgets can omit
all sources or clip the header itself. Zero candidates means no lexical matches;
positive candidates with zero included sources means no source entry fit the
available budget. The same counts apply to full, compact, outline and scoped
retrieval, agreeing with returned source attribution. The
reader pins one published generation for building and querying its immutable
lexical snapshot, rebuilding after publication. Corrupt units fail explicitly;
they cannot quietly become a successful partial index. Older flat indexes rebuild
on each query because they lack an immutable generation identity.

See [evaluation](EVALUATION.md) for measured query coverage and limits. Lexical
matching cannot infer synonyms absent from the published text; a miss is not proof
that application behavior is absent. Static Woods self-maps can opt into the same
mode but remain static source maps, not resolved Rails runtime evidence.

---

## Running Retrieval

### MCP tool: `codebase_retrieve`

The primary interface for agents. Available with explicit lexical mode over extraction output, or with an embedding provider and completed `rake woods:embed` in the default semantic mode.

```
codebase_retrieve(query: "how does billing work?")
codebase_retrieve(query: "what callbacks run when an order is placed?", budget: 12000)
```

Parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `query` | string | required | Natural-language question |
| `budget` | integer | 8000 | Token budget for context assembly |

The tool returns a formatted context string ready for use in a prompt, along with source attributions. Use `search` for exact name/pattern lookups; use `codebase_retrieve` for conceptual or behavioral questions.

### Ruby API

```ruby
retriever = Woods::Retriever.new(
  vector_store:       vector_store,
  metadata_store:     metadata_store,
  graph_store:        graph_store,
  embedding_provider: embedding_provider
)

result = retriever.retrieve("How does the User model work?")

result.context      # => "Codebase: 42 units...\n\n---\n\n## User (model)\n..."
result.strategy     # => :hybrid
result.tokens_used  # => 4200
result.sources      # => [{ identifier: "User", type: "model", score: 0.91, ... }]
result.trace        # => RetrievalTrace with elapsed_ms, candidate_count, etc.
```

`result.tokens_used` and `result.trace.tokens_used` count the final returned
`context`, including the optional formatter output and type-rank table. Counting
uses the same injected token counter or chars-per-token estimate as assembly;
it does not guarantee an exact count for the downstream model. `budget` limits
context assembly, so postprocessing can make the final count exceed it.

Override the token budget per call:

```ruby
result = retriever.retrieve("explain the checkout flow", budget: 16_000)
```

`Woods.build_retriever` instantiates a retriever from the current configuration:

```ruby
Woods.configure_with_preset(:postgresql) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = { connection: ActiveRecord::Base.connection }
end
retriever = Woods.build_retriever
result    = retriever.retrieve("what validations does Order have?")
```

---

## Degradation Tiers

Retrieval degrades gracefully when components are unavailable. The Retriever itself does not implement explicit fallback tiers, degradation happens naturally through how each component handles errors:

- **Embedding provider unavailable**: `codebase_retrieve` returns a structured configuration error. Check `woods_status` for retrieval readiness.
- **Vector store unavailable**: vector and hybrid strategies fail at query time. Keyword and graph strategies remain available for direct calls to `SearchExecutor`.
- **Metadata store error**: the structural context overview (unit counts by type) is silently omitted; `Retriever#build_structural_context` rescues `StandardError` and returns `nil`. The retrieval result is still returned without the overview.
- **Graph store unavailable**: graph expansion in hybrid strategy produces no graph candidates; vector and keyword candidates are still ranked and returned.

In all cases, errors in individual components produce empty candidate sets for that source rather than raising through the `Retriever`. Configure circuit breakers via `Woods::Resilience::CircuitBreaker` on external providers (Qdrant, OpenAI) for production deployments.

---

## Tuning

### `similarity_threshold`

Deprecated and inert. Woods retains numeric validation (`0.0`–`1.0`) and
readback for compatibility, but setting this option emits a warning. It has not
filtered retrieval results; changing it does not change scores or candidates.
Use explicit type, package or source-path scopes to select eligible units, and
inspect returned ranking evidence to assess relevance. No new score cutoff is
introduced by this deprecation.

### `max_context_tokens`

Sets the default token budget for context assembly. Default: `8000`. Builder
captures this value when constructing semantic or lexical retrievers, including
cached retrievers. The `budget` parameter on `codebase_retrieve` and
`Retriever#retrieve` overrides it per call; omitted and explicitly equal budgets
share a cache entry. Changing configuration affects newly constructed retrievers.
Direct `Retriever.new` callers can pass `default_budget:`; otherwise they retain
8000. Custom MCP collaborators without `default_budget` also retain the legacy
8000 fallback.

The setting applies to the serving process's configuration. It is not embedded
in `woods.json`; a standalone MCP process that does not load the host initializer
uses its own default unless a tool call supplies `budget`. Token accounting uses
the configured estimator, and very small budgets can still include formatting
overhead.

```ruby
config.max_context_tokens = 12_000  # More context per retrieval
```

The `ContextAssembler` carves off 10% for the structural overview first, then splits what's left:

- **Framework context active** (the query mentions Rails/framework keywords, `rails`, `activerecord`, `middleware`, etc.): primary 55%, supporting 25%, framework 20%.
- **No framework context**: primary 65%, supporting 35%, the framework section gets nothing, and its share is not proportionally folded into the other two; the fractions are just different, not rescaled.

Separately, if the supporting section ends up with no candidates (it only ever holds `:graph_expansion` results), its reserved budget is reclaimed into primary rather than wasted.

### `context_format`

Controls how assembled units are formatted. Default: `:markdown`. Valid values: `:claude`, `:markdown`, `:plain`, `:json`.

```ruby
config.context_format = :claude # XML-wrapped output for Claude-style context
config.context_format = :json   # Machine-readable output
```

### Switching embedding models

The embedding model must match between `rake woods:embed` and retrieval. Different models produce vectors with different dimensionalities. Woods raises `Woods::MCP::DimensionMismatch` when they disagree, at embed time for durable stores and at MCP boot for dumps. After changing `embedding_model`, drop the vector store and re-run full extraction and embedding:

```bash
bundle exec rake woods:extract
bundle exec rake woods:embed
```

**OpenAI model dimensions:**

| Model | Dimensions |
|-------|-----------|
| `text-embedding-3-small` (default) | 1536 |
| `text-embedding-3-large` | 3072 |

Woods' pgvector HNSW adapter supports at most 2,000 dimensions. For the large
model, request a supported output width explicitly or choose another backend;
see [pgvector configuration](CONFIGURATION_REFERENCE.md#pgvector-postgresql).

**Ollama default model:** `nomic-embed-text`. Dimensions are detected dynamically on first embed.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `codebase_retrieve` returns no results | Embeddings not generated, or embedding provider not configured | Run `rake woods:embed`; verify `embedding_provider` is set and API key is valid |
| Results are stale or missing recent changes | Index not updated after code changes | Run `rake woods:incremental` (or `rake woods:extract` for route/event changes) |
| Dimension mismatch warning in logs | `embedding_model` changed after embedding was generated | Re-run `rake woods:extract && rake woods:embed` with the new model |
| Empty results for a known class name | Keyword strategy not finding the identifier | Try a conceptual query with `codebase_retrieve`; or use `search` for exact name lookup |
| Very slow retrieval | Large vector index without HNSW index, or Qdrant cold start | For pgvector: create an HNSW index (see `BACKEND_MATRIX.md`). For Qdrant: check collection status |
| `codebase_retrieve` tool listed but disabled | Embedding provider not configured or API key missing | Set `embedding_provider`, run `woods:embed`, and check `woods_status` |
| Results clustered around one type | Diversity penalty insufficient for codebase shape | Use explicit type filters or a more specific query; inspect ranking evidence |

## Explicit package and source-path scopes

Both `codebase_retrieve` and `search` accept `packages` and `source_paths` arrays.
The Ruby API uses the same keyword arguments:

```ruby
retriever.retrieve('How are payments collected?', budget: 1200,
                   packages: ['packs/billing'], source_paths: ['packs/billing/app'])
```

These filters select eligible published units **before candidate limits**. Each
list uses OR; package, path, and type restrictions combine with AND. Empty or
omitted scope lists add no restriction. Existing unscoped calls keep their behavior.

- **Packages:** exact, case-sensitive published nearest owners. A parent package
  excludes its nested packages unless both names are requested. `.` selects only
  root-owned units. Missing ownership does not match a package restriction;
  it can still match a source path. Unknown package names return an argument error;
  a declared package with no eligible units is a valid empty scope.
- **Paths:** application-relative directory prefixes, compared at segment
  boundaries. `packs/billing` includes descendants, including nested packages,
  and excludes `packs/billing_admin`. `.` covers all published application-relative
  paths. Repeated separators and `.` are normalized; internal `..` segments are
  resolved, while attempts to escape the root, absolute paths, Windows paths,
  backslashes, and NUL are rejected. External gem paths and missing paths do not
  match. No host `realpath` or current source-file reads determine ownership.
- **Types and graph:** existing inclusion/exclusion rules remain authoritative.
  Scoped discovery uses actual published unit types, including `gem_source` units
  in the shared `rails_source` directory. Graph seeds and expansion stay within
  eligibility. Existing bare graph edges can still be ambiguous between typed
  units sharing an identifier; scope does not establish a missing edge target type.

`RetrievalResult#applied_scope` reports normalized lists, `eligible_units`,
`candidate_count`, `returned_units`, and `outcome` (`empty_scope`, `no_match`, or
`matched`). A matched candidate need not fit a tiny output budget. Scoped MCP
retrieval exposes this object in `structuredContent.data.applied_scope` and `_meta`,
with typed source provenance in `structuredContent.data.sources`; the budget continues
to apply to the context text. Scoped results omit `type_rank_context`, whose global
rank fields would otherwise describe the wrong population.

Search adds `applied_scope` beside its existing completeness evidence. Zero
eligible units means an empty scope; positive eligibility with a complete zero-match
search means no match. A partial zero-match search remains inconclusive.

### Storage and cost

Scope preparation reads the complete metadata snapshot from the selected store
bundle. Packaged discovery and lexical retrieval keep that read and the query on
one published generation. Discovery's deep-field scan budget applies to matching
after scope preparation; it does **not** cap the initial metadata read.

Vector search enumerates eligible raw vector IDs, including typed and chunk IDs,
and searches every batch of at most 100 IDs before merging the best candidates.
It embeds the query once per vector execution. In-memory, pgvector, and Qdrant
adapters support this without adding package fields or re-embedding old vectors.
Scoped pgvector queries materialize eligible rows before exact distance ranking;
scoped Qdrant requests use exact search. Custom adapters must explicitly support
native ID filters and ID enumeration; unsupported adapters return a degraded
error instead of falling back to global results. Broad scopes can cost more than
ordinary approximate search. Automatic package balancing is not enabled.

See [scope evaluation](EVALUATION.md#explicit-scope-comparison) for the matched
budget replay and its cross-boundary recall tradeoff.

## Compact published evidence and API outlines

`codebase_retrieve` and `Retriever#retrieve` accept an explicit `evidence` mode:

- `full` (default) preserves existing source formatting and budget truncation.
- `compact` chooses complete query-relevant methods and published concern display
  blocks within each ranked unit, then relevant resolved runtime metadata.
- `outline` returns declared method names, kinds, lexical owners and published
  line ranges. It is an API orientation aid, not reconstructed Ruby signatures.

```ruby
retriever.retrieve('How are payments refunded?', budget: 1200, evidence: 'compact')
# MCP:
codebase_retrieve(query: 'How are payments refunded?', budget: 1200, evidence: 'compact')
lookup(identifier: 'Billing::Invoice', type: 'model', evidence: 'outline', budget: 600)
lookup(identifier: 'Billing::Invoice', type: 'model', evidence: 'compact', query: 'refund', budget: 800)
```

Ranking, candidate limits and explicit package/path scopes are unchanged. Selection
uses the original query: method-name term matches weigh more than body matches;
source order breaks ties. With no matching terms, or no lookup query, source order
provides deterministic orientation. Nested blocks and definitions stay inside their
complete containing method. A method that cannot fit is omitted whole; compact mode
never substitutes a broken prefix. If a heredoc body lies outside its method's
syntactic range, a `whole_source_fallback` span retains the complete published
source or omits it whole when it cannot fit. Metadata fields are also included whole. More
unit names fitting in an outline does not establish that their implementation was
shown or that retrieval quality improved.

The existing retrieval token counter also charges compact headers, notices and
source spans. Compact lookup defaults to 2000 estimated tokens, using four
characters per token. These are text-context budgets; MCP JSON envelopes and
structured provenance add transport/output tokens. Very small budgets may return
no evidence text. Check omission counts and increase the budget or request full
source. `query` and `budget` apply only to compact/outline lookup; combining those
modes with `include_source: false` or nonempty `sections` is an argument error.

### Provenance and full-source verification

MCP retrieval exposes evidence under `structuredContent.data.sources[].evidence`;
compact lookup uses `structuredContent.data.evidence`. Ruby retrieval carries the
same data in `result.sources`. Every record includes the typed unit owner, original
published display path, source SHA256, generation status, selected span hashes,
zero-based byte offsets (exclusive end), one-based line ranges and omitted spans.
Span owners are **lexical declarations**, not inferred runtime dispatch owners.

Coordinates are explicitly `published_unit`: they refer to the exact published
`source_code` bytes. Physical source coordinates are unavailable. Model/controller
units may contain synthesized headers or commented inlined concerns; the excerpt
preserves those comments verbatim and labels concern display blocks. Inherited
behavior may be described by runtime metadata without a corresponding source span.
The server never opens host application source files to fill these gaps.

Published lexical retrieval and lookup report the pinned generation when present.
Legacy flat indexes and standalone semantic metadata stores do not establish a
publication generation and report it unavailable. A current reader generation must
not be substituted for an older semantic artifact's unknown generation.

Each record supplies a `full_evidence` lookup call with the actual `type`,
`identifier`, `evidence: 'full'` and `source_sha256`. Pass that hash back to verify
the same source bytes; changed source produces a typed `stale_index` refusal.
Ordinary full lookup remains available without the hash when deliberately
inspecting the newest publication. Optional `type` disambiguates names shared by
multiple unit types and preserves actual types within mixed storage directories.
Full source is never disabled by compact mode. See [evaluation](EVALUATION.md#compact-evidence-comparison-403)
for measured tradeoffs and the limits of returned-unit metrics.

### Source-owner selection remains an offline experiment

The [owner-overlap evaluation](EVALUATION.md#source-owner-overlap-experiment-412)
compares complete-span overlap against current score order. It adds no retrieval
configuration or MCP option. Display paths alone cannot prove original ownership,
especially for inlined concern display; representative runtime task evidence is
still needed before changing which units receive context budget.
