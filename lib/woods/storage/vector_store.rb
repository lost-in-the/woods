# frozen_string_literal: true

module Woods
  module Storage
    # VectorStore provides an interface for storing and searching embedding vectors.
    #
    # All vector store adapters must include the {Interface} module and implement
    # its methods. The {InMemory} adapter is provided for development and testing.
    #
    # @example Using the in-memory adapter
    #   store = Woods::Storage::VectorStore::InMemory.new
    #   store.store("User", [0.1, 0.2, 0.3], { type: "model" })
    #   results = store.search([0.1, 0.2, 0.3], limit: 5)
    #
    module VectorStore
      # Interface that all vector store adapters must implement.
      module Interface
        # Store a vector with associated metadata.
        #
        # @param id [String] Unique identifier for the vector
        # @param vector [Array<Float>] The embedding vector
        # @param metadata [Hash] Optional metadata to store alongside the vector
        # @raise [NotImplementedError] if not implemented by adapter
        def store(id, vector, metadata = {})
          raise NotImplementedError
        end

        # Store multiple vectors in a single batch operation.
        #
        # Default implementation falls back to individual store calls.
        # Adapters should override for bulk-optimized behavior (e.g.,
        # multi-row INSERT for pgvector, batch upsert for Qdrant).
        #
        # @param entries [Array<Hash>] Each entry has :id, :vector, :metadata keys
        def store_batch(entries)
          entries.each { |e| store(e[:id], e[:vector], e[:metadata] || {}) }
        end

        # Search for similar vectors using cosine similarity.
        #
        # @param query_vector [Array<Float>] The query embedding vector
        # @param limit [Integer] Maximum number of results to return
        # @param filters [Hash] Optional metadata filters to apply
        # @return [Array<SearchResult>] Results sorted by descending similarity
        # @raise [NotImplementedError] if not implemented by adapter
        def search(query_vector, limit: 10, filters: {})
          raise NotImplementedError
        end

        # Delete a vector by ID.
        #
        # @param id [String] The identifier to delete
        # @raise [NotImplementedError] if not implemented by adapter
        def delete(id)
          raise NotImplementedError
        end

        # Delete vectors matching metadata filters.
        #
        # @param filters [Hash] Metadata key-value pairs to match
        # @raise [NotImplementedError] if not implemented by adapter
        def delete_by_filter(filters)
          raise NotImplementedError
        end

        # Return the number of stored vectors.
        #
        # @return [Integer] Total count
        # @raise [NotImplementedError] if not implemented by adapter
        def count
          raise NotImplementedError
        end
      end

      # Value object representing a single search result.
      SearchResult = Struct.new(:id, :score, :metadata, keyword_init: true)

      # In-memory vector store using hash storage and cosine similarity.
      #
      # Suitable for development and testing. Not intended for production use
      # with large datasets.
      #
      # @example
      #   store = InMemory.new
      #   store.store("doc1", [1.0, 0.0], { type: "model" })
      #   store.store("doc2", [0.0, 1.0], { type: "service" })
      #   store.search([1.0, 0.0], limit: 1)
      #   # => [#<SearchResult id="doc1", score=1.0, metadata={type: "model"}>]
      #
      class InMemory
        include Interface

        def initialize
          @entries = {} # id => { vector:, metadata: }
        end

        # @see Interface#store
        def store(id, vector, metadata = {})
          @entries[id] = { vector: vector, metadata: metadata }
        end

        # @see Interface#search
        def search(query_vector, limit: 10, filters: {})
          candidates = filter_entries(filters)

          scored = candidates.map do |id, entry|
            score = cosine_similarity(query_vector, entry[:vector])
            SearchResult.new(id: id, score: score, metadata: entry[:metadata])
          end
          scored.sort_by { |r| -r.score }.first(limit)
        end

        # @see Interface#delete
        def delete(id)
          @entries.delete(id)
        end

        # @see Interface#delete_by_filter
        def delete_by_filter(filters)
          @entries.reject! do |_id, entry|
            filters.all? { |key, value| entry[:metadata][key] == value }
          end
        end

        # @see Interface#count
        def count
          @entries.size
        end

        private

        # Filter entries by metadata key-value pairs.
        #
        # @param filters [Hash] Metadata filters
        # @return [Hash] Filtered entries
        def filter_entries(filters)
          return @entries if filters.empty?

          @entries.select do |_id, entry|
            filters.all? { |key, value| entry[:metadata][key] == value }
          end
        end

        # Compute cosine similarity between two vectors.
        #
        # Uses a single-pass while loop over Array indices rather than
        # Enumerable methods. The previous `vec_a.zip(vec_b).sum { |x, y|
        # x * y }` allocated a 768-element Array-of-2-element-Arrays plus
        # a block invocation per pair — about 770 transient objects per
        # call, ~9.8M allocations per 12 k-entry search, enough to wake
        # the minor GC every second query. The while loop produces zero
        # per-pair allocations. See bench/vector_query_and_serialization.rb.
        #
        # Flonums (MRI 2.0+) mean intermediate Float arithmetic is heap-free
        # for doubles whose exponent fits in 62 bits, which embedding
        # vectors always satisfy.
        #
        # @param vec_a [Array<Float>] First vector
        # @param vec_b [Array<Float>] Second vector
        # @return [Float] Cosine similarity between -1.0 and 1.0
        # @raise [ArgumentError] if vectors have different dimensions
        def cosine_similarity(vec_a, vec_b)
          len = vec_a.length
          raise ArgumentError, "Vector dimension mismatch (#{len} vs #{vec_b.length})" unless len == vec_b.length

          i = 0
          dot = 0.0
          mag_a = 0.0
          mag_b = 0.0
          while i < len
            a = vec_a[i]
            b = vec_b[i]
            dot += a * b
            mag_a += a * a
            mag_b += b * b
            i += 1
          end

          return 0.0 if mag_a.zero? || mag_b.zero?

          dot / (Math.sqrt(mag_a) * Math.sqrt(mag_b))
        end
      end
    end
  end
end
