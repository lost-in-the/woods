# frozen_string_literal: true

module Woods
  module Console
    # Bundles the three Console response-safety layers the Server threads
    # through every tool definition:
    #
    # - Layer 1 (TableGate)          — reject tool calls that touch blocked tables.
    # - Layer 2 (CredentialScanner)  — redact credential-shaped substrings in the
    #                                  final response tree, regardless of where they arrived.
    # - Layer 3 (SafeContext)        — operator-configured column + EAV redaction.
    #
    # All three are optional. `build` returns nil when every layer is absent so
    # callers can skip the wiring entirely.
    #
    # Ordering (applied in Server#send_to_bridge, after the bridge responds):
    #   Layer 3 (columns/EAV) -> Layer 2 (credential scan) -> response emitted.
    # Layer 1 runs earlier, before tool dispatch.
    ResponseContext = Struct.new(:safe_ctx, :table_gate, :credential_scanner, keyword_init: true) do
      # @return [ResponseContext, nil] nil when every layer is absent.
      def self.build(safe_ctx: nil, table_gate: nil, credential_scanner: nil)
        return nil if safe_ctx.nil? && (table_gate.nil? || !table_gate.active?) && credential_scanner.nil?

        new(safe_ctx: safe_ctx, table_gate: table_gate, credential_scanner: credential_scanner)
      end
    end
  end
end
