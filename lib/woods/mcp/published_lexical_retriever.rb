# frozen_string_literal: true

require_relative 'index_reader'
require_relative '../retriever'
require_relative '../storage/metadata_store'
require_relative '../storage_identity'

module Woods
  module MCP
    # Loads only authoritative published extraction units. The reader pin spans
    # snapshot construction AND the query, so a publication cannot mix units.
    # No provider, vector adapter, host source read, or context cache is involved.
    class PublishedLexicalRetriever
      attr_reader :reader, :snapshot

      def initialize(index_dir:, reader: nil)
        @index_dir = Pathname.new(index_dir)
        @reader = reader || IndexReader.new(index_dir)
        @snapshot_mutex = Mutex.new
        @snapshot = nil
      end

      def mode = :lexical
      def vector_store = nil
      def graph_store = nil
      def metadata_store = @snapshot&.last&.metadata_store

      # Server uses one reader for status, tool pinning and lexical retrieval.
      # Called only during server construction, before request threads start.
      def bind_reader(reader)
        @reader = reader
        @snapshot = nil
        self
      end

      def warmup!
        validate_publication!
        reader.with_pinned_generation { snapshot_for_reader }
        self
      end

      def retrieve(query, budget: 8000, **options)
        validate_publication!
        reader.with_pinned_generation do
          retriever = snapshot_for_reader
          options[:evidence_generation] = reader.loaded_generation if options[:evidence] && options[:evidence] != 'full'
          result = retriever.retrieve(query, budget: budget, **options)
          result.sources.each { |source| source[:generation] = reader.loaded_generation }
          result
        end
      rescue Retriever::StoreError
        raise
      rescue StandardError => e
        raise if e.is_a?(Woods::InvalidQueryError) || e.is_a?(ArgumentError)

        raise Retriever::StoreError, "lexical index read failed: #{e.class}: #{e.message}"
      end

      # Explicit invalidation is used by reload after its candidate has been
      # validated. Ordinary generation changes rebuild lazily under the pin.
      def invalidate_snapshot!
        @snapshot_mutex.synchronize { @snapshot = nil }
      end

      def install_snapshot!(snapshot)
        @snapshot_mutex.synchronize { @snapshot = snapshot }
      end

      private

      def validate_publication!
        path = @index_dir.join(Generation::FILENAME)
        unless path.exist?
          raise IOError, 'published generation marker disappeared' if reader.loaded_generation

          return
        end
        data = JSON.parse(AtomicFile.read(path))
        unless data.is_a?(Hash) && data['number'].is_a?(Integer) && data['number'].positive?
          raise IOError, 'invalid published generation marker'
        end
        return if data['payload'].nil?

        payload = data['payload']
        unless payload.is_a?(String) && !payload.empty? && !Pathname.new(payload).absolute?
          raise IOError, 'invalid generation payload pointer'
        end

        directory = @index_dir.join(payload)
        return if directory.directory? && directory.realpath.to_s.start_with?("#{@index_dir.realpath}/")

        raise IOError, 'missing or escaping generation payload'
      end

      def snapshot_for_reader
        @snapshot_mutex.synchronize do
          key = reader.generation_identity
          # Flat legacy indexes have no immutable generation identity. Rebuild
          # each time instead of serving changed files from a permanent cache.
          return @snapshot.last if key.first && @snapshot&.first == key

          metadata = Storage::MetadataStore::InMemory.new
          reader.each_unit do |unit|
            metadata.store(StorageIdentity.key(unit.fetch('identifier'), unit.fetch('type')), unit)
          end
          candidate = Retriever.new(vector_store: nil, metadata_store: metadata, graph_store: nil,
                                    embedding_provider: nil, mode: :lexical)
          @snapshot = [key.freeze, candidate].freeze
          candidate
        end
      end
    end
  end
end
