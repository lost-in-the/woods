# frozen_string_literal: true

require 'woods/console/sql_noise_stripper'

# @see Woods
module Woods
  module Console
    # Extracts table and schema-qualified identifiers from a SQL string.
    #
    # Handles both JOIN-style and ANSI-89 comma-join syntax across MySQL and
    # PostgreSQL quoting styles (`backtick`, `"double"`, bare). Schema-qualified
    # identifiers (`schema.table`, `"schema"."table"`, `` `db`.`table` ``) are
    # returned as `schema.table` strings so callers can compare against either
    # the bare or qualified form.
    #
    # Noise (comments, string literals, dollar-quoted bodies) is stripped via
    # {SqlNoiseStripper} before scanning so that identifiers embedded in literal
    # content are never surfaced.
    #
    # All methods are module-level and stateless — pass a SQL string in, receive
    # an array of identifier strings out.
    #
    # @example
    #   SqlTableScanner.identifiers_in('SELECT * FROM users JOIN orders ON ...')
    #   # => ["users", "orders"]
    #
    #   SqlTableScanner.identifiers_in('SELECT * FROM "audit"."events"')
    #   # => ["audit.events"]
    #
    module SqlTableScanner # rubocop:disable Metrics/ModuleLength
      # Matches a JOIN token followed by its target identifier. The identifier
      # may be schema-qualified in any quoting style — `"schema"."table"`,
      # `` `db`.`table` ``, bare `schema.table`, or the mixed
      # `schema."table"` / `` schema.`table` `` forms — and the optional
      # schema prefix is captured separately so callers can compare against
      # either the bare or qualified configured form. An optional `ONLY`
      # keyword (PostgreSQL inheritance opt-out) is consumed before the
      # identifier so it does not hide the table name. ANSI-89 comma joins
      # are handled separately — see FROM_CLAUSE.
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
      # callers can match against bare or qualified configured forms.
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
      # directly. Anchored with `\A` because callers strip leading whitespace
      # first via #strip.
      ONLY_PREFIX = /\AONLY\s+/i

      # Returns every table/schema-qualified identifier referenced in the SQL
      # string. Noise (comments, string literals, dollar-quoted bodies) is
      # stripped before scanning. Both JOIN-style and ANSI-89 comma-join syntax
      # are handled.
      #
      # Literals are stripped under BOTH supported dialects and the scans
      # unioned. This scanner backs TableGate, so it may over-detect but must
      # never under-detect: stripping with the wrong dialect's escape rules
      # can swallow a real FROM clause — e.g. MySQL's `\'` escape applied on
      # a PostgreSQL host (where backslash is literal under
      # standard_conforming_strings) folds `'x\' FROM blocked WHERE y = '`
      # into one literal, hiding `blocked` from the gate while PostgreSQL
      # genuinely reads that table.
      #
      # @param sql [String, nil] the SQL string to scan
      # @return [Array<String>] identifiers in first-encounter order, deduplicated
      def self.identifiers_in(sql)
        return [] if sql.nil? || sql.empty?

        results = []
        %i[postgres mysql].each do |dialect|
          stripped = strip_noise(sql, dialect: dialect)
          collect_join_identifiers(stripped, results)
          collect_from_identifiers(stripped, results)
        end
        results.uniq
      end

      # @api private
      # Comments and literals must be stripped in a single combined pass —
      # stripping them separately lets a comment marker inside a literal
      # (`'-- '`) hide a real FROM clause from the gate. See
      # {SqlNoiseStripper.strip_noise}.
      def self.strip_noise(sql, dialect:)
        SqlNoiseStripper.strip_noise(sql, dialect: dialect)
      end
      private_class_method :strip_noise

      # @api private
      def self.collect_join_identifiers(sql, results)
        sql.scan(JOIN_REFERENCE) do
          match = Regexp.last_match
          results << qualified_identifier(match)
        end
      end
      private_class_method :collect_join_identifiers

      # @api private
      def self.collect_from_identifiers(sql, results)
        sql.scan(FROM_CLAUSE) do
          clause = Regexp.last_match[:clause]
          split_top_level_commas(clause).each do |chunk|
            ident = lead_identifier(chunk)
            results << ident if ident
          end
        end
      end
      private_class_method :collect_from_identifiers

      # @api private
      # Split a comma-separated list at depth 0, skipping commas inside parens.
      def self.split_top_level_commas(clause) # rubocop:disable Metrics/MethodLength
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
      private_class_method :split_top_level_commas

      # @api private
      # Extract the table identifier at the start of a FROM-list chunk,
      # joining a schema prefix to the table when both are present. The
      # PostgreSQL `ONLY` inheritance keyword is stripped first so it does
      # not hide the table.
      def self.lead_identifier(chunk)
        stripped = chunk.to_s.strip.sub(ONLY_PREFIX, '')
        return nil if stripped.empty?

        match = LEAD_IDENT.match(stripped)
        return nil unless match

        qualified_identifier(match)
      end
      private_class_method :lead_identifier

      # @api private
      # Combine a schema prefix with the table identifier captured by
      # JOIN_REFERENCE / LEAD_IDENT into a single `schema.table` string.
      def self.qualified_identifier(match)
        table = match[:backtick] || match[:double] || match[:bare]
        schema = match.named_captures.values_at(
          'schema_bt', 'schema_dq', 'schema_bare',
          'jschema_bt', 'jschema_dq', 'jschema_bare'
        ).compact.first
        schema ? "#{schema}.#{table}" : table
      end
      private_class_method :qualified_identifier
    end
  end
end
