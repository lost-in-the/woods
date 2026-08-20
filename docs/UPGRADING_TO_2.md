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

Anything that cached the old shape will miss silently: saved retrieval
queries, external notes, exported Notion pages, exported Obsidian/Unblocked
documents, and any MCP client holding an identifier list. There is no
compatibility shim — the fix is a clean re-index.

## Clean Re-Indexing

Run these against your Rails app, in order:

```bash
bundle exec rake woods:clean
bundle exec rake woods:extract
bundle exec rake woods:embed          # only if you embed for semantic search
```

If you sync to Notion, Obsidian, or Unblocked, re-run that export afterward
(`woods:notion_sync`, `woods:obsidian`, `woods:unblocked_sync`) — see
[Exporter Reconciliation](#exporter-reconciliation) below for what happens to
renamed units.

## Back Up Before Upgrading

`woods:clean` only removes the extraction/index directory (`tmp/woods` by
default, or `WOODS_OUTPUT`) — extraction output is always disposable, since a
fresh `woods:extract` regenerates it. What is *not* disposable is a durable
vector store, because the first embed after upgrading deletes vectors (see
below). Back that up first if it holds anything you can't afford to lose:

| Vector store | Applies to | Backup method |
|---|---|---|
| pgvector | PostgreSQL-only, in-database | `pg_dump` the table backing the connection you pass as `vector_store_options[:connection]`, or a schema-level snapshot of that database |
| Qdrant | Required for MySQL/MariaDB/Aurora MySQL stacks; also usable on PostgreSQL | Qdrant's own collection snapshot API |

The `:local` and `:shared_filesystem` presets need no separate backup step —
their vectors live in `dumps/` under the output directory, and Woods retains
the last `dump_retention_count` (default 3) automatically. Those dumps are
still removed by `woods:clean`, so if you rely on one, copy the directory out
first.

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

Treat that override as a one-way door for whatever it deletes — there is no
undo short of restoring the backup above.

Separately, `woods:embed` now checks the embedding provider's dimension
against what the store actually holds before embedding anything, raising
`Woods::MCP::DimensionMismatch` with both widths instead of failing per-row
partway through. The same check runs at MCP server boot for the `:local`/
`:shared_filesystem` presets, comparing the WVF1 dump header against your
resolved configuration. If you changed `embedding_model` at some point and it
"worked", this check may now surface a latent mismatch the old code silently
tolerated:

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
as "the same document under a new name" — it is a delete of the old
identifier plus an add of the new one, same as any other rename.

| Exporter | Tracks state via | Mass-deletion guard |
|---|---|---|
| Notion | Database properties, matched by unit identifier | none documented; runs the mapped Data Models/Columns sync each time |
| Obsidian | `.woods-vault` sentinel + stale-note sweep over the vault | refuses beyond 30% of managed notes; `WOODS_OBSIDIAN_FORCE_PURGE` overrides |
| Unblocked | `<output_dir>/unblocked_sync_manifest.json` | refuses beyond 30% of a manifest tracking 10+ documents; `UNBLOCKED_FORCE_PURGE` overrides |

On a rename-heavy upgrade, expect to need the relevant force-purge variable
once, for the same reason `WOODS_ALLOW_PURGE` is needed for the vector store:
the guard is doing its job by refusing a deletion that looks like a partial
index, and a full re-index after a rename-shape change is exactly that
deletion, legitimately.

## MCP Client Requirements

Woods 2.0 depends on the `mcp` gem at `>= 1.2, < 2.0` (see `woods.gemspec`;
`Gemfile.lock` resolves `1.2.0`) — 1.2 added the 2026-07-28 protocol revision:
`server/discover`, stateless Streamable HTTP, and the request-envelope
validation the Index Server relies on.

`woods-mcp-start` no longer defaults `MCP_PROTOCOL_VERSION` to `2024-11-05`.
The underlying SDK server answers `initialize` for legacy clients and serves
`server/discover` plus per-request metadata for modern ones in the same
process, so leaving the variable unset is the more compatible choice, not a
regression. **Never set `MCP_PROTOCOL_VERSION`** unless a specific client
requires the older negotiation path — it collapses the server to a single
era. The variable still works as an escape hatch and now announces itself on
stderr when set. No action is required for this change: no on-disk artifact
format changed, and no re-extraction or re-embedding is implied by it alone.

## Known Limitations

The `mcp` gem does not yet implement the Tasks extension's push notifications
or `subscriptions/listen`; Woods supplies durable `tasks/*` polling locally as
a substitute, but a client cannot be pushed a change notification when the
index regenerates. `woods-mcp-http` running in its default stateless mode has
no notification channel at all, by design — `IndexReader#ensure_fresh!`
remains the correctness path for freshness on that transport, and push was
only ever an optimization on top of it.

## Rollback and Downgrade

Downgrading is not a metadata revert. If you roll back to a pre-2.0 gem
version after running a clean re-index, the 2.0-shaped identifiers on disk
and in any durable vector store do not translate back — the old identifier
shape is gone once you've re-indexed under 2.0 and is only recoverable by
re-indexing again from the old gem version against your source tree. Keep
that in mind before upgrading a shared or production index in place.

## Failure Recovery

An interrupted `woods:extract` or `woods:incremental` leaves the index on its
last complete generation: the generation marker is bumped only after a run
finishes successfully, so a reader never sees a half-written extraction.
Re-run the task; there is nothing to clean up first.

An interrupted `woods:embed` or `woods:embed_incremental` is safe to re-run
too. The checkpoint only advances over a unit once its vector is durably
stored, so a checkpoint that ran ahead of what's actually on disk (a killed
process, an interrupted dump promote) self-heals: the next run re-embeds that
unit and reports it on stderr, rather than silently leaving it stranded.

<!--
Sources:
CHANGELOG.md - 2.0.0 Upgrade Notes, Added, Changed sections (identifier reshape, clean re-index remedy, durable-store reconciliation + 30% purge guard, DimensionMismatch, MCP protocol changes)
CLAUDE.md - Gotchas: DimensionMismatch / verify_store_dimensions! / WVF1 header; checkpoint self-heal (#148); Generation bumped last and only on success; mcp gem pin and MCP_PROTOCOL_VERSION guidance
lib/tasks/woods.rake - task names verified by grep: extract, clean, embed, embed_incremental, notion_sync, obsidian, unblocked_sync
woods.gemspec - mcp dependency at the documented >= 1.2, < 2.0 range
Gemfile.lock - confirms mcp (1.2.0) resolved, within the gemspec range
docs/BACKEND_MATRIX.md - MySQL requires an external vector backend (:qdrant); PostgreSQL can use pgvector in-database
docs/OBSIDIAN_INTEGRATION.md - .woods-vault sentinel, stale-note sweep, 30% guard, WOODS_OBSIDIAN_FORCE_PURGE
docs/UNBLOCKED_INTEGRATION.md - sync manifest, 30% guard on 10+ document manifests, UNBLOCKED_FORCE_PURGE
lib/woods.rb - output_dir default (tmp/woods), dump_retention_count default (3), embedding_model config accessor
lib/woods/embedding/indexer.rb - WOODS_ALLOW_PURGE env var and purge-guard messages
exe/woods-mcp-start - MCP_PROTOCOL_VERSION handling and stderr announcement
-->
