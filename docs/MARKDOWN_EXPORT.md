# Markdown Export

Export Woods extraction artifacts as a folder of plain Markdown notes, one per extracted unit. The
folder is local files only: no API token, no network call, no rate limit. Sync or publish it
wherever you need (a git repo, a static site, a wiki, a shared drive, or an Obsidian vault).

This is the supported export path. The Notion and Unblocked sync integrations are deprecated; see
[Notion](NOTION_INTEGRATION.md) and [Unblocked](UNBLOCKED_INTEGRATION.md).

## Quick start

```bash
bundle exec rake woods:extract
bundle exec rake woods:markdown      # writes tmp/woods/markdown/
```

## What gets generated

```
markdown/
├── .woods-vault          # ownership sentinel (marks the folder as woods-managed)
├── _Overview.md          # units per type, links to each index
├── _woods/               # machine sidecar: manifest.json, dependency_graph.json, graph_analysis.json
├── models/
│   ├── _index.md         # one index per unit type
│   └── User.md           # one note per unit
└── controllers/ ...
```

Each note has a flat YAML front matter block (id, type, file, source hash, PageRank, dependency
counts, and the `woods_managed: true` marker the stale-note sweep relies on), then a Markdown body.
Links between notes are relative Markdown links such as `[Account](../models/Account.md)`, so the
folder renders on GitHub and in any Markdown viewer.

## Obsidian flavor

Set `WOODS_MARKDOWN_OBSIDIAN=1` to switch on the Obsidian-specific output:

- `[[wikilinks]]` instead of relative Markdown links
- `tags` and `aliases` in the front matter, and `> [!warning]` callouts
- `.obsidian/` settings and a `Units.base` view (only into a Woods-owned folder)

See [Obsidian integration](OBSIDIAN_INTEGRATION.md) for how to use that output in Obsidian.

## Configuration

| Env var | Default | Effect |
|---|---|---|
| `WOODS_OUTPUT` | `config.output_dir` (`tmp/woods`) | extraction directory to read from |
| `WOODS_MARKDOWN_DIR` | `<output>/markdown` | where to write the folder |
| `WOODS_MARKDOWN_OBSIDIAN` | off | write the Obsidian flavor |
| `WOODS_MARKDOWN_INCLUDE_SOURCE` | off | embed each unit's source (credential-scrubbed) |
| `WOODS_MARKDOWN_INCLUDE_FRAMEWORK` | off | include `rails_source` and readable `gem_source` units |
| `WOODS_MARKDOWN_FORCE_PURGE` | off | bypass the 30% mass-deletion guard on the stale-note sweep |

The legacy `WOODS_OBSIDIAN_VAULT`, `WOODS_OBSIDIAN_INCLUDE_SOURCE`, `WOODS_OBSIDIAN_INCLUDE_FRAMEWORK`
and `WOODS_OBSIDIAN_FORCE_PURGE` variables are still read when the matching `WOODS_MARKDOWN_*`
variable is unset.

Re-running, ownership checks, and the guarded sweep behave as described in
[Obsidian integration](OBSIDIAN_INTEGRATION.md#re-running-and-safety).

## Renamed tasks

`woods:obsidian` and `woods:vault` still work. They export the Obsidian flavor into
`<output>/obsidian_vault`, print one deprecation line per process, and will be removed in the next
minor release. Use `woods:markdown` with `WOODS_MARKDOWN_OBSIDIAN=1` instead.

## Ruby API

The exporter class keeps its original name and namespace:

```ruby
require 'woods/obsidian/vault_exporter'

Woods::Obsidian::VaultExporter.new(
  index_dir: 'tmp/woods',
  vault_path: 'tmp/woods/markdown',
  obsidian: false
).export_all
```

`obsidian:` defaults to `true` here so existing callers keep their output; `woods:markdown` passes
`false`.
