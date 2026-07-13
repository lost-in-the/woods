# Woods Explorer

`rake woods:explore` renders an extraction index as a **self-contained,
interactive HTML explorer** — an exploration and understanding tool for the
host application that runs from a single file with zero dependencies, zero
network access, and zero servers. Open it in a browser, drop it in a PR, host
it on any static file server, or hand it to an AI agent via its `data.json`
sidecar.

```bash
# In a host Rails app, after `rake woods:extract`:
bundle exec rake woods:explore          # alias: rake woods:wander

# Output (default <output_dir>/explorer/):
#   index.html       the explorer app — open directly (file:// works)
#   flows.js         flow operation trees (only written for large apps)
#   data.json        machine-readable payload for agents/scripts
#   README.md        what these files are
#   .woods-explorer  ownership sentinel
```

For the full experience, enable request-flow precomputation before
extracting — it powers the Trace view, screen badges, and flow-confirmed
impact evidence:

```ruby
# config/initializers/woods.rb
Woods.configure do |config|
  config.precompute_flows = true
end
```

Without flows the explorer still works (structure, screens, impact via the
graph, ERD, routes), and says so with a banner rather than failing.

## Who it's for

The explorer is organized around **questions**, not data types:

- **"How does this screen work?"** — Trace: the step-by-step operation tree
  for any controller action, in technical or plain language.
- **"What breaks if I change this?"** — Impact: entry-point surfaces, member-
  level scoping (a specific callback, column, or association), covering specs,
  and destroy-cascade simulation.
- **"What should I re-test for this diff?"** — Review: paste
  `git diff --name-only`, get a regression checklist.
- **"What's the shape of this app?"** — Home's screen catalog by domain,
  Routes with reachability badges, and the Atlas (graph / ERD / table /
  overview).

It serves mixed audiences: engineers get file:line operation trees; PMs and
QA get plain-language traces and the screen catalog (a `woods_labels.yml`
file lets teams name screens in product terms); reviewers and auditors get
impact tables with explicit evidence tiers; AI agents get `data.json` and
the in-page `window.WOODS_EXPLORER` API.

## Views

| View | Question it answers |
|---|---|
| **Home** | Landing page. Search anything (screens by URL or label, units, flows); the app's screens grouped by domain with behavior badges (sends email, queues jobs, writes data, branches); stat tiles |
| **Trace** | For one screen: the gate rail (before_action chain with only/except ghosting), the params contract, the **operation tree** (calls with file:line, conditionals with verbatim conditions, transactions, job/mailer enqueues, responses with redirect destinations), and the consequence footer (model callbacks that fire on the writes this action performs) |
| **Impact** | For one unit — or one **member** of it (a callback, column, controller action, or association): which URLs reach it (flow-PROVEN vs graph-POSSIBLE), what a member change touches, which specs cover it, and a **destroy-cascade simulation** for models |
| **Routes** | Every screen as a row: verb/path, label, badges for **unreachable** (no in-app links), **dead-end**, **untested**, **no-flow**. Filter by badge, copy as CSV |
| **Atlas** | The structural views: **Overview** dashboard, force-directed **Graph**, models-only **ERD**, sortable **Table**, and the shortest-**path finder** |

Every trace and cascade tree can be exported three ways from its toolbar:
**Copy as text tree** (the box-drawing `├─ └─` rendering, pasteable into any
doc or Slack thread), **Copy as Mermaid** (a `flowchart TD` with decision
diamonds — pasteable into Notion, GitHub, Obsidian), and **Copy for AI**
(a markdown digest). A **Plain language ⇄ Technical** toggle rewrites rows
("queues background task X (runs after the response)") without hiding any
information — the raw form stays visible as a muted chip.

## Evidence tiers

Impact and Review never present a guess as a fact. Every row carries a tier:

| Tier | Meaning |
|---|---|
| **PROVEN** | A precomputed runtime flow actually touches the unit/member |
| **STRONG** | One direct join over extracted facts (e.g. a permitted param matching a column name) |
| **POSSIBLE** | Graph reachability only (≤ 3 hops over reverse edges) |

