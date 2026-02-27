# Flow Extraction

## Problem Statement

CodebaseIndex extracts **structural dependencies** (what-depends-on-what) as unordered sets. The dependency graph supports traversal (`dependencies_of`, `dependents_of`, `path_between`) and importance scoring via PageRank, but has no concept of **execution order** within methods.

Controllers capture routes and filter chains but not response codes or call sequences. Services capture entry points and dependencies but not call ordering. When an agent is asked "what happens when a customer creates a checkout?", it can find all the related units — `CheckoutsController`, `CheckoutFindOrCreate`, `CheckoutWorker` — but not the order in which they execute.

This gap forces agents to **reconstruct execution flow from memory**, which produces systematic errors.

### Error Classes

An agent-generated flow document for a checkout endpoint contained three factual errors, all traceable to the same root cause: reconstructing from compressed context instead of mechanically reading source code.

| Error | What Happened | Root Cause |
|---|---|---|
| Wrong HTTP status (202 vs 201) | Agent assumed a helper method returned 202 | Inferred inherited behavior instead of reading the `render` call |
| Wrong transaction class (`Cart` vs `Checkout`) | Agent transcribed from memory | Wrote the wrong receiver for `.transaction` |
| Swapped pipeline ordering | Agent reconstructed from mental model | Listed operations in logical order, not source order |

A programmatic approach eliminates all three: the AST contains the exact `render` call and its status code, the exact receiver of `.transaction`, and the exact source line order.

---

## Proposed Solution: FlowAssembler

FlowAssembler is a **post-extraction, on-demand layer** — not a new extractor. It provides the execution-order data needed by the `trace` intent defined in `RETRIEVAL_ARCHITECTURE.md` (query classification, intent table) — queries like "What happens when a customer places an order?" Flows are cross-cutting paths through the dependency graph, not individual code units. FlowAssembler consumes existing `ExtractedUnit` data and augments it with execution-order metadata derived from AST analysis.

### Architecture Overview

```
User specifies entry point
  │  e.g., "CheckoutsController#create"
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ FlowAssembler                                       │
│                                                     │
│  1. Load unit source from extracted data            │
│  2. Parse method body AST                           │
│  3. Extract operations in source line order         │
│  4. Resolve calls to other ExtractedUnits           │
│  5. Recurse (with cycle detection + max_depth)      │
│  6. Assemble FlowDocument                           │
└─────────────────────────────────────────────────────┘
  │                         │
  │ reads from              │ reads from
  ▼                         ▼
┌─────────────────┐  ┌──────────────────────┐
│ ExtractedUnit   │  │ DependencyGraph      │
│ source_code     │  │ dependencies_of      │
│ metadata        │  │ path_between         │
└─────────────────┘  └──────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────────┐
│ FlowDocument                                        │
│                                                     │
│  Structured output:                                 │
│  • JSON (machine-readable, for retrieval layer)     │
│  • Markdown (human-readable, for documentation)     │
└─────────────────────────────────────────────────────┘
```

### Components

| File | Responsibility |
|---|---|
| `lib/codebase_index/flow_assembler.rb` | Orchestrator: graph traversal from entry point, calls AST analyzer per unit, assembles ordered steps (~300 lines) |
| `lib/codebase_index/flow_document.rb` | Value object: holds assembled flow, `to_h` (JSON), `to_markdown` (~120 lines) |
| `lib/codebase_index/flow_analysis/operation_extractor.rb` | AST traversal: extracts method calls, transactions, responses, conditionals in source order (~400 lines) |
| `lib/codebase_index/flow_analysis/ast_parser.rb` | Adapter: normalizes Prism (Ruby 3.3+) / parser gem to common interface (~150 lines) |
| `lib/codebase_index/flow_analysis/response_code_mapper.rb` | Maps render/redirect calls to HTTP status codes via `Rack::Utils` (~50 lines) |
| `lib/tasks/flow.rake` | Rake task: `codebase_index:flow[CheckoutsController#create]` (~50 lines) |

