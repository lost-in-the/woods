# Remaining Layers Design: Chunking, Schema, Agentic, Console, Evaluation

**Status:** Approved, ready for implementation planning
**Date:** 2026-02-15
**Scope:** All 5 remaining layers from the README status table (~12K-15.5K lines)

## Overview

Five layers remain unimplemented. This design covers all of them using a two-wave agent team approach (Approach C): 5 agents in Wave 1 for core layers + Console MVP, then 2 agents in Wave 2 expanding the Console server to full spec.

| Layer | Agent | Wave | Est. Lines |
|-------|-------|------|------------|
| Semantic Chunking | `chunking` | 1 | 600-800 |
| Schema Management | `schema` | 1 | 1,000-1,500 |
| Agentic Integration | `agentic` | 1 | 2,500-3,500 |
| Console MCP Phase 0-1 | `console-core` | 1 | 2,000-2,500 |
| Evaluation Harness | `eval` | 1 | 1,500-2,500 |
| Console Tier 2-3 | `console-domain` | 2 | 3,000-4,000 |
| Console Tier 4 + Polish | `console-advanced` | 2 | 1,000-1,500 |

## Architecture

### Two-Wave Execution

**Wave 1** dispatches 5 agents concurrently on non-overlapping files in the main project directory (worktrees don't work with agent teams due to permission boundary restrictions). Each agent creates new directories and files; only `agentic` modifies existing files (`mcp/server.rb`, `retriever.rb`).

**Wave 2** dispatches 2 agents after Wave 1 is committed. Both extend the Console server with new tool tiers. They work in parallel using a registration protocol: each agent adds a `register_tier_N_tools` method to `console/server.rb` without touching other agents' registration methods.

### File Ownership

Wave 1:

| Agent | Exclusive Write Access |
|-------|----------------------|
| `chunking` | `lib/codebase_index/chunking/`, `spec/chunking/` |
| `schema` | `lib/generators/`, `lib/codebase_index/db/`, `spec/db/`, `spec/generators/` |
| `agentic` | `lib/codebase_index/operator/`, `lib/codebase_index/coordination/`, `lib/codebase_index/feedback/`, `spec/operator/`, `spec/coordination/`, `spec/feedback/`, `lib/codebase_index/mcp/server.rb`, `spec/mcp/server_spec.rb`, `lib/codebase_index/retriever.rb`, `spec/retriever_spec.rb` |
| `console-core` | `lib/codebase_index/console/`, `spec/console/`, `exe/codebase-console-mcp` |
| `eval` | `lib/codebase_index/evaluation/`, `spec/evaluation/`, `lib/tasks/codebase_index_evaluation.rake` |

Wave 2:

| Agent | Exclusive Write Access |
|-------|----------------------|
| `console-domain` | `console/tools/tier2.rb`, `console/tools/tier3.rb`, `console/adapters/`, specs for those |
| `console-advanced` | `console/tools/tier4.rb`, `console/sql_validator.rb`, `console/audit_logger.rb`, `console/confirmation.rb`, specs for those |

Conflict rules:
- Only `agentic` modifies `mcp/server.rb`, `retriever.rb`, and their specs
- `eval` creates a separate `lib/tasks/codebase_index_evaluation.rake` (never touches `codebase_index.rake`)
- `chunking` does not modify `text_preparer.rb` or `extracted_unit.rb` (additive only; embedding pipeline integration is a post-wave follow-up)
- `console-core` owns the entire `console/` namespace in Wave 1

## Layer Designs

### 1. Semantic Chunking

Splits ExtractedUnits into embeddable semantic chunks. Replaces whole-unit embedding with boundary-aware pieces.

**Files:**
- `lib/codebase_index/chunking/chunk.rb` — Value object: `content`, `chunk_type`, `parent_identifier`, `content_hash`, `token_count`, `metadata`
- `lib/codebase_index/chunking/semantic_chunker.rb` — Type-aware splitting
- `spec/chunking/chunk_spec.rb`
- `spec/chunking/semantic_chunker_spec.rb`

**Chunking rules by unit type:**

| Type | Chunks |
|------|--------|
| Model | summary, associations, validations, callbacks, scopes, each concern block |
| Controller | per-action (action + relevant filters), shared filters chunk |
| Service/Job/Mailer | summary + method-level for large units, whole-unit for small |
| All types | Units under ~200 tokens stay whole |

**Interface:**
```ruby
chunker = CodebaseIndex::Chunking::SemanticChunker.new
chunks = chunker.chunk(extracted_unit) # => Array<Chunk>
```

### 2. Schema Management

Database provisioning for metadata and embeddings. Works with Rails generators or standalone.

**Files:**
- `lib/generators/codebase_index/install_generator.rb` — Creates migration for `codebase_units` + `codebase_edges`
- `lib/generators/codebase_index/pgvector_generator.rb` — Optional migration for `codebase_embeddings` with `vector()` column
- `lib/generators/templates/` — Migration ERB templates
- `lib/codebase_index/db/migrator.rb` — Standalone migration runner (non-Rails)
- `lib/codebase_index/db/migrations/001_create_units.rb`, `002_create_edges.rb`, `003_create_embeddings.rb`
- `lib/codebase_index/db/schema_version.rb` — Applied version tracking via `codebase_index_schema_migrations` table
- `spec/db/migrator_spec.rb`, `spec/db/schema_version_spec.rb`, `spec/generators/install_generator_spec.rb`

**Dialect support:** Templates produce valid SQL for PostgreSQL, MySQL 8+, and SQLite 3. `vector()` type is PG-only (pgvector generator). JSON columns use TEXT fallback on SQLite.

**Tables:**

```
codebase_units: id, unit_type, identifier, namespace, file_path, source_code (TEXT), source_hash, metadata (JSON), created_at, updated_at
codebase_edges: id, source_id, target_id, relationship, via, created_at
codebase_embeddings: id, unit_id, chunk_type, embedding (vector), content_hash, created_at
```

### 3. Agentic Integration

Extends the MCP server from 11 to 20 tools. Adds operator tools for pipeline management, coordination infrastructure for concurrent access, and feedback loops for retrieval quality improvement.

**Operator tools (5):**

| Tool | Purpose |
|------|---------|
| `pipeline_extract` | Trigger full/incremental extraction with dry-run support |
| `pipeline_embed` | Trigger full/incremental embedding |
| `pipeline_status` | Pipeline status snapshot: last run, unit counts, staleness, errors |
| `pipeline_diagnose` | Classify recent errors (transient vs permanent), suggest remediation |
| `pipeline_repair` | Re-extract/re-embed specific units, clear stale entries |

**Feedback tools (4):**

| Tool | Purpose |
|------|---------|
| `retrieval_rate` | Agent rates a retrieval result (1-5 score + optional comment) |
| `retrieval_report_gap` | Agent reports missing unit for a query |
| `retrieval_explain` | Returns the full RetrievalTrace for a query (classification, strategy, scores) |
| `retrieval_suggest` | Suggests improvements based on accumulated feedback data |

**Supporting infrastructure:**

- `PipelineGuard` — Rate limiting with configurable cooldown between extraction runs
- `StatusReporter` — Reads extraction output metadata, computes staleness metrics
- `ErrorEscalator` — Classifies errors by type, severity, and recoverability
- `PipelineLock` — File-based (standalone), PG advisory (`pg_advisory_lock`), MySQL (`GET_LOCK`) — prevents concurrent extraction/embedding
- `FeedbackStore` — Append-only JSONL file for ratings and gap reports
- `GapDetector` — Heuristics over feedback data: repeated low scores, missing type coverage, stale units
- `RetrievalTrace` — Added to `Retriever`: captures classification, strategy, candidate scores, assembly decisions

### 4. Console MCP Server

A separate MCP server that queries live Rails application state. Communicates with a bridge process running inside the Rails environment via JSON-lines over stdio.

#### Architecture

```
Agent <-> [Console MCP Server] <-> stdio (JSON-lines) <-> [Bridge] <-> [SafeContext] <-> Database
          (host machine)                                   (Rails env)
```

#### Safety Model (5 Independent Layers)

| Layer | Mechanism |
|-------|-----------|
| 1. Connection | Read-only database role or read replica |
| 2. Transaction | Every request wrapped in rolled-back transaction |
| 3. Timeout | Per-statement timeout (PG: `SET statement_timeout`; MySQL: `max_execution_time`) |
| 4. Structured | Tiers 1-3 only accept validated input; no string interpolation |
| 5. Confirmation | Writes require pre-registered actions + human confirmation |

#### Phase 0-1: Bridge + Tier 1 (Wave 1)

**Files:**
- `exe/codebase-console-mcp` — Standalone executable
- `lib/codebase_index/console/server.rb` — MCP protocol handler with `register_tier1_tools` method
- `lib/codebase_index/console/bridge.rb` — Rails runner: boots Rails, accepts JSON-lines, validates inputs
- `lib/codebase_index/console/safe_context.rb` — Transaction rollback, statement timeout, column redaction
- `lib/codebase_index/console/connection_manager.rb` — Docker exec / direct / SSH, heartbeat (30s), reconnect (exponential backoff, max 5 retries)
- `lib/codebase_index/console/model_validator.rb` — Validates model/column names against AR schema
- `lib/codebase_index/console/tools/tier1.rb` — 9 read-only tools

**Tier 1 tools:** `console_count`, `console_sample`, `console_find`, `console_pluck`, `console_aggregate`, `console_association_count`, `console_schema`, `console_recent`, `console_status`

**Connection modes:**
```yaml
# Docker exec (recommended for development)
console:
  mode: docker
  container: my-rails-app-web-1
  command: "bundle exec rails runner lib/codebase_index/console/bridge.rb"

# Direct process (same machine)
console:
  mode: direct
  directory: /path/to/rails/app
  command: "bundle exec rails runner lib/codebase_index/console/bridge.rb"

# SSH (staging/production)
console:
  mode: ssh
  host: staging.example.com
  user: deploy
  command: "cd /var/www/app/current && bundle exec rails runner lib/codebase_index/console/bridge.rb"
```

#### Phase 2-3: Tier 2 + Tier 3 (Wave 2, `console-domain`)

**Tier 2 — Domain-aware tools (9):**
`console_diagnose_model`, `console_data_snapshot`, `console_validate_record`, `console_check_setting`, `console_update_setting` (write, requires confirmation), `console_check_policy`, `console_validate_with`, `console_check_eligibility`, `console_decorate`

**Tier 3 — Analytics tools (10):**
`console_slow_endpoints`, `console_error_rates`, `console_throughput`, `console_job_queues`, `console_job_failures`, `console_job_find` (retry requires confirmation), `console_job_schedule`, `console_redis_info`, `console_cache_stats`, `console_channel_status`

**Job backend adapters:** Sidekiq, Solid Queue, GoodJob — auto-detected or explicitly configured.

**Cache adapters:** Redis, Solid Cache, memory, file — auto-detected.

#### Phase 4-5: Tier 4 + Polish (Wave 2, `console-advanced`)

**Tier 4 — Guarded tools (3):**
- `console_eval` — Arbitrary Ruby, requires human confirmation, timeout (default 10s, max 30s)
- `console_sql` — Read-only SQL (SELECT/WITH...SELECT only), rejects DML/DDL
- `console_query` — Enhanced query builder with validated joins/grouping

**Supporting infrastructure:**
- `SqlValidator` — Parses SQL to reject non-SELECT, validates table names
- `AuditLogger` — Logs all Tier 4 invocations with params, confirmation status, result summary
- `Confirmation` — Human-in-the-loop protocol via MCP

### 5. Evaluation Harness

Measures retrieval quality against ground-truth evaluation queries.

**Files:**
- `lib/codebase_index/evaluation/query_set.rb` — Loads/saves evaluation queries with annotations (expected units, intent, scope)
- `lib/codebase_index/evaluation/evaluator.rb` — Runs queries through Retriever, captures traces, compares to ground truth
- `lib/codebase_index/evaluation/metrics.rb` — Precision@k, Recall, MRR, context completeness, token efficiency
- `lib/codebase_index/evaluation/baseline_runner.rb` — Comparison baselines: naive grep, file-level, random
- `lib/codebase_index/evaluation/report_generator.rb` — JSON report with per-query scores and aggregates
- `lib/tasks/codebase_index_evaluation.rake` — `codebase_index:evaluate`, `codebase_index:evaluate:baseline`
- Specs for all above

**Metrics:**

| Metric | Formula | Purpose |
|--------|---------|---------|
| Precision@k | relevant_in_top_k / k | Are the top results useful? |
| Recall | relevant_found / total_relevant | Did we find everything? |
| MRR | 1 / rank_of_first_relevant | How quickly does a relevant result appear? |
| Context completeness | required_units_present / required_units_total | Does the context have what's needed? |
| Token efficiency | relevant_tokens / total_tokens | How much budget goes to useful content? |

## Testing Strategy

All agents follow strict TDD: write specs first, implement to pass.

| Agent | Test Style | Rails Required |
|-------|-----------|----------------|
| `chunking` | Unit specs with mock ExtractedUnits | No |
| `schema` | Generator specs (temp dirs), migrator specs (temp SQLite) | No |
| `agentic` | Unit specs mocking pipeline components, MCP server integration | No |
| `console-core` | Unit specs. Bridge mocks AR::Base.descendants. Connection manager mocks Process.spawn | No |
| `eval` | Unit specs for metrics math, evaluator with mock Retriever | No |
| `console-domain` | Unit specs mocking Tier 1 tools as building blocks | No |
| `console-advanced` | Unit specs for SQL validation, audit logging, confirmation flow | No |

Each agent verifies before reporting done:
1. `bundle exec rspec spec/<their_dir>/` — new specs pass
2. `bundle exec rspec` — full suite green
3. `bundle exec rubocop <their_files>` — zero offenses

## Commit Strategy

- **Wave 1:** Single atomic commit after all 5 agents verified
- **Wave 2:** Single atomic commit after both agents verified
- **Post-implementation:** Docs update commit (backlog, README status, session state)

## Estimated Totals

| Metric | Wave 1 | Wave 2 | Combined |
|--------|--------|--------|----------|
| New files | 35-40 | 15-20 | 50-60 |
| New lines | 8,000-10,000 | 4,000-5,500 | 12,000-15,500 |
| New specs | 120-160 | 80-100 | 200-260 |
| Expected suite | ~1,280-1,290 | ~1,380-1,390 | ~1,380-1,390 |
