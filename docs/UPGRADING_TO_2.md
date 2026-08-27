# Upgrading to Woods 2.0

Woods 2.0 corrects how several extractors derive unit identifiers. That is a
change to the index's observable contract, not an internal refactor, so this
guide walks through what breaks, how to recover, and what to check before you
upgrade a production install.

## Breaking Changes

A shared position-aware nesting parser now derives namespaces correctly, and
abstract-model, mixin-module, and GraphQL inner-class artifacts no longer leak
into identifiers. Concretely:

| Before 2.0 | After 2.0 |
|---|---|
| `Payment::aasm` | `Billing::Payment::aasm` |
| `IssueInvoice` | `Billing::IssueInvoice` |
| `ClassMethods` (concern unit) | correctly named after its owning concern |
| `GET /users` (a route with a subdomain, format, or callable constraint) | `GET /users [subdomain=api]`; unconstrained routes are unchanged |

Anything that cached the old shape will miss silently: saved retrieval
queries, external notes, exported Notion pages, exported Obsidian/Unblocked
documents, and any MCP client holding an identifier list. There is no
compatibility shim. The fix is a clean re-index.

### The output directory layout has changed

Extraction now publishes each generation's artifacts into an immutable
directory named by `generation.json`. One atomic write commits the whole
payload, so a reader can never load a unit from one generation beside a
manifest from another.

```
tmp/woods/
├── generation.json          → {"number": 42, "payload": "payloads/gen-42", ...}
└── payloads/
    ├── gen-41/              (superseded, retained, still whole)
    └── gen-42/              manifest.json, dependency_graph.json,
                             graph_analysis.json, SUMMARY.md, <type>/*.json
```

**No re-index is required for this.** Everything inside Woods (MCP servers,
exporters, validator, watch daemon, rake tasks) resolves the pointer. It
matters only if **your own** tooling reads the index files directly. Read
`generation.json`, take its `payload` value, and resolve it relative to the
index directory:

```ruby
marker = JSON.parse(File.read(File.join(index_dir, 'generation.json')))
payload = File.join(index_dir, marker['payload'] || '.')
manifest = JSON.parse(File.read(File.join(payload, 'manifest.json')))
```

A missing `payload` key means a flat index: resolve to the index directory
itself. A pre-2.0 index, or a run whose payload directory could not be
created, gives you that shape.

Woods retains three generations. Set `WOODS_PAYLOAD_RETENTION` to keep more
(useful when long-running readers hold a generation open for a while) or
fewer. The files a pre-2.0 run left at the index root are stale from the
first payload publish onward; `woods:clean` removes them.

## Clean Re-Indexing

Run these against your Rails app, in order:

```bash
bundle exec rake woods:clean
bundle exec rake woods:extract
bundle exec rake woods:embed          # only if you embed for semantic search
```

