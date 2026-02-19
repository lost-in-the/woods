# Context Formatting & Chunking Strategy

## Purpose

This document covers two deeply connected problems:

1. **Chunking** — How extracted units are split into embeddable, retrievable pieces. This happens at index time and determines what can be found.

2. **Context formatting** — How retrieved pieces are assembled into a string that an LLM can reason about. This happens at query time and determines how useful the results are.

These two problems are connected because chunking decisions constrain formatting options, and formatting requirements should inform chunking strategy.

---

## Chunking Strategy

### The Tension

Embeddings work best on focused, semantically coherent text. But useful context often requires the bigger picture. A chunk that's too small loses meaning; a chunk that's too large dilutes the embedding signal and wastes tokens when retrieved.

For code, this tension is acute. A model's `validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }` is meaningless without knowing it's on the User model. But embedding the entire User model (with 200 lines of inlined concerns) drowns the validation signal in noise.

### Current Approach: Semantic Chunking

The extraction layer already produces semantic chunks for large units:

**Models** get split into:
- **Summary** — Class definition, table name, column list, key associations
- **Associations** — All `has_many`, `belongs_to`, `has_one` with full options
- **Callbacks** — All lifecycle callbacks (before/after/around for each type)
- **Validations** — All validation rules
- **Scopes** — Named scopes with SQL/Arel logic
- **Concerns** — Each inlined concern as a separate chunk (already done at extraction)

**Controllers** get split per-action:
- Each action gets its own chunk with the applicable `before_action`/`around_action` filters, the route mapping, permitted params, and the action body.

**Services/Jobs/Mailers** are typically small enough to be single chunks.

### Open Question: Chunk Independence vs. Context Dependency

Should each chunk be embedded independently, or should it include parent context?

**Option A: Independent chunks**
```
Chunk: "validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }\nvalidates :name, presence: true, length: { maximum: 100 }"
Embedding: Embed this text as-is
```

Pro: Smaller chunks, more focused embedding signal.
Con: "validates email" could match any model. The embedding has no idea this is User's validations.

**Option B: Context-prefixed chunks**
```
Chunk: "# User model (app/models/user.rb)\n# Table: users (columns: id, email, name, created_at, updated_at)\n# Validations:\nvalidates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }\nvalidates :name, presence: true, length: { maximum: 100 }"
Embedding: Embed this text with context header
```

Pro: Embedding captures that these are User validations. Query for "user email validation" will match strongly.
Con: Larger chunks, repeated context header across all User chunks wastes embedding tokens.

**Option C: Hierarchical embedding (recommended)**

Embed both the full unit *and* the individual chunks. Use the full-unit embedding for broad queries ("tell me about User") and chunk embeddings for specific queries ("user email validation"):

```
Embedding 1: User (full summary — class definition, key metadata, first 50 lines)
Embedding 2: User::associations (context-prefixed)
Embedding 3: User::callbacks (context-prefixed)
Embedding 4: User::validations (context-prefixed)
Embedding 5: User::AuthenticationConcern (context-prefixed, inlined concern)
```

Each chunk embedding includes a minimal context prefix:

```
# Unit: User (model)
# File: app/models/user.rb
# Section: validations
validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
validates :name, presence: true, length: { maximum: 100 }
...
```

This gives the embedding model enough signal to know *what* this code belongs to without duplicating the entire unit.

### Context Prefix Format

The context prefix added to each chunk before embedding:

```
# Unit: {identifier} ({type})
# File: {file_path}
# Section: {chunk_name}
# Dependencies: {top 3 dependencies}
{chunk_content}
```

For the full-unit summary embedding:

```
# Unit: {identifier} ({type})
# File: {file_path}
# Table: {table_name} (columns: {column_list})
# Associations: {count} ({top 3 association names})
# Dependents: {count} units depend on this
# Change frequency: {hot|active|stable|dormant}
{abbreviated source — first ~100 lines or summary chunk}
```

### Chunk Size Targets

