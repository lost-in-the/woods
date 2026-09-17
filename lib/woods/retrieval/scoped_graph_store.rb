# frozen_string_literal: true

module Woods
  module Retrieval
    # Expansion remains inside caller eligibility. Graphs retain their existing
    # bare-identifier ambiguity: the executor resolves eligible typed variants.
    class ScopedGraphStore
      def initialize(store:, scope:)
        @store = store
        @identifiers = scope.keys.to_set { |key| StorageIdentity.identifier(key) }
      end

      def dependencies_of(identifier)
        return [] unless @store && @identifiers.include?(identifier)

        @store.dependencies_of(identifier).select { |target| @identifiers.include?(target) }
      end

      def dependents_of(identifier)
        return [] unless @store && @identifiers.include?(identifier)

        @store.dependents_of(identifier).select { |target| @identifiers.include?(target) }
      end

      def pagerank
        return {} unless @store

        @store.pagerank.slice(*@identifiers)
      end
    end
  end
end