If you sync to Notion, Obsidian, or Unblocked, re-run that export afterward
(`woods:notion_sync`, `woods:obsidian`, `woods:unblocked_sync`). See
[Exporter Reconciliation](#exporter-reconciliation) below for what happens to
renamed units.

## Back Up Before Upgrading

`woods:clean` only removes the extraction/index directory (`tmp/woods` by
default, or `WOODS_OUTPUT`). That output is disposable: a fresh
`woods:extract` regenerates it.

A durable vector store is *not* disposable. The first embed after upgrading
deletes vectors (see below). Back it up first if it holds anything you can't
afford to lose:

| Vector store | Applies to | Backup method |
|---|---|---|
| pgvector | PostgreSQL-only, in-database | `pg_dump` the table backing the connection you pass as `vector_store_options[:connection]`, or a schema-level snapshot of that database |
| Qdrant | Required for MySQL/MariaDB/Aurora MySQL stacks; also usable on PostgreSQL | Qdrant's own collection snapshot API |

The `:local` and `:shared_filesystem` presets need no separate backup step.
Their vectors live in `dumps/` under the output directory, and Woods keeps the
last `dump_retention_count` (default 3). `woods:clean` still removes those
dumps, so copy the directory out first if you rely on one.

## Store and Dimension Migration

The first `woods:embed` or `woods:embed_incremental` run after upgrading
reconciles the vector store against extraction output: it deletes vectors for
every unit extraction no longer produces, which includes every renamed unit.
On a rename-heavy index this is most of the store.

A **purge guard** refuses the run if it would delete more than 30% of the
store, or purge into an empty extraction. Set `WOODS_ALLOW_PURGE=1` to
override, once you've confirmed the deletion is intentional:

```bash
WOODS_ALLOW_PURGE=1 bundle exec rake woods:embed
```

Treat that override as a one-way door for whatever it deletes. There is no
undo short of restoring the backup above.

Separately, `woods:embed` now compares the provider's dimension against what
the store holds before it embeds anything. A mismatch raises
`Woods::MCP::DimensionMismatch` with both widths, instead of failing per row
partway through.

- The same check runs at MCP server boot for the `:local` and
  `:shared_filesystem` presets (WVF1 dump header vs resolved configuration).
- If you changed `embedding_model` at some point and it "worked", this check
  may now surface a latent mismatch the old code tolerated:

```ruby
# config/initializers/woods.rb
Woods.configure do |config|
  config.embedding_model = "text-embedding-3-large" # dimension differs from -small
end
```

The remedy is the same either way: a full re-embed into a store created at
the new width. There is no in-place dimension conversion.

## Exporter Reconciliation

Notion, Obsidian, and Unblocked exports track what they last pushed and
reconcile against current extraction output. A renamed unit is not detected
as "the same document under a new name". It is a delete of the old identifier
plus an add of the new one, same as any other rename.

| Exporter | Tracks state via | Mass-deletion guard |
|---|---|---|
| Notion | `<output_dir>/notion_sync_manifest.json` (content hash + page id) | Not applicable. There is no delete path: a renamed or removed unit's old page stays in Notion; only its manifest entry is pruned |
| Obsidian | `.woods-vault` sentinel + stale-note sweep over the vault | refuses beyond 30% of managed notes; `WOODS_OBSIDIAN_FORCE_PURGE` overrides |
| Unblocked | `<output_dir>/unblocked_sync_manifest.json` | refuses beyond 30% of a manifest tracking 10+ documents; `UNBLOCKED_FORCE_PURGE` overrides |

On a rename-heavy upgrade, expect to need each force-purge variable once:

- The guard refuses a deletion that looks like a partial index. A full
  re-index after a rename-shape change is exactly that deletion, legitimately.
- This is the same reason `WOODS_ALLOW_PURGE` is needed for the vector store.
- Notion never deletes pages, so it has no guard to trip. Set
  `WOODS_NOTION_FORCE=1` to re-check every page instead of skipping unchanged
  content hashes.

## MCP Client Requirements

Woods 2.0 depends on the `mcp` gem at `>= 1.2, < 2.0` (see `woods.gemspec`).
1.2 added the 2026-07-28 protocol revision: `server/discover`, stateless
Streamable HTTP, and the request-envelope validation the Index Server uses.

`woods-mcp-start` no longer defaults `MCP_PROTOCOL_VERSION` to `2024-11-05`.

- The SDK server answers `initialize` for legacy clients and serves
  `server/discover` for modern ones in the same process.
- Leaving the variable unset is the more compatible choice, not a regression.
- **Never set `MCP_PROTOCOL_VERSION`** unless one client needs the older
  negotiation path. Setting it collapses the server to a single era. When
  set, it announces itself on stderr.
- No action is required: no on-disk format changed, and no re-extraction or
  re-embedding follows from this alone.

## Known Limitations

- The `mcp` gem does not yet implement Tasks push notifications or
  `subscriptions/listen`. Woods supplies durable `tasks/*` polling instead.
- A client cannot be pushed a change notification when the index regenerates.
- `woods-mcp-http` in its default stateless mode has no notification channel
  at all, by design. `IndexReader#ensure_fresh!` remains the correctness path
  for freshness; push was only ever an optimization.

## Rollback and Downgrade

Downgrading is not a metadata revert.

1. After a clean re-index under 2.0, the identifiers on disk and in any
   durable vector store have the 2.0 shape.
2. A pre-2.0 gem cannot translate them back.
3. The only way back is to re-index again from the old gem version against
   your source tree.

Keep that in mind before upgrading a shared or production index in place.

## Failure Recovery

An interrupted `woods:extract` or `woods:incremental` leaves the index on its
last complete generation. The generation marker is bumped only after a run
finishes, so a reader never sees a half-written extraction. Re-run the task;
there is nothing to clean up first.

An interrupted `woods:embed` or `woods:embed_incremental` is safe to re-run
too. The checkpoint advances over a unit only once its vector is durably
stored. A checkpoint that ran ahead of disk (a killed process, an interrupted
dump promote) self-heals: the next run re-embeds that unit and reports it on
stderr.