### Data Flow

1. **Entry point resolution.** User provides `CheckoutsController#create`. FlowAssembler looks up the controller unit from extracted data, finds the `create` action method.

2. **AST analysis.** OperationExtractor parses the method body and extracts operations in source line order:
   - Method calls with receiver + args + line number
   - Transaction blocks with exact receiver class
   - Response calls (render/redirect) with extracted status codes
   - Conditional branches (if/unless/case)
   - Async job enqueues (perform_async/perform_later/perform_in)

3. **Dependency resolution.** For each method call that resolves to another `ExtractedUnit` in the dependency graph, FlowAssembler recursively expands. Cycle detection via a visited set and configurable `max_depth` (default: 5) prevent infinite recursion.

4. **Assembly.** The result is a `FlowDocument` — an ordered tree of steps that preserves source-level execution order.

---

## Output Format

### JSON (for retrieval layer and programmatic consumption)

```json
{
  "entry_point": "CheckoutsController#create",
  "route": { "verb": "POST", "path": "/api/checkouts" },
  "max_depth": 5,
  "generated_at": "2026-02-13T10:30:00Z",
  "steps": [
    {
      "unit": "CheckoutsController#create",
      "type": "controller",
      "file_path": "app/controllers/api/checkouts_controller.rb",
      "operations": [
        {
          "type": "call",
          "target": "CheckoutFindOrCreate",
          "method": "call",
          "line": 42
        },
        {
          "type": "async",
          "target": "CheckoutWorker",
          "method": "perform_async",
          "args_hint": ["checkout.id"],
          "line": 45
        },
        {
          "type": "response",
          "status_code": 201,
          "render_method": "render_created",
          "resolved_from": "Rack::Utils::SYMBOL_TO_STATUS_CODE[:created]",
          "line": 48
        }
      ]
    },
    {
      "unit": "CheckoutFindOrCreate",
      "type": "service",
      "file_path": "app/services/checkout_find_or_create.rb",
      "operations": [
        {
          "type": "transaction",
          "receiver": "Checkout",
          "line": 12,
          "nested": [
            {
              "type": "call",
              "target": "cart",
              "method": "lock!",
              "line": 13
            },
            {
              "type": "call",
              "target": "Checkout",
              "method": "find_pending_or_successful",
              "line": 14
            },
            {
              "type": "conditional",
              "kind": "if",
              "condition": "checkout.persisted?",
              "line": 15,
              "then_ops": [
                {
                  "type": "call",
                  "target": "checkout",
                  "method": "touch",
                  "line": 16
                }
              ],
              "else_ops": [
                {
                  "type": "call",
                  "target": "Checkout",
                  "method": "create!",
                  "line": 18
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

### Markdown (for documentation and human review)

```markdown
## POST /api/checkouts → CheckoutsController#create

### 1. CheckoutsController#create
_app/controllers/api/checkouts_controller.rb_

| # | Operation | Target | Line |
|---|-----------|--------|------|
| 1 | call | CheckoutFindOrCreate.call | 42 |
| 2 | async | CheckoutWorker.perform_async(checkout.id) | 45 |
| 3 | response | 201 Created (via render_created) | 48 |

### 2. CheckoutFindOrCreate
_app/services/checkout_find_or_create.rb_

