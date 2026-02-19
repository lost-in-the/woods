# Design & Documentation Review

> **Status as of Feb 2026:** All critical and high bugs resolved. B-007 (token estimation) partially addressed (4.0 divisor). B-011 (cross-encoder) design-only, intentionally deferred. B-012 and B-013 resolved (scope chunking + embedding resumability implemented).

## Review Context

Three specialist reviews were conducted:
1. **Tokenization & Embedding Review** — Token estimation accuracy, embedding pipeline design, chunking strategy
2. **Rails Extraction Architecture Review** — Extractor correctness, coverage gaps, incremental extraction
3. **Technical Documentation Review** — Cross-doc consistency, accuracy, completeness

Date: 2026-02-09

## Findings Summary

| Category | Critical | High | Medium | Low |
|----------|----------|------|--------|-----|
| Code bugs (tracked in backlog) | 2 | 2 | 5 | 3 |
| Documentation accuracy | 3 | 2 | 4 | 2 |
| Cross-doc contradictions | — | 4 | 7 | — |
| Missing documentation | — | 4 | 5 | 2 |
| Design gaps (incl. agentic) | 2 | 5 | 10 | 4 |

---

## Critical Code Bugs

### B-001: ✅ EXTRACTORS key mismatch breaks incremental extraction — RESOLVED
**File:** `lib/codebase_index/extractor.rb`
**Severity:** Critical
**Resolution:** `TYPE_TO_EXTRACTOR_KEY` mapping handles all types. Incremental extraction path is fully functional.

~~The `EXTRACTORS` constant uses plural type keys but `re_extract_unit` looks up by singular type.~~

### B-002: ✅ Missing types in `re_extract_unit` — RESOLVED
**File:** `lib/codebase_index/extractor.rb`
**Severity:** Critical
**Resolution:** `re_extract_unit` uses `TYPE_TO_EXTRACTOR_KEY` mapping covering all 24 extractor types including jobs, mailers, GraphQL types, and rails_source.

~~The `case` statement only handles `:model`, `:controller`, `:service`, `:component`.~~

---

## High Code Bugs

### B-003: API controllers silently omitted — RESOLVED
**File:** `lib/codebase_index/extractors/controller_extractor.rb:30`
**Severity:** High
**Resolution:** Fixed in prior commits. Controller discovery now includes both `ApplicationController.descendants` and `ActionController::API.descendants`, covering API-only controllers.

~~Controller discovery uses `ApplicationController.descendants`, which misses controllers inheriting from `ActionController::API`.~~

### B-004: Config `extractors` default missing types — RESOLVED
**File:** `lib/codebase_index.rb:47`
**Severity:** High
**Resolution:** Fixed in prior commits. Default `extractors` config now includes all shipped extractors: `:models`, `:controllers`, `:services`, `:components`, `:jobs`, `:mailers`, `:graphql`, `:rails_source`.

~~The default `extractors` config only lists 4 types.~~

### B-005: Missing `app/graphql/` in incremental file patterns — RESOLVED
**File:** `lib/tasks/codebase_index.rake`
**Severity:** High
**Resolution:** Fixed in prior commits. Incremental file patterns now include `app/graphql/`, `app/jobs/`, and `app/mailers/` alongside the original directories.

~~The incremental rake task scans for changed files but not `app/graphql/`.~~

---

## Medium Code Bugs

### B-006: Missing `eager_load!` in incremental path — RESOLVED
**Severity:** Medium
**Resolution:** Fixed in prior commits. Incremental extraction path now calls `eager_load!` before processing to ensure newly-added classes are discoverable.

~~Full extraction calls `Rails.application.eager_load!` but the incremental path may skip this.~~

### B-007: Token estimation bias for Ruby code
**File:** `lib/codebase_index/extracted_unit.rb:66-69`
**Severity:** Medium

The `(length / 4.0).ceil` heuristic underestimates token counts for Ruby code by approximately 15-25%. Ruby's syntax (symbols, do/end blocks, method_names_with_underscores) produces more tokens per character than natural language. This affects token budget allocation and chunking decisions.

