# frozen_string_literal: true

module CodebaseIndex
  module Embedding
    # Prepares ExtractedUnit data for embedding by building context-prefixed text.
    #
    # Follows the context prefix format from docs/CONTEXT_AND_CHUNKING.md:
    #   [type] identifier
    #   namespace: ...
    #   file: ...
    #   dependencies: dep1, dep2, ...
    #
    # Handles token limit enforcement by truncating text that exceeds the
    # embedding model's context window.
    #
    # @example
    #   preparer = CodebaseIndex::Embedding::TextPreparer.new(max_tokens: 8192)
    #   text = preparer.prepare(unit)
    #   chunks = preparer.prepare_chunks(unit)
    class TextPreparer
      DEFAULT_MAX_TOKENS = 8192

      # @param max_tokens [Integer] maximum token budget for prepared text
      def initialize(max_tokens: DEFAULT_MAX_TOKENS)
        @max_tokens = max_tokens
      end

      # Prepare text for embedding from an ExtractedUnit.
      #
      # Builds a context prefix and appends the unit's source code (or first
      # chunk content for chunked units). Enforces token limits via truncation.
      #
      # @param unit [CodebaseIndex::ExtractedUnit] the unit to prepare
      # @return [String] context-prefixed text ready for embedding
      def prepare(unit)
        prefix = build_prefix(unit)
        content = select_content(unit)
        text = "#{prefix}\n#{content}"
        enforce_token_limit(text)
      end

      # Prepare text for each chunk of an ExtractedUnit.
      #
      # If the unit has no chunks, returns a single-element array with the
      # full prepared text. For chunked units, each chunk gets the same
      # context prefix prepended.
      #
      # @param unit [CodebaseIndex::ExtractedUnit] the unit to prepare
      # @return [Array<String>] array of context-prefixed texts
      def prepare_chunks(unit)
        return [prepare(unit)] unless unit.chunks&.any?

        prefix = build_prefix(unit)
        unit.chunks.map do |chunk|
          text = "#{prefix}\n#{chunk[:content]}"
          enforce_token_limit(text)
        end
      end

      private

      # Build the context prefix for a unit.
      #
      # @param unit [CodebaseIndex::ExtractedUnit] the unit
      # @return [String] formatted prefix lines
      def build_prefix(unit)
        lines = []
        lines << "[#{unit.type}] #{unit.identifier}"
        lines << "namespace: #{unit.namespace}" if unit.namespace
        lines << "file: #{unit.file_path}" if unit.file_path
        append_dependency_line(lines, unit.dependencies)
        lines.join("\n")
      end

      # Append a formatted dependency line if dependencies exist.
      #
      # @param lines [Array<String>] lines to append to
      # @param dependencies [Array<Hash>, nil] dependency list
      # @return [void]
      def append_dependency_line(lines, dependencies)
        return unless dependencies&.any?

        dep_names = dependencies.map { |d| d[:target] }.compact.first(10)
        lines << "dependencies: #{dep_names.join(', ')}" if dep_names.any?
      end

      # Select the content to embed for a unit.
      #
      # @param unit [CodebaseIndex::ExtractedUnit] the unit
      # @return [String] source code or first chunk content
      def select_content(unit)
        if unit.chunks&.any?
          unit.chunks.first[:content]
        else
          unit.source_code || ''
        end
      end

      # Truncate text to fit within the token budget.
      #
      # @param text [String] the text to truncate
      # @return [String] text within token limits
      def enforce_token_limit(text)
        estimated = (text.length / 3.5).ceil
        return text if estimated <= @max_tokens

        max_chars = (@max_tokens * 3.5).floor
        text[0...max_chars]
      end
    end
  end
end
