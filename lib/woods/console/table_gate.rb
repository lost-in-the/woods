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
    # Five entry points match how Console tools arrive at tables:
    # - #check_sql!(sql)                    — for console_sql; extracts every
    #   FROM/JOIN identifier including ANSI-89 comma-joins, ignoring content
    #   inside PG dollar-quoted literals.
    # - #check_model!(name)                 — for model-based tools.
    # - #check_table!(name)                 — direct check.
    # - #check_joins!(model, joins)         — for console_query joins.
    # - #check_association!(model, assoc)   — for console_association_count.
    #
    # @example
    #   gate = TableGate.new(
    #     blocked_tables: %w[authorizations],
    #     model_tables: { 'Authorization' => 'authorizations', 'User' => 'users' },
    #     model_reflections: { 'User' => { 'authorizations' => 'authorizations' } }
    #   )
    #   gate.check_sql!('SELECT * FROM users, authorizations')  # raises TableGateError
    #   gate.check_joins!('User', [:authorizations])            # raises TableGateError
    #
    class TableGate # rubocop:disable Metrics/ClassLength
      # Matches a JOIN token followed by its target identifier. ANSI-89
      # comma joins are handled separately — see FROM_CLAUSE.
      JOIN_REFERENCE = /
        \bJOIN\s+
        (?:
          `(?<backtick>[^`]+)` |
          "(?<double>[^"]+)"   |
          (?<bare>\w+(?:\.\w+)?)
        )
      /xi

      # Matches a FROM clause and captures its body up to the next clause
      # terminator. The body may be a single table, a comma-joined list, or
      # a parenthesized subquery.
      FROM_CLAUSE = /
        \bFROM\s+
        (?<clause>.+?)
        (?=
          \b(?:WHERE|GROUP|HAVING|ORDER|LIMIT|OFFSET|UNION|INTERSECT|EXCEPT|
               JOIN|INNER|OUTER|LEFT|RIGHT|FULL|CROSS)\b
          | [;)]
          | \z
        )
      /xim

      # Matches a leading table identifier at the start of a FROM-list chunk.
      LEAD_IDENT = /
        \A
        (?:
          `(?<backtick>[^`]+)` |
          "(?<double>[^"]+)"   |
          (?<bare>\w+(?:\.\w+)?)
        )
      /xi

      # @param blocked_tables [Array<String>] table names to block (case-insensitive).
      # @param model_tables [Hash{String=>String}] model name => table name.
      # @param model_reflections [Hash{String=>Hash{String=>String}}]
      #   model name => { association_name => target_table }. Used by
      #   #check_joins! and #check_association! to resolve association names
      #   before consulting the block list.
      def initialize(blocked_tables:, model_tables:, model_reflections: {})
        @blocked = Array(blocked_tables).to_set { |t| t.to_s.downcase }
        @model_tables = model_tables || {}
        @model_reflections = model_reflections || {}
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
        check_join_tokens!(stripped)
        check_from_clauses!(stripped)
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

      # Resolve each join name through the model's reflection map and reject
      # any that target a blocked table. Unknown association names pass
      # through — executor-side validation catches them later.
      #
      # @param model_name [String, Symbol] Source model for the query.
      # @param joins [Array<String, Symbol>, nil] Association names being joined.
      # @raise [TableGateError] if any join's target table is blocked.
      def check_joins!(model_name, joins) # rubocop:disable Naming/PredicateMethod,Metrics/CyclomaticComplexity
        return true unless active?
        return true if joins.nil? || Array(joins).empty?

        reflections = @model_reflections[model_name.to_s]
        return true unless reflections

        Array(joins).each do |join|
          table = reflections[join.to_s]
          next if table.nil?
          raise TableGateError, reject_message(table) if blocked?(table)
        end
        true
      end

      # Resolve a single association name against the model's reflection map.
      #
      # @param model_name [String, Symbol] Source model.
      # @param association [String, Symbol, nil] Association name.
      # @raise [TableGateError] if the association's target table is blocked.
      def check_association!(model_name, association) # rubocop:disable Naming/PredicateMethod
        return true unless active?
        return true if association.nil?

        reflections = @model_reflections[model_name.to_s]
        return true unless reflections

        table = reflections[association.to_s]
        return true if table.nil?
        raise TableGateError, reject_message(table) if blocked?(table)

        true
      end

      private

      def blocked?(raw)
        @blocked.include?(strip_schema(raw).downcase)
      end

      # Match every JOIN token and reject blocked targets.
      def check_join_tokens!(sql)
        sql.scan(JOIN_REFERENCE) do
          match = Regexp.last_match
          raw = match[:backtick] || match[:double] || match[:bare]
          raise TableGateError, reject_message(raw) if blocked?(raw)
        end
      end

      # Walk every FROM clause, split on top-level commas, and reject blocked
      # targets in any position of an ANSI-89 comma-joined table list.
      def check_from_clauses!(sql)
        sql.scan(FROM_CLAUSE) do
          clause = Regexp.last_match[:clause]
          split_top_level_commas(clause).each do |chunk|
            raw = lead_identifier(chunk)
            next unless raw
            raise TableGateError, reject_message(raw) if blocked?(raw)
          end
        end
      end

      # Split a comma-separated list at depth 0, skipping commas inside parens.
      def split_top_level_commas(clause) # rubocop:disable Metrics/MethodLength
        depth = 0
        buf = +''
        parts = []
        clause.each_char do |ch|
          case ch
          when '('
            depth += 1
            buf << ch
          when ')'
            depth -= 1
            buf << ch
          when ','
            if depth.zero?
              parts << buf
              buf = +''
            else
              buf << ch
            end
          else
            buf << ch
          end
        end
        parts << buf unless buf.strip.empty?
        parts
      end

      # Extract the table identifier at the start of a FROM-list chunk.
      def lead_identifier(chunk)
        stripped = chunk.to_s.strip
        return nil if stripped.empty?

        match = LEAD_IDENT.match(stripped)
        return nil unless match

        match[:backtick] || match[:double] || match[:bare]
      end

      # Strip SQL comments, single-quoted string literals, and PG dollar-quoted
      # literals so their contents cannot forge (or hide) a table reference.
      # Dollar-quotes are stripped before single-quotes so stray apostrophes
      # inside a dollar-quoted literal do not confuse the single-quote scanner.
      def strip_noise(sql)
        out = sql.gsub(/--[^\n]*/, '')                  # line comments
        out = out.gsub(%r{/\*.*?\*/}m, '')              # block comments
        out = out.gsub(/\$(\w*)\$.*?\$\1\$/m, "''")     # PG dollar-quoted strings
        out.gsub(/'(?:\\.|[^'])*'/, "''")               # single-quoted strings
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
