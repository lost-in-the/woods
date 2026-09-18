# frozen_string_literal: true

require 'set'

module Woods
  module MCP
    # Retain the paged rows' ancestors once, together with their witness edges
    # and other recorded relationships between visible/context endpoints.
    module TraversalEvidencePage
      def self.apply(result)
        explanation = result[:explanation]
        return result unless explanation

        visible = result.fetch(:nodes).keys.to_set
        witnesses = explanation.fetch(:witnesses)
        needed = ancestors(visible, witnesses)
        page_witnesses = witnesses.slice(*(witnesses.keys & needed.to_a))
        witness_edges = page_witnesses.values.map { |witness| witness[:edge_id] }.compact.to_set
        edges = explanation.fetch(:edges).select do |id, edge|
          source = edge[:source][:identifier]
          target = edge[:target][:identifier]
          witness_edges.include?(id) ||
            (needed.include?(source) && needed.include?(target) && (visible.include?(source) || visible.include?(target)))
        end
        result[:explanation] = explanation.merge(edges: edges, witnesses: page_witnesses.to_h do |identifier, witness|
          [identifier, witness.merge(context: !visible.include?(identifier))]
        end)
        result
      end

      def self.ancestors(visible, witnesses)
        needed = Set.new
        visible.each do |identifier|
          identifier = witnesses.fetch(identifier)[:parent] while identifier && needed.add?(identifier)
        end
        needed
      end
      private_class_method :ancestors
    end
  end
end
