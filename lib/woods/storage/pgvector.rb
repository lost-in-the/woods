# frozen_string_literal: true

require 'json'
require_relative 'vector_store'

module Woods
  # Same conditional-define pattern used elsewhere in the gem so this
  # file can be required in isolation (e.g. by specs that bypass the
  # full lib/woods.rb load) without tripping NameError on the
  # dimension-mismatch and batch-conflict raises below.
  class Error < StandardError; end unless defined?(Woods::Error)

  module Storage
    module VectorStore
      # PostgreSQL + pgvector adapter for vector storage and similarity search.
      #
      # Uses the pgvector extension for efficient approximate nearest neighbor
      # search with HNSW indexing. Stores metadata as JSONB for flexible filtering.
      #
      # @example
      #   store = Pgvector.new(connection: ActiveRecord::Base.connection, dimensions: 768)
      #   store.ensure_schema!
      #   store.store("User", [0.1, 0.2, ...], { type: "model" })
      #   results = store.search([0.1, 0.2, ...], limit: 5, filters: { type: "model" })
      #
      class Pgvector # rubocop:disable Metrics/ClassLength
        include Interface

        TABLE = 'woods_vectors'
        TABLE_NAME_PATTERN = /\A[a-z_][a-z0-9_]*\z/

        attr_reader :table, :schema, :dimensions

        # @param connection [Object] ActiveRecord database connection
        # @param dimensions [Integer] Size of the embedding vectors
        # @param table [String] PostgreSQL table name
        def initialize(connection:, dimensions:, table: TABLE, schema: nil)
          @connection = connection
          @dimensions = normalize_dimensions(dimensions)
          @table = table.to_s
          @schema = schema&.to_s
          validate_identifier!(:table, @table, table)
          validate_identifier!(:schema, @schema, schema) if @schema
        end

        # Create the pgvector extension, vectors table, and HNSW index.
        #
        # Safe to call multiple times (uses IF NOT EXISTS).
        def ensure_schema!
          @connection.transaction do
            @connection.execute('CREATE EXTENSION IF NOT EXISTS vector')
            @connection.execute(<<~SQL)
              CREATE TABLE IF NOT EXISTS #{qualified_table} (
                id TEXT PRIMARY KEY,
                embedding vector(#{@dimensions}),
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
              )
            SQL
            @connection.execute(<<~SQL)
              CREATE INDEX IF NOT EXISTS idx_#{@table}_embedding_hnsw
              ON #{qualified_table} USING hnsw (embedding vector_cosine_ops)
            SQL
          end
        end

        # Store or update a vector with metadata.
        #
        # @param id [String] Unique identifier
        # @param vector [Array<Float>] The embedding vector
        # @param metadata [Hash] Optional metadata
        # @see Interface#store
        def store(id, vector, metadata = {})
          validate_vector!(vector)
          validate_dimensions!(vector) if @dimensions
          entry = format_entry(id, vector, metadata)

          @connection.execute(<<~SQL)
            INSERT INTO #{qualified_table} (id, embedding, metadata, created_at)
            VALUES #{entry}
            ON CONFLICT (id) DO UPDATE SET
              embedding = EXCLUDED.embedding,
              metadata = EXCLUDED.metadata,
              created_at = CURRENT_TIMESTAMP
          SQL
        end

        # Store multiple vectors in a single multi-row INSERT.
        #
        # Duplicate ids within one batch are collapsed to the LAST occurrence
        # (upsert semantics) before the statement is built — a multi-row
        # `INSERT ... ON CONFLICT (id) DO UPDATE` cannot touch the same row
        # twice, and PostgreSQL's `PG::CardinalityViolation` names no id and
        # lands after earlier batches have already been written (#181).
        #
        # @param entries [Array<Hash>] Each entry has :id, :vector, :metadata keys
        # @raise [ArgumentError] if any entry has a non-numeric or wrong-dimension vector.
        #   Validation runs BEFORE any INSERT so partial-batch writes can't occur.
        # @raise [Woods::Error] if PostgreSQL still reports a cardinality or
        #   uniqueness violation — re-raised naming every id in the batch.
        def store_batch(entries)
          return if entries.empty?

          # Pre-validate every vector before any SQL — prevents partial-batch
          # state when a later entry's dimension doesn't match.
          entries.each_with_index do |entry, idx|
            vector = entry[:vector]
            validate_vector!(vector)
            validate_dimensions!(vector, index: idx) if @dimensions
          end

          entries = deduplicate_entries(entries)
          values = entries.map { |entry| format_entry(entry[:id], entry[:vector], entry[:metadata] || {}) }

          execute_upsert(<<~SQL, entries)
            INSERT INTO #{qualified_table} (id, embedding, metadata, created_at)
            VALUES #{values.join(",\n")}
            ON CONFLICT (id) DO UPDATE SET
              embedding = EXCLUDED.embedding,
              metadata = EXCLUDED.metadata,
              created_at = CURRENT_TIMESTAMP
          SQL
        end

        # Search for similar vectors using cosine distance.
        #
        # The query vector is dimension-checked before SQL runs, mirroring the
        # upsert path: otherwise a wrong-dimension query surfaces as a
        # server-side PG::DataException instead of the typed Woods::Error
        # callers already handle from {#store_batch}.
        #
        # @param query_vector [Array<Float>] The query embedding
        # @param limit [Integer] Maximum results to return
        # @param filters [Hash] Metadata key-value filters
        # @return [Array<SearchResult>] Results sorted by descending similarity
        # @raise [Woods::Error] if the query vector's length disagrees with the
        #   configured dimension
        # @see Interface#search
        def search(query_vector, limit: 10, filters: {})
          validate_vector!(query_vector)
          validate_dimensions!(query_vector) if @dimensions
          vector_literal = build_vector_literal(query_vector)
          where_clause = build_where(filters)

          sql = <<~SQL
            SELECT id, embedding <=> '#{vector_literal}' AS distance, metadata
            FROM #{qualified_table}
            #{where_clause}
            ORDER BY distance ASC
            LIMIT #{limit.to_i}
          SQL

          rows = @connection.execute(sql)
          rows.map { |row| row_to_result(row) }
        end

        # The vector width the table was actually created with.
        #
        # `ensure_schema!` is `CREATE TABLE IF NOT EXISTS`, so a table built by
        # an earlier run at a different width is left exactly as it was — and
        # the mismatch only surfaces later, as a PG::DataException on the first
        # insert ("expected 384 dimensions, not 768"), after the run has already
        # paid to embed everything. Reading it back lets the pipeline refuse up
        # front with a re-index remedy (#214).
        #
        # For pgvector's `vector` type, `atttypmod` carries the dimension
        # directly (unlike varchar, which offsets it).
        #
        # @return [Integer, nil] the column's dimension, or nil when the table
        #   does not exist yet or the width cannot be determined
        def stored_dimensions
          rows = @connection.execute(<<~SQL)
            SELECT a.atttypmod AS dimension
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = #{@connection.quote(@table)}
              AND n.nspname = #{schema_sql}
              AND a.attname = 'embedding' AND a.attnum > 0
          SQL
          row = rows.first
          return nil unless row

          dimension = row['dimension'].to_i
          dimension.positive? ? dimension : nil
        end

        # Iterate over every stored id without loading vectors.
        #
        # One `SELECT id` — the embed pipeline uses this to reconcile the
        # durable store against the units extraction still holds, and paying
        # for the vector columns to answer a question about ids would be
        # pointless IO.
        #
        # @see Interface#each_id
        def each_id(&block)
          return enum_for(:each_id) unless block

          rows = @connection.execute("SELECT id FROM #{qualified_table}")
          rows.each { |row| yield(row['id']) }
        end

        # @see Interface#delete
        def delete(id)
          quoted_id = @connection.quote(id)
          @connection.execute("DELETE FROM #{qualified_table} WHERE id = #{quoted_id}")
        end

        # @see Interface#delete_by_filter
        def delete_by_filter(filters)
          where_clause = build_where(filters)
          @connection.execute("DELETE FROM #{qualified_table} #{where_clause}")
        end

        # @see Interface#count
        def count
          result = @connection.execute("SELECT COUNT(*) AS count FROM #{qualified_table}")
          result.first['count'].to_i
        end

        private

        def normalize_dimensions(value)
          return value if value.is_a?(Integer) && value.positive?

          raise ArgumentError, 'dimensions must be a positive Integer'
        end

        def validate_identifier!(name, value, original)
          return if TABLE_NAME_PATTERN.match?(value)

          raise ArgumentError, "#{name} must be a PostgreSQL identifier, got #{original.inspect}"
        end

        def quote_identifier(value)
          @connection.respond_to?(:quote_table_name) ? @connection.quote_table_name(value) : value
        end

        def qualified_table
          [@schema, @table].compact.map { |part| quote_identifier(part) }.join('.')
        end

        def schema_sql
          @schema ? @connection.quote(@schema) : 'current_schema()'
        end

        # Collapse duplicate ids within a batch, keeping the LAST occurrence
        # of each id (upsert semantics — the final write wins). Duplicates
        # signal an upstream problem (cross-type identifier twins, orphaned
        # files re-embedding one unit twice), so dropped ids are logged
        # rather than silently discarded.
        #
        # @param entries [Array<Hash>] Batch entries with :id keys
        # @return [Array<Hash>] Entries with at most one row per id, original
        #   order preserved
        def deduplicate_entries(entries)
          deduped = entries.reverse.uniq { |entry| entry[:id] }.reverse
          return entries if deduped.length == entries.length

          duplicated = entries.group_by { |entry| entry[:id] }
                              .select { |_, occurrences| occurrences.length > 1 }
                              .keys
          warn '[Woods::Storage::Pgvector] store_batch received duplicate ids ' \
               "(keeping the last occurrence of each): #{duplicated.join(', ')}"
          deduped
        end

        # Execute the multi-row upsert, converting a cardinality/uniqueness
        # violation that still escapes the in-batch dedup into a
        # {Woods::Error} naming every id in the batch — the raw PostgreSQL
        # error names no id, which makes a partially-landed embed (earlier
        # batches already committed) very hard to diagnose.
        #
        # @param sql [String] The INSERT ... ON CONFLICT statement
        # @param entries [Array<Hash>] The batch, used for the error message
        # @raise [Woods::Error] on a cardinality or uniqueness violation
        def execute_upsert(sql, entries)
          @connection.execute(sql)
        rescue StandardError => e
          raise unless conflict_violation?(e)

          ids = entries.map { |entry| entry[:id] }
          raise Woods::Error,
                "pgvector batch upsert hit a duplicate-row conflict (#{e.class}: #{e.message.strip}). " \
                "Batch ids: #{ids.join(', ')}"
        end

        # Duck-typed detection of PostgreSQL cardinality/uniqueness
        # violations. The gem does not depend on the pg gem, and the error
        # usually arrives wrapped in ActiveRecord::StatementInvalid, so match
        # on class name and message across the error and its cause.
        #
        # @param error [StandardError]
        # @return [Boolean]
        def conflict_violation?(error)
          [error, error.cause].compact.any? do |err|
            err.class.name.to_s.match?(/CardinalityViolation|UniqueViolation/) ||
              err.message.to_s.match?(/cannot affect row a second time|duplicate key value/)
          end
        end

        # Format a single entry as a SQL VALUES tuple.
        #
        # @param id [String] Unique identifier
        # @param vector [Array<Float>] Embedding vector
        # @param metadata [Hash] Entry metadata
        # @return [String] SQL values row literal
        def format_entry(id, vector, metadata)
          quoted_id = @connection.quote(id)
          quoted_metadata = @connection.quote(JSON.generate(metadata))
          vector_literal = build_vector_literal(vector)
          "(#{quoted_id}, '#{vector_literal}', #{quoted_metadata}::jsonb, CURRENT_TIMESTAMP)"
        end

        # Build the `[x,y,z]` pgvector literal from a validated numeric vector.
        # Coerces each element through `Float()` first — `Float#to_s` is
        # guaranteed to produce only digits, `.`, `-`, and `e`, which closes
        # the theoretical `Numeric`-subclass `#to_s` injection vector even
        # though {#validate_vector!} already rejects non-Numeric inputs.
        # `Float()` raises `RangeError` on `Complex` values with an imaginary
        # part — we surface that as an `ArgumentError` so callers see the
        # same error shape as the other vector-validation paths instead of
        # the raw coercion error.
        def build_vector_literal(vector)
          coerced = vector.each_with_index.map do |element, i|
            Float(element).to_s
          rescue RangeError, TypeError, ArgumentError => e
            raise ArgumentError,
                  "Vector element at index #{i} cannot be coerced to Float: #{element.inspect} (#{e.class})"
          end
          "[#{coerced.join(',')}]"
        end

        # Convert a database row to a SearchResult.
        #
        # @param row [Hash] Database row with id, distance, metadata
        # @return [SearchResult]
        def row_to_result(row)
          metadata = row['metadata']
          parsed_metadata = metadata.is_a?(String) ? JSON.parse(metadata) : metadata
          SearchResult.new(
            id: row['id'],
            score: 1.0 - row['distance'].to_f,
            metadata: parsed_metadata
          )
        end

        # Build a WHERE clause from metadata filters.
        #
        # @param filters [Hash] Metadata key-value pairs
        # @return [String] SQL WHERE clause, or empty string if no filters
        def build_where(filters)
          return '' if filters.empty?

          conditions = filters.map do |key, value|
            key_s = key.to_s
            unless key_s.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
              raise ArgumentError, "Invalid filter key: #{key_s.inspect}"
            end

            # Belt-and-suspenders: regex above already rejects any value that
            # could alter the SQL shape, but we still pass the key through
            # `@connection.quote` so the quoting story is uniform across the
            # key and value positions and a future regex-relaxation does not
            # silently unlock injection.
            if value.is_a?(Array)
              # Membership filter. An empty Array would produce `IN ()`
              # which is a syntax error; emit an always-false predicate
              # so the query still parses and returns no rows.
              next 'FALSE' if value.empty?

              quoted = value.map { |v| @connection.quote(v.to_s) }.join(', ')
              "metadata->>#{@connection.quote(key_s)} IN (#{quoted})"
            else
              "metadata->>#{@connection.quote(key_s)} = #{@connection.quote(value.to_s)}"
            end
          end
          "WHERE #{conditions.join(' AND ')}"
        end

        # Validate that all vector elements are numeric and finite.
        # Rejecting NaN / Infinity also closes a defense-in-depth gap
        # around the vector-literal SQL construction — `Float::NAN.to_s`
        # yields `"NaN"` which pgvector rejects, but other float-like
        # sentinels can leak through string construction unexpectedly.
        #
        # @param vector [Array] The vector to validate
        # @raise [ArgumentError] if any element is not numeric or is non-finite
        def validate_vector!(vector)
          vector.each_with_index do |element, i|
            unless element.is_a?(Numeric)
              raise ArgumentError, "Vector element at index #{i} is not numeric: #{element.inspect}"
            end
            if element.is_a?(Float) && !element.finite?
              raise ArgumentError, "Vector element at index #{i} is not finite: #{element.inspect}"
            end
          end
        end

        # Assert the provided vector matches the store's configured dimension.
        #
        # @param vector [Array<Numeric>]
        # @param index [Integer, nil] position in the batch, used in the error message
        # @raise [Woods::Error] on dimension mismatch
        def validate_dimensions!(vector, index: nil)
          return if vector.length == @dimensions

          where = index ? " (entry #{index})" : ''
          raise Woods::Error,
                "Vector dimension mismatch#{where}: got #{vector.length}, expected #{@dimensions}"
        end
      end
    end
  end
end
