# frozen_string_literal: true

require 'set'

# @see Woods
module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Console
    class TableGateError < Woods::Error; end

    # Layer 1 of the Console defense-in-depth stack: reject requests that
    # touch operator-blocked tables before any data is returned.
    #
    # Unlike column- or row-level redaction, a blocked table short-circuits
    # the entire tool call — there is no partial response for the agent to
    # analyze for leaked material. Use this for tables where the safest
    # answer is "don't look," e.g., an `authorizations` table that stores
    # Stripe OAuth credentials.
    #
    # Three entry points match how Console tools arrive at tables:
    # - #check_sql!(sql)     — for console_sql; extracts FROM/JOIN identifiers
    #   (quote-aware, case-insensitive, schema-qualified).
    # - #check_model!(name)  — for model-based tools; resolves the model via
    #   an injected table registry.
    # - #check_table!(name)  — direct check for callers that already know
    #   the table.
    #
    # @example
    #   gate = TableGate.new(
    #     blocked_tables: %w[authorizations],
    #     model_tables: { 'Authorization' => 'authorizations' }
    #   )
    #   gate.check_sql!('SELECT * FROM authorizations')  # raises TableGateError
    #   gate.check_model!('Authorization')               # raises TableGateError
    #
    class TableGate
      # Matches the identifier after FROM/JOIN. Supports backtick, double-quote,
      # and bare identifiers; schema-qualified names come through the bare branch
      # via `schema.table`.
      TABLE_REFERENCE = /
        \b(?:FROM|JOIN)\s+
        (?:
          `(?<backtick>[^`]+)` |
          "(?<double>[^"]+)"   |
          (?<bare>\w+(?:\.\w+)?)
        )
      /xi

      # @param blocked_tables [Array<String>] table names to block (case-insensitive).
      # @param model_tables [Hash{String=>String}] model name => table name.
      def initialize(blocked_tables:, model_tables:)
        @blocked = Array(blocked_tables).map { |t| t.to_s.downcase }.to_set
        @model_tables = model_tables || {}
      end

      # @return [Boolean] whether the gate has any tables to enforce.
      def active?
        !@blocked.empty?
      end

      # @raise [TableGateError] if the SQL references a blocked table.
      def check_sql!(sql) # rubocop:disable Naming/PredicateMethod
        return true unless active?
        return true if sql.nil? || sql.empty?

        stripped = strip_noise(sql)
        stripped.scan(TABLE_REFERENCE) do
          match = Regexp.last_match
          raw = match[:backtick] || match[:double] || match[:bare]
          raise TableGateError, reject_message(raw) if blocked?(raw)
        end
        true
      end

      # @raise [TableGateError] if the named model's table is on the block list.
      def check_model!(model_name)
        return true unless active?

        table = @model_tables[model_name.to_s]
        return true if table.nil?

        check_table!(table)
      end

      # @raise [TableGateError] if the table name is on the block list.
      def check_table!(table_name) # rubocop:disable Naming/PredicateMethod
        return true unless active?
        return true if table_name.nil? || table_name.to_s.empty?

        raise TableGateError, reject_message(table_name) if blocked?(table_name)

        true
      end

      private

      def blocked?(raw)
        @blocked.include?(strip_schema(raw).downcase)
      end

      # Strip SQL comments and single-quoted string literals so their contents
      # cannot forge (or hide) a table reference.
      def strip_noise(sql)
        out = sql.gsub(/--[^\n]*/, '') # line comments
        out = out.gsub(%r{/\*.*?\*/}m, '')       # block comments
        out.gsub(/'(?:\\.|[^'])*'/, "''")        # empty out string literals
      end

      def strip_schema(raw)
        raw.to_s.split('.').last.to_s
      end

      def reject_message(name)
        "Rejected: table '#{name}' is on console_blocked_tables. " \
          'This tool is gated in Console MCP configuration.'
      end
    end
  end
end
