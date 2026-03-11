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

      # Keywords that are forbidden anywhere in the SQL (not just at start).
      BODY_FORBIDDEN_KEYWORDS = %w[UNION INTO COPY].freeze

      # Dangerous functions that can be used for DoS or file access.
      DANGEROUS_FUNCTIONS = %w[
        pg_sleep lo_import lo_export pg_read_file pg_write_file
        load_file sleep benchmark
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

        # Check for writable CTEs (before body keywords to give better error messages)
        check_writable_ctes!(normalized)

        # Check for forbidden keywords anywhere in the SQL body
        check_body_forbidden_keywords!(normalized)

        # Check for dangerous functions
        check_dangerous_functions!(normalized)

        # After stripping comments, check again for forbidden keywords that might have been hidden
        check_forbidden_keywords_in_body!(normalized)

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
      # Strips SQL comments and string literals before checking.
      #
      # @param sql [String]
      # @return [Boolean]
      def contains_multiple_statements?(sql)
        # Strip SQL comments before checking
        stripped = sql.gsub(/--[^\n]*/, '') # line comments
        stripped = stripped.gsub(%r{/\*.*?\*/}m, '') # block comments
        # Strip single-quoted strings to avoid false positives
        stripped = stripped.gsub(/'[^']*'/, '')
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

      # Check if the SQL contains forbidden keywords anywhere in the body.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a forbidden keyword is found
      def check_body_forbidden_keywords!(sql)
        BODY_FORBIDDEN_KEYWORDS.each do |keyword|
          raise SqlValidationError, "Rejected: #{keyword} is not allowed" if sql.match?(/\b#{keyword}\b/i)
        end
      end

      # Check if the SQL contains writable CTEs (WITH...DELETE/UPDATE/INSERT).
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a writable CTE is found
      def check_writable_ctes!(sql)
        return unless sql.match?(/WITH\s+\w+\s+AS\s*\(\s*(DELETE|UPDATE|INSERT)\b/i)

        raise SqlValidationError, 'Rejected: writable CTEs are not allowed'
      end

      # Check if the SQL calls dangerous functions.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a dangerous function is found
      def check_dangerous_functions!(sql)
        DANGEROUS_FUNCTIONS.each do |func|
          if sql.match?(/\b#{func}\s*\(/i)
            raise SqlValidationError, "Rejected: dangerous function #{func} is not allowed"
          end
        end
      end

      # Check if the SQL contains forbidden keywords anywhere in the body after stripping comments.
      # This catches comment-hidden injections like "SELECT 1 --;\nDELETE FROM users".
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a forbidden keyword is found
      def check_forbidden_keywords_in_body!(sql)
        # Strip comments to reveal hidden statements
        stripped = sql.gsub(/--[^\n]*/, '') # line comments
        stripped = stripped.gsub(%r{/\*.*?\*/}m, '') # block comments

        # Check if any forbidden keyword appears anywhere (not just at start)
        FORBIDDEN_KEYWORDS.each do |keyword|
          # Look for keyword as a whole word anywhere in the stripped SQL
          next unless stripped.match?(/\b#{keyword}\b/i)

          # Make sure it's not at the very start (already checked)
          unless stripped.match?(/\A\s*#{keyword}\b/i)
            raise SqlValidationError,
                  "Rejected: #{keyword} statements are not allowed (found in SQL body)"
          end
        end
      end
    end
  end
end
