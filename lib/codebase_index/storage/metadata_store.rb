# frozen_string_literal: true

require 'json'

module CodebaseIndex
  module Storage
    # MetadataStore provides an interface for storing and querying unit metadata.
    #
    # All metadata store adapters must include the {Interface} module and implement
    # its methods. The {SQLite} adapter is provided for local persistence.
    #
    # @example Using the SQLite adapter
    #   store = CodebaseIndex::Storage::MetadataStore::SQLite.new(":memory:")
    #   store.store("User", { type: "model", file_path: "app/models/user.rb" })
    #   store.find("User")
    #
    module MetadataStore
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
          require 'sqlite3'
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
          rows.map do |row|
            parsed = JSON.parse(row['data'])
            parsed['id'] = row['id']
            parsed
          end
        end

        # @see Interface#search
        def search(query, fields: nil)
          if fields
            conditions = fields.map { "json_extract(data, '$.#{_1}') LIKE ?" }.join(' OR ')
            params = fields.map { "%#{query}%" }
            rows = @db.execute("SELECT id, data FROM units WHERE #{conditions}", params)
          else
            rows = @db.execute('SELECT id, data FROM units WHERE data LIKE ?', ["%#{query}%"])
          end

          rows.map do |row|
            parsed = JSON.parse(row['data'])
            parsed['id'] = row['id']
            parsed
          end
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
