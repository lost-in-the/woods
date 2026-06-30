# Woods Documentation

Woods is a Ruby gem that extracts structured data from Rails applications for AI-assisted development. Unlike file-level tools, it uses **runtime introspection** — booting the Rails app and querying `ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs — to produce version-accurate representations with inlined concerns, resolved callback chains, and schema-aware associations.

## Current State

All major layers are implemented: 34 extractors (including state machines, events, decorators, database views, caching patterns, factories, test mappings, and more), retrieval pipeline (query classification, hybrid search, RRF ranking), storage backends (pgvector, Qdrant, SQLite), embedding providers (OpenAI, Ollama), two MCP servers (29-tool index server + 31-tool console server), AST analysis, flow extraction, temporal snapshots, Notion export, and evaluation harness. Behavioral depth enrichment adds callback side-effect analysis, resolved Rails config introspection (`BehavioralProfile`), and optional pre-computed request flow maps (`FlowPrecomputer`).

What's next: see [COVERAGE_GAP_ANALYSIS.md](COVERAGE_GAP_ANALYSIS.md) for remaining coverage work (HAML/Slim expansion, configuration semantic parsing, Stimulus/Hotwire).

## User Guides

| Document | Purpose |
|----------|---------|
| [GETTING_STARTED.md](GETTING_STARTED.md) | Install, configure, extract, and inspect — end-to-end walkthrough |
| [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md) | All configuration options with defaults, types, and examples |
| [MCP_SERVERS.md](MCP_SERVERS.md) | Index server vs console server — full tool catalog, setup for Claude Code / Cursor / Windsurf |
| [DOCKER_SETUP.md](DOCKER_SETUP.md) | Docker-specific guide — split architecture, volume mounts, path translation, MCP config |
| [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) | Console MCP server setup — stdio, Docker, HTTP/Rack, SSH bridge, tool tiers, safety model |
| [BACKEND_MATRIX.md](BACKEND_MATRIX.md) | Infrastructure selection guide — vector stores, embedding providers, metadata stores, cost modeling |
| [MCP_HTTP_TRANSPORT.md](MCP_HTTP_TRANSPORT.md) | Design and usage for the HTTP/Rack MCP transport (`exe/woods-mcp-http`) |
| [MCP_WORKTREE_SETUP.md](MCP_WORKTREE_SETUP.md) | MCP registration in git worktrees — why tools may be missing for subagents, how to fix it |
| [MCP_REGISTRATION.md](MCP_REGISTRATION.md) | Configure MCP optimally — worktree-safe registration, multi-app naming convention, and console tool-catalog gating to cut token cost |
| [MCP_FEATURE_STATUS.md](MCP_FEATURE_STATUS.md) | What MCP/console features and config knobs exist, what's on by default, and how to check what's active in your app |
| [FAQ.md](FAQ.md) | Frequently asked questions — general, setup, extraction, MCP servers, Docker, storage |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Symptom → cause → fix for extraction, MCP, embedding, storage, Docker, and Notion problems |
| [WHY_WOODS.md](WHY_WOODS.md) | What Woods is, why it exists, before/after examples |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Pipeline stages, ExtractedUnit, dependency graph, retrieval, storage backends, MCP servers |
| [EXTRACTOR_REFERENCE.md](EXTRACTOR_REFERENCE.md) | Per-extractor documentation — what each of the 34 extractors captures, edge cases, example output |
| [AGENT_GUIDE.md](AGENT_GUIDE.md) | Deep reference for AI agents — workflows, full tool table, relationship type catalog, gotchas |
| [MCP_TOOL_COOKBOOK.md](MCP_TOOL_COOKBOOK.md) | Scenario-based MCP tool examples — question → tool → parameters → expected output |
| [RETRIEVAL_GUIDE.md](RETRIEVAL_GUIDE.md) | Query classification, search strategies, RRF ranking, token budget tuning, and troubleshooting |
| [EMBEDDING_MODELS.md](EMBEDDING_MODELS.md) | Picking an Ollama embedding model — context windows, dimensions, tradeoffs, and how the context-length registry works |

## Reference

| Document | Purpose |
|----------|---------|
| [COVERAGE_GAP_ANALYSIS.md](COVERAGE_GAP_ANALYSIS.md) | Gap analysis identifying missing extraction coverage and untapped data uses |
| [TOKEN_BENCHMARK.md](TOKEN_BENCHMARK.md) | Token estimation benchmark — tiktoken comparison, divisor calibration |
| [USE_CASES_AND_FEATURE_GAPS.md](USE_CASES_AND_FEATURE_GAPS.md) | 37 use cases across 4 categories with implementation status |
| [NOTION_INTEGRATION.md](NOTION_INTEGRATION.md) | Sync codebase data to Notion databases (Data Models + Columns schemas) |
| [UNBLOCKED_INTEGRATION.md](UNBLOCKED_INTEGRATION.md) | Sync extraction data to an Unblocked collection — incremental sync, CI setup, API quirks |
| [OBSIDIAN_INTEGRATION.md](OBSIDIAN_INTEGRATION.md) | Export to a self-contained Obsidian vault — graph view, Bases, agent sidecar, safe re-runs |
| [PG_QUERY_SPIKE.md](PG_QUERY_SPIKE.md) | Design doc — evaluation of optional `pg_query` AST identifier extraction for the Console MCP SQL scanner |
| [self-analysis/](self-analysis/) | Woods analyzed by itself — extraction output, quality audit |

Historical design documents from the build phase are in [design/](design/) (see [design/README.md](design/README.md)).

## Benchmarks

The `bench/` directory contains opt-in benchmarks for console-layer components. Run any bench individually:

```bash
bundle exec ruby bench/credential_scanner_bench.rb
bundle exec ruby bench/sql_validator_bench.rb
bundle exec ruby bench/table_gate_bench.rb
```

These benchmarks are **not part of the test suite** and are never run in CI. They exist so performance claims can be proven or disproven without scaffolding from scratch. Each file documents what it measures, how to run it, and rough IPS targets at the top.

## Planned Documentation

| Document | Scope |
|----------|-------|
| API_REFERENCE.md | Key public classes and interfaces (may generate from YARD) |

## Documentation Principles

- **Audience-first** — each page targets a specific reader (gem user, contributor, agent)
- **Code is the source of truth** — docs explain _why_ and _how to use_, not implementation details that drift
- **Examples over explanations** — show configuration, show output, show usage
- **No duplicating CLAUDE.md** — `CLAUDE.md` is for agents working _on_ the gem; `docs/` is for users of the gem