| # | Operation | Target | Line |
|---|-----------|--------|------|
| 1 | transaction | Checkout.transaction | 12 |
| 1.1 | lock | cart.lock! | 13 |
| 1.2 | call | Checkout.find_pending_or_successful | 14 |
| 1.3 | if checkout.persisted? | | 15 |
| 1.3a | call | checkout.touch | 16 |
| 1.3b | call | Checkout.create! | 18 |
```

The Markdown format is intentionally mechanical — it shows exactly what the code does, without narrative interpretation. Human or agent curation adds the "why" layer on top.

---

## Extractability Matrix

~70% of a typical flow document's factual content is mechanically extractable from source code. The remaining 30% requires human or agent curation — but the curation operates on correct extracted data rather than reconstructed memory.

| Category | Extractable? | Method | Examples |
|---|---|---|---|
| Route mappings | Yes (existing) | ControllerExtractor already captures routes | `POST /api/checkouts → CheckoutsController#create` |
| Call ordering within methods | Yes (AST) | Source line order from parsed method body | `FindOrCreate` before `Worker.perform_async` |
| Response codes | Yes (AST + Rack) | Parse render/redirect calls, resolve status symbols | `render_created` → 201 via `Rack::Utils` |
| Transaction receivers | Yes (AST) | Extract exact receiver from `.transaction` call | `Checkout.transaction`, not `Cart.transaction` |
| Lock calls | Yes (AST) | Detect `.lock!`, `.with_lock`, `FOR UPDATE` | `cart.lock!` |
| Async job enqueues | Yes (AST) | Detect `perform_async`, `perform_later`, `perform_in` | `CheckoutWorker.perform_async(checkout.id)` |
| Conditional structure | Partial (AST) | Branch structure extractable, semantics require context | `if checkout.persisted?` — structure yes, meaning no |
| Error handling (rescue) | Partial (AST) | Rescue clauses extractable, recovery intent requires context | `rescue ActiveRecord::RecordInvalid` |
| Narrative explanations | No | Requires domain knowledge | "This ensures only one active checkout exists per cart" |
| Section naming | No | Requires editorial judgment | "Failure Paths", "Background Infrastructure" |
| Business context | No | Requires domain knowledge | Why 3DS matters, what abandoned carts are |

---

## AST Parsing Approach

### Parser Strategy

| Parser | Ruby Version | Status | Tradeoffs |
|---|---|---|---|
| **Prism** | 3.3+ | Preferred | Ships with Ruby, fast, actively maintained by Shopify/Ruby core |
| **parser gem** | < 3.3 | Fallback | Mature, wide compatibility, additional gem dependency |
| `RubyVM::AbstractSyntaxTree` | Any | Avoided | Deprecated in favor of Prism, unstable API |

FlowAssembler uses an adapter layer (`AstParser`) that normalizes both Prism and the parser gem to a common interface. The adapter auto-detects the available parser at boot time.

### AstParser Adapter Interface

```ruby
module CodebaseIndex
  module FlowAnalysis
    class AstParser
      # Parse Ruby source and return a normalized AST.
      #
      # @param source [String] Ruby source code
      # @return [AstNode] Normalized AST root node
      def parse(source)
        if prism_available?
          parse_with_prism(source)
        else
          parse_with_parser_gem(source)
        end
      end

      # Extract a specific method body from source.
      #
      # @param source [String] Ruby source code
      # @param method_name [String] Method to extract
      # @return [AstNode, nil] Method body AST or nil if not found
      def extract_method(source, method_name)
        root = parse(source)
        find_method_def(root, method_name)
      end

      private

      def prism_available?
        defined?(Prism)
      end
    end
  end
end
```

### Normalized AST Node

Both parsers are normalized to a common node structure:

```ruby
AstNode = Struct.new(
  :type,       # Symbol: :send, :block, :if, :rescue, :def, :class, etc.
  :children,   # Array<AstNode>: child nodes
  :line,       # Integer: source line number
  :receiver,   # String, nil: method call receiver (for :send)
  :method_name,# String, nil: method name (for :send, :def)
  :arguments,  # Array<String>: argument representations (for :send)
  keyword_init: true
)
```

### OperationExtractor Algorithm

OperationExtractor walks the normalized AST for a method body and produces an ordered list of operations:

