# Documentation

## Planning & Proposal

| Document | Purpose |
|----------|---------|
| [PROPOSAL.md](PROPOSAL.md) | Core proposal — problem statement, design principles, architecture overview, evaluation strategy, implementation roadmap |
| [BACKEND_MATRIX.md](BACKEND_MATRIX.md) | Deep analysis of every backend option (vector stores, embedding providers, metadata stores, graph stores, job systems) with tradeoffs, selection guidance, and cost modeling |
| [RETRIEVAL_ARCHITECTURE.md](RETRIEVAL_ARCHITECTURE.md) | Detailed technical design for the retrieval layer — query classification, search strategies, storage interfaces, embedding pipeline, context assembly, ranking, configuration |
| [CONTEXT_AND_CHUNKING.md](CONTEXT_AND_CHUNKING.md) | How units are split into embeddable chunks, how retrieved chunks are formatted for different LLMs, token budget interaction, and validation plan |
| [OPERATIONS.md](OPERATIONS.md) | Production concerns — schema management (migrations, versioning, upgrades), error handling and graceful degradation (circuit breakers, fallback tiers), observability (instrumentation, tracing, structured logging, health checks) |
| [AGENTIC_STRATEGY.md](AGENTIC_STRATEGY.md) | How AI agents should consume the system — tool-use interface, task-to-strategy mapping, multi-turn patterns, MCP server design, anti-patterns, evaluation queries |
| [MODEL_EXTRACTION_FIXES.md](MODEL_EXTRACTION_FIXES.md) | Six model extraction fixes (chunking gate, Proc serialization, STI detection, method filtering, callback conditions, token estimation) and their impact on downstream AI consumption |
| [CONSOLE_SERVER.md](CONSOLE_SERVER.md) | Console MCP server design — architecture, bridge protocol, safety model (5 layers), tool interface (4 tiers), deployment modes (Docker/direct/SSH), phased implementation |
| [FLOW_EXTRACTION.md](FLOW_EXTRACTION.md) | Flow extraction design — AST-based execution order analysis, FlowAssembler architecture, operation extraction (calls, transactions, responses, async), Prism/parser adapter, rake task interface |

## Reading Order

1. **PROPOSAL.md** — Start here. Frames the problem, system design, and roadmap.
2. **BACKEND_MATRIX.md** — Reference when selecting infrastructure. Includes cost modeling.
3. **RETRIEVAL_ARCHITECTURE.md** — Reference when implementing retrieval.
4. **CONTEXT_AND_CHUNKING.md** — Reference when implementing chunking and context assembly.
5. **OPERATIONS.md** — Reference when deploying to production.
6. **AGENTIC_STRATEGY.md** — Reference when designing agent integrations.
7. **CONSOLE_SERVER.md** — Reference when implementing live data access alongside extraction.
8. **FLOW_EXTRACTION.md** — Reference when implementing execution flow tracing from entry points.

## Status

| Layer | Status |
|-------|--------|
| Extraction | ✅ Complete (8 extractors, dependency graph with PageRank, GraphAnalyzer, rake tasks) |
| Storage Interfaces | 📋 Designed (see RETRIEVAL_ARCHITECTURE.md) |
| Embedding Pipeline | 📋 Designed (see RETRIEVAL_ARCHITECTURE.md) |
| Chunking Strategy | 📋 Designed (see CONTEXT_AND_CHUNKING.md) |
| Context Formatting | 📋 Designed (see CONTEXT_AND_CHUNKING.md) |
| Retrieval Core | 📋 Designed (see RETRIEVAL_ARCHITECTURE.md) |
| Backend Implementations | 📋 Planned (see BACKEND_MATRIX.md) |
| Schema Management | 📋 Designed (see OPERATIONS.md) |
| Error Handling | 📋 Designed (see OPERATIONS.md) |
| Observability | 📋 Designed (see OPERATIONS.md) |
| Agentic Integration | 📋 Planned (see AGENTIC_STRATEGY.md) |
| Console MCP Server | 📋 Designed (see CONSOLE_SERVER.md) |
| AST Layer | ✅ Complete (Prism adapter, normalized Node, MethodExtractor, CallSiteExtractor, ConstantResolver) |
| RubyAnalyzer | ✅ Complete (ClassAnalyzer, MethodAnalyzer, DataFlowAnalyzer, TraceEnricher) |
| Flow Extraction | ✅ Complete (FlowAssembler, OperationExtractor, ResponseCodeMapper, FlowDocument) |
| Evaluation Harness | 📋 Planned (see PROPOSAL.md) |
| Cost Modeling | 📋 Documented (see BACKEND_MATRIX.md) |
