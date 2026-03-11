# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # CachingExtractor detects caching usage across controllers, models, and views.
    #
    # Scans `app/controllers/**/*.rb`, `app/models/**/*.rb`, and
    # `app/views/**/*.erb` for cache-related patterns: Rails.cache.*,
    # caches_action, fragment cache blocks, cache_key, cache_version,
    # and expires_in. Produces one unit per file that contains any
    # cache calls, identifying the strategy and TTL patterns.
    #
    # @example
    #   extractor = CachingExtractor.new
    #   units = extractor.extract_all
    #   ctrl = units.find { |u| u.identifier == "app/controllers/products_controller.rb" }
    #   ctrl.metadata[:cache_strategy]  # => :low_level
    #   ctrl.metadata[:cache_calls].size # => 3
    #
    class CachingExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # File glob patterns to scan
      SCAN_PATTERNS = {
        controller: 'app/controllers/**/*.rb',
        model: 'app/models/**/*.rb',
        view: 'app/views/**/*.erb'
      }.freeze

      # Patterns that indicate cache usage, grouped by type
      CACHE_PATTERNS = {
        fetch: /Rails\.cache\.fetch\s*[(\[]/,
        read: /Rails\.cache\.read\s*[(\[]/,
        write: /Rails\.cache\.write\s*[(\[]/,
        delete: /Rails\.cache\.delete\s*[(\[]/,
        exist: /Rails\.cache\.exist\?\s*[(\[]/,
        caches_action: /\bcaches_action\b/,
        fragment: /\bcache\s+.*?\bdo\b|\bcache\s+do\b|\bcache\s*\(/,
        cache_key: /\bcache_key\b/,
        cache_version: /\bcache_version\b/
      }.freeze

      # Patterns for extracting TTL values
      TTL_PATTERN = /expires_in:\s*([^,\n)]+)/

      # Key-pattern regex (first argument to Rails.cache.*)
      KEY_PATTERN = /Rails\.cache\.(?:fetch|read|write|delete|exist\?)\s*[(\[]?\s*([^,\n)\]]+)/

      def initialize
        @rails_root = Rails.root
      end

      # Extract caching units from all scanned files.
      #
      # @return [Array<ExtractedUnit>] One unit per file with cache calls
      def extract_all
        units = []

        SCAN_PATTERNS.each do |file_type, pattern|
          Dir[@rails_root.join(pattern)].each do |file|
            unit = extract_caching_file(file, file_type)
            units << unit if unit
          end
        end

        units
      end

      # Extract a single file for caching patterns.
      #
      # Returns nil if the file contains no cache calls.
      #
      # @param file_path [String] Absolute path to the file
      # @param file_type [Symbol] :controller, :model, or :view
      # @return [ExtractedUnit, nil] The unit or nil if no cache usage
      def extract_caching_file(file_path, file_type = nil)
        source = File.read(file_path)

        return nil unless cache_usage?(source)

        file_type ||= infer_file_type(file_path)
        identifier = relative_path(file_path)

        unit = ExtractedUnit.new(
          type: :caching,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace   = nil
        unit.source_code = annotate_source(source, identifier, file_type)
        unit.metadata    = extract_metadata(source, file_type)
        unit.dependencies = extract_dependencies(source)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract caching info from #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Detection
      # ──────────────────────────────────────────────────────────────────────

      # Check whether the source contains any cache calls.
      #
      # @param source [String] Ruby or ERB source
      # @return [Boolean]
      def cache_usage?(source)
        CACHE_PATTERNS.values.any? { |pattern| source.match?(pattern) }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # Prepend a summary annotation header to the source.
      #
      # @param source [String] Source code
      # @param identifier [String] Relative file path identifier
      # @param file_type [Symbol] :controller, :model, or :view
      # @return [String] Annotated source
      def annotate_source(source, identifier, file_type)
        annotation = <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Caching: #{identifier.ljust(59)}║
          # ║ File type: #{file_type.to_s.ljust(57)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

        ANNOTATION

        annotation + source
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build the metadata hash for a caching unit.
      #
      # @param source [String] Source code
      # @param file_type [Symbol] :controller, :model, or :view
      # @return [Hash] Caching metadata
      def extract_metadata(source, file_type)
        cache_calls = extract_cache_calls(source)
        {
          cache_calls: cache_calls,
          cache_strategy: infer_cache_strategy(source, cache_calls),
          file_type: file_type,
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') }
        }
      end

      # Extract individual cache call entries from source.
      #
      # Each entry has :type, :key_pattern, and :ttl.
      #
      # @param source [String] Source code
      # @return [Array<Hash>] Cache call descriptors
      def extract_cache_calls(source)
        calls = []

        CACHE_PATTERNS.each do |type, pattern|
          source.scan(pattern) do
            key = extract_key_pattern(source, type)
            ttl = extract_ttl(source)
            calls << { type: type, key_pattern: key, ttl: ttl }
          end
        end

        calls
      end

      # Extract the key pattern for a Rails.cache call.
      #
      # Returns a simplified string representation of the first argument.
      #
      # @param source [String] Source code
      # @param type [Symbol] The cache call type
      # @return [String, nil] The key pattern or nil
      def extract_key_pattern(source, type)
        return nil unless %i[fetch read write delete exist].include?(type)

        match = source.match(KEY_PATTERN)
        match ? match[1].strip[0, 60] : nil
      end

      # Extract TTL value from expires_in option.
      #
      # @param source [String] Source code
      # @return [String, nil] The TTL expression or nil
      def extract_ttl(source)
        match = source.match(TTL_PATTERN)
        match ? match[1].strip : nil
      end

      # Infer the caching strategy from the call types present.
      #
      # @param source [String] Source code
      # @param cache_calls [Array<Hash>] Extracted cache calls
      # @return [Symbol] :fragment, :action, :low_level, or :mixed
      def infer_cache_strategy(source, _cache_calls)
        has_action    = source.match?(CACHE_PATTERNS[:caches_action])
        has_fragment  = source.match?(CACHE_PATTERNS[:fragment])
        has_low_level = source.match?(/Rails\.cache\.(?:fetch|read|write)/)

        active_strategies = [has_action, has_fragment, has_low_level].count(true)

        return :mixed if active_strategies > 1
        return :action if has_action
        return :fragment if has_fragment
        return :low_level if has_low_level

        :unknown
      end

      # ──────────────────────────────────────────────────────────────────────
      # Helpers
      # ──────────────────────────────────────────────────────────────────────

      # Infer the file type from the file path.
      #
      # @param file_path [String] Absolute path to the file
      # @return [Symbol] :controller, :model, or :view
      def infer_file_type(file_path)
        case file_path
        when %r{app/controllers/} then :controller
        when %r{app/models/}      then :model
        when %r{app/views/}       then :view
        else :unknown
        end
      end

      # Compute the relative path from Rails root.
      #
      # @param file_path [String] Absolute path
      # @return [String] Relative path (e.g., "app/controllers/products_controller.rb")
      def relative_path(file_path)
        file_path.sub("#{@rails_root}/", '')
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build the dependency array by scanning source for common references.
      #
      # @param source [String] Source code
      # @return [Array<Hash>] Dependency hashes with :type, :target, :via
      def extract_dependencies(source)
        scan_common_dependencies(source)
      end
    end
  end
end