```ruby
module CodebaseIndex
  module FlowAnalysis
    class OperationExtractor
      # Extract operations from a method body AST.
      #
      # @param method_ast [AstNode] Parsed method body
      # @param context [Hash] Unit metadata for resolving receivers
      # @return [Array<Hash>] Ordered operations
      def extract(method_ast, context: {})
        operations = []
        walk(method_ast, operations, context)
        operations
      end

      private

      def walk(node, operations, context)
        case node.type
        when :send
          handle_send(node, operations, context)
        when :block
          handle_block(node, operations, context)
        when :if
          handle_conditional(node, operations, context)
        when :rescue
          handle_rescue(node, operations, context)
        else
          # Recurse into children
          node.children&.each { |child| walk(child, operations, context) if child.is_a?(AstNode) }
        end
      end

      def handle_send(node, operations, context)
        if transaction_call?(node)
          # Handled by handle_block when we see the block wrapper
          return
        end

        if async_enqueue?(node)
          operations << {
            type: :async,
            target: node.receiver,
            method: node.method_name,
            args_hint: extract_args_hint(node),
            line: node.line
          }
        elsif response_call?(node)
          operations << {
            type: :response,
            status_code: ResponseCodeMapper.resolve(node),
            render_method: node.method_name,
            line: node.line
          }
        elsif significant_call?(node, context)
          operations << {
            type: :call,
            target: node.receiver,
            method: node.method_name,
            line: node.line
          }
        end
      end

      def handle_block(node, operations, context)
        send_node = node.children.first
        if transaction_call?(send_node)
          nested = []
          walk_block_body(node, nested, context)

          operations << {
            type: :transaction,
            receiver: send_node.receiver,
            line: send_node.line,
            nested: nested
          }
        else
          # Non-transaction block — recurse into body
          walk_block_body(node, operations, context)
        end
      end

      def handle_conditional(node, operations, context)
        then_ops = []
        else_ops = []

        walk(node.children[1], then_ops, context) if node.children[1]
        walk(node.children[2], else_ops, context) if node.children[2]

        # Only emit if at least one branch has significant operations
        return if then_ops.empty? && else_ops.empty?

        operations << {
          type: :conditional,
          kind: node.type == :if ? "if" : "unless",
          condition: node.children[0].to_source,
          line: node.line,
          then_ops: then_ops,
          else_ops: else_ops
        }
      end

      # Detects: .transaction, .with_lock
      def transaction_call?(node)
        node.type == :send &&
          %w[transaction with_lock].include?(node.method_name)
      end

      # Detects: perform_async, perform_later, perform_in, perform_at
      def async_enqueue?(node)
        node.type == :send &&
          %w[perform_async perform_later perform_in perform_at].include?(node.method_name)
      end

      # Detects: render, redirect_to, head, render_*, respond_with
      def response_call?(node)
        node.type == :send &&
          (node.method_name.start_with?("render") ||
           %w[redirect_to head respond_with].include?(node.method_name))
      end
    end
  end
end
```

### ResponseCodeMapper

Maps render/redirect calls to HTTP status codes using `Rack::Utils::SYMBOL_TO_STATUS_CODE`:

```ruby
module CodebaseIndex
  module FlowAnalysis
    class ResponseCodeMapper
      SYMBOL_TO_STATUS = Rack::Utils::SYMBOL_TO_STATUS_CODE

      # Resolve a render/response AST node to an HTTP status code.
      #
      # @param node [AstNode] A :send node for a render/redirect call
      # @return [Integer, nil] HTTP status code or nil if unresolvable
      def self.resolve(node)
        # Case 1: render json: ..., status: :created
        status_arg = extract_status_kwarg(node)
        return resolve_status(status_arg) if status_arg

        # Case 2: render_created (convention: render_<status>)
        if node.method_name.start_with?("render_")
          status_name = node.method_name.delete_prefix("render_")
          return SYMBOL_TO_STATUS[status_name.to_sym] if SYMBOL_TO_STATUS.key?(status_name.to_sym)
        end

        # Case 3: head :no_content
        if node.method_name == "head" && node.arguments.first
          return resolve_status(node.arguments.first)
        end

        # Case 4: redirect_to (default 302)
        return 302 if node.method_name == "redirect_to"

        nil
      end

      def self.resolve_status(value)
        case value
        when Integer then value
        when Symbol  then SYMBOL_TO_STATUS[value]
        when String
          # Try as symbol first, then as integer
          SYMBOL_TO_STATUS[value.to_sym] || (value.match?(/\A\d+\z/) ? value.to_i : nil)
        end
      end
    end
  end
end
```

