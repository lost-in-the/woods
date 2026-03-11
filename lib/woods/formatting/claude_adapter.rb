# frozen_string_literal: true

require_relative 'base'

module CodebaseIndex
  module Formatting
    # Formats assembled context as XML for Claude models.
    #
    # Produces structured XML with:
    # - `<codebase-context>` root element
    # - `<meta>` tag with token usage and budget
    # - `<content>` section with indented context text
    # - `<sources>` section with self-closing `<source>` elements
    #
    # @example
    #   adapter = ClaudeAdapter.new
    #   xml = adapter.format(assembled_context)
    #   # => "<codebase-context>\n  <meta tokens=\"42\" budget=\"8000\" />\n..."
    #
    class ClaudeAdapter < Base
      # Format assembled context as XML for Claude.
      #
      # @param assembled_context [CodebaseIndex::Retrieval::AssembledContext]
      # @return [String] XML-formatted context
      def format(assembled_context)
        parts = []
        parts << '<codebase-context>'
        parts << "  <meta tokens=\"#{assembled_context.tokens_used}\" budget=\"#{assembled_context.budget}\" />"
        parts << format_content(assembled_context.context)
        parts << format_sources(assembled_context.sources)
        parts << '</codebase-context>'
        parts.join("\n")
      end

      private

      # Format the content section with indentation.
      #
      # @param context [String]
      # @return [String]
      def format_content(context)
        lines = []
        lines << '  <content>'
        lines << indent(escape_xml(context), 4) unless context.empty?
        lines << '  </content>'
        lines.join("\n")
      end

      # Format the sources section.
      #
      # @param sources [Array<Hash>]
      # @return [String]
      def format_sources(sources)
        lines = []
        lines << '  <sources>'
        sources.each do |source|
          lines << "    <source #{source_attributes(source)} />"
        end
        lines << '  </sources>'
        lines.join("\n")
      end

      # Build attribute string for a source element.
      #
      # @param source [Hash]
      # @return [String]
      def source_attributes(source)
        [
          "identifier=\"#{escape_xml(source[:identifier].to_s)}\"",
          "type=\"#{escape_xml(source[:type].to_s)}\"",
          "score=\"#{source[:score]}\"",
          "file=\"#{escape_xml(source[:file_path].to_s)}\""
        ].join(' ')
      end

      # Indent every line of text by the given number of spaces.
      #
      # @param text [String]
      # @param spaces [Integer]
      # @return [String]
      def indent(text, spaces)
        prefix = ' ' * spaces
        text.lines.map { |line| "#{prefix}#{line.chomp}" }.join("\n")
      end

      # Escape XML special characters.
      #
      # @param text [String]
      # @return [String]
      def escape_xml(text)
        text.gsub('&', '&amp;')
            .gsub('<', '&lt;')
            .gsub('>', '&gt;')
            .gsub('"', '&quot;')
      end
    end
  end
end
