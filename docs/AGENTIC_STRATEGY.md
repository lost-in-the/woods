# Agentic Strategy Guide

## Purpose

This document defines how AI agents should interact with CodebaseIndex. It serves as both a design specification for the tool-use interface and a reference guide that agents can consult when deciding how to retrieve codebase context.

The key insight: an agent's retrieval strategy should vary based on what it's trying to accomplish. A debugging task needs different context than an implementation task. This document maps task types to retrieval patterns.

---

## Core Principles

### 1. Retrieve, Don't Guess

When an agent has access to CodebaseIndex, it should retrieve before answering any codebase-specific question. Even if the agent has seen the code in a previous turn, the index may contain richer context (inlined concerns, dependency graph, framework source).

### 2. Start Narrow, Expand As Needed

Begin with the most specific retrieval possible. If that's insufficient, broaden. Don't start with comprehensive retrieval — it wastes token budget on potentially irrelevant context.

```
Step 1: Direct lookup ("Order model") → specific unit
Step 2: If insufficient, retrieve dependencies
Step 3: If still insufficient, semantic search for related concepts
Step 4: If framework behavior needed, retrieve framework source
```

### 3. Budget Awareness

Every retrieval consumes token budget. An agent should track how much context it's accumulated and make explicit decisions about what to include vs. summarize vs. drop.

### 4. Attribution

When the agent references information from retrieval, it should cite the source unit. This enables the human to verify and builds trust.

---

## Tool-Use Interface

### Available Tools

```yaml
tools:
  - name: codebase_retrieve
    description: >
      Semantic retrieval with automatic query classification.
      Returns token-budgeted context with source attribution.
      Best for natural language questions about the codebase.
    parameters:
      query: string (required)
      budget: integer (optional, default 8000)
      filters:
        type: string[] (optional, e.g. ["model", "service"])
        namespace: string[] (optional)
        recency: string (optional, "hot" | "active" | "stable" | "dormant")
      include_framework: boolean (optional, default auto-detect)

  - name: codebase_lookup
    description: >
      Direct unit fetch by identifier. Returns the full extracted unit
      with metadata, source, dependencies, and chunks.
      Best when you know exactly what you need.
    parameters:
      identifier: string (required, e.g. "Order", "CheckoutService")

  - name: codebase_dependencies
    description: >
      Forward dependency graph traversal. Returns everything
      this unit depends on, up to specified depth.
    parameters:
      identifier: string (required)
      depth: integer (optional, default 2)
      types: string[] (optional, filter dependency types)

  - name: codebase_dependents
    description: >
      Reverse dependency graph traversal. Returns everything
      that depends on this unit ("who uses this?").
    parameters:
      identifier: string (required)
      depth: integer (optional, default 2)
      types: string[] (optional)

  - name: codebase_search
    description: >
      Keyword/identifier search across indexed units.
      Best for finding units by name, method, column, or route.
    parameters:
      keywords: string[] (required)
      fields: string[] (optional, default all)
      filters: object (optional)

  - name: codebase_framework
    description: >
      Retrieve Rails/gem source for a specific concept.
      Returns version-pinned implementation details.
    parameters:
      concept: string (required, e.g. "has_many", "validates", "before_action")
      gem: string (optional, e.g. "activerecord", "devise")

  - name: codebase_structure
    description: >
      High-level codebase overview. Model counts, key services,
      architectural patterns, tech stack summary.
    parameters:
      detail: string (optional, "summary" | "full", default "summary")

  - name: codebase_recent_changes
    description: >
      Recently modified units. Useful for understanding what's
      actively being worked on.
    parameters:
      limit: integer (optional, default 20)
      type: string (optional, filter by unit type)

  - name: codebase_graph_analysis
    description: >
      Structural analysis of the dependency graph. Returns orphans
      (no dependencies or dependents), dead ends (no dependents),
      hubs (most connections), cycles, and bridges (edges whose
      removal would disconnect subgraphs).
    parameters:
      analysis: string (optional, "orphans" | "dead_ends" | "hubs" | "cycles" | "bridges" | "all", default "all")
      limit: integer (optional, default 20)

  - name: codebase_pagerank
    description: >
      PageRank scores for all units in the dependency graph.
      Identifies the most structurally important units — those
      that are most connected and most depended upon.
    parameters:
      limit: integer (optional, default 20)
```

---

## Task-to-Strategy Mapping

### Task: Understanding a Feature

**Scenario:** "How does checkout work in this application?"

**Strategy: Broad semantic → dependency expansion → selective deep dive**

```
1. codebase_retrieve("checkout flow order processing")
   → Returns: CheckoutService, OrdersController#create, Cart, Order
   → Token cost: ~3000

2. Agent identifies CheckoutService as central.
   codebase_dependencies("CheckoutService", depth: 1)
   → Returns: PaymentGateway, ShippingCalculator, TaxService, Order
   → Token cost: ~2000

3. Agent needs to understand payment specifically.
   codebase_lookup("PaymentGateway")
   → Returns: Full unit with methods, dependencies, error handling
   → Token cost: ~800

Total budget used: ~5800 / 8000
Agent now has enough context to explain the checkout flow.
```

**Key decisions:**
- Don't retrieve everything at once — it fills the budget with potentially irrelevant units
- Use dependency graph to discover related units rather than guessing
- Stop retrieving when you have enough to answer the question

---

### Task: Debugging an Error

**Scenario:** "Getting a `NoMethodError` on `order.calculate_total` — why?"

**Strategy: Direct lookup → callback/concern inspection → framework check**

