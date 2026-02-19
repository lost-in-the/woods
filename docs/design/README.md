# Design Documents

Design-phase documents extracted from the `feat/simplification` branch (Feb 2026). These were written during the early architecture phase before all subsystems were built out. Most items are now resolved — the documents serve as architectural reference and decision records.

## Key References

| Document | Status | What's Useful |
|----------|--------|--------------|
| **OPTIMIZATION_BACKLOG.md** | 39/43 resolved | 43 items with severity ratings. Remaining: #6 (fixture specs), #18 (intentional), #21 (tiktoken), #40 (Amplitude). |
| **REVIEW_FINDINGS.md** | All critical/high resolved | Code audit: 13 bugs (B-001 to B-013), doc accuracy, cross-doc contradictions. B-007 partially addressed, B-011 deferred by design. |
| **AGENTIC_STRATEGY.md** | Reference | How AI agents should use CodebaseIndex: task-type to retrieval-pattern mapping, budget awareness, tool-use interface. |
| **RETRIEVAL_ARCHITECTURE.md** | Implemented | Full retrieval pipeline design: query classification, hybrid search, RRF ranking, context assembly. |
| **OPERATIONS.md** | Implemented | Deployment, monitoring, error handling, pipeline management patterns. |
| **CONTEXT_AND_CHUNKING.md** | Implemented | Semantic chunking strategy, token budget allocation, chunk boundary rules. |
| **FLOW_EXTRACTION.md** | Implemented | Request flow tracing design, controller-through-model paths. |
| **CONSOLE_SERVER.md** | Implemented | Console MCP server design: tiered tools, safe context, SQL validation. 31 tools across 4 tiers. |
| **PROPOSAL.md** | Historical | Original project proposal and scope definition. |
| **MODEL_EXTRACTION_FIXES.md** | Resolved | Model extractor correctness fixes from early development. |

## Plans

- `plans/2025-02-11-claude-toolkit-design.md` - Initial toolkit design concept
- `plans/2026-02-13-ruby-analyzer-design.md` - Prism-based AST layer design (implemented)
