# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'template_extensions'
require_relative 'cache_call_arguments'

module Woods
  module Extractors
    # CachingExtractor detects caching usage across controllers, models, and views.
    #
    # Scans `app/controllers/**/*.rb`, `app/models/**/*.rb`, and every
    # {TemplateExtensions::SCANNED} view template (`app/views/**/*.erb`,
    # `*.haml`, `*.jbuilder`) for cache-related patterns: Rails.cache.*,
    # caches_action, fragment cache blocks (including jbuilder `cache!`),
    # cache_key, cache_version, and expires_in. Produces one unit per file that contains any
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

      # `[file_type, glob]` pairs to scan, one plain glob per view engine.
      # PathDispatcher derives its caching file rules from these, reading
      # each glob's suffix as a file extension, so a brace glob would break
      # incremental dispatch.
      SCAN_PATTERNS = [
        [:controller, 'app/controllers/**/*.rb'],
        [:model, 'app/models/**/*.rb'],
        *TemplateExtensions::SCANNED.map { |ext| [:view, "app/views/**/*#{ext}"] }
      ].freeze

      # Patterns that indicate cache usage, grouped by type
      CACHE_PATTERNS = {
        fetch: /Rails\.cache\.fetch\s*[(\[]/,
        read: /Rails\.cache\.read\s*[(\[]/,
        write: /Rails\.cache\.write\s*[(\[]/,
        delete: /Rails\.cache\.delete\s*[(\[]/,
        exist: /Rails\.cache\.exist\?\s*[(\[]/,
        caches_action: /\bcaches_action\b/,
        fragment: /\bcache(?:_if|_unless)?\s+.*?\bdo\b|\bcache(?:_if|_unless)?\s*\(|\bjson\.cache(?:_if)?!/,
        # Key methods stay last: a bare one inside the arguments of a call
        # matched above is skipped (see #extract_cache_calls).
        cache_key: /\bcache_key(?:_with_version)?\b/,
        cache_version: /\bcache_version\b/
      }.freeze

      # Call types whose first argument (after the condition, for
      # `cache_if`) is a cache key.
      KEYED_TYPES = %i[fetch read write delete exist fragment].freeze

      # Call types whose arguments are read at all. `cache_key` and
      # `cache_version` are key methods, not calls that take cache options.
      ARGUMENT_TYPES = (KEYED_TYPES + %i[caches_action]).freeze

      # Cache key methods, counted as calls unless they are a bare
      # identifier passed to another cache call.
      KEY_METHOD_TYPES = %i[cache_key cache_version].freeze

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
        SourceInputs::ConsumerErrors.log(self, "Failed to extract caching info from #{file_path}: #{e.message}")
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
      # Each entry has :type, :key_pattern, :ttl, and :options, read from
      # that occurrence's own arguments by {CacheCallArguments} — never from
      # the whole file, so a call without its own `expires_in:` gets a nil
      # ttl rather than a neighbor's. :key_pattern is the key expression's
      # source text; :options holds the literal-valued cache options.
      #
      # A key method named bare inside another cache call's arguments
      # (`json.cache! cache_key do`) is that call's key, usually a local,
      # so it is not counted. A receiver call (`record.cache_key`) there,
      # or an implicit-self call anywhere else, still counts.
      #
      # @param source [String] Source code
      # @return [Array<Hash>] Cache call descriptors
      def extract_cache_calls(source)
        calls = []
        argument_ranges = []

        CACHE_PATTERNS.each do |type, pattern|
          each_occurrence(source, pattern) do |offset|
            next if KEY_METHOD_TYPES.include?(type) && bare_cache_argument?(source, offset, argument_ranges)

            arguments = call_arguments(source, offset, type)
            range = arguments.delete(:argument_range)
            argument_ranges << range if range
            calls << { type: type }.merge(arguments)
          end
        end

        calls
      end

      # Whether a key method occurrence is a bare identifier (no receiver)
      # inside the arguments of a cache call already read.
      #
      # @param source [String] Source code
      # @param offset [Integer] Character offset of the key method name
      # @param argument_ranges [Array<Range>] Argument ranges of cache calls
      # @return [Boolean]
      def bare_cache_argument?(source, offset, argument_ranges)
        return false if offset.positive? && source[offset - 1] == '.'

        argument_ranges.any? { |range| range.cover?(offset) }
      end

      # Yield the start offset of every non-overlapping occurrence of a pattern.
      #
      # @param source [String] Source code
      # @param pattern [Regexp] Pattern to scan for
      # @yieldparam offset [Integer] Character offset where the occurrence begins
      # @return [void]
      def each_occurrence(source, pattern)
        offset = 0
        while (match = source.match(pattern, offset))
          yield match.begin(0)
          offset = [match.end(0), match.begin(0) + 1].max
        end
      end

      # Key, ttl, and literal options for one cache call occurrence.
      #
      # @param source [String] Source code
      # @param offset [Integer] Character offset where the occurrence begins
      # @param type [Symbol] The cache call type
      # @return [Hash] :key_pattern, :ttl, :options, and :argument_range
      def call_arguments(source, offset, type)
        return { key_pattern: nil, ttl: nil, options: {}, argument_range: nil } unless ARGUMENT_TYPES.include?(type)

        arguments = CacheCallArguments.read(source, offset)
        KEYED_TYPES.include?(type) ? arguments : arguments.merge(key_pattern: nil)
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
