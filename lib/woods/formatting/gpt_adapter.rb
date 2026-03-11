# frozen_string_literal: true

require_relative 'base'

module CodebaseIndex
  module Formatting
    # Formats assembled context as Markdown for GPT models.
    #
    # Produces Markdown with:
    # - `## Codebase Context` heading
    # - Token usage in bold
    # - Content in a fenced Ruby code block
    # - Sources as a bullet list
    #
    # @example
    #   adapter = GptAdapter.new
    #   md = adapter.format(assembled_context)
    #   # => "## Codebase Context\n\n**Tokens:** 42/8000\n..."
    #
    class GptAdapter < Base
      # Format assembled context as Markdown for GPT.
      #
      # @param assembled_context [CodebaseIndex::Retrieval::AssembledContext]
      # @return [String] Markdown-formatted context
      def format(assembled_context)
        parts = []
        parts << '## Codebase Context'
        parts << ''
        parts << "**Tokens:** #{assembled_context.tokens_used}/#{assembled_context.budget}"
        parts << ''
        parts << '---'
        parts << ''
        parts << '```ruby'
        parts << assembled_context.context
        parts << '```'
        parts.concat(format_sources(assembled_context.sources))
        parts.join("\n")
      end

      private

      # Format sources as a Markdown bullet list.
      #
      # @param sources [Array<Hash>]
      # @return [Array<String>] Lines to append
      def format_sources(sources)
        return [] if sources.empty?

        lines = []
        lines << ''
        lines << '### Sources'
        lines << ''
        sources.each do |source|
          identifier = source[:identifier]
          type = source[:type]
          score = source[:score]
          file_path = source[:file_path]
          lines << "- **#{identifier}** (#{type}) \u2014 score: #{score}, file: #{file_path}"
        end
        lines
      end
    end
  end
end