```
1. codebase_lookup("Order")
   → Returns: Full model with inlined concerns, callbacks, methods
   → Agent checks: is calculate_total defined? In a concern? In a module?
   → Token cost: ~1500

2. If method isn't visible, check if it's dynamically defined:
   codebase_framework("method_missing activerecord")
   → Returns: How AR handles dynamic methods, attribute methods, etc.
   → Token cost: ~500

3. If it's in a concern:
   Agent already has it (concerns are inlined in extraction).
   Check the concern's conditional inclusion logic.

4. Check recent changes:
   codebase_recent_changes(limit: 10, type: "model")
   → Was Order or any of its concerns recently modified?
   → Token cost: ~400

Total budget used: ~2400 / 8000
```

**Key decisions:**
- Start with the specific unit, not a semantic search
- Inlined concerns mean you don't need to separately fetch them
- Framework source is useful when the error might be Rails behavior, not app code
- Recent changes can identify regressions

---

### Task: Implementing a New Feature

**Scenario:** "Add a gift card payment method to checkout"

**Strategy: Understand existing patterns → find analogous implementations → identify integration points**

```
1. codebase_retrieve("payment methods checkout payment processing")
   → Returns: PaymentGateway, StripeService, PaypalService, etc.
   → Agent understands the payment abstraction pattern
   → Token cost: ~3000

2. codebase_lookup("StripeService")
   → Study how an existing payment method is implemented
   → Identify the interface: what methods it exposes, how it's called
   → Token cost: ~800

3. codebase_dependents("PaymentGateway", depth: 1)
   → Who calls into the payment system?
   → Identifies: CheckoutService, RefundService, AdminPaymentsController
   → These are the integration points for the new payment method
   → Token cost: ~1000

4. codebase_search(keywords: ["payment", "gateway"], fields: ["routes"])
   → Find the routes/controllers that handle payment selection
   → Token cost: ~300

Total budget used: ~5100 / 8000
Agent can now propose: "Based on the existing pattern (StripeService, PaypalService),
create a GiftCardService that implements the same interface..."
```

**Key decisions:**
- Find existing analogous code before proposing new code
- Use reverse dependencies to find integration points
- The agent should propose code that follows existing patterns

---

### Task: Performance Investigation

**Scenario:** "The orders page is slow — what might cause it?"

**Strategy: Trace the request path → identify heavy operations → check callback chains**

```
1. codebase_search(keywords: ["orders"], fields: ["routes"])
   → Find: GET /admin/orders → OrdersController#index
   → Token cost: ~200

2. codebase_lookup("OrdersController")
   → Full controller with filter chain, actions, params
   → Agent sees: before_actions, eager loading (or lack thereof), serialization
   → Token cost: ~1200

3. codebase_dependencies("OrdersController", depth: 1)
   → Models loaded: Order, Account, LineItem, Shipment...
   → Agent checks for N+1 patterns in the action code
   → Token cost: ~2000

4. codebase_lookup("Order")
   → Check: scopes used in index, callback chain on load, association counts
   → Token cost: ~1500

5. codebase_retrieve("order serializer decorator presenter")
   → Find how orders are rendered — heavy serialization?
   → Token cost: ~1000

Total budget used: ~5900 / 8000
```

**Key decisions:**
- Start from the HTTP entry point (route → controller)
- Follow the data loading path (controller → models)
- Check for known Rails performance antipatterns (N+1, missing eager loads, heavy callbacks on read)
- Check the rendering/serialization layer

---

### Task: Framework Reference

**Scenario:** "What options does has_many accept in our Rails version?"

**Strategy: Direct framework source retrieval**

```
1. codebase_framework("has_many", gem: "activerecord")
   → Returns: Exact source from the installed Rails version
   → Includes: all options, their defaults, and behavior
   → Token cost: ~2000

That's it. One call. No need for application code.
```

**Key decision:** Recognize when the question is about Rails behavior, not application behavior. Route directly to framework source.

---

### Task: Impact Analysis

**Scenario:** "What would break if I change the Order model's `total` column to `total_amount`?"

**Strategy: Reverse dependency traversal → keyword search for column references**

```
1. codebase_dependents("Order", depth: 2)
   → Everything that uses Order: controllers, services, jobs, mailers, components
   → Token cost: ~3000

2. codebase_search(keywords: ["total"], fields: ["method_names", "column_names"])
   → Find every unit that references a `total` method/column
   → Token cost: ~500

3. Agent cross-references: which of the dependents reference `total`?
   → These are the units that would need updating.

Total budget used: ~3500 / 8000
```

**Key decision:** Combine graph traversal (structural dependencies) with keyword search (textual references) for complete impact analysis.

---

### Task: Understanding a GraphQL API

**Scenario:** "What data can I fetch through the GraphQL API for orders?"

**Strategy: Type lookup → field expansion → resolver inspection**

```
1. codebase_search(keywords: ["order"], fields: ["identifier"], filters: { type: ["graphql_type", "graphql_query"] })
   → Returns: OrderType, OrderConnection, OrdersQuery
   → Token cost: ~300

2. codebase_lookup("OrderType")
   → Returns: Full type with fields, field-group chunks, arguments
   → Agent sees: all exposed fields, their types, resolver methods
   → Token cost: ~600

3. codebase_dependencies("OrderType", depth: 1)
   → Returns: Order (model), LineItemType, AccountType — the underlying data sources
   → Token cost: ~1000

4. codebase_lookup("OrdersQuery")
   → Returns: Query resolver with arguments, authorization, and data loading
   → Token cost: ~500

Total budget used: ~2400 / 8000
Agent can now explain what's available through the GraphQL API for orders.
```

**Key decisions:**
- Filter by GraphQL unit types to avoid noise from models/controllers with similar names
- GraphQL types map to underlying models — use dependency traversal to connect the API layer to the data layer
- Resolver source shows authorization and data loading patterns