### B-008: ViewComponent metadata uses Phlex-specific patterns — ADDRESSED
**File:** `lib/codebase_index/extractors/phlex_extractor.rb`
**Severity:** Medium
**Status:** Addressed in this session. A separate `ViewComponentExtractor` was added with ViewComponent-specific metadata patterns (slots, template paths, preview classes), keeping Phlex and ViewComponent extraction independent.

~~The Phlex extractor's metadata structure is Phlex-specific.~~

### B-009: Score fusion in hybrid search is ad-hoc — ADDRESSED
**File:** `docs/RETRIEVAL_ARCHITECTURE.md` (HybridSearch pseudocode)
**Severity:** Medium
**Status:** Addressed in this session. Replaced ad-hoc fusion with Reciprocal Rank Fusion (RRF) implementation in RETRIEVAL_ARCHITECTURE.md.

~~The `merge_candidates` method uses ad-hoc weighted score fusion.~~

### B-010: SQL injection pattern in Pgvector adapter — ADDRESSED
**File:** `docs/RETRIEVAL_ARCHITECTURE.md` (Pgvector `build_where`)
**Severity:** Medium
**Status:** Addressed in this session. Replaced string interpolation with parameterized queries using `$N` placeholder syntax in RETRIEVAL_ARCHITECTURE.md.

~~The `build_where` method interpolates filter values directly into SQL.~~

---

## Low Code Bugs

### B-011: No cross-encoder reranking stage — ADDRESSED
**Severity:** Low (design gap, not bug)
**Status:** Addressed in this session. Added cross-encoder reranking section to RETRIEVAL_ARCHITECTURE.md as an optional pipeline stage with Reranker::Interface, provider comparison, and configuration.

~~The retrieval pipeline goes directly from initial ranking to context assembly with no reranking.~~

### B-012: ✅ Missing chunking for scopes — RESOLVED
**Severity:** Low
**Resolution:** `SemanticChunker` implements scope-level chunking. Model source is split into semantic chunks (associations, validations, scopes, callbacks, methods) for fine-grained embedding and retrieval.

~~Scopes are part of the model's monolithic source.~~

### B-013: ✅ Embedding pipeline has no resumability — RESOLVED
**Severity:** Low
**Resolution:** `Embedding::Indexer` tracks processed unit identifiers and supports `index_incremental` for resumable embedding. Combined with `CircuitBreaker` and `RetryableProvider` for fault tolerance.

~~No checkpoint mechanism to resume from where it left off.~~

---

## Documentation Accuracy Issues

### Critical

**DA-001: Qdrant version mismatch**
`RETRIEVAL_ARCHITECTURE.md` Docker example uses `qdrant/qdrant:v1.7.4`. `BACKEND_MATRIX.md` correctly references v1.12.1. The Docker example should use v1.12.1.

**DA-002: Default vector store contradiction**
`RETRIEVAL_ARCHITECTURE.md` Configuration section defaults `vector_store` to `:qdrant`. Phase 1 design in PROPOSAL.md targets SQLite + FAISS as the zero-dependency starting point. The default should be `:sqlite_faiss` for Phase 1.

**DA-003: Default embedding provider contradiction**
`RETRIEVAL_ARCHITECTURE.md` Configuration defaults `embedding_provider` to `:openai`. The zero-dependency preset uses `:ollama`. For Phase 1 (zero external dependencies), the default should be `:ollama`.

### High

**DA-004: `text-embedding-ada-002` still listed**
`RETRIEVAL_ARCHITECTURE.md` OpenAI provider MODELS hash includes `text-embedding-ada-002`. This is a legacy model — OpenAI recommends `text-embedding-3-small` as replacement. Should be marked as legacy/deprecated.

