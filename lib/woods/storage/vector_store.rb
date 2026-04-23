# frozen_string_literal: true

require 'set'

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

        # Iterate over every live entry, yielding `(id, vector, metadata)`.
        #
        # Persistence seam for Snapshotter and similar consumers. Default
        # implementation falls through to `NotImplementedError`; adapters
        # that need to support dumping must implement it. Persistent
        # backends (pgvector, Qdrant) aren't expected to implement this —
        # the Snapshotter only touches non-persistent stores.
        #
        # @yield [id, vector, metadata]
        # @return [Enumerator] when no block given
        def each_entry
          raise NotImplementedError
        end

        # Bulk-load pre-computed entries. Dual of {#each_entry} — the
        # Snapshotter hydrates a store by feeding this the dump contents.
        #
        # @param entries [Enumerable<Hash>] Each entry has :id, :vector, :metadata keys
        def bulk_load(entries)
          store_batch(entries.to_a)
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
      class InMemory # rubocop:disable Metrics/ClassLength
        include Interface

        # Flat-buffer backing. One Array<Float> of length count*dim holds
        # every vector contiguously; two parallel Arrays hold the ids and
        # metadata at matching positions. Deleted entries are tombstoned
        # (their index is added to @tombstones) rather than removed, so
        # stored vector positions stay stable under concurrent iteration
        # and dumps. Tombstones are compacted at next full-embed run.
        #
        # The flat buffer exists both for cache friendliness during the
        # cosine kernel (all vectors live in one contiguous allocation)
        # and to make dump/load via `pack("e*")` a single call rather
        # than a per-vector concatenation.
        def initialize
          @dim = nil
          @ids = [] # Array<String> (frozen)
          @vectors_flat = [] # flat Array<Float>, length @ids.size * @dim
          @metadata = []     # Array<Hash>, index-aligned with @ids
          @id_to_index = {}  # id => Integer for O(1) delete/overwrite
          @tombstones = Set.new
        end

        # @return [Integer, nil] dimension of stored vectors, nil if empty
        attr_reader :dim

        # @see Interface#store
        def store(id, vector, metadata = {})
          @dim ||= vector.length
          unless vector.length == @dim
            raise ArgumentError,
                  "Vector dimension mismatch (#{vector.length} vs #{@dim})"
          end

          frozen_id = id.frozen? ? id : id.dup.freeze
          existing = @id_to_index[frozen_id]
          if existing
            overwrite(existing, vector, metadata)
          else
            append(frozen_id, vector, metadata)
          end
        end

        # @see Interface#bulk_load
        # Single-pass hydrate — more efficient than N store calls when
        # the Snapshotter feeds a large dump at boot time.
        def bulk_load(entries)
          entries.each { |entry| store(entry[:id], entry[:vector], entry[:metadata] || {}) }
        end

        # @see Interface#each_entry
        def each_entry(&block)
          return enum_for(:each_entry) unless block

          @ids.each_with_index do |id, idx|
            next if @tombstones.include?(idx)

            base = idx * @dim
            yield(id, @vectors_flat[base, @dim], @metadata[idx])
          end
        end

        # @see Interface#search
        def search(query_vector, limit: 10, filters: {})
          return [] if @dim.nil?

          unless query_vector.length == @dim
            raise ArgumentError,
                  "Vector dimension mismatch (#{query_vector.length} vs #{@dim})"
          end

          scored = gather_candidates(query_vector, filters)
          scored.sort_by! { |r| -r.score }
          scored.first(limit)
        end

        # @see Interface#delete
        def delete(id)
          idx = @id_to_index.delete(id)
          @tombstones << idx if idx
        end

        # @see Interface#delete_by_filter
        def delete_by_filter(filters)
          @ids.each_with_index do |id, idx|
            next if @tombstones.include?(idx)
            next unless filters.all? { |key, value| @metadata[idx][key] == value }

            @tombstones << idx
            @id_to_index.delete(id)
          end
        end

        # @see Interface#count
        def count
          @ids.size - @tombstones.size
        end

        private

        # Append a new entry to the flat buffer.
        def append(id, vector, metadata)
          idx = @ids.size
          @ids << id
          @vectors_flat.concat(vector)
          @metadata << metadata
          @id_to_index[id] = idx
        end

        # Overwrite an existing entry in place. Tombstones the old slot's
        # deletion marker (if any) so the new vector is live again.
        def overwrite(idx, vector, metadata)
          base = idx * @dim
          i = 0
          while i < @dim
            @vectors_flat[base + i] = vector[i]
            i += 1
          end
          @metadata[idx] = metadata
          @tombstones.delete(idx)
        end

        # Walk every non-tombstoned index, apply filters, score survivors.
        # Filter check runs BEFORE the cosine kernel — avoids computing
        # 12k dot products only to discard most of them.
        def gather_candidates(query_vector, filters)
          scored = []
          len = @ids.size
          idx = 0
          while idx < len
            if @tombstones.include?(idx)
              idx += 1
              next
            end
            meta = @metadata[idx]
            unless filters.empty? || filters.all? { |k, v| meta[k] == v }
              idx += 1
              next
            end

            score = cosine_similarity_strided(query_vector, idx * @dim)
            scored << SearchResult.new(id: @ids[idx], score: score, metadata: meta)
            idx += 1
          end
          scored
        end

        # Cosine similarity between a query Array<Float> and a vector
        # that lives at @vectors_flat[base, @dim]. Strided access avoids
        # allocating a copy of the stored vector on every comparison.
        #
        # See bench/vector_query_and_serialization.rb for the allocation
        # story — the old Enumerable path allocated ~770 objects per pair;
        # this loop allocates none inside the hot path.
        def cosine_similarity_strided(query, base)
          len = @dim
          i = 0
          dot = 0.0
          mag_a = 0.0
          mag_b = 0.0
          while i < len
            a = query[i]
            b = @vectors_flat[base + i]
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
