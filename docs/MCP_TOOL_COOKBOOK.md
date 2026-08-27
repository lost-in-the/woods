# Woods MCP Tool Cookbook

Scenario-based examples showing which tool to use, what parameters to pass, and what you'll get back. Each section answers a natural question you might ask while working in a Rails codebase.

## Conditional Tools & Wiring

The Index Server ships with **29 tools** — **14 are always registered** and **15 are conditionally registered** depending on whether their collaborator is wired into `Woods.configuration`. If you call a conditionally-wired tool that isn't registered, the MCP server will simply not advertise it in `tools/list` — clients see it as "tool not found," not as a runtime failure.

| Tool group | Count | Wiring condition |
|------------|-------|------------------|
| Always-on | 14 | Always registered — `lookup`, `search`, `dependencies`, `dependents`, `structure`, `graph_analysis`, `domain_clusters`, `pagerank`, `framework`, `recent_changes`, `reload`, `codebase_retrieve`, `trace_flow`, `woods_status` |
| `session_trace` | 1 | `Woods.configuration.session_store` set and session tracer enabled |
| Operator (5) | 5 | Operator wired — `pipeline_extract`, `pipeline_embed`, `pipeline_status`, `pipeline_diagnose`, `pipeline_repair` |
| Feedback (4) | 4 | `Woods.configuration.feedback_store` wired — `retrieval_rate`, `retrieval_report_gap`, `retrieval_explain`, `retrieval_suggest` |
| Snapshot (4) | 4 | `Woods.configuration.snapshot_store` wired (requires migrations 004 + 005) — `list_snapshots`, `snapshot_diff`, `unit_history`, `snapshot_detail` |
| `notion_sync` | 1 | `notion_api_token` + `notion_database_ids` both set |

`codebase_retrieve` is always registered (no `retrieve` alias exists), but only returns results once an embedding provider is configured and `rake woods:embed` has run.

