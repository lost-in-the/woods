# frozen_string_literal: true

require 'woods/console/sql_noise_stripper'
require 'woods/console/sql_table_scanner'

module Woods
  module Console
    # Refuse SQLite-specific syntax outside the scanner's supported grammar.
    # This is a conservative read boundary, not a general-purpose SQL parser.
    module SqliteReadGuard
      SIMPLE_IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      UNSUPPORTED_SYNTAX = /[^\x00-\x7F]|\$|\[|''\s*\(|\b(?:FROM|JOIN)(?=['"`(])/i
      QUOTED_IDENTIFIER = /"(?:[^"]|"")*"|`(?:[^`]|``)*`/

      # @param sql [String] SQL to execute on SQLite
      # @raise [SqlValidationError] when an identifier or table factor cannot be checked
      # @return [void]
      def self.validate!(sql)
        view = SqlNoiseStripper.strip_noise(sql, dialect: :sqlite)
        refuse! if view.match?(UNSUPPORTED_SYNTAX)
        view.scan(QUOTED_IDENTIFIER) { |quoted| refuse! unless quoted[1...-1].match?(SIMPLE_IDENTIFIER) }
        SqlTableScanner.relation_factors(view).each do |factor|
          refuse! unless supported_factor?(factor.strip)
        end
      end

      # A SELECT/WITH subquery has its own independently scanned table factors.
      # Parenthesized table groups and string-quoted names are refused rather
      # than silently omitted from the blocked-table scan.
      def self.supported_factor?(factor)
        return true if factor.match?(/\A\(\s*(?:SELECT|WITH)\b/i)

        match = SqlTableScanner::LEAD_IDENT.match(factor)
        match && factor[match.end(0)..].match?(/\A(?:\s|,|\)|\z)/)
      end
      private_class_method :supported_factor?

      def self.refuse!
        raise SqlValidationError,
              'Rejected: unsupported SQLite identifier or table-reference syntax. ' \
              'Use simple bare or double-quoted identifiers and SELECT subqueries.'
      end
      private_class_method :refuse!
    end
  end
end
