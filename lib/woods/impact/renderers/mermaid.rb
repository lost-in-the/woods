# frozen_string_literal: true

require_relative 'text'

module Woods
  module Impact
    module Renderers
      # Serializes only recorded witness relationships; each node is keyed by
      # endpoint, generation and actual typed identity. No graph is inferred.
      class Mermaid
        MAX_NODES = 60 # includes the visible report-coverage note
        MAX_EDGES = 120

        # @param data [Hash] validated version 1 report
        def initialize(data)
          @data = data
          @nodes = {}
          @edges = []
          @truncated = false
        end

        # @return [String] Mermaid flowchart LR; arrows show outward impact
        def render
          seed_changed
          @data.fetch('affected').each { |item| affected(item) }
          lines = header
          @nodes.each_value { |item| lines << "n#{item['number']}[\"#{Text.mermaid(item['label'])}\"]" }
          @edges.each { |source, target, via| lines << "n#{source} -->|\"#{Text.mermaid(via)}\"| n#{target}" }
          lines << '%% Truncated: node or edge display budget reached; see JSON.' if @truncated
          lines << '%% No changed or affected units recorded; this does not establish no impact.' if @nodes.empty?
          "#{lines.join("\n")}\n"
        end

        # @return [Boolean] whether {#render} dropped nodes or edges at the display budget
        def truncated?
          @truncated
        end

        private

        def header
          state = @data.fetch('coverage')['complete'] ? 'Declared complete report' : 'Incomplete report'
          lines = ['flowchart LR', "%% #{state}; #{@data['unknowns'].size} unknown records",
                   '%% Arrows point from changed targets toward affected dependents; witnesses are not exhaustive.']
          note = "#{state}; #{@data['unknowns'].size} unknown records"
          note += '; Truncated display; see JSON' if @truncated
          lines << "report_summary[\"#{Text.mermaid(note)}\"]"
          lines
        end

        def seed_changed
          if @data.dig('parameters', 'mode') == 'focus'
            context = { 'endpoint' => 'to', 'generation' => @data.fetch('endpoint')['generation'] }
            @data.fetch('focus').each { |item| node(item, context, 'focus') }
          end
          @data.fetch('changed').each do |item|
            side = item['status'] == 'removed' ? 'from' : 'to'
            context = { 'endpoint' => side, 'generation' => @data.fetch('range').dig(side, 'generation') }
            node(item, context, "changed: #{item['status']}")
          end
        end

        def affected(item)
          node(item, item, 'affected')
          Array(item['paths']).each do |path|
            unless path.values_at('endpoint', 'generation') == item.values_at('endpoint', 'generation')
              raise ArgumentError, 'Impact witness context differs from affected endpoint'
            end

            Array(path['edges']).each { |edge| relationship(edge, path) }
          end
        end

        def relationship(edge, context)
          return if clipped_edges?

          source = node(edge.fetch('target'), context, 'witness')
          target = node(edge.fetch('source'), context, 'witness')
          return if source.nil? || target.nil?

          entry = [source, target, edge['via'] || 'relationship unavailable']
          @edges << entry unless @edges.include?(entry)
        end

        def clipped_edges?
          return false if @edges.size < MAX_EDGES

          @truncated = true
        end

        def node(identity, context, status)
          key = context.values_at('endpoint', 'generation') + identity.values_at('identifier', 'type')
          return @nodes[key]['number'] if @nodes.key?(key)

          if @nodes.size >= MAX_NODES - 1
            @truncated = true
            return nil
          end

          number = @nodes.size
          label = "#{Text.identity(identity)} | #{Text.context(context)} | #{status}"
          @nodes[key] = { 'number' => number, 'label' => label }
          number
        end
      end
    end
  end
end
