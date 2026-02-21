# frozen_string_literal: true

require_relative '../mcp/tool_response_renderer'

module CodebaseIndex
  module Console
    # Renders Console MCP tool responses with smart auto-detection of data shape.
    #
    # Auto-detects:
    # - Array<Hash> → Markdown tables
    # - Single Hash → Key-value bullet lists
    # - Simple Array → Bullet list
    # - Scalars → Plain text
    #
    class ConsoleResponseRenderer < MCP::ToolResponseRenderer
      # Smart default: auto-detect data shape and render accordingly.
      #
      # @param data [Object] The bridge response result
      # @return [String] Rendered text
      def render_default(data)
        case data
        when Array
          render_array(data)
        when Hash
          render_hash(data)
        else
          data.to_s
        end
      end

      private

      def render_array(data)
        return '_(empty)_' if data.empty?

        if data.first.is_a?(Hash)
          render_table(data)
        else
          data.map { |item| "- #{item}" }.join("\n")
        end
      end

      def render_table(rows)
        keys = rows.first.keys
        lines = []
        lines << "| #{keys.join(' | ')} |"
        lines << "| #{keys.map { '---' }.join(' | ')} |"
        rows.each do |row|
          lines << "| #{keys.map { |k| row[k] }.join(' | ')} |"
        end
        lines.join("\n")
      end

      def render_hash(data)
        data.map do |key, value|
          case value
          when Hash
            "**#{key}:**\n" + value.map { |k, v| "  - #{k}: #{v}" }.join("\n")
          when Array
            "**#{key}:** #{value.size} items"
          else
            "**#{key}:** #{value}"
          end
        end.join("\n")
      end
    end

    # JSON passthrough renderer for backward compatibility.
    # Returns JSON.pretty_generate output for any data.
    class JsonConsoleRenderer < MCP::ToolResponseRenderer
      # @param data [Object] Any JSON-serializable data
      # @return [String] Pretty-printed JSON
      def render_default(data)
        JSON.pretty_generate(data)
      end
    end
  end
end
