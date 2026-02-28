# frozen_string_literal: true

require 'json'
require_relative 'vector_store'

module CodebaseIndex
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

        TABLE = 'codebase_index_vectors'

        # @param connection [Object] ActiveRecord database connection
        # @param dimensions [Integer] Size of the embedding vectors
        def initialize(connection:, dimensions:)
          @connection = connection
          @dimensions = dimensions
        end

        # Create the pgvector extension, vectors table, and HNSW index.
        #
        # Safe to call multiple times (uses IF NOT EXISTS).
        def ensure_schema!
          @connection.execute('CREATE EXTENSION IF NOT EXISTS vector')
          @connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS #{TABLE} (
              id TEXT PRIMARY KEY,
              embedding vector(#{@dimensions}),
              metadata JSONB DEFAULT '{}',
              created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
          SQL
          @connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_#{TABLE}_embedding_hnsw
            ON #{TABLE} USING hnsw (embedding vector_cosine_ops)
          SQL
        end

        # Store or update a vector with metadata.
        #
        # @param id [String] Unique identifier
        # @param vector [Array<Float>] The embedding vector
        # @param metadata [Hash] Optional metadata
        # @see Interface#store
        def store(id, vector, metadata = {})
          validate_vector!(vector)
          quoted_id = @connection.quote(id)
          quoted_metadata = @connection.quote(JSON.generate(metadata))
          vector_literal = "[#{vector.join(',')}]"

          @connection.execute(<<~SQL)
            INSERT INTO #{TABLE} (id, embedding, metadata, created_at)
            VALUES (#{quoted_id}, '#{vector_literal}', #{quoted_metadata}::jsonb, CURRENT_TIMESTAMP)
            ON CONFLICT (id) DO UPDATE SET
              embedding = EXCLUDED.embedding,
              metadata = EXCLUDED.metadata,
              created_at = CURRENT_TIMESTAMP
          SQL
        end

        # Store multiple vectors in a single multi-row INSERT.
        #
        # @param entries [Array<Hash>] Each entry has :id, :vector, :metadata keys
        def store_batch(entries)
          return if entries.empty?

          values = entries.map do |entry|
            validate_vector!(entry[:vector])
            quoted_id = @connection.quote(entry[:id])
            quoted_metadata = @connection.quote(JSON.generate(entry[:metadata] || {}))
            vector_literal = "[#{entry[:vector].join(',')}]"
            "(#{quoted_id}, '#{vector_literal}', #{quoted_metadata}::jsonb, CURRENT_TIMESTAMP)"
          end

          @connection.execute(<<~SQL)
            INSERT INTO #{TABLE} (id, embedding, metadata, created_at)
            VALUES #{values.join(",\n")}
            ON CONFLICT (id) DO UPDATE SET
              embedding = EXCLUDED.embedding,
              metadata = EXCLUDED.metadata,
              created_at = CURRENT_TIMESTAMP
          SQL
        end

        # Search for similar vectors using cosine distance.
        #
        # @param query_vector [Array<Float>] The query embedding
        # @param limit [Integer] Maximum results to return
        # @param filters [Hash] Metadata key-value filters
        # @return [Array<SearchResult>] Results sorted by descending similarity
        # @see Interface#search
        def search(query_vector, limit: 10, filters: {})
          validate_vector!(query_vector)
          vector_literal = "[#{query_vector.join(',')}]"
          where_clause = build_where(filters)

          sql = <<~SQL
            SELECT id, embedding <=> '#{vector_literal}' AS distance, metadata
            FROM #{TABLE}
            #{where_clause}
            ORDER BY distance ASC
            LIMIT #{limit.to_i}
          SQL

          rows = @connection.execute(sql)
          rows.map { |row| row_to_result(row) }
        end

        # @see Interface#delete
        def delete(id)
          quoted_id = @connection.quote(id)
          @connection.execute("DELETE FROM #{TABLE} WHERE id = #{quoted_id}")
        end

        # @see Interface#delete_by_filter
        def delete_by_filter(filters)
          where_clause = build_where(filters)
          @connection.execute("DELETE FROM #{TABLE} #{where_clause}")
        end

        # @see Interface#count
        def count
          result = @connection.execute("SELECT COUNT(*) AS count FROM #{TABLE}")
          result.first['count'].to_i
        end

        private

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

            "metadata->>'#{key_s}' = #{@connection.quote(value.to_s)}"
          end
          "WHERE #{conditions.join(' AND ')}"
        end

        # Validate that all vector elements are numeric.
        #
        # @param vector [Array] The vector to validate
        # @raise [ArgumentError] if any element is not numeric
        def validate_vector!(vector)
          vector.each_with_index do |element, i|
            unless element.is_a?(Numeric)
              raise ArgumentError, "Vector element at index #{i} is not numeric: #{element.inspect}"
            end
          end
        end
      end
    end
  end
end
