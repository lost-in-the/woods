# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
