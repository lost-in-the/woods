# frozen_string_literal: true

module Woods
  module MCP
    # Response scope is independent of traversal evidence and page selection.
    module TraversalResponse
      COVERAGE = {
        scope: 'published_relationships',
        source_references: 'not_exhaustive',
        notice: 'Graph coverage: published relationships only. Arbitrary method-body constant references ' \
                'are not exhaustively captured; missing relationships do not prove no callers or dependencies.'
      }.freeze

      def self.annotate(result)
        return if result[:found] == false

        result[:graph_coverage] = COVERAGE
        result[:total_is_exact] = !result[:partial]
      end
    end
  end
end
