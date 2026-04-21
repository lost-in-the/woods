# frozen_string_literal: true

require 'singleton'
require_relative 'redactor'

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
    # Exposed as tell-don't-ask commands: {#enforce!}, {#redact}, {#scan}. Callers
    # never need to ask which layers are configured — a {NullResponseContext} is
    # returned from {.build} when every layer is absent, and its commands are
    # no-ops that return their input unchanged.
    #
    # Ordering (applied in Server#send_to_bridge, after the bridge responds):
    #   Layer 3 (columns/EAV) -> Layer 2 (credential scan) -> response emitted.
    # Layer 1 runs earlier, before tool dispatch.
    class ResponseContext
      attr_reader :safe_ctx, :table_gate, :credential_scanner

      # @return [ResponseContext, NullResponseContext] NullResponseContext
      #   when every layer is absent so callers never receive nil.
      def self.build(safe_ctx: nil, table_gate: nil, credential_scanner: nil)
        gate_inactive = table_gate.nil? || !table_gate.active?
        if safe_ctx.nil? && gate_inactive && credential_scanner.nil?
          NullResponseContext.instance
        else
          new(safe_ctx: safe_ctx, table_gate: table_gate, credential_scanner: credential_scanner)
        end
      end

      def initialize(safe_ctx:, table_gate:, credential_scanner:)
        @safe_ctx = safe_ctx
        @table_gate = table_gate
        @credential_scanner = credential_scanner
      end

      # True for real response contexts; false for {NullResponseContext}.
      def present?
        true
      end

      # Run the Layer 1 blocked-table gate against the arguments a tool was
      # invoked with. Tools may arrive at tables through five different
      # arg shapes — SQL string, model name, raw table, joined associations,
      # or a single association name — so the gate checks every variant that's
      # present. A no-op when the gate is nil.
      #
      # @param args [Hash] Tool arguments (symbol keys from MCP dispatch)
      # @raise [TableGateError] if any referenced identifier is blocked
      def enforce!(args) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        return unless @table_gate

        @table_gate.check_sql!(args[:sql]) if args[:sql]
        @table_gate.check_model!(args[:model]) if args[:model]
        @table_gate.check_table!(args[:table]) if args[:table]
        @table_gate.check_joins!(args[:model], args[:joins]) if args[:model] && args[:joins]
        return unless args[:model] && args[:association]

        @table_gate.check_association!(args[:model], args[:association])
      end

      # Apply Layer 3 (column + EAV) redaction to a result value. Shape-aware —
      # see {Redactor.apply} for the supported envelope keys.
      #
      # @param result [Object]
      # @return [Object] Redacted result, same shape as input.
      def redact(result)
        return result unless @safe_ctx

        Redactor.apply(result, @safe_ctx)
      end

      # Run Layer 2 (credential scanner) over a value and return the scanned
      # form alongside any hit counts. Callers decide whether to log the
      # counts — the context deliberately does not assume access to a logger.
      #
      # @param value [Object]
      # @return [Array(Object, Hash)] [scanned_value, counts_by_pattern]
      def scan(value)
        return [value, {}] unless @credential_scanner

        @credential_scanner.scan(value)
      end
    end

    # Null variant returned by {ResponseContext.build} when every layer is
    # absent. Exposes the same public surface so callers never need &.nil-guards.
    class NullResponseContext
      include Singleton

      def present?
        false
      end

      def safe_ctx
        nil
      end

      def table_gate
        nil
      end

      def credential_scanner
        nil
      end

      def enforce!(_args)
        nil
      end

      def redact(result)
        result
      end

      def scan(value)
        [value, {}]
      end
    end
  end
end
