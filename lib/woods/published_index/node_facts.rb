# frozen_string_literal: true

module Woods
  class PublishedIndex
    # The per-unit summaries a generation's graph nodes carry (#837), read
    # without opening any unit: which units list unresolved renders and which
    # actions publish facts. {PublishedIndex#units_with} answers through it;
    # a reader that already holds the raw graph calls {.call} directly and
    # does not parse the graph again.
    module NodeFacts
      # Fact name => [graph node key, the key it is answered under].
      FACTS = { unresolved_renders: %w[unresolved_render_count count],
                action_facts: %w[fact_actions actions] }.freeze

      # @param graph [Hash] raw dependency graph data
      # @param fact [Symbol, String] a key of {FACTS}
      # @return [Array<Hash>, nil] `{ 'identifier', 'type', count|actions }`
      #   sorted by identifier and type; nil when the writer did not summarise
      # @raise [ArgumentError] for a fact outside {FACTS}
      def self.call(graph, fact)
        node_key, answer_key = FACTS.fetch(fact.to_sym) do
          raise ArgumentError, "Unknown node fact #{fact.inspect}; known: #{FACTS.keys.join(', ')}"
        end
        return nil unless Array(graph['node_facts']).include?(node_key)

        entries = records(graph).filter_map do |identifier, node|
          value = node[node_key]
          { 'identifier' => identifier, 'type' => node['type'].to_s, answer_key => value } if present?(value)
        end
        entries.sort_by { |entry| entry.values_at('identifier', 'type') }
      end

      # @return [Array<Array(String, Hash)>] primary nodes and variants
      def self.records(graph)
        primary = (graph['nodes'] || {}).select { |_, node| node.is_a?(Hash) }.to_a
        variants = Array(graph['variants']).select { |record| record.is_a?(Hash) && record['identifier'] }
        primary + variants.map { |record| [record['identifier'], record] }
      end

      # @return [Boolean] a count above zero or a non-empty list
      def self.present?(value)
        value.is_a?(Integer) ? value.positive? : Array(value).any?
      end
    end
  end
end