**DA-005: Pgvector index type mismatch**
`RETRIEVAL_ARCHITECTURE.md` Pgvector `ensure_table` creates an IVFFlat index. `BACKEND_MATRIX.md` recommends HNSW for codebases under 1M vectors. The pseudocode should use HNSW to match the recommendation.

### Medium

**DA-006:** MCP server model detection — CONTEXT_AND_CHUNKING.md claims "The MCP server should detect the connected agent's model and select the appropriate formatter." The MCP protocol does not expose the client model to the server. This should note that model detection is not available via MCP and the format must be configured or defaulted.

**DA-007:** `concern` listed as target type in PROPOSAL.md query classification. But concerns are inlined into their host models during extraction — they don't exist as standalone units. Should be removed from target types.

**DA-008:** Tool naming inconsistent. PROPOSAL.md uses dot notation (`codebase.retrieve`). AGENTIC_STRATEGY.md uses underscore (`codebase_retrieve`). MCP server definition uses bare names (`retrieve`). Should standardize on underscore for tool-use interface and bare names for MCP.

**DA-009:** Tool count mismatch. PROPOSAL.md lists 8 tools. AGENTIC_STRATEGY.md lists 10 tools (added `codebase_graph_analysis` and `codebase_pagerank`). PROPOSAL.md should reference the 10-tool set.

---

## Cross-Document Contradictions

### High

| # | Documents | Contradiction | Resolution |
|---|-----------|---------------|------------|
| CC-001 | RETRIEVAL_ARCHITECTURE ↔ BACKEND_MATRIX | Qdrant version: v1.7.4 vs v1.12.1 | Use v1.12.1 everywhere |
| CC-002 | RETRIEVAL_ARCHITECTURE ↔ PROPOSAL | Default vector store: `:qdrant` vs `:sqlite_faiss` | Phase 1 default = `:sqlite_faiss` |
| CC-003 | RETRIEVAL_ARCHITECTURE ↔ BACKEND_MATRIX | Pgvector index: IVFFlat vs HNSW | Use HNSW per BACKEND_MATRIX recommendation |
| CC-004 | PROPOSAL ↔ AGENTIC_STRATEGY | Tool naming: dot notation vs underscore | Standardize on underscore |

### Medium

| # | Documents | Contradiction | Resolution |
|---|-----------|---------------|------------|
| CC-005 | PROPOSAL ↔ AGENTIC_STRATEGY | Tool count: 8 vs 10 | Update PROPOSAL to reference 10 tools |
| CC-006 | RETRIEVAL_ARCHITECTURE ↔ PROPOSAL | Default embedding: `:openai` vs zero-dependency `:ollama` | Phase 1 default = `:ollama` |
| CC-007 | CONTEXT_AND_CHUNKING ↔ MCP protocol | MCP model detection claimed but not available | Document as limitation |
| CC-008 | PROPOSAL ↔ extraction reality | `concern` listed as target type | Remove — concerns are inlined |
| CC-009 | RETRIEVAL_ARCHITECTURE ↔ BACKEND_MATRIX | ada-002 listed as option vs deprecated | Mark as legacy |
| CC-010 | Various docs | Voyage Code 2 vs Code 3 references | Emphasize Code 3, keep Code 2 as legacy option |
| CC-011 | AGENTIC_STRATEGY ↔ PROPOSAL | MCP tool names: bare vs prefixed | MCP uses bare names, tool-use uses `codebase_` prefix |

---

## Missing Documentation

### High Priority

| # | Topic | Where It Should Go | Description |
|---|-------|--------------------|-------------|
| MD-001 | Agent as Operator | AGENTIC_STRATEGY.md | No design for agents managing extraction, embedding pipeline, or diagnosing failures |
| MD-002 | Multi-Agent Coordination | AGENTIC_STRATEGY.md | No design for multiple agents sharing the same index concurrently |
| MD-003 | Agent Self-Service & Diagnostics | AGENTIC_STRATEGY.md | No design for agents assessing retrieval quality or reporting gaps |
| MD-004 | Concurrent indexing safety | OPERATIONS.md | No documentation of which operations are safe for concurrent access |

