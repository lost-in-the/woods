# Shared AST Layer, RubyAnalyzer & FlowAssembler

**Date:** 2026-02-13
**Status:** Design approved, ready for implementation planning

## Problem

CodebaseIndex has two unmet needs that share the same root requirement:

1. **Self-analysis.** The gem cannot analyze itself — it's plain Ruby with no Rails runtime. Contributors (human and AI) have no structured way to query "what calls `DependencyGraph#register`?" or "how does data flow from extraction to JSON output?"

2. **Execution flow tracing.** The dependency graph captures what-depends-on-what but not execution order. When an agent is asked "what happens when a customer creates a checkout?", it can find related units but not the order they execute. This forces agents to reconstruct flow from memory, producing systematic errors (wrong status codes, swapped pipeline ordering, wrong transaction receivers).

Both features need the same AST infrastructure: Prism parsing, method extraction, call site detection, constant resolution. Building them independently would duplicate ~350 lines of fragile work that already exists as regex/indentation heuristics across 4+ extractors.

## Solution

A **shared AST layer** (`lib/codebase_index/ast/`) that provides robust Ruby source parsing, consumed by two independent features:

- **RubyAnalyzer** — generic Ruby code analysis producing `ExtractedUnit` objects for self-referencing dataflow maps
- **FlowAssembler** — post-extraction execution flow tracing for Rails applications

The AST layer also resolves two open backlog items:
- **#12** — Fragile method boundary detection in controller/mailer extractors (~240 lines of indentation heuristics)
- **#13** — Fragile scope extraction regex in model extractor (~90 lines)

## Design Decisions

### Why merge the AST layer?

FlowAssembler's `AstParser` + `OperationExtractor` and RubyAnalyzer's `PrismHelpers` + `MethodAnalyzer` do the same work with different names: parse Ruby source, walk AST nodes, extract call sites, resolve constants. Building them independently means:
- Duplicated parser adapter logic (Prism + parser gem fallback)
- Duplicated AST walking
- Two places to fix when Prism's API changes
- Missed opportunity to eliminate existing regex heuristics in extractors

### Why Prism over other parsers?

Prism is in Ruby stdlib since 3.3. No new dependencies. It produces a well-documented AST with source location tracking. The gem requires Ruby 3.0+, and Prism is available as a gem for Ruby 3.0-3.2. `RubyVM::AbstractSyntaxTree` is deprecated in favor of Prism.

### Why static + trace for self-analysis?

Static analysis shows what *could* be called. TracePoint shows what *is* called during test execution. The combination surfaces dead code, hot paths, and untested branches. Static is the source of truth; tracing adds color.

### Why FlowAssembler is post-extraction, not a new extractor?

FlowAssembler consumes existing `ExtractedUnit` data and the `DependencyGraph`. It doesn't modify extractors or add fields to ExtractedUnit. Flows are cross-cutting paths through the graph, not individual code units. This keeps the extraction layer stable while adding a new query capability.

## Architecture

```
lib/codebase_index/
├── ast/                                # SHARED AST LAYER
│   ├── parser.rb                       # Prism adapter (parser gem fallback)
│   ├── node.rb                         # Normalized AstNode struct
│   ├── method_extractor.rb             # Extract method body ASTs from source
│   ├── call_site_extractor.rb          # Extract call sites from any AST node
│   └── constant_resolver.rb            # Resolve constant paths to FQNs
│
├── ruby_analyzer.rb                    # Self-analysis orchestrator
├── ruby_analyzer/
│   ├── class_analyzer.rb               # Classes, modules, inheritance, mixins
│   ├── method_analyzer.rb              # Method defs, call graph, parameters
│   ├── dataflow_analyzer.rb            # Data shape transformations
│   └── trace_enricher.rb              # Optional TracePoint integration
│
├── flow_assembler.rb                   # Flow tracing orchestrator
├── flow_document.rb                    # FlowDocument value object
└── flow_analysis/
    ├── operation_extractor.rb          # Ordered operation extraction from method bodies
    └── response_code_mapper.rb         # render/redirect → HTTP status codes
```

