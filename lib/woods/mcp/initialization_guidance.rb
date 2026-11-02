# frozen_string_literal: true

module Woods
  module MCP
    # Short, client-neutral instructions for initialize and modern discovery.
    #
    # The text leads with the identity of the served index (checkout, branch,
    # generation, writer build) and any mismatch with the launch checkout or
    # this build, read once at startup from `generation.json` and the
    # manifest. Otherwise only tool registration shapes it: readiness and
    # retrieval can change after startup, so clients must consult live status
    # before use.
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
      # @param identity [ServedIdentity, nil] the served index at startup
      # @return [String] instructions, without provider calls
      def self.for(tool_names, identity: nil)
        rest = "#{WORKFLOW}Registered tools: #{tool_names.sort.join(', ')}"
        "#{fit(identity_lines(identity), MAX_BYTES - rest.bytesize)}#{rest}"
      end

      # Long paths and several warnings can outgrow the budget; the full
      # identity is always in woods_status.
      TRUNCATED = "... (truncated; see woods_status identity)\n"

      # @param text [String]
      # @param budget [Integer] bytes available
      # @return [String]
      def self.fit(text, budget)
        return text if text.bytesize <= budget

        keep = [budget - TRUNCATED.bytesize, 0].max
        "#{text.byteslice(0, keep).scrub('')}#{TRUNCATED}"
      end

      # @param identity [ServedIdentity, nil]
      # @return [String] identity line plus warnings, or empty
      def self.identity_lines(identity)
        return '' unless identity

        lines = [identity.summary]
        lines.concat(identity.warnings.map { |warning| "WARNING: #{warning}" })
        lines << 'The generation can advance while connected; woods_status reports the current one.'
        "#{lines.join("\n")}\n"
      end
    end
  end
end
