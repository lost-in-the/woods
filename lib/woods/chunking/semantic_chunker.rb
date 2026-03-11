# frozen_string_literal: true

require_relative 'chunk'

module CodebaseIndex
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

    # Splits ExtractedUnits into semantic chunks based on unit type.
    #
    # Models are split by: summary, associations, validations, callbacks,
    # scopes, methods. Controllers are split by: summary (filters), per-action.
    # Other types use whole-unit or method-level splitting based on size.
    #
    # Units below the token threshold are returned as a single :whole chunk.
    #
    # @example
    #   chunker = SemanticChunker.new(threshold: 200)
    #   chunks = chunker.chunk(extracted_unit)
    #   chunks.map(&:chunk_type) # => [:summary, :associations, :validations, :methods]
    #
    class SemanticChunker
      # Default token threshold below which units stay whole.
      DEFAULT_THRESHOLD = 200

      # @param threshold [Integer] Token count threshold for chunking
      def initialize(threshold: DEFAULT_THRESHOLD)
        @threshold = threshold
      end

      # Split an ExtractedUnit into semantic chunks.
      #
      # @param unit [ExtractedUnit] The unit to chunk
      # @return [Array<Chunk>] Ordered list of chunks
      def chunk(unit)
        return [] if unit.source_code.nil? || unit.source_code.strip.empty?
        return [build_whole_chunk(unit)] if unit.estimated_tokens <= @threshold

        case unit.type
        when :model then ModelChunker.new(unit).chunk
        when :controller then ControllerChunker.new(unit).chunk
        else [build_whole_chunk(unit)]
        end
      end

      private

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
  end
end