### Medium Priority

| # | Topic | Where It Should Go |
|---|-------|--------------------|
| MD-005 | Transitive invalidation between extraction and embedding | OPERATIONS.md |
| MD-006 | Agent-driven operations (how agents trigger pipeline tasks) | OPERATIONS.md |
| MD-007 | Matryoshka dimension reduction | BACKEND_MATRIX.md |
| MD-008 | Vector quantization (scalar/binary) | BACKEND_MATRIX.md |
| MD-009 | `tiktoken` gem for exact OpenAI token counts | CONTEXT_AND_CHUNKING.md |

### Low Priority

| # | Topic | Where It Should Go |
|---|-------|--------------------|
| MD-010 | Scopes and per-concern chunking implementation status | CONTEXT_AND_CHUNKING.md |
| MD-011 | API controller discovery gap | CLAUDE.md |

---

## Design Gaps

### Critical

| # | Gap | Layer | Impact |
|---|-----|-------|--------|
| DG-001 | No agent-as-operator design | Agentic | Agents can query but not manage the index — no extraction triggers, no pipeline monitoring, no failure recovery |
| DG-002 | No concurrent write safety for embedding pipeline | Embedding | Multiple agents or CI processes running extraction/embedding simultaneously could corrupt the index |

### High

| # | Gap | Layer |
|---|-----|-------|
| DG-003 | No multi-agent coordination model | Agentic |
| DG-004 | No retrieval quality feedback loop | Agentic |
| DG-005 | No agent index gap detection | Agentic |
| DG-006 | No operational tools in MCP server | Agentic |
| DG-007 | No self-diagnosis/explainability tools | Agentic |

### Medium

| # | Gap | Layer |
|---|-----|-------|
| DG-008 | RRF not specified for score fusion | Retrieval |
| DG-009 | No cross-encoder reranking stage | Retrieval |
| DG-010 | Token estimation accuracy for Ruby code | Extraction |
| DG-011 | No resumability in embedding pipeline | Embedding |
| DG-012 | No concurrent write safety documentation | Operations |
| DG-013 | Transitive invalidation not bridged (extraction → embedding) | Operations |
| DG-014 | Missing scopes/per-concern chunking implementation | Chunking |
| DG-015 | Agent-to-agent handoff patterns missing | Agentic |
| DG-016 | Token budget coordination across agents | Agentic |
| DG-017 | Shared retrieval cache design missing | Agentic |

### Low

| # | Gap | Layer |
|---|-----|-------|
| DG-018 | No binary/scalar quantization guidance | Storage |
| DG-019 | Matryoshka dimension reduction not documented | Embedding |
| DG-020 | No CI agent extraction → development agent notification pattern | Agentic |
| DG-021 | Retrieval trace explainability tool not designed | Agentic |

---

## Recommendations

### Immediate (documentation fixes — this review)
1. Fix all cross-document contradictions (CC-001 through CC-011)
2. Expand AGENTIC_STRATEGY.md with operator, coordination, and diagnostics sections
3. Update OPERATIONS.md with concurrency safety and agent-driven operations
4. Add accuracy notes to token estimation in CONTEXT_AND_CHUNKING.md
5. Update CLAUDE.md with known limitations

### Next Sprint (code fixes)
1. Fix EXTRACTORS key mismatch (B-001) — incremental extraction is broken
2. Add missing types to `re_extract_unit` (B-002)
3. Fix API controller discovery (B-003)
4. Update config defaults (B-004)

### Future
1. Implement RRF for score fusion (B-009)
2. Add cross-encoder reranking (B-011)
3. Add embedding pipeline resumability (B-013)
4. Add ViewComponent extractor
5. Add serializer/decorator extractor

---

## References

- Existing optimization backlog: `docs/OPTIMIZATION_BACKLOG.md` (29 items, 4 resolved)
- Architecture docs: `docs/README.md` for full index
- Code bugs tracked in: `docs/backlog.json`
