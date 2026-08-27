# Woods Documentation

Woods is a Ruby gem that extracts structured data from Rails applications for AI-assisted
development. It uses **runtime introspection**, not file parsing: it boots the Rails app and
queries `ActiveRecord::Base.descendants`, `Rails.application.routes`, and the reflection APIs.
The output is version-accurate: inlined concerns, resolved callback chains, and schema-aware
associations.

## Current State

All major layers are implemented:

- **Extraction**: 34 extractors + 7 helpers, covering models, controllers, jobs, state machines,
  events, decorators, database views, caching patterns, factories, test mappings, and more.
- **Retrieval**: query classification, hybrid search, RRF ranking.
- **Storage**: pgvector, Qdrant, and SQLite backends.
- **Embedding**: OpenAI and Ollama providers.
- **MCP servers**: an Index Server (29 tools: 14 always-on + 15 that register conditionally on
  wiring) and a Console Server (31 tool schemas, 9 executable by default, 11 with
  `console_embedded_read_tools` enabled).
- **Analysis**: AST analysis, flow extraction, temporal snapshots.
- **Export**: Notion and Obsidian sync, plus an evaluation harness for retrieval quality.

Behavioral depth enrichment adds callback side-effect analysis, resolved Rails config
introspection (`BehavioralProfile`), and optional pre-computed request flow maps
(`FlowPrecomputer`).

## Getting Started

| Document | Purpose |
|----------|---------|
| [GETTING_STARTED.md](GETTING_STARTED.md) | Install, configure, extract, and inspect: end-to-end walkthrough |
| [UPGRADING_TO_2.md](UPGRADING_TO_2.md) | Upgrading to Woods 2.0: breaking identifier changes, re-index steps, store/dimension migration, MCP client requirements |
| [WHY_WOODS.md](WHY_WOODS.md) | What Woods is, why it exists, before/after examples |
| [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md) | All configuration options with defaults, types, and examples |
| [FAQ.md](FAQ.md) | Frequently asked questions: setup, extraction, MCP servers, Docker, storage |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Symptom to cause to fix, for extraction, MCP, embedding, storage, Docker, and Notion |

## Reference

| Document | Purpose |
|----------|---------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Pipeline stages, ExtractedUnit, dependency graph, retrieval, storage backends, MCP servers |
| [EXTRACTOR_REFERENCE.md](EXTRACTOR_REFERENCE.md) | Per-extractor documentation: what each of the 34 extractors captures, edge cases, example output |
| [INCREMENTAL_EXTRACTION.md](INCREMENTAL_EXTRACTION.md) | The equivalence contract for `woods:incremental`, the path-to-extractor dispatch inventory, and the differential harness |
| [WATCH_DAEMON.md](WATCH_DAEMON.md) | `woods:watch`, the resident daemon that keeps the index current: restart triggers, failure posture, placement trade-offs |
| [RETRIEVAL_GUIDE.md](RETRIEVAL_GUIDE.md) | Query classification, search strategies, RRF ranking, token budget tuning |
| [BACKEND_MATRIX.md](BACKEND_MATRIX.md) | Infrastructure selection guide: vector stores, embedding providers, metadata stores, cost modeling |
| [EMBEDDING_MODELS.md](EMBEDDING_MODELS.md) | Picking an Ollama embedding model: context windows, dimensions, tradeoffs |
| [TOKEN_BENCHMARK.md](TOKEN_BENCHMARK.md) | Token estimation benchmark: tiktoken comparison, divisor calibration |

## Agents and MCP

| Document | Purpose |
|----------|---------|
| [AGENT_GUIDE.md](AGENT_GUIDE.md) | Deep reference for AI agents: workflows, full tool table, relationship type catalog, gotchas |
| [MCP_SERVERS.md](MCP_SERVERS.md) | Index server vs console server: full tool catalog, setup for Claude Code / Cursor / Windsurf |
| [MCP_TOOL_COOKBOOK.md](MCP_TOOL_COOKBOOK.md) | Scenario-based MCP tool examples: question to tool to parameters to expected output |
| [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) | Console MCP server setup: stdio, Docker, HTTP/Rack, SSH bridge, tool tiers, safety model |
| [MCP_HTTP_TRANSPORT.md](MCP_HTTP_TRANSPORT.md) | The HTTP/Rack MCP transport (`exe/woods-mcp-http`) |
| [MCP_WORKTREE_SETUP.md](MCP_WORKTREE_SETUP.md) | MCP registration in git worktrees: why tools may be missing for subagents, how to fix it |

## Integrations

| Document | Purpose |
|----------|---------|
| [DOCKER_SETUP.md](DOCKER_SETUP.md) | Docker-specific guide: split architecture, volume mounts, path translation, MCP config |
| [NOTION_INTEGRATION.md](NOTION_INTEGRATION.md) | Sync codebase data to Notion databases (Data Models + Columns schemas) |
| [UNBLOCKED_INTEGRATION.md](UNBLOCKED_INTEGRATION.md) | Sync extraction data to an Unblocked collection: incremental sync, CI setup, API quirks |
| [OBSIDIAN_INTEGRATION.md](OBSIDIAN_INTEGRATION.md) | Export to a self-contained Obsidian vault: graph view, Bases, agent sidecar, safe re-runs |

## Design

Historical build-phase design documents were removed for the 2.0 release: see
[design/README.md](design/README.md) for the one that remains live, and
`git log --follow -- docs/design/` for the rest. `backlog.json` in this directory is the
maintainers' bug and work ledger, not user documentation.

| Document | Purpose |
|----------|---------|
| [design/MCP_2026_STRATEGY.md](design/MCP_2026_STRATEGY.md) | MCP 2026-07-28 adoption: what changed in the protocol, what the SDK implements, compatibility matrix for legacy clients and old Ruby |

## Self-Analysis

[self-analysis/](self-analysis/): Woods run against its own codebase: architecture overview,
call graph, data flow, and dependency map, each as a Mermaid diagram.

## Benchmarks

The `bench/` directory contains opt-in benchmarks for console-layer components. Run any bench
individually:

```bash
bundle exec ruby bench/credential_scanner_bench.rb
bundle exec ruby bench/sql_validator_bench.rb
bundle exec ruby bench/table_gate_bench.rb
```

These benchmarks are **not part of the test suite** and never run in CI. They exist so
performance claims can be proven or disproven without scaffolding from scratch. Each file
documents what it measures, how to run it, and rough IPS targets at the top.

## Documentation Principles

- **Audience-first**: each page targets a specific reader (gem user, contributor, agent).
- **Code is the source of truth**: docs explain _why_ and _how to use_, not implementation
  details that drift.
- **Examples over explanations**: show configuration, show output, show usage.
- **No duplicating CLAUDE.md**: `CLAUDE.md` is for agents working _on_ the gem; `docs/` is for
  users of the gem.
