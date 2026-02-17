# Comprehensive Audit: CodebaseIndex Gem

**Date:** 2026-02-15
**Scope:** Full repository — 105 files, ~17,760 LOC, 1,535 specs
**Method:** 5-agent parallel review (code quality, test quality, architecture, MCP validation, production readiness)

---

## 1. Executive Summary

CodebaseIndex is an ambitious, architecturally sound gem with a **mature extraction layer** and **well-designed retrieval pipeline**. The extraction system (13+ unit types, dependency graphs, PageRank, incremental extraction) is production-ready. The retrieval pipeline interfaces are clean and extensible.

However, the gem has **critical blockers** that prevent production deployment:

### Showstoppers

1. **All 51 MCP tools are broken at runtime.** Every handler uses `_server_context:` but the `mcp` gem expects `server_context:`. The spec helper bypasses the gem's dispatch, masking the bug. Zero MCP tools are functional.

2. **5 security vulnerabilities.** SQL injection via pgvector filter keys (C-4), SQL validator bypass via UNION/CTE/comments (C-3), shell injection in ConnectionManager (C-5), ReDoS via unescaped user regex (H-4), and unvalidated `console_eval` confirmation (not server-enforced).

3. **Configuration system is incomplete.** No way to configure vector stores, metadata stores, embedding providers, or logger from the Configuration class. No factory/builder. No `CodebaseIndex.retrieve("query")` convenience API. Users must manually wire 4+ adapters.

### Key Strengths

- **Extraction layer is genuinely excellent.** 13+ unit types, concern inlining, dependency graphs, PageRank scoring, incremental extraction, git metadata — all production-tested.
- **Clean interfaces throughout.** VectorStore::Interface, MetadataStore::Interface, GraphStore::Interface, Provider::Interface — proper contracts with `raise NotImplementedError`.
- **Resilience patterns.** CircuitBreaker, RetryableProvider, PipelineLock, ErrorEscalator — correct patterns (with concurrency caveats).
- **Comprehensive design docs.** 12 documents covering retrieval, operations, backend selection, agentic strategy, flow extraction, chunking.

### Vital Statistics

| Metric | Value |
|--------|-------|
| Total lib files | 93 |
| Total spec files | 87 |
| Total examples | 1,535 (0 failures) |
| MCP tools (index server) | 20 |
| MCP tools (console server) | 31 |
| MCP tools working at runtime | **0** |
| Extractors | 13+ types |
| Storage adapters (vector) | 3 (InMemory, Pgvector, Qdrant) |
| Storage adapters (metadata) | 1 (SQLite only) |
| Storage adapters (graph) | 1 (Memory only) |
| Embedding providers | 2 (OpenAI, Ollama) |
| Security vulnerabilities | 5 (2 Critical, 2 High, 1 Medium) |
| Lib files with zero test coverage | 10 |
| Doc-implementation alignment | 6.5/10 average |

---

## 2. Code Quality Findings

### Critical (5 issues)

**C-1. CircuitBreaker is not thread-safe** — `resilience/circuit_breaker.rb:42-44,108-118`
`@failure_count`, `@state`, `@last_failure_time` are mutable shared state with zero synchronization. In multi-threaded servers (Puma), concurrent calls lose failure counts (`+=1` is not atomic) and race on state transitions. The circuit may never open.
*Fix:* `Mutex` around state transitions, or `Concurrent::AtomicFixnum` for failure count.

**C-2. PipelineLock has TOCTOU race condition** — `coordination/pipeline_lock.rb:41-50`
Check-then-create sequence (`File.exist?` → `File.write`) is not atomic. Two processes can both pass the existence check. `File.write` uses truncate mode, so `rescue Errno::EEXIST` on line 52 can never fire. The "Write lock file atomically" comment is incorrect.
*Fix:* `File.open(path, File::WRONLY | File::CREAT | File::EXCL)` for true atomic creation.

**C-3. SqlValidator is bypassable** — `console/sql_validator.rb:26-53`
Only checks `FORBIDDEN_KEYWORDS` at string start (`/\A\s*#{keyword}\b/i`). Bypass vectors: `SELECT 1 UNION SELECT password FROM users` (UNION not forbidden), writable CTEs (`WITH d AS (DELETE...) SELECT...`), `INTO OUTFILE`, `pg_sleep()` for DoS, comment-based semicolon hiding. No function blocklist.
*Fix:* Check for UNION/INTO/COPY throughout body, strip SQL comments before semicolon check, add function blocklist.