---

### Task: GraphQL Mutation Impact

**Scenario:** "What happens when CreateOrder mutation runs? What side effects does it trigger?"

**Strategy: Mutation lookup → dependency chain → callback inspection**

```
1. codebase_lookup("CreateOrderMutation")
   → Returns: Mutation with arguments, return type, resolver body
   → Token cost: ~600

2. codebase_dependencies("CreateOrderMutation", depth: 1)
   → Returns: Order, CheckoutService, OrderType — what it creates and calls
   → Token cost: ~800

3. codebase_lookup("Order")
   → Check callbacks: after_create hooks, mailer triggers, job enqueues
   → Token cost: ~1500

Total budget used: ~2900 / 8000
```

**Key decision:** GraphQL mutations are thin wrappers — the real logic lives in services and model callbacks. Follow the dependency chain to find side effects.

---

### Task: Onboarding / Orientation

**Scenario:** New developer asks "Give me an overview of this codebase"

**Strategy: Structure overview → key models → architectural patterns**

```
1. codebase_structure(detail: "full")
   → Returns: Model counts, service patterns, tech stack, key conventions
   → Token cost: ~1000

2. codebase_retrieve("core domain models most important")
   → Returns: The models with highest importance scores
   → Token cost: ~2000

3. codebase_retrieve("architectural patterns service objects conventions")
   → Returns: Representative service objects showing patterns
   → Token cost: ~2000

Total budget used: ~5000 / 8000
Agent can synthesize a codebase orientation document.
```

---

## Multi-Turn Retrieval Patterns

### Conversation Context Management

Across multiple turns, the agent should:

1. **Track retrieved units** — Don't re-retrieve what you already have
2. **Accumulate understanding** — Build a mental model across turns
3. **Adjust budget** — Later turns can use remaining budget from earlier turns
4. **Reference previous retrievals** — "As seen in the Order model retrieved earlier..."

### Deduplication

The retrieval layer accepts a `previously_retrieved` parameter:

```yaml
codebase_retrieve:
  query: "order validation rules"
  previously_retrieved: ["Order", "CheckoutService", "OrdersController"]
  # These units will be excluded from results (already in context)
```

### Progressive Depth

```
Turn 1: "What does this codebase do?"
  → codebase_structure() → broad overview
  
Turn 2: "Tell me more about the order system"
  → codebase_retrieve("order system") → key order-related units
  
Turn 3: "How are payments handled?"
  → codebase_dependencies("Order") filtered to payment-related
  → codebase_lookup("PaymentGateway")
  
Turn 4: "What happens when a payment fails?"
  → codebase_retrieve("payment failure error handling retry")
  → codebase_framework("rescue_from") if error handling is framework-level
```

Each turn builds on the previous, and the agent's understanding compounds.

---

## Output Format for Agents

### Structured Response

Retrieval results should be structured for agent consumption, not just raw text:

```json
{
  "context": "... assembled context string ...",
  "tokens_used": 4521,
  "budget_remaining": 3479,
  "sources": [
    {
      "identifier": "Order",
      "type": "model",
      "file_path": "app/models/order.rb",
      "relevance_score": 0.94,
      "change_frequency": "hot",
      "truncated": false
    },
    {
      "identifier": "CheckoutService",
      "type": "service",
      "file_path": "app/services/checkout_service.rb",
      "relevance_score": 0.87,
      "change_frequency": "active",
      "truncated": false
    }
  ],
  "classification": {
    "intent": "understand",
    "scope": "focused",
    "target_type": "service",
    "framework_context": false
  },
  "suggestions": [
    "Consider retrieving dependencies of CheckoutService for more context",
    "Related units not included due to budget: RefundService, OrderMailer"
  ]
}
```

### Suggestions Field

The `suggestions` field helps agents decide what to retrieve next. It includes:
- Units that were relevant but didn't fit in the budget
- Dependency paths that might be useful
- Framework source that might clarify behavior
- Related units in the same namespace

### Confidence Signals

Each source includes a `relevance_score` so the agent can assess confidence:
- 0.90+ → Highly relevant, almost certainly what was asked about
- 0.75-0.90 → Likely relevant, worth including
- 0.60-0.75 → Possibly relevant, include if budget allows
- < 0.60 → Marginal, probably noise

---

## MCP Server Design

For agent frameworks that support MCP (Model Context Protocol), CodebaseIndex exposes itself as an MCP server:

```json
{
  "name": "codebase-index",
  "version": "1.0.0",
  "description": "Rails codebase extraction and retrieval",
  "tools": [
    {
      "name": "retrieve",
      "description": "Semantic retrieval with auto-classification",
      "inputSchema": {
        "type": "object",
        "properties": {
          "query": { "type": "string" },
          "budget": { "type": "integer", "default": 8000 },
          "filters": { "type": "object" }
        },
        "required": ["query"]
      }
    },
    {
      "name": "lookup",
      "description": "Direct unit fetch by identifier",
      "inputSchema": {
        "type": "object",
        "properties": {
          "identifier": { "type": "string" }
        },
        "required": ["identifier"]
      }
    },
    {
      "name": "dependencies",
      "description": "Forward dependency traversal",
      "inputSchema": {
        "type": "object",
        "properties": {
          "identifier": { "type": "string" },
          "depth": { "type": "integer", "default": 2 }
        },
        "required": ["identifier"]
      }
    },
    {
      "name": "dependents",
      "description": "Reverse dependency traversal (who uses this?)",
      "inputSchema": {
        "type": "object",
        "properties": {
          "identifier": { "type": "string" },
          "depth": { "type": "integer", "default": 2 }
        },
        "required": ["identifier"]
      }
    },
    {
      "name": "framework",
      "description": "Version-pinned Rails/gem source",
      "inputSchema": {
        "type": "object",
        "properties": {
          "concept": { "type": "string" },
          "gem": { "type": "string" }
        },
        "required": ["concept"]
      }
    },
    {
      "name": "structure",
      "description": "Codebase overview and architecture summary",
      "inputSchema": {
        "type": "object",
        "properties": {
          "detail": { "type": "string", "enum": ["summary", "full"] }
        }
      }
    },
    {
      "name": "graph_analysis",
      "description": "Structural analysis: orphans, dead ends, hubs, cycles, bridges",
      "inputSchema": {
        "type": "object",
        "properties": {
          "analysis": { "type": "string", "enum": ["orphans", "dead_ends", "hubs", "cycles", "bridges", "all"], "default": "all" },
          "limit": { "type": "integer", "default": 20 }
        }
      }
    },
    {
      "name": "pagerank",
      "description": "PageRank scores for dependency graph nodes",
      "inputSchema": {
        "type": "object",
        "properties": {
          "limit": { "type": "integer", "default": 20 }
        }
      }
    }
  ],
  "resources": [
    {
      "uri": "codebase://manifest",
      "name": "Index Manifest",
      "description": "Extraction metadata, git SHA, unit counts"
    },
    {
      "uri": "codebase://graph",
      "name": "Dependency Graph",
      "description": "Full dependency graph as adjacency list, with PageRank scores and structural analysis (orphans, dead ends, hubs, cycles, bridges)"
    }
  ]
}
```

### MCP Server Implementation Strategy

The MCP server wraps the Ruby retrieval core:

```
Agent (Claude Code, Cursor, etc.)
  │
  │ MCP protocol (stdio or HTTP)
  │
  ▼
┌──────────────────┐
│ MCP Server       │  Ruby process, thin protocol wrapper
│ (mcp-server-rb)  │
└──────────────────┘
  │
  │ Direct Ruby calls
  │
  ▼
┌──────────────────┐
│ CodebaseIndex    │  Retriever, stores, embedding provider
│ Retrieval Core   │
└──────────────────┘
```

The server can run:
- **Standalone:** `bundle exec codebase-mcp-server` (stdio mode)
- **In-process:** Loaded within a Rails console or development server
- **HTTP:** As a Rack app for network-accessible retrieval

---

## Anti-Patterns

### Don't: Retrieve Everything First

```
# BAD: Burns entire budget on one massive retrieval
codebase_retrieve("tell me everything about orders", budget: 16000)
```

```
# GOOD: Incremental, focused retrieval
codebase_lookup("Order")
# ... assess what's needed ...
codebase_dependencies("Order", depth: 1)
```

### Don't: Ignore Classification

```
# BAD: Treat every question the same way
codebase_retrieve("what column type is users.email")  # Wastes budget on semantic search
```

```
# GOOD: Use the right tool
codebase_lookup("User")  # Direct lookup, check schema metadata
```

### Don't: Re-Retrieve Known Context

```
# BAD: Retrieve Order again in a follow-up turn
Turn 1: codebase_lookup("Order")
Turn 2: codebase_retrieve("order validations")  # Will re-fetch Order
```

```
# GOOD: Use previously_retrieved
Turn 2: codebase_retrieve("order validations", previously_retrieved: ["Order"])
```

### Don't: Skip Framework Source for Framework Questions

```
# BAD: Answer "what options does validates support" from memory
# LLM training data mixes Rails versions
```

```
# GOOD: 
codebase_framework("validates", gem: "activerecord")
# Returns exact options for the installed Rails version
```

### Don't: Ignore the Dependency Graph

```
# BAD: Semantic search for "what services use Order"
codebase_retrieve("services that use Order")  # May miss some
```

```
# GOOD: Graph traversal is exhaustive
codebase_dependents("Order", types: ["service"])
# Returns ALL services that depend on Order
```

---

## Evaluation Queries

These queries can be used to evaluate retrieval quality across different task types:

### Understanding Queries
1. "How does the checkout process work end-to-end?"
2. "Explain the relationship between accounts and subscriptions"
3. "What happens when a product is published?"
4. "How are prices calculated for an order?"

### Debugging Queries
5. "What callbacks fire when an order is saved?"
6. "What could cause a payment to silently fail?"
7. "Why might a user's session not persist?"
8. "What validations prevent order creation?"

### Implementation Queries
9. "How should I add a new discount type?"
10. "What's the pattern for adding a new background job?"
11. "How do existing services handle external API failures?"
12. "What's the convention for adding a new admin controller?"

### Framework Queries
13. "What options does has_many support?"
14. "How does Rails handle strong parameters?"
15. "What lifecycle callbacks exist for ActiveRecord?"
16. "How does Devise handle authentication?"

### Impact Queries
17. "What would break if I rename the orders table?"
18. "What depends on the Account model?"
19. "What services would be affected by changing the payment API?"
20. "Which controllers use the authentication concern?"

### Performance Queries
21. "What models have the most callbacks?"
22. "Which controllers load the most associations?"
23. "What are the most frequently changed files?"
24. "Which services have the most dependencies?"

### GraphQL Queries
25. "What fields are exposed on the OrderType?"
26. "How does the CreateOrder mutation work end-to-end?"
27. "What GraphQL types depend on the Account model?"
28. "Which mutations trigger background jobs?"
29. "What authorization checks exist in the GraphQL layer?"

### Orientation Queries
30. "Give me an overview of this codebase"
31. "What are the key domain models?"
32. "What external services does this app integrate with?"
33. "What's the testing strategy?"

---

## Agent-as-Operator