---

## Integration with Existing Pipeline

FlowAssembler is designed to layer on top of the existing extraction and retrieval systems without modifying them.

### What It Reuses

| Existing Component | How FlowAssembler Uses It |
|---|---|
| `ExtractedUnit#source_code` | Source input for AST parsing |
| `ExtractedUnit#metadata` | Route data, filter chains, association names for context |
| `ExtractedUnit#dependencies` | Initial set of units to consider for expansion |
| `DependencyGraph#dependencies_of` | Forward traversal for recursive expansion |
| `DependencyGraph#path_between` | Verify connectivity between entry point and resolved targets |
| `ControllerExtractor` route data | Populates the `route` field in FlowDocument |
| Token estimation (`(length / 3.5).ceil`) | Budget-aware flow document generation |

### What It Does Not Change

- **No changes to existing extractors.** Extractors continue producing `ExtractedUnit` as before.
- **No changes to `ExtractedUnit`.** No new fields added to the value object.
- **No changes to `DependencyGraph`.** Uses existing traversal methods.
- **No new columns or migrations.** FlowDocuments are computed on demand, not stored.

### New Additions

| Addition | Purpose |
|---|---|
| `lib/codebase_index/flow_assembler.rb` | Orchestrator |
| `lib/codebase_index/flow_document.rb` | Value object |
| `lib/codebase_index/flow_analysis/` directory | AST parsing and operation extraction |
| `lib/tasks/flow.rake` | Rake interface |

### Retrieval Layer Integration

The `trace` intent in `RETRIEVAL_ARCHITECTURE.md` is designed for queries like "What happens when an order is placed?" The current strategy selector maps this to `graph_traversal + vector_search`, which finds related units but cannot order them.

With FlowAssembler, the `trace` intent can delegate to `FlowAssembler` for entry points that resolve to a specific controller action or service method:

```ruby
# In Retrieval::StrategySelector (future)
when :trace
  if entry_point = resolve_entry_point(classification)
    # Delegate to FlowAssembler for ordered trace
    flow = FlowAssembler.new(graph: graph, extracted_dir: output_dir).assemble(entry_point)
    flow.to_context  # Returns token-budgeted context string
  else
    # Fall back to graph_traversal + vector_search
    HybridSearch.new(...)
  end
```

This is a future integration point — FlowAssembler works standalone via the rake task before the retrieval layer is built.

### Rake Task Interface

```ruby
# lib/tasks/flow.rake
namespace :codebase_index do
  desc "Generate execution flow document for an entry point"
  task :flow, [:entry_point] => :environment do |_t, args|
    require "codebase_index"

    entry_point = args[:entry_point]
    abort "Usage: rake codebase_index:flow[CheckoutsController#create]" unless entry_point

    # Load extracted data from JSON files on disk
    output_dir = CodebaseIndex.configuration.output_dir
    graph = CodebaseIndex::DependencyGraph.load(File.join(output_dir, "dependency_graph.json"))

    assembler = CodebaseIndex::FlowAssembler.new(graph: graph, extracted_dir: output_dir)
    flow = assembler.assemble(entry_point)

    case ENV.fetch("FORMAT", "markdown")
    when "json"
      puts JSON.pretty_generate(flow.to_h)
    when "markdown"
      puts flow.to_markdown
    end
  end
end
```

Usage:

```bash
# Markdown output (default)
bundle exec rake codebase_index:flow[CheckoutsController#create]

# JSON output
FORMAT=json bundle exec rake codebase_index:flow[CheckoutsController#create]

# With depth limit
MAX_DEPTH=3 bundle exec rake codebase_index:flow[CheckoutsController#create]
```