**C-4. Pgvector SQL injection via filter keys** — `storage/pgvector.rb:136-139`
`build_where` interpolates filter keys directly: `metadata->>'#{key}'`. Values are quoted via `@connection.quote`, but keys are raw. Attacker-controlled filter keys (from MCP input) enable injection.
*Fix:* `@connection.quote_column_name(key)` or whitelist validation.

**C-5. ConnectionManager shell injection** — `console/connection_manager.rb:126-141`
All three `build_*_command` methods interpolate config values into shell strings passed to `Open3.popen2(cmd)` (single-string form invokes shell). Container name `foo; rm -rf /` executes arbitrary commands.
*Fix:* Use array form: `Open3.popen2('docker', 'exec', '-i', container, *command.split)`.

### High (8 issues)

**H-1. batch_git_data may exceed ARG_MAX** — `extractor.rb:379-384`
Splats all file paths as CLI args. >1000 files hits kernel limit (~256KB macOS). Large Rails apps easily exceed this.

**H-2. cosine_similarity no dimension validation** — `storage/vector_store.rb:138-146`
`vec_a.zip(vec_b)` silently pads with `nil` on length mismatch → `TypeError`.

**H-3. Configuration not thread-safe** — `codebase_index.rb:121-128`
Module-level mutable accessor. `configure` block yields during threaded Rails boot → partial config visible.

**H-4. ReDoS in search/framework tools** — `mcp/index_reader.rb:135`
`Regexp.new(query)` with user input. Malicious patterns cause catastrophic backtracking.

**H-5. Feedback store no score validation** — `feedback/store.rb:31-39`
Accepts any value for `score` — negatives, strings, nil. Corrupts `average_score`.

**H-6. SafeContext rollback doesn't prevent MySQL DDL** — `console/safe_context.rb:39-47`
MySQL auto-commits DDL regardless of transaction state. Bypassed SqlValidator + DDL = permanent schema changes.

**H-7. PipelineGuard read/write race** — `operator/pipeline_guard.rb:45-49`
JSON state file read-modify-write without locking. Concurrent `record!` calls lose operations.

**H-8. Retriever ignores budget parameter** — `retriever.rb:73,79,102-108`
`budget:` accepted but never forwarded to ContextAssembler. Always uses `DEFAULT_BUDGET = 8000`.

### Medium (14 issues)

| ID | File | Issue |
|----|------|-------|
| M-1 | `retrieval/query_classifier.rb:103` | Allocates stop_words Set on every call |
| M-2 | `resilience/index_validator.rb:161` | `safe_filename` differs from Extractor's — causes false validation errors |
| M-3 | `dependency_graph.rb:46` | `type_index` accumulates duplicates on re-register |
| M-4 | `retrieval/ranker.rb:123,232` | Double metadata_store lookup per candidate |
| M-5 | `observability/health_check.rb:68` | Probe makes real (paid) embedding API call |
| M-6 | `feedback/store.rb:62` | Reads entire JSONL file on every query — no pagination |
| M-7 | `extracted_unit.rb:70` | Memoized `estimated_tokens` goes stale if metadata changes |
| M-8 | `embedding/indexer.rb:121` | Stats incremented then lost on re-raise |
| M-9 | `extracted_unit.rb:72` | Token estimation 3.5 chars/token never validated |
| M-10 | `console/bridge.rb:102` | Dynamic dispatch via `send(:"handle_#{tool}")` |
| M-11 | `storage/qdrant.rb:147` | New HTTP connection per request — no pooling |
| M-12 | `embedding/openai.rb:83` | No configurable timeout on HTTP calls |
| M-13 | `mcp/server.rb:425` | `pipeline_extract` / `pipeline_embed` are stubs returning "triggered" |
| M-14 | `extractor.rb:681` | `constantize` on unit_id without sanitization |

---

## 3. Test Quality Findings

### Coverage Map