### Shared AST Layer (`ast/`)

**`Ast::Parser`** — Adapter that normalizes Prism and parser gem to a common interface. Auto-detects available parser at load time.

```ruby
CodebaseIndex::Ast::Parser.new.parse(source)        # → Ast::Node (root)
CodebaseIndex::Ast::Parser.new.extract_method(source, "create")  # → Ast::Node | nil
```

**`Ast::Node`** — Normalized AST node struct used by all consumers:

```ruby
Ast::Node = Struct.new(
  :type,        # Symbol: :send, :block, :if, :rescue, :def, :class, etc.
  :children,    # Array<Ast::Node>
  :line,        # Integer: source line number
  :receiver,    # String, nil: method call receiver (for :send)
  :method_name, # String, nil: method name (for :send, :def)
  :arguments,   # Array<String>: argument representations (for :send)
  keyword_init: true
)
```

**`Ast::MethodExtractor`** — Extracts method body ASTs. Replaces the ~240 lines of `nesting_delta` / `neutralize_strings_and_comments` / indentation-based boundary detection duplicated across controller and mailer extractors.

**`Ast::CallSiteExtractor`** — Extracts call sites (receiver, method, args, line) from any AST node. Shared by RubyAnalyzer's MethodAnalyzer (for call graph building) and FlowAssembler's OperationExtractor (for flow ordering).

**`Ast::ConstantResolver`** — Resolves constant paths (e.g., `CodebaseIndex::Extractor` → fully qualified name). Shared by all consumers that need to map constants to known units.

### RubyAnalyzer (Self-Analysis)

Entry point: `CodebaseIndex::RubyAnalyzer.analyze(paths:, trace_data: nil)`

**ClassAnalyzer** — Walks Prism AST via `Ast::Parser` to extract class/module definitions, superclasses, includes, constant references. Produces `:ruby_class` and `:ruby_module` `ExtractedUnit` objects.

**MethodAnalyzer** — Uses `Ast::MethodExtractor` + `Ast::CallSiteExtractor` to extract method definitions, call sites, parameters, visibility. Produces `:ruby_method` units linked to parent class via dependencies.

**DataFlowAnalyzer** — Uses `Ast::CallSiteExtractor` to find data transformation boundaries (`.new`, `.to_h`, `.to_json`, assignment patterns). Adds `data_transformations` metadata to existing units. Initial version is conservative.

**TraceEnricher** — Optional runtime layer. Wraps test execution with `TracePoint.new(:call, :return)` filtered to `codebase_index` source paths. Records caller→callee pairs, call counts, argument types. Writes `tmp/trace_data.json`. RubyAnalyzer merges trace data into static analysis.

### FlowAssembler (Execution Flow Tracing)

Entry point: `CodebaseIndex::FlowAssembler.new(graph:, extracted_dir:).assemble(entry_point)`

**OperationExtractor** — Uses `Ast::CallSiteExtractor` + domain-specific classification (transaction detection, async enqueue detection, response call detection). Extracts operations in source line order with nesting for transaction blocks and conditionals.

**ResponseCodeMapper** — Maps render/redirect AST nodes to HTTP status codes via `Rack::Utils::SYMBOL_TO_STATUS_CODE`. FlowAssembler-specific, no equivalent in self-analysis.

**FlowDocument** — Value object holding the assembled flow tree. `to_h` for JSON, `to_markdown` for human-readable output.

Full FlowAssembler design (entry point resolution, recursive expansion, cycle detection, edge cases, output format, testing strategy) is in `docs/FLOW_EXTRACTION.md`.

## New ExtractedUnit Types

Three new type values for self-analysis, distinct from Rails types:
- `:ruby_class` — a class definition
- `:ruby_module` — a module definition
- `:ruby_method` — a method definition (linked to parent class/module)

These coexist with existing types (`:model`, `:controller`, etc.) in the same DependencyGraph.

## Output

