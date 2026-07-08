# frozen_string_literal: true

module Woods
  module SvelteFlow
    # Renders a scoped subgraph payload (as produced by {SubgraphScoper#payload})
    # as a Mermaid `erDiagram` string — a text output that renders inline in
    # GitHub, Markdown, and chat, so an agent can hand back a diagram without a
    # file or a server.
    #
    # Edge orientation note: our association edges are oriented FK-holder → PK
    # (source holds the foreign key), so every association is a many-to-one
    # FK→PK relationship regardless of whether Rails declared it `belongs_to` or
    # `has_many`; the macro is preserved as the edge label. Join-table
    # (`has_and_belongs_to_many`) is many-to-many; generic code edges render as
    # a dashed, non-identifying relationship.
    class MermaidRenderer
      # Mermaid crow's-foot cardinality by relationship, keyed on the (FK→PK)
      # orientation our edges already carry.
      ASSOCIATION_CARDINALITY = {
        'has_and_belongs_to_many' => '}o--o{',
        'has_one' => '||--||'
      }.freeze
      DEFAULT_ASSOCIATION_CARDINALITY = '}o--||'
      GENERIC_CARDINALITY = '}o..o{'

      # @param payload [Hash] { 'nodes' => [...], 'edges' => [...] }
      # @return [String] A Mermaid erDiagram document
      def render(payload)
        lines = ['erDiagram']
        (payload['nodes'] || []).each { |node| lines.concat(entity_lines(node)) }
        (payload['edges'] || []).each { |edge| lines << relationship_line(edge) }
        "#{lines.join("\n")}\n"
      end

      private

      # Entity block for a node: model columns become attributes; other unit
      # types get an empty block so isolated nodes still appear.
      #
      # @param node [Hash]
      # @return [Array<String>]
      def entity_lines(node)
        name = safe_name(node['id'])
        columns = node.dig('data', 'columns') || []
        return ["  #{name} {", '  }'] if columns.empty?

        ["  #{name} {"] + columns.map { |col| "    #{attribute_line(col)}" } + ['  }']
      end

      # A single attribute line: `type name PK|FK`.
      #
      # @param col [Hash]
      # @return [String]
      def attribute_line(col)
        type = safe_token(col['type']).then { |t| t.empty? ? 'string' : t }
        constraint = if col['primary'] then ' PK'
                     elsif col['foreign'] then ' FK'
                     else ''
                     end
        "#{type} #{safe_token(col['name'])}#{constraint}"
      end

      # @param edge [Hash]
      # @return [String]
      def relationship_line(edge)
        via = edge.dig('data', 'via')
        cardinality = if edge['type'] == 'association'
                        ASSOCIATION_CARDINALITY[via] || DEFAULT_ASSOCIATION_CARDINALITY
                      else
                        GENERIC_CARDINALITY
                      end
        label = via || 'depends_on'
        "  #{safe_name(edge['source'])} #{cardinality} #{safe_name(edge['target'])} : \"#{label}\""
      end

      # Mermaid entity names must be alphanumeric/underscore. Map `::` to `__`
      # (reversible-ish) and any other non-word char to `_`.
      #
      # @param identifier [String]
      # @return [String]
      def safe_name(identifier)
        identifier.to_s.gsub('::', '__').gsub(/[^A-Za-z0-9_]/, '_')
      end

      # Attribute names/types: strip anything outside a safe token set.
      #
      # @param value [Object]
      # @return [String]
      def safe_token(value)
        value.to_s.gsub(/[^A-Za-z0-9_]/, '_')
      end
    end
  end
end
