# Reading a published index from Ruby

`Woods::PublishedIndex` is the stable, read-only API for tools that are not MCP clients: RuboCop cops, CI gate scripts, and the `woods:check:*` tasks. It needs no Rails, opens one published generation, and never moves off it for the life of the reader.

```ruby
require 'woods/published_index'

index = Woods::PublishedIndex.new(Rails.root.join('tmp/woods'))
index.generation_number            # => 42
index.unit('Order')                # => { "type" => "model", "identifier" => "Order", ... }
index.units(type: 'model')         # => index entries with a "type" key
index.edges(via: 'belongs_to')     # => [{ from: "Comment", to: "Post", via: "belongs_to", through: nil, disable_joins: false }]
index.dependents_of('Post')        # => ["Comment", "PostsController"]
index.table_database_map           # => { "orders" => "primary", "events" => "analytics" }
index.external_dependency_checksum # => "9f2c81ad..." (changes on every publish)
index.close
```

Prefer the block form so the lock in the next section is always released:

```ruby
Woods::PublishedIndex.open(Rails.root.join('tmp/woods')) do |index|
  index.table_database_map
end
```

## One generation, pinned for the reader's whole life

Unlike `Woods::MCP::IndexReader`, a `PublishedIndex` never refreshes between calls. It resolves one generation at `.new`/`.open` time and every fact it returns, `units`, the table map, `generation_number`, `external_dependency_checksum`, comes from that one generation for as long as the reader is open. There is no `reload` and no auto-refresh: open a new reader to see a later publish.

Opening a numbered generation acquires that generation's `manifest.json` lock through the same retention protocol `Woods::PayloadStore#prune` respects (a shared advisory `flock`, taken read-only). The lock is held for the reader's whole lifetime, not just one read, so a publish's retention pass cannot remove the payload out from under a long-lived reader: `PayloadStore#prune` takes a non-blocking exclusive lock on the same file before removing a generation, and skips any generation it cannot lock. `#close` releases it (`ensure` in the block form), so a reader that is done reading stops holding the generation open.

## API

| Method | Returns | Notes |
|---|---|---|
| `.new(index_dir, generation: nil)` | reader, holding a lock | `generation:` pins a published `payloads/gen-N`; omit for the currently published one |
| `.open(index_dir, generation: nil) { |index| ... }` | the block's value | releases the lock in `ensure`, on return or exception |
| `.available_generations(index_dir)` | `Array<Integer>` | Published generations, ascending: see below |
| `#generation_number` | Integer | 0 for an index written flat (pre-2.0 layout) |
| `#close` | nil | Releases the retention lock; safe to call more than once |
| `#unit(identifier)` | Hash or nil | The unit JSON, string keys |
| `#units(type: nil)` | `Array<Hash>` | `_index.json` entries plus `"type"` |
| `#edges(via: nil)`, `#each_edge` | `Array<Hash>` | Every forward edge with `through` and `disable_joins`; an identifier shared by more than one type contributes one edge per owning type, never folded into a single deduplicated entry |
| `#dependents_of(identifier, via: nil)` | `Array<String>` | Reverse index |
| `#table_database_map` | `Hash` | Model table to database; empty on Rails 6.0 extractions |
| `#external_dependency_checksum` | String | SHA-256 of the pinned payload's `manifest.json` |

The reader wraps `Woods::MCP::IndexReader` with `auto_refresh: false`; the unit and graph shapes are the ones documented in [Extractor reference](EXTRACTOR_REFERENCE.md#extractedunit-field-reference).

### `available_generations`: published means published

A generation is listed only when both hold:

* its number is at or below the pointer `generation.json` currently names;
* its `payloads/gen-N` directory holds a `manifest.json`.

A directory numbered above the pointer (a payload built but never bumped to) and a directory missing its manifest (an interrupted or corrupted publish) are never listed, and `.new(index_dir, generation: N)` raises `ArgumentError` for either. Retention itself is bounded by `WOODS_PAYLOAD_RETENTION` (default 3).

## Keying a RuboCop cache on the index

RuboCop caches offenses per file and invalidates the cache when a cop's `external_dependency_checksum` changes. `rubocop-rails` uses this to re-run schema-aware cops when `db/schema.rb` changes. The same pattern works against Woods: the pinned payload's `manifest.json` is rewritten through `AtomicFile` on every publish, so its digest is the checksum.

### Worked example: `Multidb/ForeignKeyAcrossDatabases`

The cop flags an `add_foreign_key` in a migration whose two tables resolve to different databases. The table-to-database map comes from the index (`metadata.database` on model units), so the cop never boots Rails.

```ruby
# lib/rubocop/cop/multidb/foreign_key_across_databases.rb
# frozen_string_literal: true

require 'woods/published_index'

module RuboCop
  module Cop
    module Multidb
      # Flags `add_foreign_key :from, :to` when the two tables live in
      # different databases. MySQL and PostgreSQL both refuse the constraint
      # at the database level; catching it in review is cheaper.
      class ForeignKeyAcrossDatabases < Base
        MSG = 'Foreign key from `%<from>s` (%<from_db>s) to `%<to>s` (%<to_db>s) crosses databases.'
        RESTRICT_ON_SEND = %i[add_foreign_key].freeze

        def_node_matcher :foreign_key_tables, <<~PATTERN
          (send nil? :add_foreign_key ${sym str} ${sym str} ...)
        PATTERN

        def on_send(node)
          foreign_key_tables(node) do |from_node, to_node|
            from = from_node.value.to_s
            to = to_node.value.to_s
            from_db = table_databases[from]
            to_db = table_databases[to]
            next if from_db.nil? || to_db.nil? || from_db == to_db

            add_offense(node, message: format(MSG, from: from, from_db: from_db, to: to, to_db: to_db))
          end
        end

        # RuboCop re-runs the cop on every file when this changes, and the
        # pinned manifest changes on every Woods publish.
        def external_dependency_checksum
          index.external_dependency_checksum
        rescue ArgumentError
          'no-woods-index'
        end

        private

        def table_databases
          @table_databases ||= index.table_database_map
        rescue ArgumentError
          {}
        end

        def index
          @index ||= Woods::PublishedIndex.new(File.join(Dir.pwd, 'tmp/woods'))
        end
      end
    end
  end
end
```

Register it in `.rubocop.yml` with `require: ./lib/rubocop/cop/multidb/foreign_key_across_databases` and enable `Multidb/ForeignKeyAcrossDatabases` for `db/migrate/**/*.rb` and `db/*_migrate/**/*.rb`.

Keep the index current in CI so the cop sees the same generation the app runs on:

```ruby
# config/ci.rb (Rails 8.1)
step "Woods: refresh", "bin/rails woods:incremental"
step "Style", "bin/rubocop"
```

A memoized cop instance holds its `PublishedIndex` (and its retention lock) for the process's lifetime; RuboCop runs each cop once per process, so there is no explicit `close` call above.

## Comparing two generations

`generation:` pins a retained payload. Two readers over two generations are the base for [`woods:check:moved_messages`](#moved-message-check), and for any check that asks "what changed between these two publishes".

```ruby
before = Woods::PublishedIndex.new(dir, generation: 41)
after = Woods::PublishedIndex.new(dir, generation: 42)
added = after.units.map { |u| u['identifier'] } - before.units.map { |u| u['identifier'] }
before.close
after.close
added
```

Retention is `WOODS_PAYLOAD_RETENTION` generations (default 3). Raise it on a CI runner that compares against an older baseline, or the older side of the comparison may no longer be published.

(The `## Moved-message check` section is added in Task 12.)
