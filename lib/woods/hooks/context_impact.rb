# frozen_string_literal: true

module Woods
  module Hooks
    # Resolve one unambiguous edited identity, then reuse the bounded graph walk.
    class ContextImpact
      MAX_NODES = 50_000

      def initialize(reader, renderer)
        @reader = reader
        @renderer = renderer
      end

      def call(path, generation, freshness)
        graph = @reader.raw_graph_data
        roots = roots_for(graph, path)
        header = "Woods candidates from generation #{generation} (pre-refresh snapshot; " \
                 "source freshness: #{freshness}). Changed path: #{JSON.generate(path)}."
        return unresolved(header, roots) unless roots.size == 1

        root = roots.first
        traversal = @reader.traverse_dependents(root.fetch('identifier'), depth: 2, explain: true, max_nodes: 10,
                                                                          max_edges: 100)
        @renderer.context(header, rows_for(traversal), partial: !!traversal[:partial])
      end

      private

      def rows_for(traversal)
        rows = traversal.fetch(:explanation).fetch(:witnesses).filter_map do |_identifier, witness|
          next if witness[:impact] == 'root'

          edge = traversal[:explanation][:edges].fetch(witness.fetch(:edge_id))
          evidence_row(edge, witness)
        end
        rows << 'No candidate found within this bounded snapshot; verify manually with dependents.' if rows.empty?
        rows
      end

      def roots_for(graph, path)
        records = records_for(graph)
        matching = records.select { |node| node['file_path'] == path }
        identities = matching.map { |node| node.slice('identifier', 'type') }.uniq
        return identities if identities.size != 1

        # A recorded edge target does not identify which same-named type it means.
        records.select { |node| node['identifier'] == identities.first['identifier'] }
               .map { |node| node.slice('identifier', 'type') }.uniq
      end

      def unresolved(header, roots)
        reason = roots.empty? ? 'unresolved changed path' : 'ambiguous changed identity'
        rows = roots.first(10).map { |root| "#{root['identifier']} (#{root['type']})" }
        @renderer.context("#{header} #{reason}; verify with search and typed lookup.", rows, partial: true)
      end

      def evidence_row(edge, witness)
        source = edge.fetch(:source)
        target = edge.fetch(:target)
        target_type = target[:type] || "ambiguous/unknown #{Array(target[:candidate_types]).join(',')}"
        test_hint = source[:type] == 'test_mapping' ? '; test suggestion' : ''
        uncertain = witness[:typed_path_complete] ? '' : '; typed path incomplete'
        "#{witness[:impact]} candidate: #{source[:identifier]} (#{source[:type]}) " \
          "--via=#{edge[:via] || 'unknown'}--> #{target[:identifier]} (#{target_type})#{test_hint}#{uncertain}"
      end

      def records_for(graph)
        nodes = graph.fetch('nodes')
        variants = graph.fetch('variants', [])
        raise ArgumentError unless nodes.is_a?(Hash) && variants.is_a?(Array)
        raise ArgumentError if nodes.size + variants.size > MAX_NODES

        nodes.map { |identifier, node| node.merge('identifier' => identifier) } + variants
      end
    end
  end
end