### Self-Analysis: Structured JSON (for AI agents)

```
tmp/codebase_index_self/
├── manifest.json
├── dependency_graph.json
├── graph_analysis.json
├── ruby_classes/
│   ├── CodebaseIndex__Extractor.json
│   ├── CodebaseIndex__ExtractedUnit.json
│   └── _index.json
├── ruby_modules/
│   └── _index.json
└── ruby_methods/
    ├── CodebaseIndex__Extractor__extract_all.json
    └── _index.json
```

Each unit JSON includes standard ExtractedUnit fields plus:
- `call_graph` — methods this method calls
- `called_by` — methods that call this method (reverse pass)
- `data_transformations` — type/shape changes at boundaries
- `trace_data` — runtime call counts, argument types, hot path flag (when available)

### Self-Analysis: Human-Readable Mermaid

```
docs/self-analysis/
├── DATAFLOW.md          # Data transformation pipeline (Mermaid flowchart)
├── CALL_GRAPH.md        # Class-level call relationships (Mermaid graph)
├── DEPENDENCY_MAP.md    # Class dependency graph (Mermaid graph)
└── ARCHITECTURE.md      # Combined summary with embedded diagrams + stats
```

Mermaid files are generated from JSON — a view, not a source of truth.

### Flow Tracing Output

On-demand via rake task:
```bash
bundle exec rake codebase_index:flow[CheckoutsController#create]           # Markdown
FORMAT=json bundle exec rake codebase_index:flow[CheckoutsController#create]  # JSON
```

Output format documented in `docs/FLOW_EXTRACTION.md`.

### Git Strategy

All self-analysis output committed to the repo with `.gitattributes`:
```
tmp/codebase_index_self/** linguist-generated=true
docs/self-analysis/** linguist-generated=true
```

Collapses generated files in GitHub PRs while keeping them accessible.

## Automation

### Pre-Commit Hook

`scripts/regenerate-self-analysis.sh`:
```bash
#!/bin/bash
changed_files=$(git diff --cached --name-only -- 'lib/')
if [ -n "$changed_files" ]; then
  bundle exec rake codebase_index:self_analyze
  git add tmp/codebase_index_self/ docs/self-analysis/
fi
```

### Staleness Detection

The manifest includes a `source_checksum` (SHA256 of all `lib/**/*.rb` contents concatenated, sorted by path). If the checksum matches, the hook is a no-op.

### Rake Tasks

```bash
bundle exec rake codebase_index:self_analyze   # Static analysis + Mermaid generation
bundle exec rake codebase_index:self_trace     # Run specs with TracePoint, write tmp/trace_data.json
bundle exec rake codebase_index:flow[entry]    # Generate execution flow trace (requires Rails boot)
```

## Backlog Alignment

The shared AST layer resolves two open optimization backlog items as a side effect:

| Backlog Item | Current State | Resolution |
|---|---|---|
| **#12 — Fragile method boundary detection** | ~240 lines of `nesting_delta` + `neutralize_strings_and_comments` duplicated in controller + mailer extractors | Replaced by `Ast::MethodExtractor` |
| **#13 — Fragile scope extraction regex** | ~90 lines of regex + dual-depth tracking in model extractor | Replaced by `Ast::Parser` block boundary detection |

Additionally, `neutralize_strings_and_comments()` is duplicated in 3+ extractors. The AST parser handles this natively, eliminating all copies.

## Swarm Implementation Plan

This design is structured for **parallel agent execution**. The shared AST layer is the critical path — once it's built and tested, RubyAnalyzer and FlowAssembler can proceed independently.

### Dependency Graph (what blocks what)

