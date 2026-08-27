# Obsidian Integration

Export Woods extraction artifacts to a self-contained [Obsidian](https://obsidian.md) vault, a
folder of interlinked Markdown notes, one per extracted unit. The vault is designed to be read two
ways at once:

- **By humans**: explore the app's structure in Obsidian's graph view, filter and sort units in an
  Obsidian [Bases](https://help.obsidian.md/bases) table, and drill into a single unit's note with its
  dependencies and dependents as clickable wikilinks.
- **By agents**: load the entire dependency topology from a single `_woods/` sidecar (one read,
  no per-note fan-out), with a stable `id → note path` manifest for navigation.

Unlike the Notion and Unblocked exporters, this one writes **local files only**: there is no API
token, no network call, and no rate limit. An Obsidian vault is just a folder.

## Quick start

```bash
# 1. Extract (produces tmp/woods/ with the dependency graph + per-unit JSON)
bundle exec rake woods:extract

# 2. Generate the vault (defaults to tmp/woods/obsidian_vault/)
bundle exec rake woods:obsidian
```

Then in Obsidian: **Open folder as vault** → point it at `tmp/woods/obsidian_vault`. For the full
experience (graph colors, Bases, link format) open the generated folder *as its own vault* rather than
nesting it inside an existing one, a nested folder inherits the host vault's config and ignores the
shipped `.obsidian/` settings.

## What gets generated

```
obsidian_vault/
├── .woods-vault              # ownership sentinel (marks this dir as woods-managed)
├── .obsidian/                # vault config, only written into a woods-owned vault
│   ├── app.json              #   newLinkFormat: absolute, useMarkdownLinks: false
│   ├── types.json            #   property types (pagerank → number, tags → tags)
│   └── graph.json            #   color groups by #woods/<type> (global graph)
├── _woods/                   # machine sidecar (the agent interface)
│   ├── manifest.json         #   { notes: {id → {path,type,pagerank,tags}}, paths: {path → id} }
│   ├── dependency_graph.json #   verbatim copy, full topology for traversal
│   └── graph_analysis.json   #   verbatim copy, hubs / cycles / orphans / bridges
├── Units.base                # Obsidian Bases view (filterable/sortable unit inventory)
├── _Overview.md              # top-level map of contents
├── models/
│   ├── _index.md             # MOC: every model as a wikilink
│   └── User.md
├── controllers/
│   └── Users__RegistrationsController.md
└── …                         # one folder per extracted unit type
```

## A unit note

Each note carries **flat YAML frontmatter** (the machine-queryable surface) and a Markdown body with
wikilinks (the human surface). Frontmatter is kept flat on purpose. Obsidian's Properties UI does
not support nested objects or arrays-of-objects, so the structured edge data lives in the `_woods/`
sidecar instead.

```markdown
---
woods_managed: true
id: User
type: model
file: app/models/user.rb
source_hash: a3c5f8e9
pagerank: 0.0421
dependency_count: 3
dependent_count: 12
tags:
- woods/model
- woods/hub
aliases:
- User
---

# User

**File:** `app/models/user.rb` | **LOC:** 84 | **Table:** users (17 columns)

> [!warning] Hub, high blast radius
> 12 units depend on this (PageRank 0.0421).

## Depends on
- [[models/Account|Account]], *belongs_to*
- [[mailers/WelcomeMailer|WelcomeMailer]], *job_enqueue*

## Used by (12)
**controllers:** [[controllers/Users__RegistrationsController|Users::RegistrationsController]]
**jobs:** [[jobs/SyncProfileJob|SyncProfileJob]]
```

Wikilinks are path-qualified with an alias (`[[models/Account|Account]]`): the target is the
sanitized vault path so the link always resolves, and the alias shows the original identifier. The
note's `# H1` carries the clean identifier so the sanitized filename never shows as the title.

## The three visualizer surfaces

| Surface | Best for | Notes |
|---|---|---|
| **Graph view** | seeing connections / blast radius at a glance | colored by `#woods/<type>` tag (global graph); for the *local* graph, create the color-by-tag groups once. Obsidian persists them per-vault |
| **Bases (`Units.base`)** | inventory & triage, "all models sorted by PageRank", "show me the hubs" | requires Obsidian ≥ 1.9 (cards/list views ≥ 1.10); inert and harmless on older versions |
| **Note bodies + backlinks** | drilling into one unit and navigating outward | "Depends on" / "Used by" are clickable; Obsidian's backlink panel shows inbound links |

## Configuration

All options are passed to the rake task via environment variables, there are **no global
`Woods.configure` settings** for this exporter (the vault path is an output location, not a
credential):

| Env var | Default | Effect |
|---|---|---|
| `WOODS_OUTPUT` | `config.output_dir` (`tmp/woods`) | extraction directory to read from |
| `WOODS_OBSIDIAN_VAULT` | `<output>/obsidian_vault` | where to write the vault |
| `WOODS_OBSIDIAN_INCLUDE_SOURCE` | off | embed each unit's source code (credential-scrubbed) in its note |
| `WOODS_OBSIDIAN_INCLUDE_FRAMEWORK` | off | include `rails_source` units (large; off by default) |
| `WOODS_OBSIDIAN_FORCE_PURGE` | off | bypass the 30% mass-deletion guard during the stale-note sweep |

```bash
WOODS_OBSIDIAN_VAULT=~/notes/myapp-code WOODS_OBSIDIAN_INCLUDE_SOURCE=1 bundle exec rake woods:obsidian
```

Or call the exporter directly:

```ruby
require 'woods/obsidian/vault_exporter'

Woods::Obsidian::VaultExporter.new(
  index_dir: 'tmp/woods',
  vault_path: 'tmp/woods/obsidian_vault',
  include_source: false,
  include_framework: false
).export_all
# => { exported: 412, indexes: 19, swept: 3, skipped: 0, errors: [] }
```

## Re-running and safety

The exporter **fully regenerates** the vault on every run (no incremental manifest, local writes are
cheap). Output is deterministic: re-running against an unchanged extraction produces byte-identical
notes, so unchanged units never show up in a git diff.

Notes Woods manages carry `woods_managed: true` in their frontmatter. On each run, after all notes are
written successfully, a **sweep** removes managed notes whose unit no longer exists, so deletions in
your code propagate. Several guards make the sweep safe to point at a real vault:

- It only runs against a directory carrying the `.woods-vault` sentinel (written by Woods on first run).
- It only deletes notes with the `woods_managed: true` marker, your own notes are never touched.
- It refuses to delete more than 30% of managed notes at once (the signature of a partial extraction)
  unless `WOODS_OBSIDIAN_FORCE_PURGE=1` is set.
- It resolves symlinks and confirms every deletion target is inside the vault root.
- It is skipped entirely if any note failed to write that run (a stale note is harmless; a deleted
  reviewed note is not).

The same ownership check guards the `.obsidian/` config: Woods will **not** overwrite an existing,
foreign `.obsidian/` folder, it leaves your Obsidian settings untouched and warns instead.

## Limitations

- **Bases needs Obsidian ≥ 1.9** (≥ 1.10 for card/list views). The `.base` file is harmless on older
  versions, it simply doesn't render.
- **`gem_source` units are not exported.** They aren't reachable through the index reader; only
  `rails_source` is covered by `include_framework`.
- **Hand-edits diverge.** The vault is meant to be regenerated. Editing a note's properties in
  Obsidian rewrites its frontmatter, after which a re-export will overwrite your changes.
- **Nested vaults ignore the shipped config.** Open the generated folder as its own vault for graph
  colors, Bases, and link-format settings to apply.

See `docs/AGENT_GUIDE.md` for how an agent consumes the `_woods/` sidecar.