Each view also carries a fixed **blind-spot box** stating what the analysis
cannot see (regex-based side-effect detection, depth-3 trace cap,
`update_column`/`update_all` skipping callbacks, JS-built URLs invisible to
reachability).

## Plain names: `woods_labels.yml`

Screens default to humanized names ("Posts — Create"). Teams can override
them — and name URL domains — with an optional YAML file next to the index
(or anywhere, via `WOODS_EXPLORER_LABELS`):

```yaml
# <output_dir>/woods_labels.yml
screens:
  CheckoutsController#show: "Checkout page"
  Admin::OrdersController#index: "Order management"
domains:
  /admin: "Administration"
  /carts: "Shopping"
```

## Large codebases

Tested against a real 6,600-unit / 1,200-screen production extraction. Past
~1,200 units the Atlas graph opens with the top 600 units by PageRank
(opt-out in Display), the ERD caps at the 100 most connected models with
focus-neighborhood reach to the rest, unconnected units park in a static grid,
and the camera auto-fits until first interaction. Home renders domain groups
lazily so 1,200+ screens stay snappy. When the compacted flow trees exceed
~1.5 MB they move to a `flows.js` sidecar loaded via `<script src>` (which,
unlike `fetch()`, works from `file://`) — keep the two files together.

Filters, display options, and the cap all persist across reloads
(localStorage). Each family/relationship row has a hover **"only"** button to
isolate it, and each section header gets a **"show all"** reset once anything
is off.

## Filters and interaction

- **Search** (`/`) — type-ahead across screens (by label, `VERB /path`, or
  path substring), unit identifiers, and file paths.
- **Keyboard** — `1`–`5` switch top-level views, arrow keys walk the graph,
  `Enter` opens details, `f` focuses a neighborhood, `p` opens the path
  finder, `?` shows help.
- **Navigation never steals your view** — clicking a unit opens the detail
  panel in place; *Show in graph* is the explicit jump.
- **Detail panel** — schema columns, associations, validations, callbacks
  *with analyzed side-effects*, scopes, routes, filters, permitted params,
  dependencies/dependents by kind — plus per-action **Trace** links on
  controllers, and **Impact** / **Simulate destroy** buttons.

## Configuration

Follows the Obsidian-exporter pattern: no `Woods::Configuration` accessors,
everything via env vars on the rake task (or constructor kwargs on
`Woods::Explorer::SiteBuilder`).

| Env var | Default | Effect |
|---|---|---|
| `WOODS_OUTPUT` | `config.output_dir` | Extraction index to read |
| `WOODS_EXPLORER_OUTPUT` | `<output_dir>/explorer` | Where to write the site |
| `WOODS_EXPLORER_LABELS` | `<output_dir>/woods_labels.yml` | Plain-name overrides for screens/domains |
| `WOODS_EXPLORER_INCLUDE_FRAMEWORK` | off | Include `rails_source` nodes |
| `WOODS_EXPLORER_FORCE` | off | Overwrite a non-empty directory that lacks the `.woods-explorer` sentinel |

Re-running against an unchanged extraction produces **byte-identical output**
(no build timestamps) — safe to commit or diff.

## The `data.json` payload (`woods-explorer/2`)

