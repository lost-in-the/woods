# frozen_string_literal: true

require_relative 'hydration'
require_relative 'index_reader'
require_relative '../retriever'
require_relative '../retrieval/lexical_token_cache'
require_relative '../storage/metadata_store'
require_relative '../storage_identity'

module Woods
  module MCP
    # Loads only authoritative published extraction units. The reader pin spans
    # snapshot construction AND the query, so a publication cannot mix units.
    # No provider, vector adapter, host source read, or context cache is involved.
    class PublishedLexicalRetriever
      # The store's own bookkeeping key: a unit's copy is never indexed.
      STORE_STAMP = 'updated_at'
      # Each unit file is parsed straight into deep-frozen JSON data, without
      # the store's stamp, which the lexical index, the metadata store and the
      # next generation's build then share without a copy.
      FROZEN_UNIT = lambda do |content|
        unit = JSON.parse(content, freeze: true)
        unit.key?(STORE_STAMP) ? unit.except(STORE_STAMP).freeze : unit
      end
      private_constant :FROZEN_UNIT, :STORE_STAMP

      # The decoded units of the generation last built, by unit file and
      # file identity ({IndexReader#each_unit}'s +reuse+). A build reads
      # through it and fills a table of its own, so a unit the new generation
      # no longer publishes is not kept.
      class UnitReuse
        attr_reader :table

        # @param previous [Hash, nil] the table of the build before
        def initialize(previous)
          @previous = previous || {}
          @table = {}
        end

        # @return [Hash, nil] the unit decoded from the same file identity before
        def fetch(key, identity)
          entry = @previous[key]
          return unless entry && entry.first == identity

          @table[key] = entry
          entry.last
        end

        def store(key, identity, unit)
          @table[key] = [identity, unit].freeze
        end
      end
      private_constant :UnitReuse

      attr_reader :reader, :snapshot, :default_budget

      # @param token_cache [Retrieval::LexicalTokenCache, nil] tokenized
      #   fields reused across generations; every retriever in the process
      #   shares one unless a caller passes its own
      def initialize(index_dir:, reader: nil, default_budget: 8000, token_cache: nil)
        @token_cache = token_cache || Retrieval::LexicalTokenCache.shared
        @default_budget = default_budget
        @index_dir = Pathname.new(index_dir)
        @reader = reader || IndexReader.new(index_dir)
        @snapshot_mutex = Mutex.new
        @snapshot = nil
        @reuse = nil
        @last_index = nil
        @last_retriever = nil
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

      def retrieve(query, budget: @default_budget, **options)
        validate_publication!
        reader.with_pinned_generation do
          retriever = snapshot_for_reader
          options[:evidence_generation] = reader.loaded_generation if options[:evidence] && options[:evidence] != 'full'
          result = retriever.retrieve(query, budget: budget, **options)
          result.sources.each { |source| source[:generation] = reader.loaded_generation }
          result
        end
      rescue Retriever::StoreError, Hydration::Warming
        raise
      rescue StandardError => e
        raise if e.is_a?(Woods::InvalidQueryError) || e.is_a?(ArgumentError)

        raise Retriever::StoreError, "lexical index read failed: #{e.class}: #{e.message}"
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

      # A call answered past the hydration wait cap ({Hydration.past_cap?})
      # never queues on the snapshot mutex: the thread holding it is building
      # the corpus (the background warm-up, or another request), and waiting
      # for that build is exactly the wait the cap bounds. It raises
      # {Hydration::Warming} instead, which `codebase_retrieve` answers as a
      # retryable "warming" result. A free mutex is taken as usual, so a
      # past-cap call that finds no build in progress still builds and answers.
      def snapshot_for_reader
        return @snapshot_mutex.synchronize { current_snapshot } unless Hydration.past_cap?

        raise Hydration::Warming, 'the lexical corpus is being built' unless @snapshot_mutex.try_lock

        begin
          current_snapshot
        ensure
          @snapshot_mutex.unlock
        end
      end

      # Callers hold `@snapshot_mutex`.
      def current_snapshot
        key = reader.generation_identity
        # Flat legacy indexes have no immutable generation identity. Rebuild
        # each time instead of serving changed files from a permanent cache.
        return @snapshot.last if key.first && @snapshot&.first == key

        units = {}
        # A unit file the generation before published under the same file
        # identity is the unit decoded then (a flat index has no generations
        # to carry it between, so it is read in full each time).
        reuse = UnitReuse.new(key.first && @reuse)
        reader.each_unit(decode: FROZEN_UNIT, reuse: reuse) do |unit|
          # The warm-up gives up its pins here when a reload or a refresh is
          # waiting for them (IndexReader#yielding_to_drains); nothing is
          # installed, and it rebuilds on the generation that follows.
          reader.yield_point!
          units[StorageIdentity.key(unit.fetch('identifier'), unit.fetch('type')).freeze] = unit
        end
        @reuse = reuse.table.freeze
        candidate = unchanged_snapshot(units) || build_snapshot(units)
        @snapshot = [key.freeze, candidate].freeze
        candidate
      end

      # Tokens and the documents of reused units may come from an earlier
      # generation's build; each unit's key and every statistic come from
      # this one.
      def build_snapshot(units)
        index = Retrieval::LexicalIndex.new(units: units, token_cache: @token_cache, reusable: @last_index)
        @last_index = index
        @last_retriever = Retriever.new(vector_store: nil, metadata_store: metadata_store_for(units), graph_store: nil,
                                        embedding_provider: nil, mode: :lexical, lexical_index: index)
      end

      # The retriever built last, when the new generation publishes exactly
      # the unit objects its index holds (a publication that changed no unit
      # file, or none the index reads) under the same lexical configuration:
      # nothing it holds would differ. It is that build's own retriever, not
      # whatever snapshot is installed now, which a reload may have replaced.
      # Its tokens are fetched from the cache all the same, so the cache
      # keeps them and counts the build as a reuse of every unit.
      #
      # @return [Retriever, nil]
      def unchanged_snapshot(units)
        previous = @last_index
        return unless previous && @last_retriever && previous.units.size == units.size &&
                      units.all? { |key, unit| previous.units[key].equal?(unit) }

        configuration = Retrieval::LexicalIndex.configuration_key
        return unless previous.configuration_key == configuration

        build = @token_cache.begin_build(configuration)
        previous.documents_by_key.each_value do |document|
          build.fetch(document.digest) { [document.fields, document.terms, document.lengths] }
        end
        @token_cache.commit(build)
        @last_retriever
      end

      # The public store holds the same frozen units. A write replaces a
      # record and never reaches the index; binding a reader discards it.
      def metadata_store_for(units)
        stamp = Time.now.iso8601
        Storage::MetadataStore::InMemory.new.tap do |store|
          store.bulk_load(units.map { |key, unit| [key, unit.merge(STORE_STAMP => stamp)] })
        end
      end
    end
  end
end