| Unit Type | Chunk Strategy | Target Tokens per Chunk |
|-----------|---------------|------------------------|
| Model (< 100 lines) | Single chunk with context prefix | 200-800 |
| Model (100-500 lines) | Semantic split (summary, assoc, callbacks, validations) | 200-600 each |
| Model (> 500 lines) | Semantic split + per-concern chunks | 200-600 each |
| Controller (< 5 actions) | Single chunk | 300-1000 |
| Controller (5+ actions) | Per-action chunks | 200-500 each |
| Service | Single chunk (most are < 200 lines) | 200-1000 |
| Job/Worker | Single chunk | 100-500 |
| Mailer | Per-action if > 3 actions, else single | 200-600 |
| Component | Single chunk | 200-600 |
| GraphQL type/mutation | Summary + field-group chunks (batches of 10 fields) + arguments chunk | 200-800 each |
| Framework source | Per-method or per-concept | 200-800 |

### Embedding Model Context Window Interaction

Chunk size must stay within the embedding model's context window:

| Provider | Max Tokens | Effective Max per Chunk |
|----------|-----------|------------------------|
| OpenAI text-embedding-3-small | 8,191 | ~7,000 (leave room for prefix) |
| OpenAI text-embedding-3-large | 8,191 | ~7,000 |
| Voyage Code 3 | 32,000 | ~30,000 |
| Voyage Code 2 (legacy) | 16,000 | ~14,000 |
| Ollama nomic-embed-text | 8,192 | ~7,000 |

Most extracted chunks will be well under these limits. The exception is large models with many inlined concerns, or framework source files. These should be split at natural boundaries (method definitions, section comments) rather than truncated.

**Truncation fallback:** If a chunk exceeds the context window after splitting at every natural boundary, truncate from the middle (preserve the beginning and end, which typically contain the most important context — class definition and closing logic).

### Re-embedding on Change

When a unit changes, what needs re-embedding?

**Unit-level change (e.g., added a validation to User):**
- Re-embed the full-unit summary (it may reference the validation count)
- Re-embed the changed chunk (User::validations)
- Don't re-embed unchanged chunks (User::associations, User::callbacks)
- Don't re-embed dependents (they reference User, but User's identity hasn't changed)

