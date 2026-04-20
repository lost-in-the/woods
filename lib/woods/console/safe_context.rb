# frozen_string_literal: true

# Stub for environments that don't load ActiveRecord
unless defined?(ActiveRecord::Rollback)
  module ActiveRecord
    class Rollback < StandardError; end
  end
end

module Woods
  module Console
    # Wraps tool execution in a rolled-back transaction with statement timeout.
    #
    # Safety layers:
    # - Every query runs inside a transaction that is always rolled back
    # - Statement timeout prevents runaway queries
    # - Column redaction replaces sensitive values with "[REDACTED]"
    #
    # @example
    #   ctx = SafeContext.new(connection: conn, timeout_ms: 5000, redacted_columns: %w[ssn])
    #   ctx.execute { |c| c.execute("SELECT count(*) FROM users") }
    #
    # @example Key-value (EAV) redaction
    #   ctx = SafeContext.new(
    #     connection: conn,
    #     redacted_key_values: [
    #       { key_column: 'key', value_column: 'value',
    #         sensitive_keys: %w[stripe_access_token oauth_token] }
    #     ]
    #   )
    #
    class SafeContext
      # @return [Array<String>] Column names whose values are replaced with "[REDACTED]"
      attr_reader :redacted_columns

      # @return [Array<Hash>] Normalized EAV redaction patterns. Each entry has
      #   string keys: 'key_column', 'value_column', 'sensitive_keys'.
      attr_reader :redacted_key_values

      # @param connection [Object] Database connection (or mock)
      # @param timeout_ms [Integer] Statement timeout in milliseconds
      # @param redacted_columns [Array<String>] Column names whose values should be redacted
      # @param redacted_key_values [Array<Hash>] EAV-style redaction patterns.
      #   Each pattern: {key_column: 'key', value_column: 'value',
      #   sensitive_keys: %w[stripe_access_token ...]}. When a row's
      #   `key_column` cell matches one of `sensitive_keys`, the same row's
      #   `value_column` cell is replaced with "[REDACTED]".
      def initialize(connection:, timeout_ms: 5000, redacted_columns: [], redacted_key_values: [])
        @connection = connection
        @timeout_ms = timeout_ms
        @redacted_columns = redacted_columns.map(&:to_s)
        @redacted_key_values = normalize_key_value_patterns(redacted_key_values)
      end

      # Execute a block within a rolled-back transaction with statement timeout.
      #
      # The transaction is always rolled back to ensure read-only behavior.
      #
      # @yield [connection] The database connection
      # @return [Object] The block's return value
      def execute
        result = nil
        @connection.transaction do
          set_timeout
          result = yield(@connection)
          raise ActiveRecord::Rollback
        end
        result
      end

      # Replace values of redacted columns with "[REDACTED]".
      #
      # Runs column-name redaction first, then EAV key-value redaction — a row
      # like {key: "stripe_access_token", value: "sk_live_..."} has its `value`
      # column replaced when "stripe_access_token" is in the sensitive_keys
      # list, regardless of whether `value` itself is in redacted_columns.
      #
      # @param hash [Hash] Record attributes
      # @param _model_name [String] Model name (reserved for per-model redaction rules)
      # @return [Hash] Redacted copy of the hash
      def redact(hash, _model_name = nil)
        return hash if @redacted_columns.empty? && @redacted_key_values.empty?

        redacted = hash.transform_keys(&:to_s).each_with_object({}) do |(key, value), out|
          out[key] = @redacted_columns.include?(key) ? '[REDACTED]' : value
        end
        apply_key_value_redaction(redacted)
      end

      private

      def normalize_key_value_patterns(patterns)
        Array(patterns).filter_map { |pattern| normalize_pattern(pattern) }
      end

      def normalize_pattern(pattern)
        key_col = fetch_pattern_string(pattern, :key_column)
        val_col = fetch_pattern_string(pattern, :value_column)
        sensitive = Array(pattern[:sensitive_keys] || pattern['sensitive_keys']).map(&:to_s)
        return if key_col.nil? || val_col.nil? || sensitive.empty?

        { 'key_column' => key_col, 'value_column' => val_col, 'sensitive_keys' => sensitive }
      end

      def fetch_pattern_string(pattern, key)
        (pattern[key] || pattern[key.to_s])&.to_s
      end

      def apply_key_value_redaction(hash)
        @redacted_key_values.each do |pattern|
          key_col = pattern['key_column']
          val_col = pattern['value_column']
          next unless hash.key?(key_col) && hash.key?(val_col)
          next unless pattern['sensitive_keys'].include?(hash[key_col].to_s)

          hash[val_col] = '[REDACTED]'
        end
        hash
      end

      # Set statement timeout on the connection.
      #
      # PostgreSQL uses SET statement_timeout (applies to all statement types).
      # MySQL uses SET max_execution_time (applies to SELECT only — MySQL limitation:
      # DDL and DML statements cannot be time-limited via this variable).
      def set_timeout(connection = @connection, timeout_ms = @timeout_ms)
        adapter = connection.adapter_name.downcase
        if adapter.include?('mysql')
          connection.execute("SET max_execution_time = #{timeout_ms.to_i}")
        else
          connection.execute("SET statement_timeout = '#{timeout_ms.to_i}ms'")
        end
      rescue StandardError
        # Unsupported adapter — timeout enforcement is best-effort
        nil
      end
    end
  end
end
