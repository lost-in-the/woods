# frozen_string_literal: true

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
        results = ids.each_slice(BATCH_SIZE).flat_map do |batch|
          @store.search(query_vector, limit: limit, filters: filters, ids: batch).each do |result|
            next if batch.include?(result.id)

            raise Scope::InvalidScopeError, 'vector adapter returned an ID outside the requested scope'
          end
        end
        results.sort_by { |result| [-result.score, result.id] }.first(limit)
      rescue NotImplementedError
        raise Scope::InvalidScopeError, 'vector adapter cannot enumerate IDs for complete scoped search'
      end

      private

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