| Layer | Spec Coverage | Quality |
|-------|--------------|---------|
| Extractors (8 files) | Full | Good — real behavior with mocked Rails |
| Core (4 files) | Full | Good — real data structures |
| Retrieval (4 files) | Full | Good — SearchExecutor uses real stores |
| Formatting (5 files) | Full | Good — real formatting |
| Embedding (4 files) | Full | Good |
| Evaluation (5 files) | Full | Good |
| MCP Index Server (1 file) | Full | Good — tests tool invocation (but bypasses gem dispatch) |
| Resilience (3 files) | Full | Adequate — no concurrency tests |
| Operator (3 files) | Full | Adequate |
| Chunking (2 files) | Full | Good |
| Storage (5 files) | Full | **Mixed** — InMemory/SQLite real; Pgvector/Qdrant 100% mocked |
| Console Tools (4 files) | Full | **Weak** — hash-building verification only |
| Console Adapters (4 files) | Full | **Weak** — hash-building only |
| Console Server (1 file) | Partial | **Weak** — registration count only |
| Generators (2 files) | Partial | **Weak** — template content only |
| Shared Extractor Modules (3 files) | **None** | Only tested indirectly |
| Rake Tasks (2 files) | **None** | |
| Executables (2 files) | **None** | |
| Railtie | **None** | |

### Files With Zero Coverage (10)

| File | Risk |
|------|------|
| `extractors/ast_source_extraction.rb` | High — shared module |
| `extractors/shared_utility_methods.rb` | High — shared module |
| `extractors/shared_dependency_scanner.rb` | High — shared module |
| `ruby_analyzer/fqn_builder.rb` | Medium |
| `railtie.rb` | Medium |
| `tasks/codebase_index.rake` | Medium |
| `tasks/codebase_index_evaluation.rake` | Low |
| `exe/codebase-index-mcp` | Low |
| `exe/codebase-console-mcp` | Low |
| `version.rb` | Low |

### Anti-Patterns (6 categories)

1. **`instance_variable_get` for assertions** — 4 files test internal state instead of behavior
2. **`allow_any_instance_of`** — `retriever_spec.rb` uses deprecated pattern
3. **100% mock-based tests where real implementations exist** — retriever pipeline, gap_detector, retryable_provider
4. **`sleep` in tests** — circuit_breaker and pipeline_lock specs use wall-clock delays
5. **Unverified doubles** — `double('MetadataStore')` instead of `instance_double` in ranker/assembler specs
6. **No assertions on error content** — multiple specs check `raise_error` without message

### Missing Edge Cases (Priority Order)

**P0 — Security:**
- SQL validator bypass via UNION, CTEs, comments (no bypass tests exist)
- Audit logger tamper resistance (symlinks, permission changes)

**P1 — Correctness:**
- CircuitBreaker concurrent access — no thread-safety test
- PipelineLock concurrent access — no contention test
- Retrieval pipeline integration — no end-to-end test with real components
- SemanticChunker with malformed source (syntax errors, binary, non-UTF8)
- ConnectionManager Docker/SSH success paths — only error paths tested

**P2 — Robustness:**
- Embedding indexer partial batch failure
- Feedback store file corruption (truncated lines)
- GraphStore self-referential edges
- MetadataStore SQLite file-based locking

### Test Quality Metrics

- **Real behavior tests:** ~60% of specs
- **Mock-heavy but acceptable:** ~20%
- **Mock-only / hash-building only:** ~20% (console subsystem, pgvector, qdrant, retriever pipeline)
- **Weakest area:** Console subsystem — 14 spec files that only test hash structure

---

## 4. Architecture & Design Review

### Alignment Scores

| Document | Score | Key Issue |
|----------|-------|-----------|
| CONTEXT_AND_CHUNKING.md | 9/10 | Very well aligned |
| MODEL_EXTRACTION_FIXES.md | 9/10 | All 6 fixes verifiable |
| CONSOLE_SERVER.md | 8/10 | Redaction designed but unwired; MySQL timeout no-op |
| OPTIMIZATION_BACKLOG.md | 8/10 | Status tracking accurate |
| REVIEW_FINDINGS.md | 8/10 | Most bugs fixed; graphql_subscription still missing |
| RETRIEVAL_ARCHITECTURE.md | 7/10 | Pipeline solid, adapter coverage thin |
| FLOW_EXTRACTION.md | 7/10 | Core works, not MCP-integrated |
| AGENTIC_STRATEGY.md | 7/10 | Tools exist but names shifted |
| OPERATIONS.md | 6/10 | Schema/resilience done; transitive invalidation unbuilt |
| PROPOSAL.md | 6/10 | Phase 3+ claims exceed reality |
| docs/README.md | 7/10 | "Complete" overgenerous for some layers |
| BACKEND_MATRIX.md | 4/10 | Extensive docs, minimal adapters |
| **Overall** | **6.5/10** | |

