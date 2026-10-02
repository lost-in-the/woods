# frozen_string_literal: true

require 'set'
require_relative 'scope_error'
require_relative 'scope_corpus'
require_relative '../storage/metadata_store'

module Woods
  module Retrieval
    # Resolves explicit scope from published metadata, never host filesystem
    # paths. Ownership is exact; path prefixes match complete directory segments.
    # Every eligible unit is selected before any search strategy applies a limit.
    #
    # A scope resolves from one of two sources: a metadata store, read once
    # here (F6 step 1), with the eligible records copied into the scope's own
    # in-memory store; or a {ScopeCorpus}, an earlier read of such a store
    # shared across requests (F6 step 2), from which the scope's store is a
    # read-only view and nothing is read or copied per request.
    class Scope
      attr_reader :packages, :source_paths, :keys

      def self.requested?(packages: nil, source_paths: nil)
        [packages, source_paths].any? { |list| !list.nil? && list != [] }
      end

      # @param metadata_store [Storage::MetadataStore::Interface, nil] the
      #   store to read, exclusive with +corpus+
      # @param corpus [ScopeCorpus, nil] an existing read of the store
      # @raise [ArgumentError] unless exactly one source is given
      # @raise [InvalidScopeError] for a malformed list, an escaping path, an
      #   unknown package, or a record the store lists but cannot find
      def initialize(metadata_store: nil, corpus: nil, packages: nil, source_paths: nil, types: nil,
                     exclude_types: nil)
        raise ArgumentError, 'give exactly one of metadata_store: or corpus:' if metadata_store.nil? == corpus.nil?

        @packages = normalize_list(packages, 'packages').freeze
        @source_paths = normalize_list(source_paths, 'source_paths').map do |path|
          normalize_path(path)
        end.uniq.sort.freeze
        @corpus = corpus || ScopeCorpus.from_store(metadata_store, records: :share)
        validate_packages!
        @keys = select_keys(types, exclude_types)
        @key_set = @keys.to_set.freeze
        @metadata_store = copy_eligible_records if corpus.nil?
      end

      # The eligible records as a metadata store: the scope's own in-memory
      # copy for the store form, a read-only view of the corpus otherwise.
      #
      # @return [Storage::MetadataStore::Interface]
      # @raise [InvalidScopeError] for a corpus that kept no records
      def metadata_store
        @metadata_store ||= @corpus.view(@keys)
      end

      def include?(key)
        @key_set.include?(key.to_s.sub(/#chunk_\d+\z/, ''))
      end

      def summary
        { packages: packages, source_paths: source_paths, eligible_units: keys.size }
      end

      private

      def select_keys(types, excluded)
        allowed = Array(types).map(&:to_s)
        excluded = Array(excluded).map(&:to_s)
        keys = []
        @corpus.each_fact { |fact| keys << fact.key if eligible?(fact, allowed, excluded) }
        keys.freeze
      end

      # The store form keeps the one copy it needs: the scope's own store
      # copies each eligible record as the store returned it (F6 step 1).
      def copy_eligible_records
        store = Storage::MetadataStore::InMemory.new
        @keys.each { |key| store.store(key, @corpus.fact(key).record) }
        store
      end

      def normalize_list(list, name)
        return [] if list.nil?
        unless list.is_a?(Array) && list.all? { |value| value.is_a?(String) && !value.empty? && !value.include?("\0") }
          raise InvalidScopeError, "#{name} must be an array of nonempty strings"
        end

        list.uniq.sort.map { |value| value.dup.freeze }
      end

      def normalize_path(path)
        if path.start_with?('/') || path.match?(/\A[A-Za-z]:/) || path.include?('\\')
          raise InvalidScopeError, "source path must be application-relative: #{path.inspect}"
        end

        segments = []
        path.split('/').each do |part|
          next if part.empty? || part == '.'

          if part == '..'
            raise InvalidScopeError, "source path escapes application root: #{path.inspect}" if segments.empty?

            segments.pop
          else
            segments << part
          end
        end
        (segments.empty? ? '.' : segments.join('/')).freeze
      end

      def validate_packages!
        unknown = packages.reject { |name| @corpus.package_names.include?(name) }
        raise InvalidScopeError, "unknown package scope: #{unknown.join(', ')}" unless unknown.empty?
      end

      def eligible?(fact, allowed, excluded)
        return false unless packages.empty? || fact.owners.all? { |owner| packages.include?(owner) }

        paths = fact.paths
        return false unless source_paths.empty? || (paths.any? && paths.all? { |path| path_match?(path) })

        return allowed.include?(fact.type) unless allowed.empty?

        !excluded.include?(fact.type)
      end

      def path_match?(path)
        return false unless path.is_a?(String) && !path.empty? && !path.include?("\0")

        normalized = normalize_path(path)
        source_paths.any? { |prefix| prefix == '.' || normalized == prefix || normalized.start_with?("#{prefix}/") }
      rescue InvalidScopeError
        false
      end
    end
  end
end