---

## Edge Cases

### Cycles

Units A and B can depend on each other (A calls B, B calls A). FlowAssembler tracks a `visited` set during recursive expansion and stops when revisiting a unit, emitting a `{ type: "cycle", target: "A" }` marker in the output.

### Metaprogramming

Ruby metaprogramming (`define_method`, `method_missing`, `send`) produces calls that are invisible to AST analysis. FlowAssembler handles this by:

1. **Detection:** When it encounters a `send(:method_name, ...)` or `public_send(...)`, it emits a `{ type: "dynamic_dispatch" }` marker with whatever target information is statically available.
2. **No guessing:** It does not attempt to resolve dynamic dispatch at extraction time. The marker signals to the consumer (agent or human) that manual inspection is needed.

### Inherited Methods

When a controller action calls `render_created` and that method is defined in a parent class or concern, the AST for the current class won't contain the method definition. FlowAssembler resolves this by:

1. Checking the current unit's `source_code` (which already includes inlined concerns).
2. Checking parent class units in the dependency graph.
3. If unresolved, emitting the call as-is with a `resolved: false` flag.

### Dynamic Status Codes

Some applications compute status codes dynamically:

```ruby
status = checkout.persisted? ? :ok : :created
render json: checkout, status: status
```

The AST can extract the `render` call but cannot resolve `status` to a concrete value. ResponseCodeMapper returns `nil` for unresolvable status codes, and the operation is emitted with `status_code: null`.

### STI and Polymorphic Dispatch

When `service.call` could dispatch to any of several subclasses, FlowAssembler expands only the statically-determinable target. If the receiver type is ambiguous (e.g., a local variable), it uses the dependency graph to find candidate targets and emits all of them with a `candidates: [...]` field.

### Blocks and Procs

Block-passing patterns like `items.each { |item| process(item) }` are common in Ruby. OperationExtractor walks into block bodies and extracts significant calls, nesting them under the parent call. However, blocks passed as arguments to external methods (e.g., `retry_on(wait: 5.seconds) { do_work }`) are only partially analyzable.

### Framework Callbacks

Before/after action filters are already captured by `ControllerExtractor` in the unit metadata. FlowAssembler reads `metadata[:callbacks]` to prepend before-action operations and append after-action operations to the flow, providing a complete picture of what executes for a given action.

---

## Testing Strategy

### Unit Specs (gem-level, `spec/`)

| Test Area | What to Test | Approach |
|---|---|---|
| `AstParser` | Prism and parser gem produce identical normalized ASTs for the same source | Parse known Ruby snippets with both parsers, compare output |
| `OperationExtractor` | Correct operation extraction for each operation type | Feed known AST structures, assert operation list |
| `ResponseCodeMapper` | Status code resolution for all render/redirect patterns | Table-driven tests: input node → expected status code |
| `FlowAssembler` | Recursive expansion with cycle detection, depth limiting | Mock graph and unit store with known topology |
| `FlowDocument` | `to_h` round-trip serialization, `to_markdown` formatting | Assert JSON structure and markdown output |

Example spec structure:

```ruby
RSpec.describe CodebaseIndex::FlowAnalysis::OperationExtractor do
  describe "#extract" do
    it "extracts method calls in source order" do
      source = <<~RUBY
        def create
          result = FindOrCreate.call(cart)
          Worker.perform_async(result.id)
          render_created(result)
        end
      RUBY

      ast = AstParser.new.extract_method(source, "create")
      ops = described_class.new.extract(ast)

      expect(ops.map { |o| o[:type] }).to eq(%i[call async response])
      expect(ops[0][:target]).to eq("FindOrCreate")
      expect(ops[1][:target]).to eq("Worker")
      expect(ops[2][:status_code]).to eq(201)
    end

    it "extracts transaction blocks with exact receiver" do
      source = <<~RUBY
        def call
          Checkout.transaction do
            cart.lock!
            checkout = Checkout.find_or_create_by!(cart: cart)
          end
        end
      RUBY

      ast = AstParser.new.extract_method(source, "call")
      ops = described_class.new.extract(ast)

      expect(ops.size).to eq(1)
      expect(ops[0][:type]).to eq(:transaction)
      expect(ops[0][:receiver]).to eq("Checkout")
      expect(ops[0][:nested].size).to eq(2)
    end

    it "handles cycles without infinite recursion" do
      # Test via FlowAssembler with a graph where A → B → A
    end
  end
end
```