```
                    ┌─────────────────┐
                    │  AST Layer (L0) │
                    │  parser, node,  │
                    │  method_ext,    │
                    │  call_site_ext, │
                    │  const_resolver │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
     ┌────────────┐  ┌────────────┐  ┌────────────────┐
     │ RubyAnalyzer│  │FlowAssembler│  │Extractor Backlog│
     │   (L1a)    │  │   (L1b)    │  │  #12, #13 (L1c)│
     └─────┬──────┘  └─────┬──────┘  └────────────────┘
           │              │
           ▼              ▼
  ┌──────────────┐  ┌──────────────┐
  │ Self-Analysis │  │  Rake Tasks  │
  │ Output (L2a) │  │  + Docs (L2b)│
  └──────┬───────┘  └──────────────┘
         │
         ▼
  ┌──────────────┐
  │  Automation  │
  │  Hook (L3)   │
  └──────────────┘
```

### Agent Specializations

| Agent | Specialty | Scope | Blocked By |
|---|---|---|---|
| **ast-foundation** | AST parsing, Prism API, normalized node model | `lib/codebase_index/ast/` + specs | Nothing (start immediately) |
| **ruby-analyzer** | Class/method/dataflow analysis, ExtractedUnit production | `lib/codebase_index/ruby_analyzer/` + specs | ast-foundation |
| **flow-assembler** | Execution flow tracing, graph traversal, FlowDocument | `lib/codebase_index/flow_assembler.rb`, `flow_analysis/`, `flow_document.rb` + specs | ast-foundation |
| **output-and-automation** | JSON/Mermaid output, rake tasks, pre-commit hook, .gitattributes | `lib/tasks/`, `scripts/`, `docs/self-analysis/` | ruby-analyzer (for self-analysis output), flow-assembler (for flow rake task) |
| **backlog-cleanup** | Replace regex heuristics in existing extractors with AST layer | Controller, mailer, model extractors | ast-foundation |

### Task Breakdown by Agent

#### ast-foundation (Level 0 — start immediately)

```json
[
  {
    "id": "L0-1",
    "title": "Implement Ast::Node normalized struct",
    "file": "lib/codebase_index/ast/node.rb",
    "spec": "spec/ast/node_spec.rb",
    "acceptance": "Struct with type, children, line, receiver, method_name, arguments. Supports keyword_init."
  },
  {
    "id": "L0-2",
    "title": "Implement Ast::Parser with Prism adapter",
    "file": "lib/codebase_index/ast/parser.rb",
    "spec": "spec/ast/parser_spec.rb",
    "acceptance": "Parses Ruby source into Ast::Node tree. Auto-detects Prism availability. Falls back to parser gem if Prism unavailable. Tests verify identical output for both parsers on known snippets."
  },
  {
    "id": "L0-3",
    "title": "Implement Ast::MethodExtractor",
    "file": "lib/codebase_index/ast/method_extractor.rb",
    "spec": "spec/ast/method_extractor_spec.rb",
    "acceptance": "Extracts method body AST by name from source. Handles: def/end, multi-line signatures, rescue/ensure blocks, class methods (def self.foo). Tests include edge cases that break current indentation heuristics."
  },
  {
    "id": "L0-4",
    "title": "Implement Ast::CallSiteExtractor",
    "file": "lib/codebase_index/ast/call_site_extractor.rb",
    "spec": "spec/ast/call_site_extractor_spec.rb",
    "acceptance": "Extracts call sites from any AST node. Returns [{receiver:, method_name:, arguments:, line:}]. Handles: method calls, chained calls, block-passing calls. Tests verify source-order preservation."
  },
  {
    "id": "L0-5",
    "title": "Implement Ast::ConstantResolver",
    "file": "lib/codebase_index/ast/constant_resolver.rb",
    "spec": "spec/ast/constant_resolver_spec.rb",
    "acceptance": "Resolves constant paths from AST nodes to fully qualified names. Handles: nested modules (A::B::C), relative constants, top-level (::Foo). Takes a known_constants list for disambiguation."
  }
]
```

#### ruby-analyzer (Level 1a — after ast-foundation)

