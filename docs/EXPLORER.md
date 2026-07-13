# Woods Explorer

`rake woods:explore` renders an extraction index as a **self-contained,
interactive HTML explorer** — a visual map of the host application that runs
from a single file with zero dependencies, zero network access, and zero
servers. Open it in a browser, drop it in a PR, host it on any static file
server, or hand it to an AI agent via its `data.json` sidecar.

```bash
# In a host Rails app, after `rake woods:extract`:
bundle exec rake woods:explore          # alias: rake woods:wander

# Output (default <output_dir>/explorer/):
#   index.html       the explorer app — open directly (file:// works)
#   data.json        machine-readable payload for agents/scripts
#   README.md        what these files are
#   .woods-explorer  ownership sentinel
```

## Who it's for

- **Engineers new to a codebase** — start at Overview, click the top PageRank
  units, use *Focus neighborhood* to walk outward one hop at a time.
- **Non-engineers** — the Table view and per-unit detail panel read like a
  catalog; no graph literacy required. Every fact reachable in the graph is
  also reachable by search + click.
- **AI agents** — `data.json` carries the full normalized payload
  (`woods-explorer/1` schema), every unit has a *Copy for AI* markdown digest,
  and URLs deep-link (`#/unit/Post`, `#/path/A/B`) so links can be exchanged
  between people and agents. The payload is also exposed in the page as
  `window.WOODS_EXPLORER.data`.

## Views

| View | What it shows |
|---|---|
| **Overview** | Stat tiles, units-by-type chart, top PageRank units, hubs, dependency cycles, orphans/bridges, extraction provenance |
| **Graph** | Force-directed dependency graph. Node size = PageRank, color + glyph = unit family, arrows point at dependencies. Pan/zoom/drag; double-click a node (or *Focus neighborhood*) for its ego network with a depth slider |
| **ERD** | Models only: schema boxes with column lists, association edges labeled with their macro (`belongs_to`, `has_many`, …) |
| **Table** | Sortable, filterable list of every unit — the accessibility twin of the graph |

Plus a **path finder** (`p`, or *Find a path…*): pick any two units and the
explorer traces the shortest dependency chain between them, rendered as a
left-to-right storyboard — "how does a request in this view end up enqueueing
that job?"

## Large codebases

Tested against a real 6,600-unit / 6,100-edge production app. At that size the
explorer changes its defaults (everything below is automatic past ~1,200
units):

- **Top slice first.** The graph opens with the top 600 units by PageRank —
  the core of the app — instead of the full hairball. The status bar says so;
  the Display checkbox ("Top 600 by PageRank only") turns it off, and Focus /
  path / search always reach the full graph.
- **ERD caps at the 100 most connected models** with a banner; *Focus
  neighborhood* on any model shows its full association neighborhood (and
  stays in the ERD).
- **Unconnected units sit in a static grid** beside the simulated cluster
  instead of drifting off and dragging the camera with them.
- The camera **auto-fits while the layout settles** and stops the moment you
  pan or zoom; nodes never shrink below a visible size.

Filters, display options, and the cap all **persist across reloads**
(localStorage). Each family/relationship row has a hover **"only"** button to
isolate it, and each section header gets a **"show all"** reset once anything
is off.

## Filters and interaction

- **Families** (sidebar) — toggle the eight unit families (Models & data,
  Controllers & HTTP, Views, Services, Jobs & mail, Policies, Tests,
  Concerns) on/off.
- **Relationships** — toggle edge kinds (`belongs_to`, `render`, `link_to`,
  `job_enqueue`, …).
- **Search** (`/`) — type-ahead across identifiers and file paths.
- **Keyboard** — arrow keys walk the graph spatially, `Enter` opens details,
  `f` focuses a neighborhood, `1`–`4` switch views, `?` shows help.
- **Navigation never steals your view** — clicking a unit in the table,
  overview, or detail panel opens the detail panel in place; the detail
  panel's *Show in graph* action does the explicit jump.
- **Detail panel** — schema columns, associations, validations, callbacks
  *with analyzed side-effects* (columns written, jobs enqueued, mailers
  triggered), scopes, routes, filters, permitted params, dependencies and
  dependents grouped by relationship kind — all cross-linked.

## Configuration

Follows the Obsidian-exporter pattern: no `Woods::Configuration` accessors,
everything via env vars on the rake task (or constructor kwargs on
`Woods::Explorer::SiteBuilder`).

| Env var | Default | Effect |
|---|---|---|
| `WOODS_OUTPUT` | `config.output_dir` | Extraction index to read |
| `WOODS_EXPLORER_OUTPUT` | `<output_dir>/explorer` | Where to write the site |
| `WOODS_EXPLORER_INCLUDE_FRAMEWORK` | off | Include `rails_source` nodes |
| `WOODS_EXPLORER_FORCE` | off | Overwrite a non-empty directory that lacks the `.woods-explorer` sentinel |

Re-running against an unchanged extraction produces **byte-identical output**
(no build timestamps) — safe to commit or diff.

## The `data.json` payload (`woods-explorer/1`)

```jsonc
{
  "schema": "woods-explorer/1",
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
  "analysis": { "orphans": [idx...], "hubs": [{ "node": idx, "dependent_count": n }],
                "cycles": [[idx...]], "bridges": [...], "dead_ends": [...] },
  "meta":   { "include_framework": false, "skipped_units": 0, "skipped_edges": 18, ... }
}
```

Nodes are sorted by identifier and edges by `(source, target, via)`, so the
payload is deterministic for a given extraction. Fact lists are capped at 60
entries per list (`columns_total` carries the real count); the per-unit JSON
in the index remains the uncapped source of truth.

## Design notes

- Reads the graph via `IndexReader#raw_graph_data` (persisted PageRank) and
  per-unit JSON for facts; excludes `rails_source`/`gem_source` by default.
- Frontend is dependency-free vanilla JS on a `<canvas>` (Barnes-Hut force
  layout). All data-driven text is inserted via `textContent`; the embedded
  JSON escapes `</` so the payload can never break out of its script tag.
- **Color** follows the project's data-viz method: eight family hues in a
  fixed slot order, one validated set per theme (light and dark are separately
  stepped, not auto-flipped). Both sets sit in the CVD floor band for
  all-pairs comparison, which is why identity never rides on color alone —
  every node also carries its family's letter glyph, the legend is always
  present, and the Table view is the WCAG-clean twin of the graph.
- Source code is **not** embedded — the explorer shows structure and facts,
  and links back to file paths. This keeps the HTML small and avoids shipping
  credentials-in-source by construction.
- Honors `prefers-reduced-motion` (layout settles instantly), keyboard
  navigation everywhere, `aria-live` announcements for selection changes.

## Serving beyond `file://`

The output is static — any file host works:

```bash
ruby -run -e httpd tmp/woods/explorer -p 8000    # stdlib one-liner
```

For CI, publish `explorer/` as a build artifact so every branch gets a
browsable map of its codebase.
