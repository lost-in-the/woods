# frozen_string_literal: true

module Woods
  module MCP
    # Short, client-neutral instructions for initialize and modern discovery.
    #
    # The text leads with any warning about the served index (a mismatch
    # with the client's checkout or this build), then its identity
    # (checkout, branch, generation, writer build), read once at startup
    # from `generation.json` and the manifest. Otherwise only tool registration shapes it: readiness and
    # retrieval can change after startup, so clients must consult live status
    # before use.
    module InitializationGuidance
      # Contract budget for all supported wiring combinations, tested at build.
      MAX_BYTES = 2048

      WORKFLOW = <<~TEXT
        Start with woods_status: check index readiness, generation freshness and relevant type counts before relying on results.
        For exact names, discover identifiers with search (prefer literal exact_prefix/exact_suffix), then inspect with lookup. For conceptual questions, check retrieval mode and data in woods_status before codebase_retrieve; structural readiness alone is insufficient. Otherwise use search and lookup.
        Follow dependencies or dependents at depth 1 or 2; narrow types and via before paging. For how one unit reaches another, use path. Respect partial results and limits: a missing match is not proof of absence, and a partial traversal does not establish every dependent or leaf.
        Verify important conclusions against current source and tests. Recorded relationships and inferred downstream impact do not prove runtime execution or test coverage.
        Registration does not authorize extraction, configuration changes, or access to live application data. Use only the tools registered here and operate within the user's authorized scope.
      TEXT

      # @param tool_names [Array<String>] actual names after conditional registration
      # @param identity [ServedIdentity, nil] the served index at startup
      # @param awaiting [String, nil] the index directory, when the server
      #   started before any index was published there
      # @return [String] instructions, without provider calls
      def self.for(tool_names, identity: nil, awaiting: nil)
        rest = "#{WORKFLOW}Registered tools: #{tool_names.sort.join(', ')}"
        "#{fit(identity_parts(identity, awaiting), MAX_BYTES - rest.bytesize)}#{rest}"
      end

      # @param index_dir [String, nil]
      # @return [String]
      def self.awaiting_line(index_dir)
        return '' unless index_dir

        "No index was published in #{index_dir} when this server started. Until one is, every tool but " \
          "woods_status answers a retryable `building` result; woods_status says what the server is waiting for.\n"
      end

      # Long paths and several warnings can outgrow the budget; the full
      # identity is always in woods_status.
      TRUNCATED = "... (truncated; see woods_status identity)\n"

      # Bytes a shortened line keeps before {TRUNCATED}.
      MIN_KEPT_BYTES = 60

      # Lines in display order: identity warnings first, then the summary,
      # the awaiting line and the generation note. Each carries the rank it
      # is shortened in when over budget: the generation note first
      # (dropped), then the summary, then the awaiting line, and warnings
      # last, the final one first.
      #
      # @param identity [ServedIdentity, nil]
      # @param awaiting [String, nil]
      # @return [Array<Array(String, Integer)>]
      def self.identity_parts(identity, awaiting)
        parts = []
        warnings = identity ? identity.warnings : []
        warnings.each_with_index { |warning, index| parts << ["WARNING: #{warning}\n", 3 + warnings.size - index] }
        parts << ["#{identity.summary}\n", 1] if identity
        parts << [awaiting_line(awaiting), 2] if awaiting
        parts << ["The generation can advance while connected; woods_status reports the current one.\n", 0] if identity
        parts
      end

      # @param parts [Array<Array(String, Integer)>] from {.identity_parts}
      # @param budget [Integer] bytes available
      # @return [String]
      def self.fit(parts, budget)
        texts = parts.map(&:first)
        over = texts.sum(&:bytesize) - budget
        parts.each_index.sort_by { |index| parts[index].last }.each do |index|
          break if over <= 0

          text = texts[index]
          kept = parts[index].last.zero? ? 0 : [text.bytesize - over - TRUNCATED.bytesize, MIN_KEPT_BYTES].max
          shortened = kept.zero? ? '' : "#{text.byteslice(0, kept).scrub('')}#{TRUNCATED}"
          next if shortened.bytesize >= text.bytesize

          over -= text.bytesize - shortened.bytesize
          texts[index] = shortened
        end
        texts.join
      end
    end
  end
end