```json
[
  {
    "id": "L1a-1",
    "title": "Implement ClassAnalyzer",
    "file": "lib/codebase_index/ruby_analyzer/class_analyzer.rb",
    "spec": "spec/ruby_analyzer/class_analyzer_spec.rb",
    "acceptance": "Extracts class/module definitions from Ruby files. Produces :ruby_class and :ruby_module ExtractedUnit objects with identifier, file_path, namespace, source_code, dependencies (superclass, includes)."
  },
  {
    "id": "L1a-2",
    "title": "Implement MethodAnalyzer",
    "file": "lib/codebase_index/ruby_analyzer/method_analyzer.rb",
    "spec": "spec/ruby_analyzer/method_analyzer_spec.rb",
    "acceptance": "Extracts method definitions for each class. Produces :ruby_method ExtractedUnit objects linked to parent class via dependencies. Includes call_graph metadata (methods called). Uses Ast::MethodExtractor + Ast::CallSiteExtractor."
  },
  {
    "id": "L1a-3",
    "title": "Implement DataFlowAnalyzer",
    "file": "lib/codebase_index/ruby_analyzer/dataflow_analyzer.rb",
    "spec": "spec/ruby_analyzer/dataflow_analyzer_spec.rb",
    "acceptance": "Identifies .new, .to_h, .to_json calls and annotates units with data_transformations metadata. Conservative: only explicit transformation calls, no inference."
  },
  {
    "id": "L1a-4",
    "title": "Implement TraceEnricher",
    "file": "lib/codebase_index/ruby_analyzer/trace_enricher.rb",
    "spec": "spec/ruby_analyzer/trace_enricher_spec.rb",
    "acceptance": "TracePoint recording filtered to codebase_index paths. Writes trace_data.json. Merges into static analysis: hot paths, traced_callers, untested method flags."
  },
  {
    "id": "L1a-5",
    "title": "Implement RubyAnalyzer orchestrator",
    "file": "lib/codebase_index/ruby_analyzer.rb",
    "spec": "spec/ruby_analyzer_spec.rb",
    "acceptance": "analyze(paths:, trace_data:) coordinates ClassAnalyzer + MethodAnalyzer + DataFlowAnalyzer. Returns Array<ExtractedUnit>. Feeds into DependencyGraph and GraphAnalyzer. Run on lib/codebase_index/ produces correct self-analysis."
  }
]
```

#### flow-assembler (Level 1b — after ast-foundation, parallel with ruby-analyzer)

```json
[
  {
    "id": "L1b-1",
    "title": "Implement OperationExtractor",
    "file": "lib/codebase_index/flow_analysis/operation_extractor.rb",
    "spec": "spec/flow_analysis/operation_extractor_spec.rb",
    "acceptance": "Uses Ast::CallSiteExtractor + domain classification. Extracts operations in source order: method calls, transaction blocks (with nesting), async enqueues, response calls, conditionals. Tests verify correct ordering and nesting."
  },
  {
    "id": "L1b-2",
    "title": "Implement ResponseCodeMapper",
    "file": "lib/codebase_index/flow_analysis/response_code_mapper.rb",
    "spec": "spec/flow_analysis/response_code_mapper_spec.rb",
    "acceptance": "Maps render/redirect AST nodes to HTTP status codes via Rack::Utils. Handles: status kwarg, render_<status> convention, head, redirect_to (default 302). Returns nil for unresolvable."
  },
  {
    "id": "L1b-3",
    "title": "Implement FlowDocument value object",
    "file": "lib/codebase_index/flow_document.rb",
    "spec": "spec/flow_document_spec.rb",
    "acceptance": "to_h produces JSON matching the format in FLOW_EXTRACTION.md. to_markdown produces the table format. Round-trip: FlowDocument.from_h(doc.to_h) == doc."
  },
  {
    "id": "L1b-4",
    "title": "Implement FlowAssembler orchestrator",
    "file": "lib/codebase_index/flow_assembler.rb",
    "spec": "spec/flow_assembler_spec.rb",
    "acceptance": "assemble(entry_point) walks DependencyGraph, calls OperationExtractor per unit, resolves cross-unit calls recursively. Cycle detection via visited set. Configurable max_depth (default 5). Prepends before_action filters from controller metadata."
  }
]
```

