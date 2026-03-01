# CodebaseIndex Documentation

CodebaseIndex is a Ruby gem that extracts structured data from Rails applications for AI-assisted development. Unlike file-level tools, it uses **runtime introspection** — booting the Rails app and querying `ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs — to produce version-accurate representations with inlined concerns, resolved callback chains, and schema-aware associations.

## Current State

All major layers are implemented: 34 extractors (including state machines, events, decorators, database views, caching patterns, factories, test mappings, and more), retrieval pipeline (query classification, hybrid search, RRF ranking), storage backends (pgvector, Qdrant, SQLite), embedding providers (OpenAI, Ollama), two MCP servers (27-tool index server + 31-tool console server), AST analysis, flow extraction, temporal snapshots, Notion export, and evaluation harness. Behavioral depth enrichment adds callback side-effect analysis, resolved Rails config introspection (`BehavioralProfile`), and optional pre-computed request flow maps (`FlowPrecomputer`).

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
| [MCP_HTTP_TRANSPORT.md](MCP_HTTP_TRANSPORT.md) | Design and usage for the HTTP/Rack MCP transport (`exe/codebase-index-mcp-http`) |

## Reference

| Document | Purpose |
|----------|---------|
| [COVERAGE_GAP_ANALYSIS.md](COVERAGE_GAP_ANALYSIS.md) | Gap analysis identifying missing extraction coverage and untapped data uses |
| [TOKEN_BENCHMARK.md](TOKEN_BENCHMARK.md) | Token estimation benchmark — tiktoken comparison, divisor calibration |
| [USE_CASES_AND_FEATURE_GAPS.md](USE_CASES_AND_FEATURE_GAPS.md) | 37 use cases across 4 categories with implementation status |
| [NOTION_INTEGRATION.md](NOTION_INTEGRATION.md) | Sync codebase data to Notion databases (Data Models + Columns schemas) |
| [self-analysis/](self-analysis/) | CodebaseIndex analyzed by itself — extraction output, quality audit |

Historical design documents from the build phase are in [design/](design/) (see [design/README.md](design/README.md)).

## Planned Documentation

| Document | Scope |
|----------|-------|
| ARCHITECTURE.md | Pipeline stages, ExtractedUnit, dependency graph, backend agnosticism |
| EXTRACTOR_REFERENCE.md | Per-extractor output details, edge cases, how to add a new extractor |
| RETRIEVAL_GUIDE.md | Query classification, search strategies, RRF ranking, token budget tuning |
| API_REFERENCE.md | Key public classes and interfaces (may generate from YARD) |

## Documentation Principles

- **Audience-first** — each page targets a specific reader (gem user, contributor, agent)
- **Code is the source of truth** — docs explain _why_ and _how to use_, not implementation details that drift
- **Examples over explanations** — show configuration, show output, show usage
- **No duplicating CLAUDE.md** — `CLAUDE.md` is for agents working _on_ the gem; `docs/` is for users of the gem