**Structural change (e.g., added a new association):**
- Re-embed the full-unit summary
- Re-embed the changed chunk (User::associations)
- Consider re-embedding the other end of the association (if Order now `belongs_to :user`, Order's association chunk should update)

**Identity change (e.g., renamed User to Account):**
- Re-embed everything — all chunks, all dependents that reference the old name

**Concern change (e.g., modified the Authentication concern):**
- Re-embed the concern chunk on every model that includes it
- Re-embed the full-unit summary for every includer
- The dependency graph already tracks this — concern → includer edges drive the blast radius

The indexing pipeline tracks chunk checksums to only re-embed chunks whose content actually changed. The extraction layer already implements this: `ExtractedUnit#build_default_chunks` computes a `content_hash` (SHA256) per chunk, and `ExtractedUnit#to_h` includes a `source_hash` for the full unit. The retrieval/embedding layer can compare these hashes against stored values to skip unchanged chunks:

```ruby
# content_hash and source_hash are already computed by the extraction layer.
# The indexing pipeline compares against stored checksums:
module CodebaseIndex
  class ChunkChecksummer
    def needs_reembedding?(chunk)
      # chunk.content_hash is set by ExtractedUnit#build_default_chunks (SHA256)
      stored_checksum = @metadata_store.chunk_checksum(chunk.id)
      chunk.content_hash != stored_checksum
    end
  end
end
```

---

## Context Formatting for LLMs

### The Problem

You've retrieved 7 relevant code units totaling 6,800 tokens. Now you need to format them into a string that an LLM can reason about effectively.

This is not trivial. The format affects:
- Whether the LLM can find specific information within the context
- Whether the LLM correctly attributes code to the right unit
- Whether the LLM understands the relationships between units
- Whether the LLM confuses context with instructions

Different LLMs respond differently to formatting. Claude handles XML structure well. GPT-4 handles markdown well. Both struggle with undifferentiated walls of text.

### Format Strategy: Structured Sections with Clear Boundaries

The assembled context uses a layered format with explicit section markers, unit boundaries, and metadata annotations:

```
<codebase_context query="how does checkout work?" tokens="6841" sources="7">

<structure>
Application overview: Rails 7.1 monolith, MySQL 8.0, 312 models, 94 workers.
Key domain areas: accounts, orders, products, subscriptions, shipping.
Relevant area: Order processing (12 models, 4 services, 3 controllers).
</structure>

<unit identifier="CheckoutService" type="service" file="app/services/checkout_service.rb" relevance="0.94" change_frequency="hot">
class CheckoutService
  def initialize(cart:, account:)
    @cart = cart
    @account = account
  end

  def call
    validate_cart!
    order = create_order
    process_payment(order)
    send_confirmation(order)
    order
  rescue PaymentGateway::PaymentFailed => e
    handle_payment_failure(e)
  end

  private

  def create_order
    Order.create!(
      account: @account,
      line_items: @cart.line_items.map { |li| build_line_item(li) },
      total: @cart.calculated_total
    )
  end

  # ... (truncated, 47 more lines available)
end
</unit>

<unit identifier="Order" type="model" file="app/models/order.rb" relevance="0.89" change_frequency="active">
# Table: orders
# Columns: id (bigint), account_id (bigint), status (varchar), total (decimal),
#          created_at (datetime), updated_at (datetime)
# Indexes: index_orders_on_account_id, index_orders_on_status
# Foreign keys: fk_orders_account_id → accounts.id

class Order < ApplicationRecord
  belongs_to :account
  has_many :line_items, dependent: :destroy
  has_many :payments

  validates :total, numericality: { greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: %w[pending paid shipped cancelled] }

  before_create :generate_order_number
  after_create :notify_warehouse

  scope :recent, -> { where("created_at > ?", 30.days.ago) }

  # ... (truncated, 89 more lines available — includes concerns: Trackable, Discountable)
end
</unit>

<unit identifier="PaymentGateway" type="service" file="app/services/payment_gateway.rb" relevance="0.78" change_frequency="stable">
# ... service source
</unit>

<dependencies>
CheckoutService → Order (creates), PaymentGateway (calls), Cart (reads), OrderMailer (triggers)
Order → Account (belongs_to), LineItem (has_many), Payment (has_many)
PaymentGateway → StripeService (delegates), PaymentLog (writes)
</dependencies>

</codebase_context>
```

### Why This Format

**XML-style tags for section boundaries.** LLMs (especially Claude) handle nested XML well. The tags make it unambiguous where one unit ends and another begins. This prevents the LLM from confusing code in one unit with another.

**Metadata attributes on unit tags.** The `relevance`, `type`, and `change_frequency` attributes give the LLM signals about what to prioritize without consuming significant tokens.

**Schema comments prepended to models.** When the LLM sees `# Table: orders` at the top of the Order model, it can answer schema questions ("what columns does Order have?") without needing a separate schema retrieval.

**Dependency section at the end.** The explicit dependency map helps the LLM reason about relationships without scanning all the source code to infer them.

**Truncation markers.** `# ... (truncated, 47 more lines available)` tells the LLM (and the human) that more exists. This is important — the LLM should know when it has partial information.

### Adapter Pattern for LLM-Specific Formatting

Different LLMs prefer different formats. The context formatter uses an adapter pattern:

```ruby
module CodebaseIndex
  module Formatting
    class Adapter
      def format(assembled_context)
        raise NotImplementedError
      end
    end

    class ClaudeAdapter < Adapter
      # Claude handles XML well, prefers structured tags
      def format(context)
        sections = []
        sections << xml_tag("codebase_context", context.metadata) {
          [
            xml_tag("structure") { context.structural_overview },
            *context.sources.map { |s| format_unit(s) },
            xml_tag("dependencies") { format_dependency_map(context.dependencies) }
          ].join("\n\n")
        }
        sections.join("\n")
      end

      private

      def format_unit(source)
        attrs = {
          identifier: source.identifier,
          type: source.type,
          file: source.file_path,
          relevance: source.relevance_score.round(2),
          change_frequency: source.change_frequency
        }
        xml_tag("unit", attrs) { source.formatted_source }
      end
    end

    class GPTAdapter < Adapter
      # GPT-4 handles markdown well
      def format(context)
        sections = []
        sections << "## Codebase Context\n"
        sections << "**Query:** #{context.query}\n"
        sections << "### Structure\n#{context.structural_overview}\n"

        context.sources.each do |source|
          sections << "### #{source.identifier} (#{source.type})"
          sections << "*File: #{source.file_path} | Relevance: #{source.relevance_score.round(2)}*\n"
          sections << "```ruby\n#{source.formatted_source}\n```\n"
        end

        sections << "### Dependencies\n#{format_dependency_map(context.dependencies)}\n"
        sections.join("\n")
      end
    end

    class GenericAdapter < Adapter
      # Plain text with clear separators — works with any LLM
      def format(context)
        sections = []
        sections << "=== CODEBASE CONTEXT ==="
        sections << "Query: #{context.query}"
        sections << ""
        sections << "--- STRUCTURE ---"
        sections << context.structural_overview
        sections << ""

        context.sources.each do |source|
          sections << "--- #{source.identifier} (#{source.type}) ---"
          sections << "File: #{source.file_path}"
          sections << "Relevance: #{source.relevance_score.round(2)}"
          sections << ""
          sections << source.formatted_source
          sections << ""
        end

        sections << "--- DEPENDENCIES ---"
        sections << format_dependency_map(context.dependencies)
        sections.join("\n")
      end
    end
  end
end
```

### Configuration

```ruby
CodebaseIndex.configure do |config|
  # Auto-detect from environment, or set explicitly:
  config.context_format = :claude    # XML-structured
  config.context_format = :gpt      # Markdown
  config.context_format = :generic  # Plain text separators

  # Or provide a custom formatter:
  config.context_formatter = MyCustomFormatter.new
end
```

### Formatting Rules

Regardless of adapter, these rules apply:

**1. Never include instructions in context.**

The context block should contain only code and metadata. Never include phrases like "You should answer based on the following code" or "Use this context to help the user." That belongs in the system prompt or user message, not in the retrieval output.

The retrieval system returns data. The integration layer (MCP server, CLI, editor plugin) is responsible for framing that data within a prompt.

**2. Preserve exact source code.**

Don't rewrite, summarize, or normalize the code in context. The LLM needs to see the actual source to give accurate answers. Reformatting variable names or collapsing whitespace can change meaning.

Exception: stripping trailing whitespace and normalizing line endings is fine.

**3. Annotate truncations explicitly.**

When a unit is truncated to fit the token budget, mark what's missing:

```ruby
# ... (truncated: 47 lines omitted — callbacks, private methods)
# Full source: app/models/order.rb (156 lines, 4,200 tokens)
```

This gives the LLM (and the agent) enough information to decide whether to retrieve the full unit.

**4. Order by relevance, not alphabetically.**

The first unit in the context should be the most relevant. LLMs weight content near the beginning of their context window more heavily (primacy effect). Don't waste this position on structural overview for focused queries.

Exception: structural overview always comes first for `exploratory` and `comprehensive` scope queries, because the LLM needs the big picture before diving into specifics.

**5. Include unit boundaries even for single-unit results.**

Even if only one unit is retrieved, wrap it in the standard format tags. This maintains consistency for agents that parse the output, and prevents the LLM from confusing the code context with conversational text.

**6. Keep dependency maps compact.**

The dependency section uses arrow notation, not full source:

```
CheckoutService → Order (creates), PaymentGateway (calls)
```

Not:

```
CheckoutService depends on Order (creates instances via Order.create!)
CheckoutService depends on PaymentGateway (calls PaymentGateway.new.charge)
```

The compact form costs fewer tokens and the LLM can look at the source for details.

### Token Budget Interaction

Context formatting has its own token overhead. The format adapter must account for this:

| Format | Overhead per Unit | Overhead Total (7 units) |
|--------|------------------|-------------------------|
| Claude (XML) | ~40 tokens (tags + attributes) | ~350 tokens |
| GPT (Markdown) | ~30 tokens (headers + fences) | ~280 tokens |
| Generic (plain text) | ~20 tokens (separators) | ~210 tokens |
| Structural section | — | ~100-200 tokens |
| Dependency map | — | ~50-150 tokens |

The context assembler should reserve formatting overhead from the token budget before allocating to content:

```ruby
def available_content_budget(total_budget, source_count, format)
  format_overhead = format.estimated_overhead(source_count)
  structural_overhead = 200  # approximate
  dependency_overhead = 100  # approximate
  total_budget - format_overhead - structural_overhead - dependency_overhead
end
```

### Formatting for Agent Tool Responses

When CodebaseIndex serves as an MCP tool, the formatted context is returned as a tool result. In this case, the format should be optimized for the agent's model:

```ruby
# MCP tool response
{
  "content": [
    {
      "type": "text",
      "text": formatted_context  # Uses the appropriate adapter
    }
  ],
  "isError": false
}
```

The MCP server should select the appropriate formatter based on configuration. Note: the MCP protocol does not expose the client model to the server, so model-specific formatting cannot be auto-detected. The format must be set via configuration (e.g., `config.context_format = :claude`) or defaulted to the generic adapter.

### Formatting for CLI / Human Consumption

When a human reads the output (via CLI or rake task), use a more readable format:

```
╔══════════════════════════════════════════════════════════════╗
║  Codebase Context: "how does checkout work?"                ║
║  7 sources, 6,841 tokens                                   ║
╚══════════════════════════════════════════════════════════════╝

── CheckoutService (service) ─────────────────── relevance: 0.94
   app/services/checkout_service.rb | hot | 12 dependents

   class CheckoutService
     def initialize(cart:, account:)
       ...
     end
   end

── Order (model) ─────────────────────────────── relevance: 0.89
   app/models/order.rb | active | 34 dependents

   # Table: orders (id, account_id, status, total, ...)
   class Order < ApplicationRecord
     ...
   end

── Dependencies ──────────────────────────────────────────────
   CheckoutService → Order, PaymentGateway, Cart, OrderMailer
   Order → Account, LineItem, Payment
```

This is handled by a `HumanAdapter` formatter.

---

## Validation Plan

### Chunking Validation

To validate that semantic chunking produces better retrieval than alternatives, run a comparative evaluation:

**Chunking strategies to compare:**

| Strategy | Description |
|----------|-------------|
| Semantic (current) | Split by purpose: summary, associations, callbacks, validations |
| File-level | One embedding per file, no splitting |
| Fixed-size | Split at ~500 token boundaries regardless of content |
| Method-level | One chunk per method definition |
| AST-based | Split at Ruby AST node boundaries (class, module, method, block) |

**Evaluation protocol:**

1. Extract 10 representative models of varying sizes (50-500 lines)
2. Apply each chunking strategy
3. Embed all chunks with the same provider (OpenAI text-embedding-3-small)
4. Run 25 queries against each strategy (mix of specific and broad)
5. Measure Precision@5, MRR, and token efficiency
6. Qualitative assessment: for 10 selected queries, which strategy produces the most useful context?

**Hypothesis:** Semantic chunking outperforms fixed-size and file-level for specific queries ("what validations does User have?") but may underperform for broad queries ("tell me about User"). Hierarchical embedding (Option C above) should handle both cases.

### Context Format Validation

To validate formatting effectiveness:

1. Take 10 retrieval results
2. Format each with Claude, GPT, and Generic adapters
3. Present each formatted context + query to the respective LLM
4. Evaluate response quality (correctness, completeness, attribution accuracy)
5. Compare: does format actually matter, or is the content what matters?

**Hypothesis:** Format matters most for multi-unit retrievals (where boundary clarity is important) and less for single-unit lookups. XML tags will outperform plain separators for Claude on complex queries.
