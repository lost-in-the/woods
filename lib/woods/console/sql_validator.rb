# frozen_string_literal: true

require 'woods/console/sql_noise_stripper'

# @see Woods
module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Console
    class SqlValidationError < Woods::Error; end

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
      #
      # UNION / INTERSECT / EXCEPT are SQL set operators — any of them can graft
      # a second SELECT onto a validated one, which defeats the "single SELECT"
      # posture even though TableGate still catches references to blocked tables.
      # INTO / COPY are PostgreSQL write vectors that must not appear in read
      # contexts.
      BODY_FORBIDDEN_KEYWORDS = %w[UNION INTERSECT EXCEPT INTO COPY].freeze

      # Dangerous functions that can be used for DoS or file access.
      DANGEROUS_FUNCTIONS = %w[
        pg_sleep lo_import lo_export pg_read_file pg_write_file
        load_file sleep benchmark
      ].freeze

      # Allowed statement prefixes (case-insensitive).
      ALLOWED_PREFIXES = /\A\s*(SELECT|WITH|EXPLAIN)\b/i

      # Frozen map of forbidden keyword => regex matching the keyword at statement start.
      # Used by {#check_forbidden_keywords!} and {#check_forbidden_keywords_in_body!}.
      FORBIDDEN_PREFIX_REGEXES = FORBIDDEN_KEYWORDS.to_h do |kw|
        [kw, /\A\s*#{kw}\b/i]
      end.freeze

      # Frozen map of forbidden body keyword => regex matching the keyword anywhere.
      # Used by {#check_body_forbidden_keywords!}.
      BODY_FORBIDDEN_REGEXES = BODY_FORBIDDEN_KEYWORDS.to_h do |kw|
        [kw, /\b#{kw}\b/i]
      end.freeze

      # Frozen map of forbidden keyword => regex matching the keyword anywhere in the body.
      # Used by {#check_forbidden_keywords_in_body!} for the whole-body scan.
      FORBIDDEN_BODY_REGEXES = FORBIDDEN_KEYWORDS.to_h do |kw|
        [kw, /\b#{kw}\b/i]
      end.freeze

      # Frozen map of dangerous function name => regex matching a call to that function.
      # Used by {#check_dangerous_functions!}.
      DANGEROUS_FUNCTION_REGEXES = DANGEROUS_FUNCTIONS.to_h do |func|
        [func, /\b#{func}\s*\(/i]
      end.freeze

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
        stripped = SqlNoiseStripper.strip_comments(sql)
        stripped = SqlNoiseStripper.strip_literals(stripped)
        stripped.include?(';')
      end

      # Check if the SQL starts with a forbidden keyword.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a forbidden keyword is found
      def check_forbidden_keywords!(sql)
        FORBIDDEN_PREFIX_REGEXES.each do |keyword, pattern|
          raise SqlValidationError, "Rejected: #{keyword} statements are not allowed" if sql.match?(pattern)
        end
      end

      # Check if the SQL contains forbidden keywords anywhere in the body.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a forbidden keyword is found
      def check_body_forbidden_keywords!(sql)
        BODY_FORBIDDEN_REGEXES.each do |keyword, pattern|
          raise SqlValidationError, "Rejected: #{keyword} is not allowed" if sql.match?(pattern)
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
        DANGEROUS_FUNCTION_REGEXES.each do |func, pattern|
          raise SqlValidationError, "Rejected: dangerous function #{func} is not allowed" if sql.match?(pattern)
        end
      end

      # Check if the SQL contains forbidden keywords anywhere in the body after stripping comments.
      # This catches comment-hidden injections like "SELECT 1 --;\nDELETE FROM users".
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a forbidden keyword is found
      def check_forbidden_keywords_in_body!(sql)
        stripped = SqlNoiseStripper.strip_comments(sql)

        # Check if any forbidden keyword appears anywhere (not just at start)
        FORBIDDEN_BODY_REGEXES.each do |keyword, body_pattern|
          # Look for keyword as a whole word anywhere in the stripped SQL
          next unless stripped.match?(body_pattern)

          # Make sure it's not at the very start (already checked)
          unless stripped.match?(FORBIDDEN_PREFIX_REGEXES[keyword])
            raise SqlValidationError,
                  "Rejected: #{keyword} statements are not allowed (found in SQL body)"
          end
        end
      end
    end
  end
end
