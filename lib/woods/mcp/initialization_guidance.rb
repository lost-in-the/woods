# frozen_string_literal: true

module Woods
  module MCP
    # Short, client-neutral instructions for initialize and modern discovery.
    # Only tool registration shapes the text: readiness and retrieval can
    # change after startup, so clients must consult live status before use.
    module InitializationGuidance
      # Contract budget for all supported wiring combinations, tested at build.
      MAX_BYTES = 2048

      WORKFLOW = <<~TEXT
        Start with woods_status: check index readiness, generation freshness and relevant type counts before relying on results.
        For exact names, discover identifiers with search (prefer literal exact_prefix/exact_suffix), then inspect with lookup. For conceptual questions, check retrieval mode and data in woods_status before codebase_retrieve; structural readiness alone is insufficient. Otherwise use search and lookup.
        Follow dependencies or dependents at depth 1 or 2; narrow types and via before paging. Respect partial results and limits: a missing match is not proof of absence, and a partial traversal does not establish every dependent or leaf.
        Verify important conclusions against current source and tests. Recorded relationships and inferred downstream impact do not prove runtime execution or test coverage.
        Registration does not authorize extraction, configuration changes, or live Console access. Use only the tools registered here and operate within the user's authorized scope.
      TEXT

      # @param tool_names [Array<String>] actual names after conditional registration
      # @return [String] stable instructions, without index data or provider calls
      def self.for(tool_names)
        "#{WORKFLOW}Registered tools: #{tool_names.sort.join(', ')}"
      end
    end
  end
end
