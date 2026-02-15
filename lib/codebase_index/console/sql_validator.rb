# frozen_string_literal: true

# @see CodebaseIndex
module CodebaseIndex
  class Error < StandardError; end unless defined?(CodebaseIndex::Error)

  module Console
    class SqlValidationError < CodebaseIndex::Error; end

    # Validates SQL strings for read-only safety.
    #
    # Allows only SELECT and WITH...SELECT statements. Rejects DML (INSERT,
    # UPDATE, DELETE), DDL (CREATE, DROP, ALTER, TRUNCATE), and administrative
    # commands (GRANT, REVOKE). Also rejects multiple statements (semicolons).
    #
    # Uses pattern-based validation, not full SQL parsing.
    #
    # @example
    #   validator = SqlValidator.new
    #   validator.validate!('SELECT * FROM users')         # => true
    #   validator.validate!('DELETE FROM users')            # => raises SqlValidationError
    #   validator.valid?('SELECT 1')                       # => true
    #
    class SqlValidator
      # Forbidden statement prefixes (case-insensitive).
      FORBIDDEN_KEYWORDS = %w[
        INSERT UPDATE DELETE DROP ALTER TRUNCATE CREATE GRANT REVOKE
      ].freeze

      # Allowed statement prefixes (case-insensitive).
      ALLOWED_PREFIXES = /\A\s*(SELECT|WITH|EXPLAIN)\b/i

      # @return [true]
      # @raise [SqlValidationError] if the SQL is not a safe read-only statement
      def validate!(sql) # rubocop:disable Naming/PredicateMethod
        raise SqlValidationError, 'SQL is empty' if sql.nil? || sql.strip.empty?

        normalized = sql.strip

        # Reject multiple statements (semicolons not inside string literals)
        if contains_multiple_statements?(normalized)
          raise SqlValidationError, 'Rejected: multiple statements are not allowed'
        end

        # Check for forbidden keywords at statement start
        check_forbidden_keywords!(normalized)

        # Must start with an allowed prefix
        unless normalized.match?(ALLOWED_PREFIXES)
          raise SqlValidationError, 'Rejected: SQL must start with SELECT, WITH, or EXPLAIN'
        end

        true
      end

      # Check if SQL is valid without raising.
      #
      # @param sql [String] SQL string to validate
      # @return [Boolean]
      def valid?(sql)
        validate!(sql)
        true
      rescue SqlValidationError
        false
      end

      private

      # Check if the SQL contains multiple statements separated by semicolons.
      # Ignores semicolons inside single-quoted string literals.
      #
      # @param sql [String]
      # @return [Boolean]
      def contains_multiple_statements?(sql)
        # Strip single-quoted strings to avoid false positives
        stripped = sql.gsub(/'[^']*'/, '')
        stripped.include?(';')
      end

      # Check if the SQL starts with a forbidden keyword.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a forbidden keyword is found
      def check_forbidden_keywords!(sql)
        FORBIDDEN_KEYWORDS.each do |keyword|
          if sql.match?(/\A\s*#{keyword}\b/i)
            raise SqlValidationError, "Rejected: #{keyword} statements are not allowed"
          end
        end
      end
    end
  end
end
