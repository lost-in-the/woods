# CodebaseIndex Documentation

CodebaseIndex is a Ruby gem that extracts structured data from Rails applications for AI-assisted development. Unlike file-level tools, it uses **runtime introspection** — booting the Rails app and querying `ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs — to produce version-accurate representations with inlined concerns, resolved callback chains, and schema-aware associations.

## Current State

All major layers are implemented: 13 extractors, retrieval pipeline (query classification, hybrid search, RRF ranking), storage backends (pgvector, Qdrant, SQLite), embedding providers (OpenAI, Ollama), two MCP servers (21-tool index server + 31-tool console server), AST analysis, flow extraction, and evaluation harness.

What's next: see [COVERAGE_GAP_ANALYSIS.md](COVERAGE_GAP_ANALYSIS.md) for extractor gaps and [backlog.json](backlog.json) for tracked tasks.

## Current Documents

| Document | Purpose |
|----------|---------|
| [BACKEND_MATRIX.md](BACKEND_MATRIX.md) | Infrastructure selection guide — vector stores, embedding providers, metadata stores, cost modeling |
| [COVERAGE_GAP_ANALYSIS.md](COVERAGE_GAP_ANALYSIS.md) | Gap analysis identifying missing extraction coverage and untapped data uses |
| [backlog.json](backlog.json) | Task tracker for pending development work |

Historical design documents from the build phase are in `_project-resources/docs/` for reference.

## Documentation Roadmap

The pages below don't exist yet — each heading describes a planned document with its scope and audience.

### Getting Started

Installation, configuration, running your first extraction. Audience: a developer adding the gem to a Rails app.

- Adding the gem to a Gemfile
- Generator-based setup (`rails generate codebase_index:install`)
- Configuration options (backend selection, embedding provider)
- Running `rake codebase_index:extract` and inspecting output
- Incremental extraction workflow

### Architecture

High-level pipeline overview. Audience: contributors and advanced users who need to understand how data flows.

- Pipeline stages: extraction → chunking → embedding → storage → retrieval → formatting → MCP
- `ExtractedUnit` as the universal data object
- Runtime introspection vs static parsing — why and what it means
- Backend agnosticism — how storage/embedding adapters work
- Dependency graph with PageRank scoring

### Configuration Reference

All configuration options in one place. Audience: anyone deploying or tuning the gem.

- Complete option reference with defaults
- Backend selection (pgvector vs Qdrant vs SQLite, OpenAI vs Ollama)
- Environment-specific settings
- Presets for common stacks (PostgreSQL + pgvector + OpenAI, SQLite + Ollama)

### Extractor Reference

What each extractor produces. Audience: users wanting to understand extraction output, contributors adding extractors.

- The 13 extractors: models, controllers, routes, jobs, mailers, services, concerns, initializers, configurations, views, channels, Rails sources, framework sources
- What each extractor covers (associations, callbacks, scopes, validations, etc.)
- Edge cases: STI, namespaced classes, empty files, concern inlining
- How to add a new extractor (interface contract, registration, testing)

### MCP Server Guide

Setting up and using the MCP servers. Audience: developers integrating with AI coding tools.

- Index server (21 tools) vs Console server (31 tools) — when to use which
- Tool catalog organized by category
- Setup and configuration for each server
- Security model: SafeContext, SqlValidator, audit logging, read-only transactions

### Retrieval Guide

How retrieval works and how to tune it. Audience: users optimizing AI responses for their codebase.

- Query classification (structural, semantic, mixed)
- Search strategies and when each is used
- Ranking with Reciprocal Rank Fusion (RRF)
- Context assembly and token budgets
- Tuning retrieval for different use cases

### API Reference

Key public classes and their interfaces. Audience: contributors and advanced users.

- Core classes: `ExtractedUnit`, `DependencyGraph`, `Retriever`, `Configuration`
- Extractor interface contract
- Storage adapter interface
- Future: generated from YARD docs

## Documentation Principles

- **Audience-first** — each page targets a specific reader (gem user, contributor, agent)
- **Code is the source of truth** — docs explain _why_ and _how to use_, not implementation details that drift
- **Examples over explanations** — show configuration, show output, show usage
- **No duplicating CLAUDE.md** — `CLAUDE.md` is for agents working _on_ the gem; `docs/` is for users of the gem