The preceding sections cover agents as *consumers* of the index — querying, retrieving, assembling context. This section covers agents as *operators*: triggering extraction, managing the embedding pipeline, diagnosing failures, and recovering from errors.

### Why Agents Need Operator Capabilities

A fully autonomous coding agent should be able to notice that its index is stale, trigger a re-extraction, verify the results, and resume its coding task — all without human intervention. Today's design requires a human to run `rake codebase_index:extract` and `rake codebase_index:index`. Operator tools close this gap.

### Operator Tool Interface

```yaml
tools:
  - name: codebase_extract
    description: >
      Trigger extraction for the current codebase. Runs the extraction
      pipeline and produces updated JSON output. Supports full or
      incremental modes.
    parameters:
      mode: string (required, "full" | "incremental")
      extractors: string[] (optional, default all configured)
      dry_run: boolean (optional, default false)

  - name: codebase_embed
    description: >
      Trigger embedding for extracted units. Generates vector embeddings
      and stores them in the configured vector store. Supports full
      re-index or targeted updates.
    parameters:
      mode: string (required, "full" | "incremental")
      identifiers: string[] (optional, for incremental — specific units to re-embed)

  - name: codebase_pipeline_status
    description: >
      Check the status of extraction and embedding pipelines.
      Returns last run times, unit counts, staleness assessment,
      and any pending retry queue items.
    parameters: {}

  - name: codebase_diagnose
    description: >
      Run diagnostic checks on the index. Validates schema version,
      embedding dimensions, manifest freshness, unit count consistency,
      and component health (vector store, metadata store, graph store).
    parameters:
      checks: string[] (optional, default all)
        # Available: "schema", "dimensions", "freshness", "counts", "health"

  - name: codebase_repair
    description: >
      Attempt to repair specific index issues identified by codebase_diagnose.
      Supports targeted repairs without full re-index.
    parameters:
      issue: string (required, "stale_units" | "missing_embeddings" | "orphaned_vectors" | "count_mismatch")
      identifiers: string[] (optional, scope repair to specific units)
```

### MCP Server Extensions

```json
{
  "tools": [
    {
      "name": "extract",
      "description": "Trigger codebase extraction (full or incremental)",
      "inputSchema": {
        "type": "object",
        "properties": {
          "mode": { "type": "string", "enum": ["full", "incremental"] },
          "extractors": { "type": "array", "items": { "type": "string" } },
          "dry_run": { "type": "boolean", "default": false }
        },
        "required": ["mode"]
      }
    },
    {
      "name": "embed",
      "description": "Trigger embedding pipeline (full or incremental)",
      "inputSchema": {
        "type": "object",
        "properties": {
          "mode": { "type": "string", "enum": ["full", "incremental"] },
          "identifiers": { "type": "array", "items": { "type": "string" } }
        },
        "required": ["mode"]
      }
    },
    {
      "name": "pipeline_status",
      "description": "Check extraction and embedding pipeline status",
      "inputSchema": { "type": "object", "properties": {} }
    },
    {
      "name": "diagnose",
      "description": "Run index health diagnostics",
      "inputSchema": {
        "type": "object",
        "properties": {
          "checks": { "type": "array", "items": { "type": "string" } }
        }
      }
    },
    {
      "name": "repair",
      "description": "Repair specific index issues",
      "inputSchema": {
        "type": "object",
        "properties": {
          "issue": { "type": "string", "enum": ["stale_units", "missing_embeddings", "orphaned_vectors", "count_mismatch"] },
          "identifiers": { "type": "array", "items": { "type": "string" } }
        },
        "required": ["issue"]
      }
    }
  ]
}
```

### Pipeline Status Response

```json
{
  "extraction": {
    "last_run": "2025-02-08T14:30:00Z",
    "mode": "incremental",
    "git_sha": "abc123f",
    "units_extracted": 47,
    "duration_seconds": 12.3,
    "status": "completed"
  },
  "embedding": {
    "last_run": "2025-02-08T14:31:00Z",
    "mode": "incremental",
    "units_embedded": 47,
    "retry_queue_size": 0,
    "duration_seconds": 8.7,
    "status": "completed"
  },
  "index": {
    "total_units": 1247,
    "total_embeddings": 1247,
    "manifest_git_sha": "abc123f",
    "current_git_sha": "def456a",
    "staleness": "3_commits_behind",
    "schema_version": "004"
  },
  "health": {
    "vector_store": "ok",
    "metadata_store": "ok",
    "graph_store": "ok",
    "embedding_provider": "ok"
  }
}
```

### Failure Diagnosis Patterns

When an agent encounters a retrieval that returns empty or degraded results, it should follow this diagnostic flow:

```
1. codebase_pipeline_status()
   → Check: Is the index stale? Is the embedding pipeline behind?

2. If stale:
   codebase_extract(mode: "incremental")
   → Re-extract changed units
   codebase_embed(mode: "incremental")
   → Re-embed the newly extracted units

3. If extraction fails:
   codebase_diagnose(checks: ["schema", "health"])
   → Identify: Is it a schema mismatch? A down backend?

4. If a component is unhealthy:
   Agent reports to human: "Vector store is unreachable.
   Retrieval is degraded to keyword-only (Tier 2).
   I can continue with reduced accuracy or wait for the
   vector store to be restored."

5. If dimensions mismatch:
   Agent reports to human: "Embedding dimensions changed
   (stored: 1536, provider: 1024). A full re-index is
   required. Run: rake codebase_index:reindex"
```

### Recovery Patterns