#### output-and-automation (Level 2 — after ruby-analyzer and flow-assembler)

```json
[
  {
    "id": "L2-1",
    "title": "Implement self_analyze rake task",
    "file": "lib/tasks/codebase_index.rake",
    "acceptance": "rake codebase_index:self_analyze runs RubyAnalyzer on lib/codebase_index/, writes JSON to tmp/codebase_index_self/. Includes staleness detection via source_checksum."
  },
  {
    "id": "L2-2",
    "title": "Implement self_trace rake task",
    "file": "lib/tasks/codebase_index.rake",
    "acceptance": "rake codebase_index:self_trace runs specs with TracePoint recording, writes tmp/trace_data.json."
  },
  {
    "id": "L2-3",
    "title": "Implement flow rake task",
    "file": "lib/tasks/codebase_index.rake",
    "acceptance": "rake codebase_index:flow[entry_point] generates flow document. FORMAT=json|markdown. MAX_DEPTH configurable."
  },
  {
    "id": "L2-4",
    "title": "Implement Mermaid generation from JSON",
    "files": ["lib/codebase_index/ruby_analyzer/mermaid_renderer.rb"],
    "acceptance": "Reads self-analysis JSON, produces DATAFLOW.md, CALL_GRAPH.md, DEPENDENCY_MAP.md, ARCHITECTURE.md in docs/self-analysis/."
  },
  {
    "id": "L2-5",
    "title": "Implement pre-commit hook and .gitattributes",
    "files": ["scripts/regenerate-self-analysis.sh", ".gitattributes"],
    "acceptance": "Hook detects lib/ changes in staged files, runs self_analyze, adds output. .gitattributes marks output as linguist-generated."
  }
]
```

#### backlog-cleanup (Level 1c — after ast-foundation, parallel with ruby-analyzer and flow-assembler)

```json
[
  {
    "id": "L1c-1",
    "title": "Replace controller method boundary detection with Ast::MethodExtractor",
    "file": "lib/codebase_index/extractors/controller_extractor.rb",
    "acceptance": "Remove extract_action_source indentation heuristic (~120 lines). Use Ast::MethodExtractor. Existing controller_extractor_spec passes. Output unchanged."
  },
  {
    "id": "L1c-2",
    "title": "Replace mailer method boundary detection with Ast::MethodExtractor",
    "file": "lib/codebase_index/extractors/mailer_extractor.rb",
    "acceptance": "Remove duplicated extract_action_source (~120 lines). Use Ast::MethodExtractor. Existing specs pass."
  },
  {
    "id": "L1c-3",
    "title": "Replace model scope extraction regex with AST parsing",
    "file": "lib/codebase_index/extractors/model_extractor.rb",
    "acceptance": "Remove extract_scope_source regex + scope_keyword_delta (~90 lines). Use Ast::Parser for block boundary detection. Existing model_extractor_spec passes."
  },
  {
    "id": "L1c-4",
    "title": "Remove neutralize_strings_and_comments duplicates",
    "files": ["All extractors with the method"],
    "acceptance": "No extractor defines neutralize_strings_and_comments. AST parser handles this natively. Full spec suite passes."
  }
]
```

## V1 Scope

### In scope
- Shared AST layer (Prism + parser gem fallback)
- RubyAnalyzer: ClassAnalyzer + MethodAnalyzer + DataFlowAnalyzer + TraceEnricher
- FlowAssembler: OperationExtractor + ResponseCodeMapper + FlowDocument
- JSON output for self-analysis using existing ExtractedUnit + DependencyGraph
- Mermaid generation from self-analysis JSON
- Rake tasks: self_analyze, self_trace, flow
- Pre-commit hook with staleness detection
- `.gitattributes` with `linguist-generated`
- Backlog #12 and #13 resolution

### Explicitly NOT in scope for v1
- Replacing source parsing in extractors beyond #12/#13 (future phase)
- Analyzing code outside `lib/codebase_index/`
- Supporting arbitrary Ruby projects
- Embedding or vector storage of self-analysis output
- MCP server changes
- Caching flow documents on disk

