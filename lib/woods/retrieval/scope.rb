# frozen_string_literal: true

require 'json'
require 'set'
require_relative '../storage_identity'
require_relative '../source_contributors'
require_relative '../storage/metadata_store'

module Woods
  module Retrieval
    # Resolves explicit scope from published metadata, never host filesystem
    # paths. Ownership is exact; path prefixes match complete directory segments.
    # Every eligible unit is selected before any search strategy applies a limit.
    class Scope
      class InvalidScopeError < ArgumentError; end

      attr_reader :packages, :source_paths, :keys, :metadata_store

      def self.requested?(packages: nil, source_paths: nil)
        [packages, source_paths].any? { |list| !list.nil? && list != [] }
      end

      def initialize(metadata_store:, packages: nil, source_paths: nil, types: nil, exclude_types: nil)
        @packages = normalize_list(packages, 'packages').freeze
        @source_paths = normalize_list(source_paths, 'source_paths').map do |path|
          normalize_path(path)
        end.uniq.sort.freeze
        facts = metadata_store.all_identifiers.sort.map { |key| read_facts(metadata_store, key) }
        validate_packages!(facts)
        @metadata_store = Storage::MetadataStore::InMemory.new
        facts.each do |fact|
          next unless eligible?(fact, types, exclude_types)

          @metadata_store.store(fact[:key], fact[:record])
        end
        @keys = @metadata_store.all_identifiers.sort.freeze
        @key_set = @keys.to_set.freeze
      end

      def include?(key)
        @key_set.include?(key.to_s.sub(/#chunk_\d+\z/, ''))
      end

      def summary
        { packages: packages, source_paths: source_paths, eligible_units: keys.size }
      end

      private

      # One read and one contributor validation per record (F6 step 1). The
      # record is taken as the store returned it: the scope's own store makes
      # the single copy it keeps, and every read below accepts string or
      # symbol keys, so the JSON round trip that used to normalise and copy
      # each record first is gone, as is validating the contributor records
      # once for the package check and twice more for eligibility.
      #
      # @return [Hash] +key+, +record+, validated +contributors+, physical +paths+
      def read_facts(metadata_store, key)
        record = metadata_store.find(key)
        raise InvalidScopeError, "missing metadata for scoped unit #{key.inspect}" unless record.is_a?(Hash)

        contributors = SourceContributors.records(record)
        paths = if contributors.empty?
                  Array(field(record, 'file_path'))
                else
                  contributors.map { |contributor| contributor.fetch('file_path') }
                end
        { key: key, record: record, contributors: contributors, paths: paths }
      end

      def field(hash, name)
        return nil unless hash.is_a?(Hash)

        hash.key?(name) ? hash[name] : hash[name.to_sym]
      end

      def declared_package(record)
        field(field(record, 'metadata'), 'package')
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

      def validate_packages!(facts)
        names = facts.filter_map do |fact|
          field(fact[:record], 'identifier') if field(fact[:record], 'type') == 'package'
        end
        names.concat(facts.filter_map { |fact| declared_package(fact[:record]) })
        names.concat(facts.flat_map { |fact| fact[:contributors].filter_map { |record| record['package'] } })
        unknown = packages - names
        raise InvalidScopeError, "unknown package scope: #{unknown.join(', ')}" unless unknown.empty?
      end

      def eligible?(fact, types, excluded)
        unit = fact[:record]
        owners = if fact[:contributors].empty?
                   [declared_package(unit)]
                 else
                   fact[:contributors].map { |record| record['package'] }
                 end
        return false unless packages.empty? || owners.all? { |owner| packages.include?(owner) }

        paths = fact[:paths]
        return false unless source_paths.empty? || (paths.any? && paths.all? { |path| path_match?(path) })

        type = field(unit, 'type')
        return Array(types).map(&:to_s).include?(type) if types && !types.empty?

        !Array(excluded).map(&:to_s).include?(type)
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