| Issue | Agent Can Self-Recover? | Recovery Action |
|-------|------------------------|-----------------|
| Stale index (few commits behind) | Yes | `codebase_extract(mode: "incremental")` + `codebase_embed(mode: "incremental")` |
| Missing embeddings for some units | Yes | `codebase_repair(issue: "missing_embeddings")` |
| Orphaned vectors (units deleted from extraction) | Yes | `codebase_repair(issue: "orphaned_vectors")` |
| Count mismatch (extraction vs index) | Yes | `codebase_repair(issue: "count_mismatch")` |
| Vector store unreachable | No | Report to human, degrade to Tier 2 |
| Dimension mismatch | No | Report to human, requires full re-index |
| Schema version mismatch | No | Report to human, requires migration |
| Embedding API quota exhausted | No | Report to human, queue for later |

### Operator Safety Model

Operator tools have higher blast radius than retrieval tools. Safety constraints:

1. **Extraction is read-only for source files.** It reads Ruby source and writes JSON output. It cannot modify application code.
2. **Embedding writes to the vector store only.** It cannot modify extracted JSON or application data.
3. **Repair operations are scoped.** `codebase_repair` only touches CodebaseIndex data, never application tables.
4. **Dry-run by default for destructive operations.** `codebase_extract(mode: "full", dry_run: true)` previews what would change without executing.
5. **Rate-limited pipeline triggers.** An agent cannot trigger full extraction more than once per 5 minutes to prevent runaway loops.

```ruby
module CodebaseIndex
  module Operator
    class PipelineGuard
      COOLDOWN_SECONDS = 300  # 5 minutes between full runs

      def initialize
        @last_full_extraction = nil
        @last_full_embedding = nil
      end

      def allow_extraction?(mode)
        return true if mode == "incremental"
        return true if @last_full_extraction.nil?

        elapsed = Time.now - @last_full_extraction
        if elapsed < COOLDOWN_SECONDS
          raise CooldownError,
            "Full extraction ran #{elapsed.to_i}s ago. " \
            "Wait #{(COOLDOWN_SECONDS - elapsed).ceil}s or use incremental mode."
        end

        true
      end

      def record_extraction!(mode)
        @last_full_extraction = Time.now if mode == "full"
      end
    end
  end
end
```

---

## Multi-Agent Coordination

When multiple agents work on the same codebase simultaneously — for example, one agent investigating a bug while another implements a feature — they share the same CodebaseIndex. This section designs the coordination model for concurrent agent access.

### Shared State Model

CodebaseIndex state consists of three layers with different concurrency characteristics:

| State Layer | Storage | Read Safety | Write Safety |
|-------------|---------|-------------|--------------|
| Extracted JSON | File system (`tmp/codebase_index/**/*.json`) | Safe — files are immutable between extractions | Unsafe — concurrent extractions can produce partial state |
| Vector embeddings | Vector store (Qdrant/pgvector/FAISS) | Safe — vector stores handle concurrent reads | Backend-dependent — Qdrant is safe, FAISS is not |
| Metadata | Database (MySQL/PostgreSQL/SQLite) | Safe — standard database reads | Safe with transactions — databases handle concurrent writes |
| Dependency graph | In-memory (loaded from JSON) | Safe — each agent loads its own copy | N/A — graph is rebuilt on extraction, not updated in place |

### Concurrency Levels

Three distinct concurrency scenarios, from simplest to most complex:

**Level 1: Multiple readers, no writers (most common)**

Multiple agents query the index concurrently. No extraction or embedding is running. This is safe by default — all retrieval operations are read-only against stable storage.

**Level 2: Multiple readers, one writer**

Agents query the index while an extraction or embedding job runs. Reads may see stale data during the write window. This is acceptable — agents get slightly outdated results, which is no worse than the pre-extraction state.

**Level 3: Multiple writers (rare, must be serialized)**

Two agents both try to run extraction or embedding simultaneously. This must be prevented through locking.

### Locking Strategy

Extraction and embedding operations acquire an advisory lock before proceeding. The lock mechanism depends on the runtime environment:

```ruby
module CodebaseIndex
  module Coordination
    class PipelineLock
      LOCK_FILE = "tmp/codebase_index/.pipeline.lock"

      # File-based lock (works everywhere, including development)
      def acquire!(operation:, timeout: 30)
        lock_path = Rails.root.join(LOCK_FILE)
        FileUtils.mkdir_p(File.dirname(lock_path))

        @lock_file = File.open(lock_path, File::RDWR | File::CREAT)

        acquired = false
        deadline = Time.now + timeout
        until acquired || Time.now > deadline
          acquired = @lock_file.flock(File::LOCK_EX | File::LOCK_NB)
          sleep(0.5) unless acquired
        end

        unless acquired
          existing = read_lock_info
          raise LockContention,
            "Pipeline locked by #{existing[:agent]} " \
            "(#{existing[:operation]}, started #{existing[:started_at]}). " \
            "Retry after current operation completes."
        end

        write_lock_info(operation: operation)
        true
      end

      def release!
        @lock_file&.flock(File::LOCK_UN)
        @lock_file&.close
      end

      private

      def write_lock_info(operation:)
        @lock_file.rewind
        @lock_file.truncate(0)
        @lock_file.write({
          agent: CodebaseIndex.current_agent_id,
          operation: operation,
          started_at: Time.now.iso8601,
          pid: Process.pid
        }.to_json)
        @lock_file.flush
      end

      def read_lock_info
        @lock_file.rewind
        content = @lock_file.read
        return {} if content.empty?

        JSON.parse(content, symbolize_names: true)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
```

For database-backed deployments, advisory locks provide stronger guarantees:

```ruby
# PostgreSQL advisory lock
module CodebaseIndex
  module Coordination
    class PostgresAdvisoryLock
      LOCK_ID = 0x436F6465  # "Code" in hex

      def acquire!(operation:, timeout: 30)
        acquired = ActiveRecord::Base.connection.execute(
          "SELECT pg_try_advisory_lock(#{LOCK_ID})"
        ).first["pg_try_advisory_lock"]

        raise LockContention, "Pipeline locked by another process" unless acquired
        true
      end

      def release!
        ActiveRecord::Base.connection.execute(
          "SELECT pg_advisory_unlock(#{LOCK_ID})"
        )
      end
    end
  end
end
```

```ruby
# MySQL advisory lock
module CodebaseIndex
  module Coordination
    class MysqlAdvisoryLock
      LOCK_NAME = "codebase_index_pipeline"

      def acquire!(operation:, timeout: 30)
        result = ActiveRecord::Base.connection.execute(
          "SELECT GET_LOCK('#{LOCK_NAME}', #{timeout})"
        ).first
        acquired = result.first == 1

        raise LockContention, "Pipeline locked by another process" unless acquired
        true
      end

      def release!
        ActiveRecord::Base.connection.execute(
          "SELECT RELEASE_LOCK('#{LOCK_NAME}')"
        )
      end
    end
  end
end
```

### Agent Handoff Patterns

When Agent A finishes a task that changes code and Agent B needs to work on related code, the index may be stale. Handoff patterns:

**Pattern 1: Extraction-on-save (development mode)**

File watchers trigger incremental extraction whenever source files change. Agents always query a near-current index. This is the recommended pattern for development with multiple agents.

```ruby
# Triggered by file system watcher (e.g., Listen gem)
CodebaseIndex::Watcher.on_change do |changed_files|
  CodebaseIndex.extract_incremental(changed_files)
  CodebaseIndex.embed_incremental(changed_identifiers)
end
```

**Pattern 2: Explicit handoff (CI/batch mode)**

Agent A completes work, triggers extraction, and signals Agent B that the index is ready.

```
Agent A: completes code changes
Agent A: codebase_extract(mode: "incremental")
Agent A: codebase_embed(mode: "incremental")
Agent A: signals Agent B (via shared task system or message queue)
Agent B: codebase_pipeline_status()  → confirms index is current
Agent B: begins retrieval
```

**Pattern 3: Optimistic reads with staleness tolerance**

Agents read from whatever index state is available and accept that results may be slightly behind. The `pipeline_status` response includes a `staleness` field so agents can decide whether to proceed or wait.

```
Agent B: codebase_pipeline_status()
  → staleness: "3_commits_behind"
Agent B: decides 3 commits is acceptable, proceeds with retrieval
Agent B: notes in its output: "Based on index from commit abc123, 3 commits behind HEAD"
```

### Token Budget Coordination

When multiple agents share a context window (e.g., in a multi-agent orchestration framework), they must negotiate token budget allocation. CodebaseIndex supports partitioned budgets:

```ruby
# Each agent requests a portion of the total budget
result_a = retriever.retrieve("checkout flow", budget: 4000)   # Agent A: 4000 tokens
result_b = retriever.retrieve("payment types", budget: 3000)   # Agent B: 3000 tokens
# Remaining 1000 tokens for system/structural context

# The orchestrator can also request a shared structural context once
structural = retriever.structural_context  # ~800 tokens, shared across agents
```

The orchestration framework is responsible for dividing the total context budget among agents. CodebaseIndex respects whatever budget it's given per-request and does not coordinate across requests itself.

---

## Agent Self-Service

Agents should be able to assess whether the context they received was helpful, report gaps, and trigger improvements. This creates a feedback loop where agent usage patterns drive index quality improvements.

### Quality Assessment Tools

```yaml
tools:
  - name: codebase_rate_retrieval
    description: >
      Report whether a retrieval result was useful. Enables the system
      to learn which queries produce good results and which need
      improvement.
    parameters:
      query: string (required, the original query)
      rating: string (required, "helpful" | "partial" | "unhelpful" | "wrong")
      missing: string (optional, what the agent expected but didn't find)
      notes: string (optional, free-text feedback)

  - name: codebase_report_gap
    description: >
      Report a gap in the index — something the agent looked for but
      couldn't find. Feeds into an improvement pipeline that can
      prioritize what to extract or index next.
    parameters:
      description: string (required, what was missing)
      query: string (optional, the query that triggered the gap discovery)
      expected_type: string (optional, "model" | "service" | "controller" | etc.)
      expected_identifier: string (optional, e.g. "DiscountCalculator")

  - name: codebase_retrieval_explain
    description: >
      Explain why a query returned specific results. Returns the full
      retrieval trace including classification, strategy selection,
      scoring breakdown, and budget allocation decisions.
    parameters:
      query: string (required)
      budget: integer (optional, default 8000)

  - name: codebase_suggest_improvements
    description: >
      Based on accumulated feedback, suggest index improvements.
      Returns prioritized list of actions: units to re-extract,
      chunks to add, embeddings to refresh, new extractors to build.
    parameters: {}
```

### MCP Server Extensions

```json
{
  "tools": [
    {
      "name": "rate_retrieval",
      "description": "Rate whether retrieval results were useful",
      "inputSchema": {
        "type": "object",
        "properties": {
          "query": { "type": "string" },
          "rating": { "type": "string", "enum": ["helpful", "partial", "unhelpful", "wrong"] },
          "missing": { "type": "string" },
          "notes": { "type": "string" }
        },
        "required": ["query", "rating"]
      }
    },
    {
      "name": "report_gap",
      "description": "Report a missing unit or coverage gap",
      "inputSchema": {
        "type": "object",
        "properties": {
          "description": { "type": "string" },
          "query": { "type": "string" },
          "expected_type": { "type": "string" },
          "expected_identifier": { "type": "string" }
        },
        "required": ["description"]
      }
    },
    {
      "name": "retrieval_explain",
      "description": "Explain why a query returned specific results",
      "inputSchema": {
        "type": "object",
        "properties": {
          "query": { "type": "string" },
          "budget": { "type": "integer", "default": 8000 }
        },
        "required": ["query"]
      }
    },
    {
      "name": "suggest_improvements",
      "description": "Get prioritized index improvement suggestions",
      "inputSchema": { "type": "object", "properties": {} }
    }
  ]
}
```