## Future Phases

### Phase 2: Full Extractor AST Migration

**Context:** After v1, the AST layer is proven. The remaining extractors (service, job, GraphQL, serializer, etc.) still use regex-based source parsing.

**Goal:** All extractors delegate AST-level work to `ast/`, keeping only domain-specific reflection.

**Tasks:**
```json
[
  {
    "id": "phase2-1",
    "title": "Migrate ModelExtractor to AST layer (beyond scope extraction)",
    "description": "ModelExtractor still uses regex for class definition detection and some dependency scanning. Refactor remaining regex patterns to use Ast::Parser and Ast::CallSiteExtractor.",
    "files": ["lib/codebase_index/extractors/model_extractor.rb"],
    "acceptance": "No regex-based source parsing remains in ModelExtractor. Existing specs pass."
  },
  {
    "id": "phase2-2",
    "title": "Migrate ServiceExtractor to AST layer",
    "description": "ServiceExtractor is the most regex-heavy extractor. Replace entry point detection, public method extraction, and initialize parameter parsing with AST equivalents.",
    "files": ["lib/codebase_index/extractors/service_extractor.rb"],
    "acceptance": "ServiceExtractor uses Ast::MethodExtractor for method discovery and Ast::CallSiteExtractor for dependency detection. Existing specs pass."
  },
  {
    "id": "phase2-3",
    "title": "Migrate remaining extractors",
    "description": "Apply the pattern to JobExtractor, GraphQLExtractor, SerializerExtractor, ManagerExtractor, PolicyExtractor, ValidatorExtractor, PhlexExtractor, ViewComponentExtractor.",
    "files": ["lib/codebase_index/extractors/*.rb"],
    "acceptance": "All extractor outputs unchanged. Full spec suite passes."
  }
]
```

### Phase 3: Spec Coverage Mapping

**Context:** TraceEnricher records method calls during test runs. Cross-referencing with spec files produces a coverage map.

**Goal:** "Which specs test which source methods?" and "Which methods have no spec coverage?"

**Tasks:**
```json
[
  {
    "id": "phase3-1",
    "title": "Extend TraceEnricher to record caller source file",
    "description": "Record source file of caller alongside method pairs. When caller is in spec/, creates a spec→source link.",
    "acceptance": "trace_data.json includes caller_file. Spec-originating calls identifiable."
  },
  {
    "id": "phase3-2",
    "title": "Build spec coverage analyzer",
    "description": "Reads trace_data.json, produces coverage report: source method → spec files, spec file → source methods.",
    "acceptance": "Coverage report JSON produced. Cross-references match actual test execution."
  },
  {
    "id": "phase3-3",
    "title": "Add coverage gaps to Mermaid output",
    "description": "Red nodes for untested methods in call graph and dependency map diagrams.",
    "acceptance": "Mermaid diagrams visually distinguish tested vs untested methods."
  }
]
```

### Phase 4: MCP Self-Analysis Resource

**Context:** Existing MCP server reads extraction JSON from a configurable directory.

**Goal:** Expose self-analysis via dedicated MCP resource without switching index directories.

**Tasks:**
```json
[
  {
    "id": "phase4-1",
    "title": "Add codebase://self resource to MCP server",
    "description": "New resource scoped to self-analysis output directory.",
    "acceptance": "Resource returns self-analysis manifest and graph data. Existing resources unaffected."
  },
  {
    "id": "phase4-2",
    "title": "Add self-analysis query tools",
    "description": "Scope parameter on existing tools (or self_ prefix) to query self-analysis index.",
    "acceptance": "Agents can query gem's own class/method data through MCP."
  }
]
```

### Phase 5: Arbitrary Ruby Project Support

Not yet planned. Key questions to answer after Phase 2:
- Does ExtractedUnit need new fields for non-gem Ruby?
- How should directory scanning be configured without Rails conventions?
- Should this be a separate gem?
