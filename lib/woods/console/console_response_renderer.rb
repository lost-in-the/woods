# frozen_string_literal: true

require_relative '../mcp/tool_response_renderer'
require_relative '../mcp/renderers/json_renderer'

module Woods
  module Console
    # Renders Console MCP tool responses with smart auto-detection of data shape.
    #
    # Auto-detects:
    # - Array<Hash> → Markdown tables
    # - Single Hash → Key-value bullet lists (Array values recurse into tables;
    #   `rows` / `values` paired with a sibling `columns` render as positional
    #   Markdown tables so sql/query/pluck output isn't collapsed)
    # - Simple Array → Bullet list
    # - Scalars → Plain text
    #
    class ConsoleResponseRenderer < MCP::ToolResponseRenderer
      # Keys that carry positional row data in tool responses. When any of
      # these appears alongside a `columns` array we render a proper table
      # using the columns as headers instead of dumping bracketed arrays.
      POSITIONAL_ROW_KEYS = %w[rows values].freeze
      private_constant :POSITIONAL_ROW_KEYS

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
        header_row(keys) + rows.map { |row| row_line(keys.map { |k| row[k] }) }.join
      end

      def render_hash(data)
        columns = stringify_array(data['columns'] || data[:columns])
        data.map { |key, value| render_hash_entry(key, value, columns) }.join("\n")
      end

      def render_hash_entry(key, value, sibling_columns)
        case value
        when Hash
          "**#{key}:**\n" + value.map { |k, v| "  - #{k}: #{v}" }.join("\n")
        when Array
          "**#{key}:**\n" + render_hash_array_value(key, value, sibling_columns)
        else
          "**#{key}:** #{value}"
        end
      end

      def render_hash_array_value(key, value, sibling_columns)
        if POSITIONAL_ROW_KEYS.include?(key.to_s) && sibling_columns && !sibling_columns.empty?
          render_positional_table(value, sibling_columns)
        else
          render_array(value)
        end
      end

      # Build a Markdown table from positional row data + a columns header.
      # Handles both Array<Array> (multi-column rows) and flat scalar arrays
      # (pluck with a single column — Rails collapses the result).
      def render_positional_table(rows, columns)
        return '_(empty)_' if rows.empty?

        header_row(columns) + rows.map { |row| row_line(positional_row_values(row)) }.join
      end

      def positional_row_values(row)
        row.is_a?(Array) ? row : [row]
      end

      def header_row(keys)
        "| #{keys.join(' | ')} |\n| #{keys.map { '---' }.join(' | ')} |\n"
      end

      def row_line(values)
        "| #{values.join(' | ')} |\n"
      end

      def stringify_array(value)
        value.is_a?(Array) ? value.map(&:to_s) : nil
      end
    end

    # JSON passthrough renderer for backward compatibility.
    # Delegates to MCP::Renderers::JsonRenderer for consistent JSON output.
    class JsonConsoleRenderer < MCP::Renderers::JsonRenderer
    end
  end
end