### Unresolved Contradictions

- **CC-004:** BACKEND_MATRIX.md lists "Development default" as SQLite-vss — no SQLite-vss adapter exists
- **CC-007:** PROPOSAL.md Phase 3 claims PostgreSQL/MySQL/SQLite/In-Memory storage — only SQLite MetadataStore exists
- **CC-009:** AGENTIC_STRATEGY.md tool names don't match MCP (`codebase_search` vs `search`, `codebase_lookup` vs `lookup`)
- **CC-003:** PROPOSAL.md says "10 retrieval tools" — MCP server has 20 tools total

### Documented but Unimplemented

1. Cost modeling code (BACKEND_MATRIX.md formulas — no CostCalculator class)
2. ResponseCodeMapper (FLOW_EXTRACTION.md design)
3. MySQL statement timeout (SafeContext comments reference it — implementation is `rescue nil`)
4. `trace_flow` MCP tool (AGENTIC_STRATEGY.md)
5. Transitive invalidation (OPERATIONS.md cascade algorithm)
6. `pipeline_extract`/`pipeline_embed` actual execution (MCP tools are stubs)

### Undocumented Features

1. 5 extractors not in architecture docs: Serializer, Manager, Policy, Validator, ViewComponent
2. RetrievalTrace diagnostic struct
3. Console job adapters (Sidekiq, SolidQueue, GoodJob, Cache)
4. Embedding::Indexer checkpoint resumability
5. SqlValidator and AuditLogger integration

### Backend Agnosticism Assessment: 4/10

CLAUDE.md says "Never hardcode or default to a single backend." Reality:

| Store Type | Implemented | Missing from Docs |
|-----------|-------------|-------------------|
| VectorStore | InMemory, Pgvector, Qdrant | FAISS, Chroma, Milvus, Pinecone |
| MetadataStore | SQLite **only** | PostgreSQL, MySQL, In-Memory |
| GraphStore | Memory **only** | PostgreSQL, MySQL, Neo4j |

The **interfaces are well-designed** — adding backends is structurally supported. But claiming backend agnosticism with one MetadataStore adapter is misleading.

---

## 5. MCP Tools Validation

### Critical: All 51 Tools Broken at Runtime

**Root cause:** Every tool handler uses `_server_context:` (underscore-prefixed). The `mcp` gem v0.6.0 looks for `server_context:` (no underscore) via `accepts_server_context?`:

```ruby
# mcp gem checks for :server_context, not :_server_context
parameters.any? { |type, name| type == :keyrest || name == :server_context }
```

**Index server (20 tools):** Handlers have `|identifier:, _server_context:, ...|` with no `**kwargs`. Gem doesn't find `server_context:`, calls without it → `ArgumentError: missing keyword: _server_context`.

**Console server (31 tools):** Handlers have `|_server_context:, **args|`. Gem finds `:keyrest`, passes `server_context: value` — but handler expects `_server_context:`, not `server_context:`. The `server_context` value is captured by `**args`, `_server_context` remains missing → `ArgumentError`.

**Why specs pass:** The spec helper at `spec/mcp/server_spec.rb:588` calls handlers directly:
```ruby
tool_class.call(**args, _server_context: {})  # Bypasses gem dispatch
```

**Fix:** Rename all `_server_context:` to `server_context:` across both servers.

### Tool-by-Tool Status

#### Index Server — 20 tools