```jsonc
{
  "schema": "woods-explorer/2",
  "app":    { "rails_version": "8.0.5", "git_branch": "...", "git_sha": "...", ... },
  "groups": [ { "key": "data", "label": "Models & data", "glyph": "M", "types": ["model", ...] }, ... ],
  "types":  { "route": 21, "view_template": 13, ... },        // counts, desc
  "via_counts": { "code_reference": 15, "link_to": 15, ... }, // edge kinds, desc
  "nodes":  [ { "id": "Post", "type": "model", "group": "data", "label": "Post",
                "file_path": "app/models/post.rb", "pagerank": 0.052,
                "in": 10, "out": 6, "summary": "8 columns · 4 associations · 3 scopes",
                "facts": { "table_name": "posts", "columns": [...], "associations": [...],
                            "callbacks": [{ "type": "after_save", "filter": "schedule_publish",
                                            "side_effects": { "jobs_enqueued": ["PublishPostJob"] } }], ... } }, ... ],
  "edges":  [ [srcIndex, tgtIndex, "belongs_to"], ... ],       // indices into nodes
  "screens": [ { "id": "PostsController#create", "controller": "PostsController",
                 "action": "create", "node": 41, "routes": ["POST /posts"],
                 "flow": 12,                    // index into flows.summaries / flow_ops
                 "domain": "Posts", "label": "Posts — Create",
                 "out": ["~CommentsController", "redirect:PostsController"], "in": 3 }, ... ],
  "flows":  { "available": true,
              "summaries": [ { "entry": "PostsController#create", "route": ["POST", "/posts"],
                               "units": [...], "calls": ["Post#save", ...], "jobs": [...],
                               "mailers": [...], "writes": ["Post"],
                               "responses": ["redirect:302"], "conditions": 2 }, ... ],
              "unit_index":   { "Post": [0, 12, ...] },          // unit → flow indices
              "method_index": { "Post#save": [12, ...] } },      // call → flow indices
  "flow_ops": [ /* per-flow compacted operation trees, or "external:flows.js" */ ],
  "analysis": { "orphans": [idx...], "hubs": [{ "node": idx, "dependent_count": n }],
                "cycles": [[idx...]], "bridges": [...], "dead_ends": [...] },
  "meta":   { "include_framework": false, "skipped_units": 0, "skipped_edges": 18, ... }
}
```

`flow_ops` entries mirror `flows.summaries` by index. Each is a list of steps
`{ "u": "PostsController#create", "t": "controller_action", "ops": [...] }`
whose ops use short keys: `t` (type: `call` / `async` / `response` /
`conditional` / `transaction` / `dynamic_dispatch`), `tgt`, `m`, `line`,
`cond`, `status`, `render`, and nested `then` / `else` / `ops`. Gem-internal
noise is stripped; `data.json` and the per-flow JSON in the index keep the
uncapped source of truth. In the embedded page, when `flow_ops` is the string
`"external:flows.js"` the trees live in `window.WOODS_FLOWOPS`.

Nodes are sorted by identifier, edges by `(source, target, via)`, screens and
flows by entry point — the payload is deterministic for a given extraction.
Fact lists are capped at 60 entries per list (`columns_total` carries the real
count); summary call lists cap at 40 (the `method_index` is built before
capping, so lookups stay complete).

## Design notes

- Reads the graph via `IndexReader#raw_graph_data` (persisted PageRank),
  per-unit JSON for facts, and `flows/*.json` (from `FlowPrecomputer`) via
  `Woods::Explorer::FlowDigest`; excludes `rails_source`/`gem_source` by
  default.
- Screens are derived by `Woods::Explorer::ScreenBuilder` from controller
  route facts plus flow entry points; outbound navigation comes from each
  controller's render closure (`link_to`/`form_action` edges within 4 render
  hops) and `redirect_to` edges.
- Frontend is dependency-free vanilla JS on a `<canvas>` (Barnes-Hut force
  layout) plus DOM views. All data-driven text is inserted via `textContent`;
  the embedded JSON escapes `</`, `<!--`, and `<script` so the payload can
  never break out of its script tag.
- **Color** follows the project's data-viz method: eight family hues in a
  fixed slot order, one validated set per theme (light and dark are separately
  stepped, not auto-flipped). Both sets sit in the CVD floor band for
  all-pairs comparison, which is why identity never rides on color alone —
  every node also carries its family's letter glyph, the legend is always
  present, and the Table view is the WCAG-clean twin of the graph.
- Source code is **not** embedded — the explorer shows structure, facts, and
  operation traces, and links back to file paths. This keeps the HTML small
  and avoids shipping credentials-in-source by construction.
- Honors `prefers-reduced-motion` (layout settles instantly), keyboard
  navigation everywhere, `aria-live` announcements for selection changes.

## Serving beyond `file://`

The output is static — any file host works:

```bash
ruby -run -e httpd tmp/woods/explorer -p 8000    # stdlib one-liner
```

For CI, publish `explorer/` as a build artifact so every branch gets a
browsable map of its codebase.