If your agent reports a tool is "missing," check Woods configuration first; the tool is gated by presence of the matching collaborator. **Console Server tools are not all unconditionally registered** — 31 tool schemas exist as an inventory, but only the 9 Tier 1 tools are executable by default, or 11 with `console_embedded_read_tools: true` (adds `console_sql`/`console_query`). Tier 2, Tier 3, and `console_eval` are schema-only in every supported mode; there is no bridge or confirmation flow that unlocks them. See [AGENT_GUIDE.md](AGENT_GUIDE.md#console-server) for the full tier table.

---

## Understanding Your Codebase

### "What models do we have?"

**Tool:** `structure` (Index Server)

```json
{
  "detail": "full"
}
```

Returns the manifest (unit counts by type, git SHA, extraction timestamp) plus the full `SUMMARY.md` overview. Use `detail: "summary"` for just the counts.

**What you'll get:** Total units broken down by type (models, controllers, services, jobs, etc.), the git commit the extraction reflects, and when it ran.

---

### "How is the User model structured?"

**Tool:** `lookup` (Index Server)

```json
{
  "identifier": "User",
  "include_source": true
}
```

**Example response:**

```json
{
  "identifier": "User",
  "type": "model",
  "file_path": "app/models/user.rb",
  "source_code": "# == Schema Information\n# id :bigint not null, pk\n# email :string not null\n# name :string\n# created_at :datetime\n#\nclass User < ApplicationRecord\n  has_many :orders\n  validates :email, presence: true, uniqueness: true\n  ...\nend\n\n# ┌───────────────────────────────────────────────────────────────────┐\n# │ Included from: Searchable                                         │\n# └───────────────────────────────────────────────────────────────────┘\n#   module Searchable\n#     ...\n#   end\n# ──────────────────────── End Searchable ───────────────────────────",
  "metadata": {
    "associations": [
      { "type": "has_many", "name": "orders", "target": "Order" }
    ],
    "validations": [
      { "attribute": "email", "type": "presence", "options": {}, "conditions": {} },
      { "attribute": "email", "type": "uniqueness", "options": {}, "conditions": {} }
    ],
    "callbacks": [],
    "inlined_concerns": ["Searchable"],
    "enums": {},
    "scopes": []
  },
  "dependencies": [
    { "type": "model", "target": "Order", "via": "has_many" }
  ],
  "dependents": [
    { "type": "controller", "identifier": "UsersController" }
  ]
}
```

To focus on just associations and callbacks without the full source:

```json
{
  "identifier": "User",
  "include_source": false,
  "sections": ["metadata", "dependencies"]
}
```

---

### "What callbacks fire when Order saves?"

**Tool:** `lookup` (Index Server)

```json
{
  "identifier": "Order",
  "include_source": false,
  "sections": ["metadata"]
}
```

**Example response** — `metadata.callbacks` contains the resolved callback chain in execution order, including callbacks inherited from concerns. Side-effects show what each callback actually does:

```json
{
  "identifier": "Order",
  "type": "model",
  "metadata": {
    "callbacks": [
      { "type": "before_validation", "filter": "normalize_status", "kind": "before", "conditions": {} },
      { "type": "before_save", "filter": "calculate_total", "kind": "before", "conditions": {},
        "side_effects": { "columns_written": ["total_cents"], "jobs_enqueued": [], "services_called": [], "mailers_triggered": [], "database_reads": [], "operations": [] } },
      { "type": "before_save", "filter": "set_slug", "kind": "before", "conditions": {},
        "side_effects": { "columns_written": ["slug"], "jobs_enqueued": [], "services_called": [], "mailers_triggered": [], "database_reads": [], "operations": [] } },
      { "type": "after_save", "filter": "reserve_stock", "kind": "after", "conditions": {},
        "side_effects": { "columns_written": [], "jobs_enqueued": ["InventoryReserveJob"], "services_called": [], "mailers_triggered": [], "database_reads": [], "operations": [] } },
      { "type": "after_commit", "filter": "send_confirmation_email", "kind": "after", "conditions": {},
        "side_effects": { "columns_written": [], "jobs_enqueued": ["OrderConfirmationJob"], "services_called": [], "mailers_triggered": ["OrderMailer"], "database_reads": [], "operations": [] } },
      { "type": "after_commit", "filter": "audit_trail", "kind": "after", "conditions": {},
        "side_effects": { "columns_written": [], "jobs_enqueued": [], "services_called": ["AuditService"], "mailers_triggered": [], "database_reads": [], "operations": [] } }
    ],
    "inlined_concerns": ["Auditable"]
  }
}
```

Callbacks from included concerns (like `audit_trail` from `Auditable`) are resolved and included in the chain. The `side_effects` hash is populated by `CallbackAnalyzer`, which scans callback method bodies for patterns like `self.col =` (column writes), `perform_later` (job enqueues), and `deliver_later` (mailer triggers).

---

### "Show me User with all concerns inlined"

**Tool:** `lookup` (Index Server)

```json
{
  "identifier": "User",
  "include_source": true
}
```

**What you'll get:** The `source_code` field contains the model source with all included concerns appended inline. This is the key feature — your AI tool sees the full behavioral surface area in one block:

```
# == Schema Information
# id         :bigint           not null, pk
# email      :string           not null
# name       :string
# created_at :datetime
#
class User < ApplicationRecord
  include Auditable
  include Searchable
  validates :email, presence: true, uniqueness: true
  has_many :orders
end

# ┌─────────────────────────────────────────────────────────────────────┐
# │ Included from: Auditable                                            │
# └─────────────────────────────────────────────────────────────────────┘
#   module Auditable
#     extend ActiveSupport::Concern
#     included do
#       after_save :audit_trail
#     end
#     def audit_trail
#       AuditLog.create!(auditable: self)
#     end
#   end
# ─────────────────────────── End Auditable ───────────────────────────

# ┌─────────────────────────────────────────────────────────────────────┐
# │ Included from: Searchable                                           │
# └─────────────────────────────────────────────────────────────────────┘
#   module Searchable
#     extend ActiveSupport::Concern
#     included do
#       scope :search, ->(q) { where("name ILIKE ?", "%#{q}%") }
#       after_commit :reindex_search
#     end
#   end
# ─────────────────────────── End Searchable ───────────────────────────
```

The `metadata.inlined_concerns` array lists which concerns were resolved:

```json
{ "inlined_concerns": ["Auditable", "Searchable"] }
```

---

### "What depends on User?"

**Tool:** `dependents` (Index Server)

```json
{
  "identifier": "User",
  "depth": 2
}
```

**What you'll get:** A BFS tree of everything that references `User` — controllers, services, jobs, mailers — up to 2 hops out. Set `depth: 1` for direct dependents only.

To find only which jobs depend on `User`:

```json
{
  "identifier": "User",
  "depth": 2,
  "types": ["job"]
}
```

---

### "What views link to OrdersController?"

**Tool:** `dependents` (Index Server)

```json
{
  "identifier": "OrdersController",
  "depth": 1,
  "via": ["link_to", "form_action"]
}
```

**What you'll get:** View templates and controllers that navigate to `OrdersController` via `link_to` helpers or form submissions. The `via` filter excludes code references and other relationship types, showing only UI navigation edges.

---

### "What does User depend on?"

**Tool:** `dependencies` (Index Server)

```json
{
  "identifier": "User",
  "depth": 2
}
```

**What you'll get:** Forward dependency tree — concerns, associations, services called from callbacks, jobs enqueued, etc.

---

### "Find all controllers that handle payments"

**Tool:** `search` (Index Server)

```json
{
  "query": "payment",
  "types": ["controller"],
  "fields": ["identifier", "source_code"],
  "limit": 10
}
```

**Example response:**

```json
[
  {
    "identifier": "PaymentsController",
    "type": "controller",
    "file_path": "app/controllers/payments_controller.rb",
    "metadata": {
      "actions": ["create", "show", "webhook"],
      "routes": [
        { "verb": "POST", "path": "/payments", "action": "create" },
        { "verb": "POST", "path": "/payments/webhook", "action": "webhook" }
      ]
    }
  }
]
```

Search `source_code` when you want semantic matches, not just naming matches.

---

### "Which controller handles POST /checkout?"

**Tool:** `search` (Index Server)

```json
{
  "query": "/checkout",
  "types": ["route"],
  "limit": 5
}
```

**What you'll get:** Route units matching `/checkout` with the bound controller and action:

```json
[
  {
    "type": "route",
    "identifier": "POST /checkout",
    "metadata": { "controller": "orders", "action": "create", "route_name": "checkout" }
  }
]
```

**Follow up** — look up the controller for full source with filters and route context:

```json
{
  "tool": "lookup",
  "params": { "identifier": "OrdersController", "include_source": true }
}
```

---

### "What jobs does CheckoutService trigger?"

**Tool:** `dependencies` (Index Server)

```json
{
  "identifier": "CheckoutService",
  "depth": 2,
  "types": ["job"]
}
```

**What you'll get:** All job units reachable from `CheckoutService` within 2 hops — including jobs triggered indirectly via model callbacks:

```json
{
  "root": "CheckoutService",
  "results": [
    { "identifier": "OrderConfirmationJob", "type": "job", "path": ["CheckoutService", "Order", "OrderConfirmationJob"] },
    { "identifier": "InventoryReserveJob", "type": "job", "path": ["CheckoutService", "LineItem", "InventoryReserveJob"] }
  ]
}
```

This traces through the dependency graph: `CheckoutService` calls `Order#save!`, which triggers `after_commit :send_confirmation`, which enqueues `OrderConfirmationJob`. Without the graph, you'd need to manually follow callbacks across multiple files.

---

### "Where does UsersController redirect to?"

**Tool:** `dependencies` (Index Server)

```json
{
  "identifier": "UsersController",
  "depth": 1,
  "via": ["redirect_to"]
}
```

**What you'll get:** Controllers that `UsersController` redirects to via `redirect_to` with named route helpers. Useful for tracing user flow after form submissions or authentication.

---

### "What methods does Rails generate on Order at runtime?"

**Tool:** `lookup` (Index Server)

```json
{
  "identifier": "Order",
  "include_source": false,
  "sections": ["metadata"]
}
```

Because Woods runs inside a booted Rails process, it captures every method Rails generates dynamically — things static analysis tools cannot see. The metadata shows these in structured form:

**Example response (relevant sections):**

```json
{
  "identifier": "Order",
  "type": "model",
  "metadata": {
    "enums": {
      "status": { "pending": 0, "active": 1, "shipped": 2, "cancelled": 3 }
    },
    "scopes": [
      { "name": "active", "source": "-> { where(status: :active) }" },
      { "name": "recent", "source": "-> { where('created_at > ?', 30.days.ago) }" }
    ],
    "associations": [
      { "type": "belongs_to", "name": "user", "target": "User" },
      { "type": "has_many", "name": "line_items", "target": "LineItem" }
    ]
  }
}
```

Woods captures the `enums`, `scopes`, and `associations` metadata directly from ActiveRecord reflection — the method names below are inferred per standard Rails conventions, not listed explicitly in the `_index.json`. From this metadata, you can infer every runtime-generated method:

| Source | Generated Methods |
|--------|------------------|
| `enum status:` | `status_pending?`, `status_active?`, `status_shipped?`, `status_cancelled?`, `pending!`, `active!`, `shipped!`, `cancelled!` |
| `scope :active` | `Order.active` |
| `belongs_to :user` | `user`, `user=`, `build_user`, `create_user`, `create_user!`, `reload_user` |
| `has_many :line_items` | `line_items`, `line_items=`, `line_item_ids`, `line_item_ids=`, `build`, `create`, `create!` on the association |

Static tools miss all of these because they only exist after Rails processes the DSL declarations at boot time. Woods captures them because it queries the runtime class via `instance_methods(false)` after Rails has finished loading.

---

### "What changed recently?"

**Tool:** `recent_changes` (Index Server)

```json
{
  "limit": 20,
  "types": ["model", "service"]
}
```

**What you'll get:** Recently modified units sorted by git `last_modified` timestamp. Useful for getting up to speed after a teammate's changes.

---

## Debugging

### "What happens when POST /orders is called?"

**Tool:** `trace_flow` (Index Server)

```json
{
  "entry_point": "OrdersController#create",
  "depth": 3
}
```

**What you'll get:** Execution flow from the controller action through services, callbacks, jobs enqueued, and mailers sent — assembled from the dependency graph. Increase `depth` to trace deeper call chains.

---

### "Why is this page slow?"

`console_slow_endpoints` is Tier 3 — schema-only, not executable in any supported mode (see [Conditional Tools & Wiring](#conditional-tools--wiring)). Trace the code path directly instead:

**Tool:** `trace_flow` (Index Server)

```json
{
  "entry_point": "ProductsController#index",
  "depth": 4
}
```

**What you'll get:** A full execution flow showing every layer the request touches — services, callbacks, jobs enqueued, mailers sent. Pair this with your own APM/logging for the "which endpoint is actually slow" half of the question; Woods answers "why," not "which."

---

## Architecture Analysis

### "Find dead code in our codebase"

**Tool:** `graph_analysis` (Index Server)

```json
{
  "analysis": "orphans",
  "limit": 20
}
```

**What you'll get:** Units with no dependents — nothing in the codebase references them. Good candidates for removal or investigation.

---

### "What are the most important models?"

**Tool:** `pagerank` (Index Server)

```json
{
  "limit": 10,
  "types": ["model"]
}
```

**What you'll get:** Models ranked by PageRank score. Higher scores mean more units depend on them — these are your core domain objects. Touching these files has the widest blast radius.

---

### "Are there circular dependencies?"

**Tool:** `graph_analysis` (Index Server)

```json
{
  "analysis": "cycles",
  "limit": 10
}
```

**What you'll get:** Circular dependency chains in the codebase. A cycle like `A → B → C → A` indicates tight coupling that may complicate testing or refactoring.

---

### "What are the key integration points?"

**Tool:** `graph_analysis` (Index Server)

```json
{
  "analysis": "bridges",
  "limit": 15
}
```

**What you'll get:** Units whose removal would disconnect parts of the dependency graph — the load-bearing structural elements of your codebase.

---

### "Which units are structural dead ends?"

**Tool:** `graph_analysis` (Index Server)

```json
{
  "analysis": "dead_ends"
}
```

**What you'll get:** Units that have no forward dependencies — leaf nodes. These tend to be pure utility classes or simple value objects.

---

### "How does Rails implement has_many?"

**Tool:** `framework` (Index Server)

```json
{
  "keyword": "has_many",
  "limit": 5
}
```

**What you'll get:** Relevant Rails source units matching the keyword — the actual implementation from the installed gem. Useful for understanding framework behavior without leaving your AI tool.

---

## Data Exploration (Console Server)

### Scope predicates

Tools that accept a `scope` parameter (`console_count`, `console_sample`, `console_pluck`, `console_aggregate`, `console_association_count`, `console_recent`) support Ransack-style predicate suffixes on hash keys. Plain keys are treated as equality, suffixed keys build safe Arel predicates. Column names are validated against the model's schema — SQL injection via column names is not possible.

| Suffix | SQL equivalent | Example |
|--------|----------------|---------|
| `_eq` | `col = value` | `{ "status_eq": "paid" }` |
| `_not_eq` | `col != value` | `{ "status_not_eq": "cancelled" }` |
| `_gt` | `col > value` | `{ "total_cents_gt": 1000 }` |
| `_gteq` | `col >= value` | `{ "created_at_gteq": "2026-01-01" }` |
| `_lt` | `col < value` | `{ "total_cents_lt": 5000 }` |
| `_lteq` | `col <= value` | `{ "created_at_lteq": "2026-12-31" }` |
| `_in` | `col IN (…)` | `{ "status_in": ["paid", "refunded"] }` |
| `_not_in` | `col NOT IN (…)` | `{ "status_not_in": ["cancelled"] }` |
| `_null` | `col IS NULL` (value: `true`) / `IS NOT NULL` (value: `false`) | `{ "deleted_at_null": true }` |
| `_not_null` | `col IS NOT NULL` (value: `true`) / `IS NULL` (value: `false`) | `{ "email_not_null": true }` |
| `_present` | `col IS NOT NULL AND col != ''` (value: `true`) | `{ "name_present": true }` |
| `_blank` | `col IS NULL OR col = ''` (value: `true`) | `{ "notes_blank": true }` |
| `_matches` | `col LIKE value` | `{ "email_matches": "%@example.com" }` |

Keys without a recognised suffix fall through to ActiveRecord `where(hash)` equality. You can mix both in a single scope:

```json
{ "status": "paid", "total_cents_gt": 1000, "created_at_gteq": "2026-01-01" }
```

---

### "How many active users do we have?"

**Tool:** `console_count` (Console Server)

```json
{
  "model": "User",
  "scope": { "active": true }
}
```

**What you'll get:** An integer count. The `scope` hash maps directly to ActiveRecord `where` conditions.

---

### "Show me a sample order"

**Tool:** `console_sample` (Console Server)

```json
{
  "model": "Order",
  "limit": 1
}
```

**What you'll get:** A random order record with all columns. To focus on specific fields:

```json
{
  "model": "Order",
  "limit": 3,
  "columns": ["id", "status", "total_cents", "created_at"],
  "scope": { "status": "pending" }
}
```

---

### "What's the User table schema?"

**Tool:** `console_schema` (Console Server)

```json
{
  "model": "User",
  "include_indexes": true
}
```

**What you'll get:** Column names, types, nullability, defaults, and (with `include_indexes: true`) all defined indexes. Reflects the live database schema, not migrations.

---

### "What are the average order totals by status?"

**Tool:** `console_aggregate` (Console Server)

```json
{
  "model": "Order",
  "function": "average",
  "column": "total_cents",
  "scope": { "status": "completed" }
}
```

**What you'll get:** A single aggregate value. Functions: `sum`, `average`, `minimum`, `maximum`, `count`. The `column` parameter is required for every function except `count`, where it may be omitted to count all matching rows.

---

### "Find all email addresses for users who joined last month"

**Tool:** `console_pluck` (Console Server)

```json
{
  "model": "User",
  "columns": ["email"],
  "scope": { "created_at_gteq": "2025-01-01" },
  "limit": 100,
  "distinct": true
}
```

**What you'll get:** An array of email values. `distinct: true` removes duplicates.

---

### "Run a custom SQL query"

**Tool:** `console_sql` (Console Server, requires `console_embedded_read_tools: true` — see [AGENT_GUIDE.md](AGENT_GUIDE.md#console-server))

```json
{
  "sql": "SELECT status, COUNT(*) as count FROM orders GROUP BY status ORDER BY count DESC",
  "limit": 50
}
```

**What you'll get:** Query results as an array of row hashes. Only `SELECT` and `WITH...SELECT` queries are permitted — all writes are rejected at the validator level before reaching the database.

---

## Semantic Search

### "Find code related to subscription billing"

**Tool:** `codebase_retrieve` (Index Server, requires embedding provider)

```json
{
  "query": "subscription billing renewal payment processing",
  "budget": 8000
}
```

**What you'll get:** A token-budgeted context string of the most semantically relevant units, ranked by hybrid search (semantic + keyword + PageRank). Requires an embedding provider (`embedding_provider: :openai` or `:ollama`) to be configured.

---

## Pipeline Management

### "Check if the index is stale"

**Tool:** `pipeline_status` (Index Server)

```json
{}
```

**What you'll get:** Last extraction time, current unit counts, and staleness indicators — whether the index reflects recent changes.

---

### "Trigger a re-extraction without restarting the server"

Trigger extraction, then reload the server's in-memory data:

**Step 1:**

**Tool:** `pipeline_extract` (Index Server)

```json
{
  "incremental": true
}
```

**Step 2 (after extraction completes):**

**Tool:** `reload` (Index Server)

```json
{}
```

**What you'll get:** Confirmation that extraction started (runs in background), then updated manifest stats after reload.

---

## Temporal Snapshots

### "What changed between last week and now?"

**Tool:** `snapshot_diff` (Index Server, requires `enable_snapshots: true`)

```json
{
  "sha_a": "abc1234",
  "sha_b": "def5678"
}
```

**What you'll get:** Lists of added, modified, and deleted units between the two git SHAs. Use `list_snapshots` first to find valid SHA values.

---

### "How has the User model evolved?"

**Tool:** `unit_history` (Index Server, requires `enable_snapshots: true`)

```json
{
  "identifier": "User",
  "limit": 10
}
```

**What you'll get:** A chronological list of snapshot versions showing when the `User` unit's source changed.

---

## CI Integration

### GitHub Actions for Incremental Extraction

Run incremental extraction on every push, cache the index between runs:

```yaml
# .github/workflows/woods.yml
name: Update Codebase Index

on:
  push:
    branches: [main]
  pull_request:

jobs:
  index:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2   # needed for incremental diff

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - name: Restore index cache
        uses: actions/cache@v4
        with:
          path: tmp/woods
          key: woods-${{ github.ref }}-${{ github.sha }}
          restore-keys: |
            woods-${{ github.ref }}-
            woods-

      - name: Run database migrations
        run: bundle exec rails db:migrate RAILS_ENV=test

      - name: Update codebase index
        run: bundle exec rake woods:incremental
        env:
          RAILS_ENV: test
          GITHUB_BASE_REF: ${{ github.base_ref }}

      - name: Validate index
        run: bundle exec rake woods:validate
```

For Docker-based CI:

```yaml
      - name: Update codebase index
        run: docker compose exec -T app bundle exec rake woods:incremental
```

---

## Retrieval Feedback

### "Rate a retrieval result and report a gap"

If semantic search missed a relevant unit, report it so the system can improve:

**Rate the result:**

**Tool:** `retrieval_rate` (Index Server)

```json
{
  "query": "user authentication flow",
  "score": 2,
  "comment": "Missed SessionsController entirely"
}
```

**Report the missing unit:**

**Tool:** `retrieval_report_gap` (Index Server)

```json
{
  "query": "user authentication flow",
  "missing_unit": "SessionsController",
  "unit_type": "controller"
}
```

**Check feedback statistics:**

**Tool:** `retrieval_explain` (Index Server)

```json
{}
```