| Tool | Broken | Additional Issues |
|------|--------|------------------|
| `lookup` | Yes | — |
| `search` | Yes | ReDoS vulnerability (user regex unescaped) |
| `dependencies` | Yes | — |
| `dependents` | Yes | — |
| `structure` | Yes | — |
| `graph_analysis` | Yes | — |
| `pagerank` | Yes | — |
| `framework` | Yes | ReDoS vulnerability |
| `recent_changes` | Yes | — |
| `reload` | Yes | Safe for repeated calls |
| `codebase_retrieve` | Yes | Fallback message references wrong tool name (`codebase_search` vs `search`) |
| `pipeline_extract` | Yes | **Stub** — returns "triggered" without running extraction |
| `pipeline_embed` | Yes | **Stub** — returns "triggered" without running embedding |
| `pipeline_status` | Yes | — |
| `pipeline_diagnose` | Yes | Creates synthetic error, doesn't use real error classification |
| `pipeline_repair` | Yes | `reset_cooldowns` is a pure no-op |
| `retrieval_rate` | Yes | No score range validation |
| `retrieval_report_gap` | Yes | — |
| `retrieval_explain` | Yes | — |
| `retrieval_suggest` | Yes | — |

#### Console Server — 31 tools (Tiers 1-4)

All 31 tools broken by `_server_context:`. Additional findings:

- **Tier 1 (9 tools):** Read-only, structurally sound
- **Tier 2 (9 tools):** `console_update_setting` has `requires_confirmation` flag but server doesn't enforce it
- **Tier 3 (10 tools):** `console_job_find` same confirmation gap
- **Tier 4 (3 tools):** `console_eval` timeout enforcement delegated to bridge, not validated server-side; `console_sql` subject to SqlValidator bypass (see C-3)

### Security Concerns

1. **ReDoS** (HIGH) — `search` and `framework` tools compile user input as regex
2. **SQL Validator bypass** (MEDIUM) — UNION, writable CTEs, pg_sleep, comment evasion
3. **`console_eval` confirmation** (BY DESIGN, HIGH RISK) — `requires_confirmation` not server-enforced
4. **Model name injection** (LOW) — User-provided model names passed to bridge without validation

### Resources & Templates

- 2 resources (`codebase://manifest`, `codebase://graph`) — OK
- 2 resource templates (`codebase://unit/{id}`, `codebase://type/{type}`) — OK

---

## 6. Production Readiness & Capabilities

### Production Readiness Scores

| Category | Score | Rationale |
|----------|-------|-----------|
| Extraction Layer | **5/5** | Complete, well-tested, production-validated |
| Retrieval Layer | **3/5** | Pipeline works, but only InMemory + SQLite backends |
| Storage Adapters | **3/5** | Interfaces clean; pgvector/Qdrant 100% mocked, no integration tests |
| Embedding Providers | **3/5** | Ollama + OpenAI work; no timeout config, missing Voyage |
| MCP Integration | **1/5** | 51 tools, all broken at runtime |
| Observability | **3/5** | StructuredLogger, HealthCheck, Instrumentation exist but not systematically wired |
| Resilience | **4/5** | Correct patterns, CircuitBreaker not thread-safe |
| Configuration | **2/5** | Only manages extraction settings; no backend selection, no presets |
| Documentation | **4/5** | Excellent design docs; no user-facing setup guide |
| Testing | **4/5** | 1535 specs; console subsystem weak, no integration tests for backends |
| Gem Packaging | **2/5** | Placeholder author/email, missing executable, `rails` dep too broad |
| Developer Setup | **2/5** | No quickstart guide, manual adapter wiring required |

### Critical Gaps

1. **Configuration system** — No way to configure backends from Configuration class
2. **No wiring layer** — No factory/builder to produce a working Retriever from config
3. **No convenience API** — No `CodebaseIndex.retrieve("query")`
4. **Gemspec issues** — Placeholder metadata, `rails >= 6.1` pulls full framework
5. **pgvector SQL safety** — Filter keys interpolated without quoting
6. **No backend integration tests** — Pgvector/Qdrant never tested against real databases

---

## 7. Complete Capability Catalog

### What Works End-to-End Today (No External Deps)

| Capability | Command/Method | Notes |
|-----------|---------------|-------|
| Extract Rails codebase | `rake codebase_index:extract` | 13+ unit types, concern inlining, git metadata |
| Incremental extraction | `rake codebase_index:incremental` | Git-based change detection |
| Query via MCP | `exe/codebase-index-mcp` | **Currently broken** (fix: rename `_server_context`) |
| Validate index | `rake codebase_index:validate` | File integrity check |
| View stats | `rake codebase_index:stats` | Extraction statistics |
| Clean index | `rake codebase_index:clean` | Remove output |
| Graph analysis | `GraphAnalyzer.new(graph)` | Orphans, hubs, cycles, bridges |
| Flow analysis | `FlowAssembler.new(units_map)` | Request flows with AST analysis |
| Evaluate retrieval | `rake codebase_index:evaluate` | Precision@k, Recall, MRR metrics |

