# frozen_string_literal: true

require_relative 'base'

module CodebaseIndex
  module Formatting
    # Formats assembled context as plain text for generic LLM consumption.
    #
    # Produces plain text with:
    # - `=== CODEBASE CONTEXT ===` header
    # - Token usage line
    # - Content separated by `---` dividers
    # - Sources in bracket notation
    #
    # @example
    #   adapter = GenericAdapter.new
    #   text = adapter.format(assembled_context)
    #   # => "=== CODEBASE CONTEXT ===\nTokens: 42 / 8000\n..."
    #
    class GenericAdapter < Base
      # Format assembled context as plain text.
      #
      # @param assembled_context [CodebaseIndex::Retrieval::AssembledContext]
      # @return [String] Plain text formatted context
      def format(assembled_context)
        parts = []
        parts << '=== CODEBASE CONTEXT ==='
        parts << "Tokens: #{assembled_context.tokens_used} / #{assembled_context.budget}"
        parts << '---'
        parts << assembled_context.context
        parts.concat(format_sources(assembled_context.sources))
        parts.join("\n")
      end

      private

      # Format sources in bracket notation.
      #
      # @param sources [Array<Hash>]
      # @return [Array<String>] Lines to append
      def format_sources(sources)
        return [] if sources.empty?

        lines = []
        lines << '---'
        sources.each do |source|
          identifier = source[:identifier]
          type = source[:type]
          score = source[:score]
          lines << "[Source: #{identifier} (#{type}) \u2014 score: #{score}]"
        end
        lines
      end
    end
  end
end
