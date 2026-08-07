# frozen_string_literal: true

require 'json'
require 'time'

module Woods
  # Same conditional-define pattern used elsewhere in the gem so this
  # file can be required in isolation (e.g. by specs that bypass the
  # full lib/woods.rb load) without tripping NameError on the friendly
  # missing-sqlite3 raise below.
  class Error < StandardError; end unless defined?(Woods::Error)
  class ConfigurationError < Error; end unless defined?(Woods::ConfigurationError)

  module Storage
    # MetadataStore provides an interface for storing and querying unit metadata.
    #
    # All metadata store adapters must include the {Interface} module and implement
    # its methods. The {SQLite} adapter is provided for local persistence.
    #
    # @example Using the SQLite adapter
    #   store = Woods::Storage::MetadataStore::SQLite.new(":memory:")
    #   store.store("User", { type: "model", file_path: "app/models/user.rb" })
    #   store.find("User")
    #
    module MetadataStore
      # Conservative whitelist for caller-supplied search field names —
      # mirrors the filter-key standard in {Woods::Storage::Pgvector#build_where}.
      # The SQLite adapter interpolates field names into a
      # `json_extract(data, '$.<field>')` JSON-path literal, so anything
      # outside this charset must be rejected before any SQL is built: a
      # crafted field name (quotes, parens, `--`) can otherwise break out of
      # the string literal and alter the query shape.
      SEARCH_FIELD_NAME = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

      # Interface that all metadata store adapters must implement.
      module Interface
        # Store or update metadata for a unit.
        #
        # @param id [String] Unique identifier for the unit
        # @param metadata [Hash] Metadata to store
        # @raise [NotImplementedError] if not implemented by adapter
        def store(id, metadata)
          raise NotImplementedError
        end

        # Find a unit by ID.
        #
        # @param id [String] The identifier to look up
        # @return [Hash, nil] The stored metadata, or nil if not found
        # @raise [NotImplementedError] if not implemented by adapter
        def find(id)
          raise NotImplementedError
        end

        # Find multiple units by IDs in a single query.
        #
        # Default implementation falls back to individual find calls.
        # Adapters should override for batch-optimized behavior.
        #
        # @param ids [Array<String>] The identifiers to look up
        # @return [Hash<String, Hash>] Map of id => metadata for found units
        def find_batch(ids)
          ids.each_with_object({}) do |id, result|
            data = find(id)
            result[id] = data if data
          end
        end

        # Find all units of a given type.
        #
        # @param type [String] The unit type to filter by
        # @return [Array<Hash>] Matching metadata records
        # @raise [NotImplementedError] if not implemented by adapter
        def find_by_type(type)
          raise NotImplementedError
        end

        # Search metadata by text query across specified fields.
        #
        # **Contract every adapter must honour** (pinned by the
        # `'hardened search'` shared examples in
        # spec/storage/metadata_store_spec.rb, which run against every
        # adapter — they were substitutable in name only until the semantics
        # were written down):
        #
        # - **Substring match**, not word or prefix match.
        # - **Case-insensitive.** InMemory used a case-sensitive
        #   `String#include?` while SQLite used `LIKE`, so the same query
        #   returned different results depending on the configured backend.
        #   Case-insensitive is both the search-like expectation and what the
        #   durable adapter already did. (SQLite's `LIKE` folds ASCII only, so
        #   non-ASCII case folding remains backend-specific — do not rely on
        #   it either way.)
        # - **`fields: nil` searches the whole record**, including keys, as
        #   serialized JSON. A query can therefore match a field *name*.
        # - **LIKE metacharacters are literal.** `%` and `_` in a query match
        #   themselves rather than acting as wildcards.
        # - Field names are validated against {SEARCH_FIELD_NAME} by every
        #   adapter, so a hostile name raises the same ArgumentError
        #   everywhere.
        #
        # @param query [String] Text to search for
        # @param fields [Array<String>, nil] Specific fields to search (nil = all)
        # @return [Array<Hash>] Matching metadata records
        # @raise [NotImplementedError] if not implemented by adapter
        def search(query, fields: nil)
          raise NotImplementedError
        end

        # Delete a unit by ID.
        #
        # @param id [String] The identifier to delete
        # @raise [NotImplementedError] if not implemented by adapter
        def delete(id)
          raise NotImplementedError
        end

        # Return the total number of stored units.
        #
        # @return [Integer] Total count
        # @raise [NotImplementedError] if not implemented by adapter
        def count
          raise NotImplementedError
        end

        private

        # Validate caller-supplied search field names against
        # {SEARCH_FIELD_NAME}, stringifying as it goes (symbol fields were
        # always accepted). Every adapter's {#search} must run its `fields:`
        # through this BEFORE touching its backing store, so a hostile field
        # name raises the same {ArgumentError} everywhere — including
        # adapters (InMemory) where the name is not an injection vector,
        # keeping the adapters substitutable.
        #
        # @param fields [Array<String, Symbol>, nil] Field names, or nil for "all fields"
        # @return [Array<String>, nil] Stringified field names, or nil if fields was nil
        # @raise [ArgumentError] if any field name fails the whitelist
        def validate_search_fields!(fields)
          return nil if fields.nil?

          fields.map do |field|
            field_s = field.to_s
            raise ArgumentError, "Invalid search field: #{field_s.inspect}" unless field_s.match?(SEARCH_FIELD_NAME)

            field_s
          end
        end
      end

      # Pure-Ruby metadata store backed by a hash. No external dependencies,
      # no persistence — vectors and metadata both live in the building
      # process and die with it. Suitable for hosts that don't bundle the
      # `sqlite3` gem (e.g., MySQL- or Postgres-only Rails apps), and for
      # short-lived processes that rebuild the index per run.
      #
      # @example
      #   store = InMemory.new
      #   store.store("User", { type: "model", namespace: "Admin" })
      #   store.find("User")  # => { "type" => "model", "namespace" => "Admin" }
      #
      class InMemory
        include Interface

        def initialize
          @data = {}
        end

        # @see Interface#store
        def store(id, metadata)
          @data[id] = stringify_keys(metadata).merge('updated_at' => Time.now.iso8601)
        end

        # @see Interface#find
        def find(id)
          record = @data[id]
          return nil unless record

          record.except('updated_at')
        end

        # @see Interface#find_batch
        def find_batch(ids)
          ids.each_with_object({}) do |id, result|
            data = find(id)
            result[id] = data if data
          end
        end

        # @see Interface#find_by_type
        def find_by_type(type)
          target = type.to_s
          @data.each_with_object([]) do |(id, record), out|
            next unless record['type'].to_s == target

            out << record.except('updated_at').merge('id' => id)
          end
        end

        # @see Interface#search
        #
        # Matching is literal substring inclusion — `%` and `_` in the query
        # have no special meaning here, and the SQLite adapter escapes them
        # so the two adapters agree. (Known, deliberate divergence: this
        # adapter is case-sensitive while SQLite's LIKE is ASCII
        # case-insensitive — not widened, not fixed here.)
        #
        # @raise [ArgumentError] if a field name fails {SEARCH_FIELD_NAME}
        def search(query, fields: nil)
          fields = validate_search_fields!(fields)
          # Case-insensitive, matching the SQLite adapter's `LIKE` (see the
          # contract note on {Interface#search}). This used to be a
          # case-sensitive `String#include?`, so the same query returned
          # different results depending on which backend a host had configured.
          needle = query.to_s.downcase
          @data.each_with_object([]) do |(id, record), out|
            haystacks = fields ? fields.map { |f| record[f] } : [JSON.generate(record)]
            next unless haystacks.compact.any? { |h| h.to_s.downcase.include?(needle) }

            out << record.except('updated_at').merge('id' => id)
          end
        end

        # @see Interface#delete
        def delete(id)
          @data.delete(id)
        end

        # @see Interface#count
        def count
          @data.size
        end

        # Iterate over every stored entry, yielding +(id, metadata)+ pairs.
        #
        # Persistence seam for {Snapshotter::Metadata}. Yields the raw internal
        # hash (including +updated_at+) so the Snapshotter can reconstruct state
        # faithfully on load.
        #
        # @yield [id, metadata] id is a String; metadata is a Hash with string keys
        # @return [Enumerator] when no block given
        def each_entry(&block)
          return enum_for(:each_entry) unless block

          @data.each(&block)
        end

        # Hydrate the store from a pre-serialized dump.
        #
        # Dual of {#each_entry} — Snapshotter feeds the deserialized dump contents
        # through this method to restore the store in a new process.
        #
        # @param entries [Enumerable<Array(String, Hash)>] Pairs of +[id, metadata]+
        # @return [void]
        def bulk_load(entries)
          entries.each { |id, meta| @data[id] = meta }
        end

        # Drop every stored entry. Used by the MCP +reload+ tool to pick up a
        # fresh embed run without restarting the process. Safe on an empty store.
        def clear!
          @data = {}
        end

        private

        # Match the SQLite adapter's string-key contract regardless of how
        # the caller serialises the input hash. Without this, find/search
        # consumers that expect string keys (the SQLite path round-trips
        # through JSON, which always returns strings) would break under
        # symbol-keyed test fixtures.
        def stringify_keys(hash)
          hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
        end
      end

      # SQLite-backed metadata store using the JSON1 extension.
      #
      # Stores unit metadata as JSON in a single table with type indexing
      # for efficient filtering. Uses upsert semantics for store operations.
      #
      # @example
      #   store = SQLite.new(":memory:")
      #   store.store("User", { type: "model", namespace: "Admin" })
      #   store.find("User")  # => { "type" => "model", "namespace" => "Admin" }
      #
      class SQLite
        include Interface

        # @param db_path [String] Path to the SQLite database file, or ":memory:" for in-memory
        def initialize(db_path = ':memory:')
          begin
            require 'sqlite3'
          rescue LoadError
            raise Woods::ConfigurationError,
                  'metadata_store: :sqlite requires the sqlite3 gem in your Gemfile. ' \
                  "Add `gem 'sqlite3'` and re-bundle, or set " \
                  "`config.metadata_store = :in_memory` if you don't need cross-process persistence."
          end
          @db = ::SQLite3::Database.new(db_path)
          @db.results_as_hash = true
          create_table
        end

        # @see Interface#store
        def store(id, metadata)
          type = metadata[:type] || metadata['type']
          data = JSON.generate(metadata)

          @db.execute(<<~SQL, [id, type.to_s, data, Time.now.iso8601])
            INSERT INTO units (id, type, data, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              type = excluded.type, data = excluded.data, updated_at = excluded.updated_at
          SQL
        end

        # @see Interface#find
        def find(id)
          row = @db.get_first_row('SELECT data FROM units WHERE id = ?', [id])
          return nil unless row

          JSON.parse(row['data'])
        end

        # @see Interface#find_batch
        def find_batch(ids)
          return {} if ids.empty?

          placeholders = Array.new(ids.size, '?').join(', ')
          rows = @db.execute("SELECT id, data FROM units WHERE id IN (#{placeholders})", ids)
          rows.to_h do |row|
            [row['id'], JSON.parse(row['data'])]
          end
        end

        # @see Interface#find_by_type
        def find_by_type(type)
          rows = @db.execute('SELECT id, data FROM units WHERE type = ?', [type.to_s])
          rows.map { |row| parse_row(row) }
        end

        # @see Interface#search
        #
        # Field names are interpolated into a `json_extract` JSON-path
        # literal, so they are validated against {SEARCH_FIELD_NAME} first —
        # a crafted name could otherwise break out of the literal and alter
        # the SQL shape. LIKE metacharacters (`%`, `_`, `\`) in the query are
        # escaped (with an explicit ESCAPE clause) so they match literally,
        # aligning with the InMemory adapter's substring semantics instead of
        # silently broadening matches.
        #
        # @raise [ArgumentError] if a field name fails the whitelist
        def search(query, fields: nil)
          fields = validate_search_fields!(fields)
          pattern = "%#{escape_like(query)}%"
          if fields
            conditions = fields.map { "json_extract(data, '$.#{_1}') LIKE ? ESCAPE '\\'" }.join(' OR ')
            params = Array.new(fields.size, pattern)
            rows = @db.execute("SELECT id, data FROM units WHERE #{conditions}", params)
          else
            rows = @db.execute("SELECT id, data FROM units WHERE data LIKE ? ESCAPE '\\'", [pattern])
          end

          rows.map { |row| parse_row(row) }
        end

        # @see Interface#delete
        def delete(id)
          @db.execute('DELETE FROM units WHERE id = ?', [id])
        end

        # @see Interface#count
        def count
          @db.get_first_value('SELECT COUNT(*) FROM units')
        end

        private

        # Escape SQL LIKE metacharacters in a user query so they match
        # literally under the `ESCAPE '\'` clause {#search} emits. Without
        # this, `%` and `_` in a query act as wildcards and silently broaden
        # matches (`"user_name"` would match `"userXname"`).
        #
        # @param query [String] Raw search query
        # @return [String] Query safe for embedding in a LIKE pattern
        def escape_like(query)
          query.to_s.gsub(/[\\%_]/) { |ch| "\\#{ch}" }
        end

        # Parse a database row into a metadata hash with the id field injected.
        #
        # @param row [Hash] Database row with 'id' and 'data' keys
        # @return [Hash] Parsed metadata with 'id' key set
        def parse_row(row)
          parsed = JSON.parse(row['data'])
          parsed['id'] = row['id']
          parsed
        end

        # Create the units table if it doesn't exist.
        def create_table
          @db.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS units (
              id TEXT PRIMARY KEY,
              type TEXT,
              data JSON,
              updated_at TEXT
            )
          SQL
          @db.execute('CREATE INDEX IF NOT EXISTS idx_units_type ON units(type)')
        end
      end
    end
  end
end
