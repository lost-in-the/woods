# frozen_string_literal: true

require_relative 'chunk'

module Woods
  module Chunking
    # Shared method-detection patterns used by ModelChunker and ControllerChunker.
    METHOD_PATTERN = /^\s*def\s+/
    PRIVATE_PATTERN = /^\s*(private|protected)\s*$/

    # Mixin that provides the shared build_chunk helper for chunker classes.
    #
    # Requires the including class to have an @unit ivar (ExtractedUnit).
    module ChunkBuilder
      private

      # Build a Chunk for a given section.
      #
      # @param chunk_type [Symbol]
      # @param content [String]
      # @return [Chunk]
      def build_chunk(chunk_type, content)
        Chunk.new(
          content: content,
          chunk_type: chunk_type,
          parent_identifier: @unit.identifier,
          parent_type: @unit.type
        )
      end
    end

    # Class-like unit types that MethodChunker handles — anything
    # shaped as "class or module with public methods, maybe privates,
    # maybe callbacks/filters." Extend this list when new extractors
    # produce units of similar structure.
    METHOD_CHUNKABLE_TYPES = %i[
      service job mailer concern policy pundit_policy serializer
      decorator presenter interactor query_object value_object
      component view_component action_cable_channel channel
      graphql_resolver graphql_type helper validator api_client poro
      manager configuration
    ].freeze

    # Splits ExtractedUnits into semantic chunks based on unit type.
    #
    # Models are split by: summary, associations, validations, callbacks,
    # scopes, methods. Controllers are split by: summary (filters), per-action.
    # Class-like types (services, jobs, mailers, concerns, policies, …) split
    # by summary + per-public-method + bundled privates via MethodChunker.
    # Other types stay whole.
    #
    # Any chunk that still exceeds `max_chars` after semantic splitting is
    # sliced into line-balanced sub-chunks so no single chunk is ever larger
    # than the embedding provider's input budget.
    #
    # Units below the token threshold are returned as a single :whole chunk.
    #
    # @example
    #   chunker = SemanticChunker.new(threshold: 200, max_chars: 20_480)
    #   chunks = chunker.chunk(extracted_unit)
    #   chunks.map(&:chunk_type) # => [:summary, :associations, :validations, :methods]
    #
    class SemanticChunker # rubocop:disable Metrics/ClassLength
      # Default token threshold below which units stay whole.
      DEFAULT_THRESHOLD = 200

      # Minimum chars-per-slice budget during tokenizer-driven recursive
      # splitting. Prevents unbounded halving on pathological content
      # (e.g., a single 2000-char regex line that tokenizes into 6000
      # tokens because BERT WordPiece fragments every `\w+` boundary).
      MIN_SLICE_CHARS = 256
      private_constant :MIN_SLICE_CHARS

      # @param threshold [Integer] Token count threshold for chunking
      # @param max_chars [Integer, nil] Hard character ceiling for any single
      #   chunk. When set, any chunk larger than this is sliced into
      #   line-balanced sub-chunks. `nil` disables the safety net.
      # @param token_counter [Woods::Embedding::TokenCounter, nil] Optional
      #   exact-token counter. When both this and `max_tokens` are set,
      #   oversize detection uses the real tokenizer rather than the
      #   char-length estimate, and post-slice verification recursively
      #   re-splits any piece that still exceeds `max_tokens`.
      # @param max_tokens [Integer, nil] Token budget used with
      #   `token_counter` for the authoritative oversize check.
      def initialize(threshold: DEFAULT_THRESHOLD, max_chars: nil,
                     token_counter: nil, max_tokens: nil)
        @threshold = threshold
        @max_chars = max_chars
        @token_counter = token_counter
        @max_tokens = max_tokens
      end

      # @return [Woods::Embedding::TokenCounter, nil]
      attr_reader :token_counter

      # @return [Integer, nil]
      attr_reader :max_tokens

      # @return [Integer, nil]
      attr_reader :max_chars

      # Split an ExtractedUnit into semantic chunks.
      #
      # @param unit [ExtractedUnit] The unit to chunk
      # @return [Array<Chunk>] Ordered list of chunks
      def chunk(unit)
        return [] if unit.source_code.nil? || unit.source_code.strip.empty?
        return [build_whole_chunk(unit)] if unit.estimated_tokens <= @threshold

        enforce_char_limit(chunks_for(unit), unit)
      end

      # Enforce {@max_chars} on a unit's already-populated `chunks` array
      # (hashes produced by extraction or a prior chunking pass). Oversize
      # chunks are split into line-balanced siblings with `_part_N` chunk
      # types; small chunks pass through unchanged. No-op when `@max_chars`
      # is unset or `unit.chunks` is empty.
      #
      # Exists so the Indexer can apply the same ceiling to pre-chunked
      # units (e.g. `rails_source`) that extraction already sliced — the
      # extractor's own chunker is unaware of the embedding provider's
      # budget and can emit chunks larger than the ceiling we'd pick here.
      #
      # @param unit [ExtractedUnit]
      # @return [void]
      def enforce_chunk_limits!(unit)
        return unless enforcement_active?
        return if unit.chunks.nil? || unit.chunks.empty?

        unit.chunks = unit.chunks.flat_map { |chunk| split_oversize_hash_chunk(chunk) }
      end

      private

      # True when either the char ceiling or the token-based verifier is
      # wired up.
      def enforcement_active?
        @max_chars || (@token_counter && @max_tokens)
      end

      # Token-authoritative oversize check, falling back to char length.
      def oversize?(content)
        return false if content.nil? || content.empty?
        return @token_counter.count(content) > @max_tokens if tokenizer_active?

        @max_chars && content.length > @max_chars
      end

      def tokenizer_active?
        @token_counter && @max_tokens
      end

      # @param chunk [Hash] a unit-chunk hash (symbol or string keys)
      # @return [Array<Hash>]
      def split_oversize_hash_chunk(chunk)
        content = chunk[:content] || chunk['content']
        return [chunk] if content.nil? || !oversize?(content)

        chunk_type = chunk[:chunk_type] || chunk['chunk_type'] || :whole
        verified_slices(content).each_with_index.map do |slice, idx|
          { content: slice, chunk_type: :"#{chunk_type}_part_#{idx}" }
        end
      end

      # Dispatch to the type-appropriate chunker.
      #
      # @param unit [ExtractedUnit]
      # @return [Array<Chunk>]
      def chunks_for(unit)
        case unit.type
        when :model then ModelChunker.new(unit).chunk
        when :controller then ControllerChunker.new(unit).chunk
        else
          return MethodChunker.new(unit).chunk if METHOD_CHUNKABLE_TYPES.include?(unit.type)

          [build_whole_chunk(unit)]
        end
      end

      # Build a single :whole chunk for small units.
      #
      # @param unit [ExtractedUnit]
      # @return [Chunk]
      def build_whole_chunk(unit)
        Chunk.new(
          content: unit.source_code,
          chunk_type: :whole,
          parent_identifier: unit.identifier,
          parent_type: unit.type
        )
      end

      # Slice any chunk whose content exceeds `@max_chars` into
      # line-balanced sub-chunks. Preserves chunk_type with a `_part_N`
      # suffix so downstream consumers can see they came from the same
      # section.
      #
      # @param chunks [Array<Chunk>]
      # @param unit [ExtractedUnit]
      # @return [Array<Chunk>]
      def enforce_char_limit(chunks, unit)
        return chunks unless @max_chars

        chunks.flat_map { |chunk| split_oversize_chunk(chunk, unit) }
      end

      # @param chunk [Chunk]
      # @param unit [ExtractedUnit]
      # @return [Array<Chunk>]
      def split_oversize_chunk(chunk, unit)
        return [chunk] unless oversize?(chunk.content)

        verified_slices(chunk.content).each_with_index.map do |slice, idx|
          Chunk.new(
            content: slice,
            chunk_type: :"#{chunk.chunk_type}_part_#{idx}",
            parent_identifier: unit.identifier,
            parent_type: unit.type
          )
        end
      end

      # Slice by lines, then (when a tokenizer is wired in) recursively
      # re-split any slice whose real token count still exceeds the
      # budget. Char-based slicing alone is unreliable on dense Rails
      # source because BERT WordPiece tokenizes `::`-heavy constants at
      # far below our estimate; the verifier catches those cases.
      #
      # @param content [String]
      # @return [Array<String>]
      def verified_slices(content)
        limit = @max_chars || estimated_char_budget
        slices = slice_by_lines(content, limit)
        return slices unless tokenizer_active?

        slices.flat_map { |slice| verify_slice(slice, limit) }
      end

      # Ensure a single post-line-split slice fits the token budget.
      # Halves the char limit and reslices if it doesn't. Stops at
      # {MIN_SLICE_CHARS} to avoid unbounded recursion on content that
      # cannot be split line-wise (minified output, huge regex literals).
      #
      # @param slice [String]
      # @param char_limit [Integer]
      # @return [Array<String>]
      def verify_slice(slice, char_limit)
        return [slice] unless @token_counter.count(slice) > @max_tokens

        smaller = char_limit / 2
        return [slice] if smaller < MIN_SLICE_CHARS

        slice_by_lines(slice, smaller).flat_map { |sub| verify_slice(sub, smaller) }
      end

      # Conservative char budget used when no explicit `max_chars` was
      # given but the tokenizer is active. Uses a permissive estimate
      # because the verifier will halve this further as needed.
      def estimated_char_budget
        return 0 unless @max_tokens

        @max_tokens * 2
      end

      # Greedy line-based slicing that respects a supplied `limit`.
      # Lines longer than `limit` are hard-cut (lossy — but such lines
      # are already pathological: minified JSON dumps, long regexes).
      #
      # @param content [String]
      # @param limit [Integer]
      # @return [Array<String>]
      def slice_by_lines(content, limit = @max_chars)
        slices = []
        current = String.new
        content.each_line do |line|
          line_parts = line.length > limit ? line.scan(/.{1,#{limit}}/m) : [line]
          line_parts.each do |part|
            if current.length + part.length > limit && !current.empty?
              slices << current
              current = String.new
            end
            current << part
          end
        end
        slices << current unless current.empty?
        slices
      end
    end

    # Chunks a model unit by semantic sections: summary, associations,
    # validations, callbacks, scopes, methods.
    #
    # @api private
    class ModelChunker
      include ChunkBuilder

      ASSOCIATION_PATTERN = /^\s*(has_many|has_one|belongs_to|has_and_belongs_to_many)\b/
      VALIDATION_PATTERN = /^\s*validates?\b/
      CALLBACK_ACTIONS = '(save|create|update|destroy|validation|action|commit|rollback|find|initialize|touch)'
      CALLBACK_PATTERN = /^\s*(before_|after_|around_)#{CALLBACK_ACTIONS}\b/
      SCOPE_PATTERN = /^\s*scope\s+:/

      SECTION_PATTERNS = {
        associations: ASSOCIATION_PATTERN,
        validations: VALIDATION_PATTERN,
        callbacks: CALLBACK_PATTERN,
        scopes: SCOPE_PATTERN
      }.freeze

      SEMANTIC_SECTIONS = %i[associations validations callbacks scopes].freeze

      # @param unit [ExtractedUnit]
      def initialize(unit)
        @unit = unit
      end

      # @return [Array<Chunk>]
      def chunk
        sections = classify_lines(@unit.source_code.lines)
        build_chunks(sections).reject(&:empty?)
      end

      private

      # @param sections [Hash<Symbol, Array<String>>]
      # @return [Array<Chunk>]
      def build_chunks(sections)
        chunks = []
        chunks << build_chunk(:summary, sections[:summary].join) if sections[:summary].any?

        SEMANTIC_SECTIONS.each do |type|
          next if sections[type].empty?

          chunks << build_chunk(type, sections[type].join)
        end

        chunks << build_chunk(:methods, sections[:methods].join) if sections[:methods].any?
        chunks
      end

      # Classify each line into a semantic section.
      #
      # @param lines [Array<String>]
      # @return [Hash<Symbol, Array<String>>]
      def classify_lines(lines)
        state = { sections: empty_sections, current: :summary, in_method: false,
                  depth: 0 }
        lines.each do |line|
          if state[:in_method]
            track_method_line(state, line)
          else
            classify_line(state, line)
          end
        end

        state[:sections]
      end

      # @return [Hash<Symbol, Array<String>>]
      def empty_sections
        { summary: [], associations: [], validations: [], callbacks: [], scopes: [], methods: [] }
      end

      # Track lines inside a method body.
      def track_method_line(state, line)
        state[:sections][:methods] << line
        update_method_depth(state, line)
        state[:in_method] = false if state[:depth] <= 0 && line.strip.match?(/^end\s*$/)
      end

      def update_method_depth(state, line)
        state[:depth] += 1 if line.match?(/\bdo\b|\bdef\b/) && !line.match?(/\bend\b/)
        state[:depth] -= 1 if line.strip == 'end' || (line.match?(/\bend\s*$/) && state[:depth].positive?)
      end

      # Classify a single non-method line.
      def classify_line(state, line)
        section = detect_semantic_section(line)
        if section
          state[:current] = section
          state[:sections][section] << line
        elsif line.match?(PRIVATE_PATTERN)
          state[:sections][:methods] << line
        elsif line.match?(METHOD_PATTERN)
          start_method(state, line)
        else
          assign_fallback(state, line)
        end
      end

      # Detect which semantic section a line belongs to, if any.
      #
      # @return [Symbol, nil] the section name, or nil if no pattern matched
      def detect_semantic_section(line)
        SECTION_PATTERNS.each do |section, pattern|
          return section if line.match?(pattern)
        end
        nil
      end

      def start_method(state, line)
        state[:in_method] = true
        state[:depth] = 1
        state[:sections][:methods] << line
      end

      def assign_fallback(state, line)
        if state[:current] == :summary || line.strip.empty? || line.match?(/^\s*#/)
          state[:sections][:summary] << line
        else
          state[:sections][state[:current]] << line
        end
      end
    end

    # Chunks a controller unit by actions: summary (class + filters),
    # then one chunk per public action method.
    #
    # @api private
    class ControllerChunker
      include ChunkBuilder

      FILTER_PATTERN = /^\s*(before_action|after_action|around_action|skip_before_action)\b/

      # @param unit [ExtractedUnit]
      def initialize(unit)
        @unit = unit
      end

      # @return [Array<Chunk>]
      def chunk
        state = parse_lines(@unit.source_code.lines)
        build_chunks(state).reject(&:empty?)
      end

      private

      # Parse controller lines into summary + action buffers.
      #
      # @param lines [Array<String>]
      # @return [Hash]
      def parse_lines(lines)
        state = { summary: [], actions: {}, current_action: nil, depth: 0,
                  in_private: false }
        lines.each do |line|
          if state[:current_action]
            track_action_line(state, line)
          else
            classify_controller_line(state, line)
          end
        end

        state
      end

      def track_action_line(state, line)
        state[:actions][state[:current_action]] << line
        state[:depth] += 1 if line.match?(/\bdo\b/) && !line.match?(/\bend\b/)
        return unless line.strip.match?(/^end\s*$/)

        state[:depth] -= 1
        return unless state[:depth] <= 0

        state[:current_action] = nil
        state[:depth] = 0
      end

      def classify_controller_line(state, line)
        if line.match?(PRIVATE_PATTERN)
          state[:in_private] = true
          state[:summary] << line
        elsif !state[:in_private] && line.match?(METHOD_PATTERN)
          start_action(state, line)
        else
          state[:summary] << line
        end
      end

      def start_action(state, line)
        action_name = line[/def\s+(\w+)/, 1]
        state[:current_action] = action_name
        state[:depth] = 1
        state[:actions][action_name] = [line]
      end

      # @param state [Hash]
      # @return [Array<Chunk>]
      def build_chunks(state)
        chunks = []
        chunks << build_chunk(:summary, state[:summary].join) if state[:summary].any?

        state[:actions].each do |action_name, action_lines|
          chunks << build_chunk(:"action_#{action_name}", action_lines.join)
        end

        chunks
      end
    end

    # Generic method-aware chunker for class-like unit types.
    #
    # Splits into:
    # - `:summary` — class/module declaration, includes, constants,
    #   attr_* DSL, class-level method calls, and any class-level code
    #   before the first public method.
    # - `:method_<name>` — one chunk per public instance method.
    # - `:private_methods` — all private/protected methods bundled
    #   together (they're usually implementation helpers and rarely
    #   queried individually).
    #
    # Used for services, jobs, mailers, concerns, policies, serializers,
    # decorators, presenters, interactors, form objects, components,
    # GraphQL resolvers, helpers, validators, and other class-like units.
    #
    # @api private
    class MethodChunker
      include ChunkBuilder

      # @param unit [ExtractedUnit]
      def initialize(unit)
        @unit = unit
      end

      # @return [Array<Chunk>]
      def chunk
        state = parse_lines(@unit.source_code.lines)
        build_chunks(state).reject(&:empty?)
      end

      private

      # Parse lines into summary + per-public-method + private buffers.
      #
      # @param lines [Array<String>]
      # @return [Hash]
      def parse_lines(lines)
        state = {
          summary: [], methods: {}, private_methods: [],
          current_method: nil, depth: 0, in_private: false
        }
        lines.each do |line|
          if state[:current_method]
            track_method_line(state, line)
          else
            classify_top_level_line(state, line)
          end
        end

        state
      end

      # While inside a method body, collect every line and track depth so
      # we know when the method closes. Blocks (`do...end`, `if...end`)
      # nest inside methods and must be balanced before the method's own
      # `end` line counts.
      def track_method_line(state, line)
        target = state[:in_private] ? state[:private_methods] : state[:methods][state[:current_method]]
        target << line

        state[:depth] += 1 if line.match?(/\bdo\b/) && !line.match?(/\bend\b/)
        return unless line.strip.match?(/^end\s*$/)

        state[:depth] -= 1
        return unless state[:depth] <= 0

        state[:current_method] = nil
        state[:depth] = 0
      end

      # Classify a class-body line: privacy marker, method start, or
      # summary content (DSL calls, attrs, comments, includes).
      def classify_top_level_line(state, line)
        if line.match?(PRIVATE_PATTERN)
          state[:in_private] = true
          state[:private_methods] << line
        elsif line.match?(METHOD_PATTERN)
          start_method(state, line)
        elsif state[:in_private]
          state[:private_methods] << line
        else
          state[:summary] << line
        end
      end

      def start_method(state, line)
        method_name = line[/def\s+(?:self\.)?(\w+)/, 1]
        state[:current_method] = method_name
        state[:depth] = 1

        if state[:in_private]
          state[:private_methods] << line
        else
          # Preserve insertion order — Hash does this by default, but we
          # initialize the entry here so `build_chunks` below walks
          # methods in source order.
          state[:methods][method_name] = [line]
        end
      end

      # Build the final chunk array from the parse state.
      #
      # @param state [Hash]
      # @return [Array<Chunk>]
      def build_chunks(state)
        chunks = []
        chunks << build_chunk(:summary, state[:summary].join) if state[:summary].any?

        state[:methods].each do |method_name, lines|
          chunks << build_chunk(:"method_#{method_name}", lines.join)
        end

        chunks << build_chunk(:private_methods, state[:private_methods].join) if state[:private_methods].any?
        chunks
      end
    end
  end
end
