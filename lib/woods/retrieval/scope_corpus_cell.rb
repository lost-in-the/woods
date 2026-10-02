# frozen_string_literal: true

module Woods
  module Retrieval
    # One pipeline's scope corpus: built on the first scoped request, kept
    # for as long as its source is unchanged, and dropped with the pipeline
    # it belongs to (F6 step 2). The build runs under a mutex so concurrent
    # scoped requests share one read of the store instead of each making
    # their own; a build that raises keeps nothing, so the next request tries
    # again and sees the same error until the store is repaired.
    class ScopeCorpusCell
      # A corpus over an immutable source (the lexical pipeline's index):
      # built once, answered for the life of the cell.
      #
      # @yieldreturn [ScopeCorpus]
      # @return [ScopeCorpusCell]
      def self.pinned(&build)
        new(nil, &build)
      end

      # A corpus over a store that may change in place: kept while
      # {Storage::MetadataStore::Interface#snapshot_version} answers the
      # version the corpus was read at. A store that tracks no changes
      # (nil) gets no corpus at all; the caller reads the store per request.
      #
      # @param store [Storage::MetadataStore::Interface] the raw adapter
      # @yieldreturn [ScopeCorpus]
      # @return [ScopeCorpusCell]
      def self.versioned(store, &build)
        new(store, &build)
      end

      def initialize(store, &build)
        @store = store
        @build = build
        @mutex = Mutex.new
        @corpus = nil
      end

      # @return [ScopeCorpus, nil] nil when the store tracks no changes
      def current
        version = @store.nil? ? :pinned : store_version
        return nil if version.nil?

        @mutex.synchronize do
          @corpus = nil unless @corpus && (version == :pinned || @corpus.snapshot_version == version)
          @corpus ||= @build.call
        end
      end

      private

      def store_version
        @store.respond_to?(:snapshot_version) ? @store.snapshot_version : nil
      end
    end
  end
end