### What Works with Minimal Setup (SQLite + Ollama)

| Capability | Setup Required | Notes |
|-----------|---------------|-------|
| Semantic retrieval | Manual Retriever wiring | InMemory VectorStore + SQLite MetadataStore + Ollama |
| Embed units | Manual Indexer wiring | Ollama provider + InMemory VectorStore |
| Format for LLMs | None | Claude, GPT, Generic, Human adapters |

### What Requires Infrastructure

| Capability | Infrastructure | Notes |
|-----------|---------------|-------|
| Persistent vectors | PostgreSQL + pgvector | Pgvector adapter (needs integration testing) |
| Scalable vectors | Qdrant server | Qdrant adapter (needs integration testing) |
| OpenAI embeddings | OPENAI_API_KEY | OpenAI provider with retry/circuit breaker |
| Console tools | Running Rails app | 31 tools via bridge protocol |

### Not Yet Functional

| Capability | Status | Blocker |
|-----------|--------|---------|
| All MCP tools | Broken | `_server_context:` naming mismatch |
| Pipeline execution via MCP | Stub | `pipeline_extract`/`pipeline_embed` don't execute |
| Configuration presets | Unbuilt | `configure_with_preset` documented but not implemented |
| MySQL MetadataStore | Unbuilt | Only SQLite adapter exists |
| PostgreSQL/MySQL GraphStore | Unbuilt | Only Memory adapter exists |
| Cost modeling | Design only | BACKEND_MATRIX.md formulas, no code |
| Transitive invalidation | Design only | OPERATIONS.md algorithm, no code |
| Flow analysis via MCP | Unwired | FlowAssembler exists, no MCP tool |

---

## 8. Critical Path to Production

### Phase 1: Unblock MCP (1 day)

1. **Rename `_server_context:` → `server_context:` everywhere** — fixes all 51 tools
2. **Update spec helper** — change `_server_context: {}` to `server_context: {}`
3. **Add integration test** — test at least one tool through the gem's actual dispatch

### Phase 2: Fix Security (2-3 days)

4. **Fix pgvector SQL injection** — quote filter keys, validate vector elements
5. **Harden SqlValidator** — block UNION, INTO, COPY, writable CTEs; strip SQL comments; add function blocklist
6. **Fix ConnectionManager shell injection** — use array form of Open3.popen2
7. **Fix ReDoS** — `Regexp.escape(query)` or `Regexp.timeout` (Ruby 3.2+)
8. **Validate feedback score** — enforce 1-5 range

### Phase 3: Fix Concurrency (1-2 days)

9. **Add Mutex to CircuitBreaker** — synchronize state transitions
10. **Fix PipelineLock atomic creation** — use `File::EXCL` flag
11. **Add file locking to PipelineGuard** — prevent state file races

### Phase 4: Complete Configuration (3-5 days)

12. **Extend Configuration class** — backend selection, connection strings, provider config
13. **Build factory/builder** — `CodebaseIndex.build_retriever` from config
14. **Add convenience API** — `CodebaseIndex.retrieve("query")`
15. **Implement presets** — `:local`, `:postgresql`, `:production`

### Phase 5: Production Hardening (3-5 days)

16. **Fix gemspec** — real metadata, `railties` dep, add `codebase-console-mcp` to executables
17. **Integration tests** — pgvector against real PostgreSQL, Qdrant against real Qdrant
18. **Wire FlowAssembler into MCP** — add `trace_flow` tool
19. **Make pipeline tools functional** — `pipeline_extract`/`pipeline_embed` should actually execute
20. **Wire SafeContext redaction** — connect the existing method to tool implementations
21. **Add HTTP timeouts** — Ollama, OpenAI, Qdrant clients
22. **Batch git args** — prevent ARG_MAX overflow in `batch_git_data`

---

## 9. Cross-Reference Validation

Findings from multiple agents that corroborate each other:

