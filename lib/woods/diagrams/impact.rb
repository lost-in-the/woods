# frozen_string_literal: true

require_relative 'builder'

module Woods
  module Diagrams
    # A unit's change impact as Woods' impact report draws it
    # ({Woods::Impact::Renderers::Mermaid}): a focus-mode report planned at
    # the reader's own generation, propagated `depth` reverse hops. The
    # renderer's display budget is the limit; a report it would truncate is
    # refused instead, so the caller can lower the depth.
    class Impact < Builder
      KIND = 'impact'
      OPTIONS = [].freeze

      private

      def prepare
        require_relative '../impact/report'
        require_relative '../impact/renderers'
        node = @type ? @source.graph_node(@identifier, type: @type) : @source.graph_node(@identifier)
        raise UnitNotFound, "No unit #{@identifier}#{" of type #{@type}" if @type} in this generation" unless node

        @type ||= node['type'].to_s
        @report = report
        @renderer = Woods::Impact::Renderers.mermaid_renderer(@report)
        @text = @renderer.render.chomp
      end

      # Planned at the reader's own generation; a flat (pre-2.0) index has no
      # number, and the report's resolver refuses it.
      def report
        raise InvalidRequest, 'The impact kind needs the index root' unless @source.index_dir

        at = @source.generation.zero? ? 'now' : "gen:#{@source.generation}"
        Woods::Impact::Report.focus(@source.index_dir, identities: [{ 'identifier' => @identifier, 'type' => @type }],
                                                       at: at, depth: @depth)
      rescue Woods::Impact::ResolutionError => e
        raise InvalidRequest, e.message
      end

      def budget
        Woods::Impact::Renderers::Mermaid::MAX_NODES
      end

      # @return [Integer] typed units in the report: the focus and every affected unit
      def size
        Array(@report.to_h['focus']).size + Array(@report.to_h['affected']).size
      end

      def refusal_text
        return nil unless @renderer.truncated?

        "#{size} units is over the impact diagram budget of #{budget} nodes and " \
          "#{Woods::Impact::Renderers::Mermaid::MAX_EDGES} edges"
      end

      def extra_details
        { 'affected' => Array(@report.to_h['affected']).size,
          'complete' => @report.to_h.dig('coverage', 'complete') == true }
      end

      def mermaid
        @text
      end
    end
  end
end
