# frozen_string_literal: true

require 'set'

module Woods
  module Retrieval
    # Complete, bounded native searches across eligible raw vector IDs. Raw IDs
    # preserve typed/chunk identity without requiring a new vector payload or an
    # embedding migration. One outer executor embeds the query once.
    class ScopedVectorStore
      BATCH_SIZE = 100

      def initialize(store:, scope:)
        @store = store
        @scope = scope
      end

      def search(query_vector, limit: 10, filters: {})
        unless @store.respond_to?(:supports_id_filter?) && @store.supports_id_filter?
          raise Scope::InvalidScopeError, 'vector adapter does not support complete ID-scoped search'
        end

        ids = @store.each_id.select { |id| eligible_id?(id, filters) }.uniq.sort
        # Type eligibility comes from authoritative unit metadata, including for
        # legacy vectors without a type payload. Other payload filters stay native.
        filters = filters.reject { |key, _| key.to_s == 'type' }
        best = []
        ids.each_slice(batch_size_for(ids.size)) do |batch|
          # Fetch every bounded batch member before our raw-ID tie-break. A
          # backend may order equal scores differently (or use SQL collation).
          results = @store.search(query_vector, limit: batch.size, filters: filters, ids: batch)
          # A Set, not Array#include?: with one unbounded batch the membership
          # check is otherwise quadratic in the scope size, and a partial
          # selection keeps the tie-break without sorting every candidate.
          allowed = batch.to_set
          results.each do |result|
            next if allowed.include?(result.id)

            raise Scope::InvalidScopeError, 'vector adapter returned an ID outside the requested scope'
          end
          best = (best + results).min_by(limit) { |result| [-result.score, result.id] }
        end
        best
      rescue NotImplementedError
        raise Scope::InvalidScopeError, 'vector adapter cannot enumerate IDs for complete scoped search'
      end

      private

      # The adapter's own bound on ids per call (N-ip-1): nil means one call
      # carries every eligible id; an adapter that says nothing keeps the
      # historical bound.
      #
      # @return [Integer] at least 1
      def batch_size_for(count)
        size = @store.respond_to?(:id_filter_batch_size) ? @store.id_filter_batch_size : BATCH_SIZE
        [size || count, 1].max
      end

      def eligible_id?(id, filters)
        return false unless @scope.include?(id)

        types = filters[:type] || filters['type']
        return true unless types

        record = @scope.metadata_store.find(id.sub(/#chunk_\d+\z/, ''))
        Array(types).map(&:to_s).include?(record['type'])
      end
    end
  end
end
