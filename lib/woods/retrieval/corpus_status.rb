# frozen_string_literal: true

module Woods
  module Retrieval
    # Bounded, local diagnostics: never probe remote stores or providers.
    # Nonempty counts establish presence, not alignment, completeness, or
    # provider health. Metadata-only corpora can still serve non-vector paths.
    module CorpusStatus
      module_function

      # @return [Hash] state and independently known local store statistics
      def build(vector_store, metadata_store, include_types: true)
        vectors = local_stats(vector_store, include_types: include_types)
        metadata = local_stats(metadata_store, include_types: include_types)
        { state: state(vectors[:count], metadata[:count]), vectors: vectors, metadata: metadata }
      end

      def local_stats(store, include_types:)
        return unknown unless store.respond_to?(:local_corpus_stats)

        stats = store.local_corpus_stats(include_types: include_types)
        return unknown unless stats[:count].is_a?(Integer) && stats[:count] >= 0

        stats
      rescue StandardError, NotImplementedError
        unknown
      end
      private_class_method :local_stats

      def unknown
        { count: nil, by_type: nil, untyped_count: nil }
      end
      private_class_method :unknown

      def state(vectors, metadata)
        return 'unknown' if vectors.nil? || metadata.nil?
        return 'empty' if vectors.zero? && metadata.zero?
        return 'metadata_only' if vectors.zero?
        return 'vectors_only' if metadata.zero?

        'nonempty'
      end
      private_class_method :state
    end
  end
end