| Finding | Code Quality | Test Quality | MCP Validator | Architecture | Production |
|---------|:---:|:---:|:---:|:---:|:---:|
| `_server_context:` bug (all MCP tools broken) | | | C | | |
| CircuitBreaker not thread-safe | C-1 | P1 gap | | | Score 4/5 |
| SqlValidator bypassable | C-3 | P0 gap | Security | | |
| Pgvector SQL injection | C-4 | | | | Gap #4 |
| Shell injection in ConnectionManager | C-5 | | | | |
| ReDoS in search tools | H-4 | | Security HIGH | | |
| Pipeline tools are stubs | M-13 | | No-ops found | Documented-not-built | |
| Config system incomplete | H-3 | | | | Gap #1 (Critical) |
| Console specs only test hashes | | Weak coverage | | | |
| Backend agnosticism gap | | | | 4/10 score | Matrix shows gaps |
| FlowAssembler not MCP-wired | | | Missing tool | 7/10 alignment | Not functional |
| SafeContext redaction unwired | | | | 8/10 gap | |
| Budget parameter ignored | H-8 | | | | |
| Retriever pipeline no integration test | | P1 gap | | | Score 3/5 |

---

## Appendix A: File Inventory

### By Layer (93 lib files)

| Layer | Files | Key Components |
|-------|-------|---------------|
| Core | 5 | codebase_index.rb, extractor.rb, extracted_unit.rb, dependency_graph.rb, graph_analyzer.rb |
| Extractors | 13 | model, controller, service, job, mailer, phlex, graphql, rails_source, view_component, serializer, manager, policy, validator |
| Shared Modules | 3 | ast_source_extraction, shared_utility_methods, shared_dependency_scanner |
| Storage | 7 | vector_store (interface + InMemory + Pgvector + Qdrant), metadata_store (interface + SQLite), graph_store (interface + Memory) |
| Retrieval | 5 | retriever, query_classifier, search_executor, ranker, context_assembler |
| Embedding | 4 | indexer, text_preparer, ollama provider, openai provider |
| Formatting | 5 | base, claude, gpt, generic, human |
| MCP | 3 | server, index_reader, resources |
| Console | 13 | server, bridge, connection_manager, safe_context, model_validator, sql_validator, audit_logger, confirmation, tools (T1-T4), adapters (4) |
| Resilience | 3 | circuit_breaker, retryable_provider, index_validator |
| Operator | 3 | status_reporter, error_escalator, pipeline_guard |
| Observability | 3 | instrumentation, structured_logger, health_check |
| Coordination | 1 | pipeline_lock |
| Feedback | 2 | store, gap_detector |
| Chunking | 2 | chunk, semantic_chunker |
| Evaluation | 5 | query_set, metrics, evaluator, baseline_runner, report_generator |
| Schema/DB | 5 | schema_version, migrator, 3 migrations |
| Generators | 2 | install_generator, pgvector_generator |
| Flow/AST | 6 | flow_assembler, flow_document, ruby_analyzer (parser, method_extractor, operation_extractor, fqn_builder) |
| Tasks | 2 | codebase_index.rake, codebase_index_evaluation.rake |
| Misc | 2 | railtie, version |

### MCP Tool Inventory (51 tools)

**Index Server (20):** lookup, search, dependencies, dependents, structure, graph_analysis, pagerank, framework, recent_changes, reload, codebase_retrieve, pipeline_extract, pipeline_embed, pipeline_status, pipeline_diagnose, pipeline_repair, retrieval_rate, retrieval_report_gap, retrieval_explain, retrieval_suggest

**Console Server (31):** T1 (9): count, sample, find, pluck, aggregate, association_count, schema, recent, status | T2 (9): diagnose_model, data_snapshot, validate_record, check_setting, update_setting, check_policy, validate_with, check_eligibility, decorate | T3 (10): slow_endpoints, error_rates, throughput, job_queues, job_failures, job_find, job_schedule, redis_info, cache_stats, channel_status | T4 (3): eval, sql, query

### Test Inventory (87 spec files, 1,535 examples)

Coverage by confidence level:
- **High confidence (real behavior):** ~55 spec files
- **Adequate (mocks with logic):** ~18 spec files
- **Low confidence (hash-building / registration only):** ~14 spec files
- **Zero coverage:** 10 lib files