### Feedback Storage

Feedback is stored in a lightweight JSON log alongside the index output. This keeps it co-located with the index and avoids additional infrastructure:

```ruby
module CodebaseIndex
  module Feedback
    class Store
      FEEDBACK_DIR = "feedback"

      def initialize(output_dir:)
        @feedback_dir = Pathname.new(output_dir).join(FEEDBACK_DIR)
        FileUtils.mkdir_p(@feedback_dir)
      end

      def record_rating(query:, rating:, missing: nil, notes: nil)
        append_entry({
          type: "rating",
          query: query,
          rating: rating,
          missing: missing,
          notes: notes,
          timestamp: Time.now.iso8601,
          agent_id: CodebaseIndex.current_agent_id
        })
      end

      def record_gap(description:, query: nil, expected_type: nil, expected_identifier: nil)
        append_entry({
          type: "gap",
          description: description,
          query: query,
          expected_type: expected_type,
          expected_identifier: expected_identifier,
          timestamp: Time.now.iso8601,
          agent_id: CodebaseIndex.current_agent_id
        })
      end

      def recent_feedback(limit: 100)
        entries = []
        feedback_files.last(limit).each do |file|
          entries.concat(JSON.parse(File.read(file), symbolize_names: true))
        end
        entries.last(limit)
      end

      private

      def append_entry(entry)
        date = Date.today.iso8601
        file_path = @feedback_dir.join("#{date}.jsonl")
        File.open(file_path, "a") { |f| f.puts(entry.to_json) }
      end

      def feedback_files
        Dir[@feedback_dir.join("*.jsonl")].sort
      end
    end
  end
end
```

### Gap Detection Heuristics

Beyond explicit agent reports, the system can detect gaps automatically:

| Signal | Detection Method | Example |
|--------|-----------------|---------|
| Query returns zero results | Retrieval trace shows no candidates | "DiscountCalculator" not found |
| Low confidence results only | All candidates score below 0.60 | Query about webhooks, no webhook-related units indexed |
| Frequent re-queries | Same query repeated across sessions | Agents keep asking about "rate limiting" — not indexed |
| Type mismatch | Agent asked for service, only models returned | "payment processing service" returns payment models but no services |
| Truncation rate | High percentage of results truncated | Units are too large, chunking would improve retrieval |

```ruby
module CodebaseIndex
  module Feedback
    class GapDetector
      def analyze(feedback_store:, retrieval_logs:)
        gaps = []

        # Zero-result queries
        retrieval_logs.select { |log| log[:candidate_count] == 0 }.each do |log|
          gaps << {
            type: "zero_results",
            query: log[:query],
            priority: "high",
            suggestion: "Check if relevant units exist in extraction output"
          }
        end

        # Low-confidence queries (all results below threshold)
        retrieval_logs.select { |log|
          log[:top_score] && log[:top_score] < 0.60
        }.each do |log|
          gaps << {
            type: "low_confidence",
            query: log[:query],
            top_score: log[:top_score],
            priority: "medium",
            suggestion: "Consider adding semantic chunks or improving text preparation"
          }
        end

        # Frequent gap reports for same identifier
        feedback_store.recent_feedback
          .select { |f| f[:type] == "gap" }
          .group_by { |f| f[:expected_identifier] }
          .select { |_id, reports| reports.size >= 3 }
          .each do |identifier, reports|
            gaps << {
              type: "repeated_gap",
              identifier: identifier,
              report_count: reports.size,
              priority: "high",
              suggestion: "Unit '#{identifier}' reported missing #{reports.size} times — verify extraction coverage"
            }
          end

        gaps.sort_by { |g| g[:priority] == "high" ? 0 : 1 }
      end
    end
  end
end
```

### Improvement Pipeline

Feedback flows into a prioritized improvement queue. The `codebase_suggest_improvements` tool returns actionable items:

```json
{
  "improvements": [
    {
      "priority": "high",
      "type": "missing_unit",
      "identifier": "DiscountCalculator",
      "evidence": "Reported missing by 3 agents across 5 sessions",
      "action": "Verify class exists in app/services/ — may need extraction directory config update"
    },
    {
      "priority": "high",
      "type": "zero_result_pattern",
      "pattern": "webhook handling",
      "query_count": 7,
      "action": "No webhook-related units in index. Check if app/webhooks/ or app/services/webhooks/ exists"
    },
    {
      "priority": "medium",
      "type": "low_confidence_pattern",
      "pattern": "rate limiting",
      "avg_top_score": 0.48,
      "action": "Rate limiting logic exists but embeds poorly. Consider adding semantic description chunks"
    },
    {
      "priority": "low",
      "type": "high_truncation",
      "identifiers": ["Order", "Account", "User"],
      "truncation_rate": 0.65,
      "action": "These units frequently truncated in results. Finer-grained chunking would improve retrieval"
    }
  ],
  "stats": {
    "total_retrievals": 342,
    "rated_helpful": 198,
    "rated_partial": 89,
    "rated_unhelpful": 41,
    "rated_wrong": 14,
    "gaps_reported": 23,
    "period": "last_30_days"
  }
}