### Integration Specs (host Rails app, `spec/integration/`)

The host-app has Post, Comment models, controllers, jobs, and a mailer. Add a flow extraction integration test:

1. Run full extraction to produce ExtractedUnits.
2. Call `FlowAssembler.assemble("PostsController#create")`.
3. Assert the flow contains operations in the correct order.
4. Assert response codes resolve correctly.
5. Assert job enqueues are detected.

---

## Implementation Sequence

### Phase 1: AST Foundation

**Goal:** Parse Ruby source and extract operations from a single method body.

**Deliverables:**
- `AstParser` adapter with Prism support (parser gem fallback deferred to Phase 1b if needed)
- `OperationExtractor` handling: method calls, transaction blocks, async enqueues, response calls, conditionals
- `ResponseCodeMapper` resolving render/redirect to HTTP status codes
- Unit specs for all three components

**Unlocks:** Can parse any Ruby method body and produce an ordered operation list. No graph integration yet.

### Phase 2: Flow Assembly

**Goal:** Walk the dependency graph from an entry point and produce a complete flow document.

**Deliverables:**
- `FlowAssembler` orchestrator with recursive expansion, cycle detection, depth limiting
- `FlowDocument` value object with `to_h` (JSON) and `to_markdown`
- Integration with `DependencyGraph` for target resolution
- Integration with `ControllerExtractor` route and callback metadata
- Unit specs for assembler, integration specs in host-app

**Unlocks:** Can generate a complete flow trace from any entry point in the extracted codebase.

### Phase 3: Rake Task and Polish

**Goal:** User-facing interface and edge case handling.

**Deliverables:**
- `flow.rake` task with format and depth options
- Edge case handling: metaprogramming markers, inherited method resolution, dynamic status codes
- Markdown formatting polish
- Documentation updates

**Unlocks:** Developers and agents can generate flow documents on demand via `bundle exec rake codebase_index:flow[entry_point]`.

---

## Open Questions

1. **Scope of "significant calls."** Not every method call is worth including in a flow (e.g., `to_s`, `present?`, attribute accessors). What heuristic separates significant operations from noise? Initial approach: include calls whose receiver resolves to an `ExtractedUnit`, exclude calls on primitives and Rails utility methods. May need a configurable exclusion list.

2. **Multi-method flows.** A service's `call` method may invoke private methods that contain the real logic. Should FlowAssembler inline private method bodies, or treat them as opaque? Initial approach: expand public interface methods only, with an opt-in flag for private method expansion.

3. **Caching flow documents.** Should generated flows be cached on disk (like extracted units), or always computed on demand? On-demand is simpler and avoids staleness, but repeated generation of the same flow is wasteful. Decision deferred until usage patterns emerge.

4. **Parser gem as runtime dependency.** For Ruby < 3.3, the parser gem is needed. Should it be a required dependency, or optional with a helpful error message? The gem already targets Rails apps, most of which run Ruby 3.1+. Prism is available as a backport gem for 3.1/3.2, which may be preferable to the parser gem.

5. **Depth vs. breadth tradeoff.** A deep flow (max_depth: 10) captures everything but may produce overwhelming output. A shallow flow (max_depth: 2) is digestible but incomplete. The default of 5 is a starting point — usage data will inform the right default.
