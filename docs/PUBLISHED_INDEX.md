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

**Not thread-safe.** A `PublishedIndex` instance is meant for one script or cop process reading one generation; it keeps no mutex around its lock file or its underlying `Woods::MCP::IndexReader`. Give each thread its own reader rather than sharing one.

## API

| Method | Returns | Notes |
|---|---|---|
| `.new(index_dir, generation: nil)` | reader, holding a lock | `generation:` pins a published `payloads/gen-N`; omit for the currently published one |
| `.open(index_dir, generation: nil) { |index| ... }` | the block's value | releases the lock in `ensure`, on return or exception |
| `.available_generations(index_dir)` | `Array<Integer>` | Published generations, ascending: see below |
| `#generation_number` | Integer | 0 for an index written flat (pre-2.0 layout) |
| `#close` | nil | Releases the retention lock; safe to call more than once |
| `#unit(identifier, type: nil)` | Hash or nil | The unit JSON, string keys; see the collision note below |
| `#units(type: nil)` | `Array<Hash>` | `_index.json` entries plus `"type"` |
| `#edges(via: nil)`, `#each_edge` | `Array<Hash>` | Every forward edge with `through` and `disable_joins`; an identifier shared by more than one type contributes one edge per owning type, never folded into a single deduplicated entry |
| `#dependents_of(identifier, via: nil)` | `Array<String>` | Reverse index |
| `#table_database_map` | `Hash` | Model table to database; empty on Rails 6.0 extractions |
| `#external_dependency_checksum` | String | SHA-256 of the pinned payload's `manifest.json` |

The reader wraps `Woods::MCP::IndexReader` with `auto_refresh: false`; the unit and graph shapes are the ones documented in [Extractor reference](EXTRACTOR_REFERENCE.md#extractedunit-field-reference).

### `#unit`: an identifier shared across types

`Woods::MCP::IndexReader#find_unit` keys its identifier map on identifier alone. If two type directories both list the same identifier (a model and a service both named `Foo`, for example), whichever type sorts last in `Woods::MCP::IndexReader::TYPE_DIRS` silently wins, and `unit(identifier)` returns that one. Pass `type:` to read a specific type's unit file directly and skip the collision entirely; `#table_database_map` always does this internally (`type: 'model'`), so a same-named non-model unit can never shadow a model's `table_name`/`database`.

### `available_generations`: published means published

A generation is listed only when both hold:

* its number is at or below the pointer `generation.json` currently names;
* its `payloads/gen-N` directory holds a `manifest.json`.

A directory numbered above the pointer (a payload built but never bumped to) and a directory missing its manifest (an interrupted or corrupted publish) are never listed, and `.new(index_dir, generation: N)` raises `ArgumentError` for either. Retention itself is bounded by `WOODS_PAYLOAD_RETENTION` (default 3).

A *missing* `generation.json` is not an error: it means a flat (pre-2.0) index, generation 0. A `generation.json` that **exists but will not parse** is different, a corrupt install, not an empty index, so `.available_generations` and `.new`/`.open` raise `Woods::PublishedIndex::CorruptPointerError` naming the file's path instead of silently reporting zero published generations.

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

## Moved-message check

`woods:check:moved_messages` opens two retained generations through `Woods::PublishedIndex` (block form, so both readers' retention locks always release) and reports every public method name that looks like it moved from one unit to another while a `:test_coverage` edge did not follow.

Each row is a **candidate move into a unit without mapped tests**, never a proven coverage loss: the check matches on method name and kind alone, so two unrelated methods that happen to share both look identical to a real move. Reported only when the source unit was covered before and the destination is not covered after; a method that was never covered is not a regression this check owns. `WOODS_CHECK_STRICT=1` exits 1 on any finding, but the check stays heuristic either way, strict mode changes the exit code, not the confidence of a row.

```bash
bin/rails woods:check:moved_messages              # previous retained generation vs the published one
bin/rails "woods:check:moved_messages[41,42]"     # explicit generations
WOODS_CHECK_STRICT=1 bin/rails woods:check:moved_messages   # exit 1 on findings, for CI (still heuristic)
WOODS_CHECK_JSON=1 bin/rails woods:check:moved_messages     # also print findings as JSON
```

With no `[from,to]` given, the generations default to the latest two from `available_generations` (a pure function, `Woods::Checks::GenerationResolution`, picks them); an index with fewer than two retained generations exits 1 with a message naming `WOODS_PAYLOAD_RETENTION` as the fix. A `generation.json` that will not parse raises `Woods::PublishedIndex::CorruptPointerError`, named by the task before it propagates, rather than being swallowed as "no findings".

### Which key holds which method list

The check reads three metadata keys and normalizes them to one `[name, kind]` shape before matching, so an instance method never collides with a class method of the same bare name:

| Extractor family | Key | Shape |
|---|---|---|
| Services, POROs, managers, decorators, policies, validators, concerns, Pundit policies, lib units | `public_methods` | Regex-extracted; a class method is a bare name **prefixed with `self.`** (`"self.build"`), an instance method is bare (`"run"`) |
| Services, POROs, managers, decorators, policies, validators, concerns, lib units | `class_methods` | Regex-extracted `def self.foo` names, prefix already stripped |
| Concerns, models | `instance_methods` | Bare names; models get this from runtime introspection (`instance_methods(false)`, filtered), a wider list than the regex-based extractors produce |
| Phlex components, ViewComponents | `public_methods` | Runtime introspection (`public_instance_methods(false)`); always bare, since these extractors only ever report instance methods |

Model units carry both `instance_methods` and `class_methods` from runtime introspection, no `public_methods` key, and it is the widest of the method lists: every instance and class method the model responds to, not just the ones a source-regex can see.

| Situation | Reported |
|---|---|
| `total` left `Checkout` (covered) and appeared in `Pricing` (not covered) | yes |
| Same move, `Pricing` covered by a test_mapping unit | no |
| `total` was never covered before the move | no |
| Method renamed in place | no (nothing gained it) |
| An instance method and a same-named class method swap units | no (kind mismatch) |
| A `self.build` public method reappears as a `class_methods` entry named `build` | yes, `kind: :class` (normalized to the same signature) |

Temporal snapshots (`snapshot_diff`, `unit_history`) store content hashes only, so they cannot see a moved method; that is why the check reads payload generations. Keep at least two retained generations (`WOODS_PAYLOAD_RETENTION`, default 3).
