# frozen_string_literal: true

require 'json'
require 'set'
require_relative '../storage_identity'
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
        records = metadata_store.all_identifiers.sort.to_h do |key|
          record = metadata_store.find(key)
          raise InvalidScopeError, "missing metadata for scoped unit #{key.inspect}" unless record.is_a?(Hash)

          [key, JSON.parse(JSON.generate(record))]
        end
        validate_packages!(records.values)
        @metadata_store = Storage::MetadataStore::InMemory.new
        records.each do |key, record|
          next unless eligible?(record, types, exclude_types)

          @metadata_store.store(key, record)
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

      def validate_packages!(records)
        names = records.filter_map { |unit| unit['identifier'] if unit['type'] == 'package' }
        names.concat(records.filter_map { |unit| unit.dig('metadata', 'package') })
        unknown = packages - names
        raise InvalidScopeError, "unknown package scope: #{unknown.join(', ')}" unless unknown.empty?
      end

      def eligible?(unit, types, excluded)
        return false unless packages.empty? || packages.include?(unit.dig('metadata', 'package'))
        return false unless source_paths.empty? || path_match?(unit['file_path'])
        return Array(types).map(&:to_s).include?(unit['type']) if types && !types.empty?

        !Array(excluded).map(&:to_s).include?(unit['type'])
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
