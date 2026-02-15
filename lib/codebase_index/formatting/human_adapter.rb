# frozen_string_literal: true

require_relative 'base'

module CodebaseIndex
  module Formatting
    # Formats assembled context with box-drawing characters for human display.
    #
    # Produces visually rich output with:
    # - Box-drawn header using Unicode box characters
    # - Token usage summary
    # - Content section
    # - Source entries with box-drawing decorators
    #
    # @example
    #   adapter = HumanAdapter.new
    #   output = adapter.format(assembled_context)
    #
    class HumanAdapter < Base
      HEADER_WIDTH = 50

      # Format assembled context for human-readable display.
      #
      # @param assembled_context [CodebaseIndex::Retrieval::AssembledContext]
      # @return [String] Box-drawing formatted context
      def format(assembled_context)
        parts = []
        parts.concat(format_header(assembled_context))
        parts << ''
        parts << assembled_context.context unless assembled_context.context.empty?
        parts.concat(format_sources(assembled_context.sources))
        parts.join("\n")
      end

      private

      # Format the box-drawing header.
      #
      # @param assembled_context [CodebaseIndex::Retrieval::AssembledContext]
      # @return [Array<String>]
      def format_header(assembled_context)
        title = 'Codebase Context'
        token_info = "Tokens: #{assembled_context.tokens_used} / #{assembled_context.budget}"
        width = [HEADER_WIDTH, title.length + 4, token_info.length + 4].max

        [
          "\u2554#{'═' * width}\u2557",
          "\u2551 #{title.ljust(width - 2)} \u2551",
          "\u255A#{'═' * width}\u255D",
          token_info
        ]
      end

      # Format sources with box-drawing decorators.
      #
      # @param sources [Array<Hash>]
      # @return [Array<String>]
      def format_sources(sources)
        return [] if sources.empty?

        lines = ['', 'Sources:']
        sources.each { |source| lines.concat(format_source_entry(source)) }
        lines
      end

      # Format a single source entry.
      #
      # @param source [Hash]
      # @return [Array<String>]
      def format_source_entry(source)
        header = "\u2500\u2500 #{source[:identifier]} (#{source[:type]}) "
        header += "\u2500" * [1, HEADER_WIDTH - header.length - 12].max
        header += " score: #{source[:score]}"
        [header, "   #{source[:file_path]}"]
      end
    end
  end
end
