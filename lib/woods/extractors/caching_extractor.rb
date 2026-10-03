# frozen_string_literal: true

require 'strscan'

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'template_extensions'
require_relative 'cache_call_arguments'
require_relative 'comment_blanking'

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
        # The scan for `do` reads tokens: a backslash pair, a quoted string,
        # or one other character, stopping at a `cache` token outside a
        # string. A string is one token, so `cache [x, "cache me"] do`
        # matches at the outer call. It stays linear: every token moves each
        # scan's quote state (outside, in "", in '') by the same one-to-one
        # map, so scans started at different `cache` tokens never share a
        # state, and at most three scans cover any character. That is why a
        # backslash pair is a token outside strings too: an escape honored
        # only inside a string merges states. An unbounded `.*?` rescanned
        # the rest of the line from every `cache` (polynomial on Ruby < 3.2).
        fragment: /\bcache(?:_if|_unless)?\s++(?:\\.|"(?:[^"\\\n]|\\.)*+"|'(?:[^'\\\n]|\\.)*+'|(?!\bcache(?:_if|_unless)?\s)[^\n"'\\])*?\bdo\b|\bcache(?:_if|_unless)?\s*+\(|\bjson\.cache(?:_if)?!/,
        # A bare key method inside the arguments of a call matched above is
        # skipped (see #extract_cache_calls).
        cache_key: /\bcache_key(?:_with_version)?\b/,
        cache_version: /\bcache_version\b/
      }.freeze

      # Call types whose first argument (after the condition, for
      # `cache_if`) is a cache key.
      KEYED_TYPES = %i[fetch read write delete exist fragment].freeze

      # Byte value of `.`, the receiver separator before a key method.
      DOT = '.'.ord

      # Cache key methods: no arguments read, and counted unless they are a
      # bare identifier passed to another cache call.
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
        # Cache calls are read from the code only: commented-out calls never run.
        code = CommentBlanking.blank(source, file_path)

        return nil unless cache_usage?(code)

        file_type ||= infer_file_type(file_path)
        identifier = relative_path(file_path)

        unit = ExtractedUnit.new(
          type: :caching,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace   = nil
        unit.source_code = annotate_source(source, identifier, file_type)
        unit.metadata    = extract_metadata(source, code, file_type)
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
      # @param source [String] Source code, for the line count
      # @param code [String] Source with comments blanked, for cache calls
      # @param file_type [Symbol] :controller, :model, or :view
      # @return [Hash] Caching metadata
      def extract_metadata(source, code, file_type)
        cache_calls = extract_cache_calls(code)
        {
          cache_calls: cache_calls,
          cache_strategy: infer_cache_strategy(code, cache_calls),
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
      # or an implicit-self call anywhere else, still counts. A fragment
      # match inside an earlier call's arguments is text in that call's key
      # (`Rails.cache.fetch([id, "cache me do"])`), so it is dropped too;
      # fragment is the last call type in {CACHE_PATTERNS}.
      #
      # @param source [String] Source code
      # @return [Array<Hash>] Cache call descriptors
      def extract_cache_calls(source)
        key_patterns, call_patterns = CACHE_PATTERNS.partition { |type, _| KEY_METHOD_TYPES.include?(type) }
        calls = []
        argument_ranges = []

        call_patterns.each do |type, pattern|
          spans = type == :fragment ? merge_ranges(argument_ranges) : []
          each_occurrence(source, pattern) do |offset|
            next if within_spans?(spans, offset)

            arguments = call_arguments(source, offset, type)
            range = arguments.delete(:argument_range)
            argument_ranges << range if range
            calls << { type: type }.merge(arguments)
          end
        end

        spans = merge_ranges(argument_ranges)
        key_patterns.each do |type, pattern|
          each_occurrence(source, pattern) do |offset|
            next if bare_cache_argument?(source, offset, spans)

            calls << { type: type, key_pattern: nil, ttl: nil, options: {} }
          end
        end

        calls
      end

      # Sorted, disjoint union of exclusive ranges, so membership is one
      # binary search instead of a scan over every cache call.
      #
      # @param ranges [Array<Range>] Exclusive byte ranges
      # @return [Array<Range>]
      def merge_ranges(ranges)
        ranges.sort_by(&:begin).each_with_object([]) do |range, merged|
          last = merged.last
          if last && range.begin <= last.end
            merged[-1] = (last.begin...[last.end, range.end].max)
          else
            merged << range
          end
        end
      end

      # Whether a key method occurrence is a bare identifier (no receiver)
      # inside the arguments of a cache call.
      #
      # @param source [String] Source code
      # @param offset [Integer] Byte offset of the key method name
      # @param spans [Array<Range>] Merged argument ranges, from {#merge_ranges}
      # @return [Boolean]
      def bare_cache_argument?(source, offset, spans)
        return false if offset.positive? && source.getbyte(offset - 1) == DOT

        within_spans?(spans, offset)
      end

      # @param spans [Array<Range>] Merged argument ranges, from {#merge_ranges}
      # @param offset [Integer] Byte offset
      # @return [Boolean]
      def within_spans?(spans, offset)
        span = spans.bsearch { |range| range.end > offset }
        span ? span.begin <= offset : false
      end

      # Yield the start offset of every non-overlapping occurrence of a pattern.
      #
      # Offsets are bytes: MatchData character offsets on a UTF-8 string are
      # counted from its start, which made a loop over many matches
      # quadratic. `fixed_anchor` lets `\b` see the text before the scan
      # position.
      #
      # @param source [String] Source code
      # @param pattern [Regexp] Pattern to scan for
      # @yieldparam offset [Integer] Byte offset where the occurrence begins
      # @return [void]
      def each_occurrence(source, pattern)
        scanner = StringScanner.new(source, fixed_anchor: true)
        while scanner.skip_until(pattern)
          yield scanner.pos - scanner.matched_size
          scanner.getch if scanner.matched_size.zero?
        end
      end

      # Key, ttl, and literal options for one cache call occurrence.
      #
      # @param source [String] Source code
      # @param offset [Integer] Byte offset where the occurrence begins
      # @param type [Symbol] The cache call type
      # @return [Hash] :key_pattern, :ttl, :options, and :argument_range
      def call_arguments(source, offset, type)
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
