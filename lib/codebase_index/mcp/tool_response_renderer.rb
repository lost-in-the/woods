# frozen_string_literal: true

module CodebaseIndex
  module MCP
    # Base class for rendering MCP tool responses in different output formats.
    #
    # Subclasses implement tool-specific render methods (render_lookup, render_search, etc.)
    # and a render_default fallback. The dispatch uses convention: tool name maps to method name.
    #
    # @example
    #   renderer = ToolResponseRenderer.for(:markdown)
    #   renderer.render(:lookup, unit_data)
    #
    class ToolResponseRenderer
      VALID_FORMATS = %i[claude markdown plain json].freeze

      # Factory method to build the appropriate renderer for a format.
      #
      # @param format [Symbol] One of :claude, :markdown, :plain, :json
      # @return [ToolResponseRenderer] A renderer instance
      # @raise [ArgumentError] if format is unknown
      def self.for(format)
        require_relative 'renderers/markdown_renderer'
        require_relative 'renderers/claude_renderer'
        require_relative 'renderers/plain_renderer'
        require_relative 'renderers/json_renderer'

        case format
        when :claude   then Renderers::ClaudeRenderer.new
        when :markdown then Renderers::MarkdownRenderer.new
        when :plain    then Renderers::PlainRenderer.new
        when :json     then Renderers::JsonRenderer.new
        else raise ArgumentError, "Unknown format: #{format.inspect}. Valid: #{VALID_FORMATS.inspect}"
        end
      end

      # Render a tool response. Dispatches to render_<tool_name> if defined,
      # otherwise falls back to render_default.
      #
      # @param tool_name [Symbol, String] The tool name
      # @param data [Object] The tool result data
      # @param opts [Hash] Additional rendering options
      # @return [String] Rendered response text
      def render(tool_name, data, **opts)
        method_name = :"render_#{tool_name}"
        if respond_to?(method_name, true)
          send(method_name, data, **opts)
        else
          render_default(data)
        end
      end

      # Default rendering — subclasses must implement.
      #
      # @param data [Object] The data to render
      # @return [String] Rendered text
      def render_default(data)
        raise NotImplementedError, "#{self.class}#render_default must be implemented"
      end

      private

      # Fetch a value from a hash by symbol or string key, falling back to a default.
      #
      # Handles data hashes that may use either symbol or string keys (e.g., data
      # assembled from JSON parsing vs. direct Hash literals).
      #
      # @param data [Hash] The source hash
      # @param key [Symbol, String] The key to look up
      # @param default [Object] Value to return when key is absent (default: nil)
      # @return [Object]
      def fetch_key(data, key, default = nil)
        data[key.to_sym] || data[key.to_s] || default
      end
    end
  end
end
