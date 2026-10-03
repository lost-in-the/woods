# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'scope_error'
require_relative '../source_contributors'
require_relative '../storage/metadata_store'
require_relative '../storage/search_text'

module Woods
  module Retrieval
    # One read of a metadata store, shared by every scope resolved against
    # it (F6 step 2). A scope used to read and validate every record per
    # request; the corpus does that once per store snapshot and keeps, per
    # record, the facts eligibility needs (type, owners, physical paths)
    # plus, when asked, an immutable copy of the record so a {View} over the
    # eligible keys can answer the scoped pipeline's metadata reads without
    # another copy per request.
    #
    # The corpus never reads the store again after construction, so it is
    # valid exactly as long as the store's content is: callers keep it only
    # while {Storage::MetadataStore::Interface#snapshot_version} agrees, or
    # for one pinned published generation.
    class ScopeCorpus
      # What a scope knows about one record. +owners+ is one entry per
      # physical source (the declared package, or each contributor's), and
      # +record+ is nil for a facts-only corpus.
      Fact = Struct.new(:key, :record, :type, :owners, :paths, keyword_init: true)

      # How records are retained: an immutable copy of each, the records as
      # given (already immutable, e.g. a lexical index's units), or not at all.
      RECORD_MODES = %i[copy share none].freeze

      # @return [Array<String>] every key, sorted
      attr_reader :keys

      # @return [Integer, nil] the store version the corpus was read at
      attr_reader :snapshot_version

      # @return [Set<String>] every package name the records declare, own or
      #   contribute, for the unknown-package check
      attr_reader :package_names

      # Read every record of +store+ once, in key order.
      #
      # @param store [Storage::MetadataStore::Interface]
      # @param records [Symbol] one of {RECORD_MODES}
      # @return [ScopeCorpus]
      # @raise [Scope::InvalidScopeError] for a key without a record
      def self.from_store(store, records: :copy)
        version = store.respond_to?(:snapshot_version) ? store.snapshot_version : nil
        pairs = store.all_identifiers.sort.map { |key| [key, store.find(key)] }
        new(pairs, records: records, snapshot_version: version)
      end

      # Share records that are already immutable, without copying them.
      #
      # @param units [Enumerable<Array(String, Hash)>, Hash{String => Hash}]
      # @param snapshot_version [Integer, nil]
      # @return [ScopeCorpus]
      def self.from_units(units, snapshot_version: nil)
        new(units, records: :share, snapshot_version: snapshot_version)
      end

      # @param pairs [Enumerable<Array(String, Hash)>] key and record
      # @param records [Symbol] one of {RECORD_MODES}
      # @param snapshot_version [Integer, nil]
      def initialize(pairs, records: :copy, snapshot_version: nil)
        raise ArgumentError, "records must be one of #{RECORD_MODES.inspect}" unless RECORD_MODES.include?(records)

        @records = records
        @snapshot_version = snapshot_version
        packages = Set.new
        facts = {}
        pairs.each do |key, record|
          raise Scope::InvalidScopeError, "duplicate scoped unit #{key.inspect}" if facts.key?(key)
          raise Scope::InvalidScopeError, "missing metadata for scoped unit #{key.inspect}" unless record.is_a?(Hash)

          facts[key] = build_fact(key, record, packages)
        end
        @keys = facts.keys.sort.freeze
        @facts = @keys.to_h { |key| [key, facts.fetch(key)] }.freeze
        @package_names = packages.freeze
        @haystacks = {}
        @haystack_mutex = Mutex.new
      end

      # @param key [String]
      # @return [Fact, nil]
      def fact(key)
        @facts[key]
      end

      # @yield [Fact] every fact, in key order
      def each_fact(&block)
        @facts.each_value(&block)
      end

      # @return [Boolean] whether records were retained
      def records?
        @records != :none
      end

      # A read-only metadata store over +keys+, every one of which this
      # corpus must hold.
      #
      # @param keys [Enumerable<String>]
      # @return [View]
      # @raise [Scope::InvalidScopeError] when records were not retained or a
      #   key is foreign to the corpus
      def view(keys)
        raise Scope::InvalidScopeError, 'scope corpus holds no records' unless records?

        facts = keys.map(&:to_s).uniq.sort.map do |key|
          @facts[key] || raise(Scope::InvalidScopeError, "missing metadata for scoped unit #{key.inspect}")
        end
        View.new(self, facts)
      end

      # The whole-record search haystacks of +facts+, built on first use and
      # shared by every view (a search over a broad scope used to serialise
      # each eligible record per request).
      #
      # @param facts [Array<Fact>]
      # @return [Array<String>] aligned with +facts+
      def haystacks(facts)
        @haystack_mutex.synchronize do
          facts.map { |fact| @haystacks[fact.key] ||= Storage::SearchText.record(fact.record) }
        end
      end

      private

      def build_fact(key, record, packages)
        contributors = SourceContributors.records(record)
        type = field(record, 'type')
        identifier = field(record, 'identifier')
        declared = field(field(record, 'metadata'), 'package')
        packages << identifier if type == 'package' && identifier
        packages << declared if declared
        owners = contributors.empty? ? [declared] : contributors.map { |contributor| contributor['package'] }
        packages.merge(owners.compact) unless contributors.empty?
        paths = contributors.empty? ? Array(field(record, 'file_path')) : contributors.map { |c| c.fetch('file_path') }
        Fact.new(key: key, record: retain(record), type: type, owners: owners.freeze, paths: paths.freeze).freeze
      end

      def field(hash, name)
        return nil unless hash.is_a?(Hash)

        hash.key?(name) ? hash[name] : hash[name.to_sym]
      end

      def retain(record)
        case @records
        when :copy then deep_freeze(JSON.parse(JSON.generate(record)))
        when :share then record
        end
      end

      def deep_freeze(value)
        case value
        when Hash then value.each do |key, child|
          key.freeze
          deep_freeze(child)
        end
        when Array then value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end

      # A read-only {Storage::MetadataStore::Interface} over the eligible
      # facts of one corpus. Answers exactly what the per-request in-memory
      # copy of the eligible records answered: records without bookkeeping,
      # +'id'+ merged onto search and type listings, insertion order equal to
      # key order. Writes raise; the capability probes a reload makes
      # (+clear!+, +bulk_load+) find nothing here.
      class View
        include Storage::MetadataStore::Interface

        # @param corpus [ScopeCorpus]
        # @param facts [Array<Fact>] in key order
        def initialize(corpus, facts)
          @corpus = corpus
          @facts = facts.freeze
          @by_key = facts.to_h { |fact| [fact.key, fact] }.freeze
        end

        # @see Storage::MetadataStore::Interface#snapshot_version
        def snapshot_version
          @corpus.snapshot_version
        end

        # @see Storage::MetadataStore::Interface#find
        # @return [Hash, nil] a record whose top level the caller may extend
        def find(id)
          @by_key[id]&.record&.dup
        end

        # @see Storage::MetadataStore::Interface#find_batch
        def find_batch(ids)
          ids.each_with_object({}) do |id, result|
            data = find(id)
            result[id] = data if data
          end
        end

        # @see Storage::MetadataStore::Interface#find_by_type
        def find_by_type(type)
          target = type.to_s
          @facts.filter_map { |fact| fact.record.merge('id' => fact.key) if fact.type.to_s == target }
        end

        # @see Storage::MetadataStore::Interface#search
        # @raise [ArgumentError] if a field name fails {Storage::MetadataStore::SEARCH_FIELD_NAME}
        def search(query, fields: nil)
          fields = validate_search_fields!(fields)
          return [] if fields == []

          needle = query.to_s.downcase
          haystacks = fields ? nil : @corpus.haystacks(@facts)
          @facts.each_with_index.filter_map do |fact, index|
            next unless fields ? field_match?(fact.record, fields, needle) : haystacks[index].include?(needle)

            fact.record.merge('id' => fact.key)
          end
        end

        # @see Storage::MetadataStore::Interface#all_identifiers
        def all_identifiers
          @facts.map(&:key)
        end

        # @see Storage::MetadataStore::Interface#count
        def count
          @facts.size
        end

        # @see Storage::MetadataStore::InMemory#local_corpus_stats
        def local_corpus_stats(include_types: true)
          return { count: count, by_type: nil, untyped_count: nil } unless include_types

          Storage::LocalCorpusStats.from_types(@facts.map { |fact| fact.record['type'] })
        end

        # @see Storage::MetadataStore::Interface#store
        # @raise [FrozenError] always
        def store(_id, _metadata)
          raise FrozenError, 'scope view is read-only'
        end

        # @see Storage::MetadataStore::Interface#delete
        # @raise [FrozenError] always
        def delete(_id)
          raise FrozenError, 'scope view is read-only'
        end

        private

        def field_match?(record, fields, needle)
          fields.any? { |field| Storage::SearchText.field(record[field])&.downcase&.include?(needle) }
        end
      end
    end
  end
end
