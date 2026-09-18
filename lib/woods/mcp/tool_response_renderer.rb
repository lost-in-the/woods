# frozen_string_literal: true

require_relative 'traversal_evidence_index'
require_relative 'traversal_evidence_text'

module Woods
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

      # Sections of graph_analysis.json in display order. Shared by the
      # graph_analysis tool (enum and pagination) and the text renderers.
      GRAPH_ANALYSIS_SECTIONS = %w[
        orphans dead_ends hubs cycles bridges
        cross_database_edges volatile_dependencies undeclared_package_edges
      ].freeze

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

      def traversal_coverage_lines(data)
        coverage = fetch_key(data, :graph_coverage)
        notice = fetch_key(coverage, :notice) if coverage.is_a?(Hash)
        notice ? [notice] : []
      end

      def traversal_lower_bound_note(data, shown)
        return unless fetch_key(data, :total_is_exact) == false

        total = fetch_key(data, :nodes_total, shown)
        offset = fetch_key(data, :nodes_offset, 0)
        position = offset.positive? ? " from offset #{offset}" : ''
        "Showing #{shown} of at least #{total}#{position} " \
          "(total unknown: #{fetch_key(data, :partial_reason)})."
      end

      def search_completeness_lines(data)
        evidence = fetch_key(data, :completeness)
        return [] unless evidence.is_a?(Hash)

        more = { true => 'yes', false => 'no', nil => 'unknown' }.fetch(fetch_key(evidence, :has_more))
        total = fetch_key(evidence, :total_matches)
        lines = [
          "Search completeness: #{fetch_key(evidence, :status)} (#{fetch_key(evidence, :reason)}).",
          "More matches: #{more}; total matches: #{total.nil? ? 'unknown' : total}; " \
          "matched lower bound: #{fetch_key(evidence, :matched_lower_bound)}."
        ]
        scope = fetch_key(data, :applied_scope)
        if scope
          lines << "Applied scope: packages=#{fetch_key(scope, :packages).inspect}; " \
                   "source_paths=#{fetch_key(scope, :source_paths).inspect}; " \
                   "eligible units=#{fetch_key(scope, :eligible_units)}."
        end
        hint = fetch_key(data, :hint)
        lines << hint if hint
        lines
      end

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
        sym_key = key.to_sym
        str_key = key.to_s
        if data.key?(sym_key)
          data[sym_key]
        elsif data.key?(str_key)
          data[str_key]
        else
          default
        end
      end
    end
  end
end
