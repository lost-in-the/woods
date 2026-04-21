# frozen_string_literal: true

require 'set'
require 'woods/console/sql_noise_stripper'

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
      # Matches a JOIN token followed by its target identifier. The
      # identifier may be schema-qualified in any quoting style —
      # `"schema"."table"`, `` `db`.`table` ``, bare `schema.table`, or the
      # mixed `schema."table"` / `` schema.`table` `` forms — and the
      # optional schema prefix is captured separately so #blocked? can
      # compare against either the bare or qualified configured form.
      # An optional `ONLY` keyword (PostgreSQL inheritance opt-out) is
      # consumed before the identifier so it does not hide the table name.
      # ANSI-89 comma joins are handled separately — see FROM_CLAUSE.
      JOIN_REFERENCE = /
        \b(?:STRAIGHT_)?JOIN\s+
        (?:ONLY\s+)?
        (?:
          (?:
            `(?<jschema_bt>[^`]+)` |
            "(?<jschema_dq>[^"]+)" |
            (?<jschema_bare>\w+)
          )
          \.
        )?
        (?:
          `(?<backtick>[^`]+)` |
          "(?<double>[^"]+)"   |
          (?<bare>\w+(?:\.\w+)?)
        )
      /xi

      # Matches a FROM clause and captures its body up to the next clause
      # terminator. The body may be a single table or a comma-joined list.
      #
      # An inner `FROM` is also a terminator — this is H-3 of the bypass
      # series. Without it, a FROM-clause subquery like
      # `FROM (SELECT * FROM blocked) AS a` would be swallowed by the outer
      # clause's `.+?` match, and the inner `FROM blocked` would never be
      # re-scanned because `.scan` advances past consumed input. Treating
      # every `FROM` as its own independent scan match is what keeps CTEs,
      # UNIONs, and nested subqueries in coverage.
      FROM_CLAUSE = /
        \bFROM\s+
        (?<clause>.+?)
        (?=
          \b(?:WHERE|GROUP|HAVING|ORDER|LIMIT|OFFSET|UNION|INTERSECT|EXCEPT|
               STRAIGHT_JOIN|JOIN|INNER|OUTER|LEFT|RIGHT|FULL|CROSS|FROM)\b
          | [;)]
          | \z
        )
      /xim

      # Matches a leading table identifier at the start of a FROM-list chunk.
      # The identifier may carry an optional schema prefix in any quoting
      # style — `"schema"."table"`, `` `db`.`table` ``, or the mixed
      # `schema."table"` / `` schema.`table` `` form — captured separately so
      # #blocked? can match against bare or qualified configured forms.
      LEAD_IDENT = /
        \A
        (?:
          (?:
            `(?<schema_bt>[^`]+)` |
            "(?<schema_dq>[^"]+)" |
            (?<schema_bare>\w+)
          )
          \.
        )?
        (?:
          `(?<backtick>[^`]+)` |
          "(?<double>[^"]+)"   |
          (?<bare>\w+(?:\.\w+)?)
        )
      /xi

      # PostgreSQL ONLY keyword that appears between FROM and the table
      # identifier. Strip it so the lead-identifier regex sees the table
      # directly. Anchored with `\A` because callers strip leading
      # whitespace first via #strip.
      ONLY_PREFIX = /\AONLY\s+/i

      # @param blocked_tables [Array<String>] table names to block
      #   (case-insensitive). Bare names (`"authorizations"`) match every
      #   schema; schema-qualified entries (`"audit.authorizations"`) only
      #   match references that carry the same schema prefix.
      # @param model_tables [Hash{String=>String}] model name => table name.
      # @param model_reflections [Hash{String=>Hash{String=>String}}]
      #   model name => { association_name => target_table }. Used by
      #   #check_joins! and #check_association! to resolve association names
      #   before consulting the block list.
      def initialize(blocked_tables:, model_tables:, model_reflections: {})
        @blocked_bare = Set.new
        @blocked_qualified = Set.new
        Array(blocked_tables).each do |entry|
          name = entry.to_s.downcase
          next if name.empty?

          name.include?('.') ? @blocked_qualified << name : @blocked_bare << name
        end
        @model_tables = model_tables || {}
        @model_reflections = model_reflections || {}
      end

      # @return [Boolean] whether the gate has any tables to enforce.
      def active?
        !(@blocked_bare.empty? && @blocked_qualified.empty?)
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

      # Schema-qualified configured entries (e.g., `audit.authorizations`)
      # match the incoming identifier verbatim, so a reference to
      # `public.authorizations` is *not* blocked. Bare configured entries
      # match every schema by comparing the schema-stripped form, preserving
      # the original wildcard semantics.
      def blocked?(raw)
        name = raw.to_s.downcase
        return true if @blocked_qualified.include?(name)

        @blocked_bare.include?(strip_schema(name))
      end

      # Match every JOIN token and reject blocked targets. When a quoted
      # schema prefix is present (e.g., `"audit"."authorizations"`) the
      # full qualified name is passed to #blocked? so a configured entry
      # like `audit.authorizations` matches verbatim, while #strip_schema
      # still falls back to the bare table name for bare configured entries.
      def check_join_tokens!(sql)
        sql.scan(JOIN_REFERENCE) do
          match = Regexp.last_match
          raw = qualified_identifier(match)
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

      # Extract the table identifier at the start of a FROM-list chunk,
      # joining a schema prefix to the table when both are present. The
      # PostgreSQL `ONLY` inheritance keyword is stripped first so it does
      # not hide the table.
      def lead_identifier(chunk)
        stripped = chunk.to_s.strip.sub(ONLY_PREFIX, '')
        return nil if stripped.empty?

        match = LEAD_IDENT.match(stripped)
        return nil unless match

        qualified_identifier(match)
      end

      # Combine a schema prefix with the table identifier captured by
      # JOIN_REFERENCE / LEAD_IDENT into a single `schema.table` string.
      # The match is expected to expose the schema via either the
      # `jschema_*` (JOIN_REFERENCE) or `schema_*` (LEAD_IDENT) named
      # captures — bare, backtick, and double-quote forms are all merged
      # into one schema slot. A pre-merged `schema.table` bare identifier
      # arrives intact through the `:bare` capture and needs no joining.
      def qualified_identifier(match)
        table = match[:backtick] || match[:double] || match[:bare]
        schema = match.named_captures.values_at(
          'schema_bt', 'schema_dq', 'schema_bare',
          'jschema_bt', 'jschema_dq', 'jschema_bare'
        ).compact.first
        schema ? "#{schema}.#{table}" : table
      end

      # Strip SQL comments, single-quoted string literals, and PG dollar-quoted
      # literals so their contents cannot forge (or hide) a table reference.
      # Delegates to {SqlNoiseStripper} for the actual stripping logic.
      # MySQL backslash-escape (`\'`) is handled by the `:mysql` dialect.
      def strip_noise(sql)
        out = SqlNoiseStripper.strip_comments(sql)
        SqlNoiseStripper.strip_literals(out, dialect: :mysql)
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
