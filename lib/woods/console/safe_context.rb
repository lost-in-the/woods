# frozen_string_literal: true

# Stub for environments that don't load ActiveRecord
unless defined?(ActiveRecord::Rollback)
  module ActiveRecord
    class Rollback < StandardError; end
  end
end

module CodebaseIndex
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
    class SafeContext
      # @param connection [Object] Database connection (or mock)
      # @param timeout_ms [Integer] Statement timeout in milliseconds
      # @param redacted_columns [Array<String>] Column names whose values should be redacted
      def initialize(connection:, timeout_ms: 5000, redacted_columns: [])
        @connection = connection
        @timeout_ms = timeout_ms
        @redacted_columns = redacted_columns.map(&:to_s)
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
      # @param hash [Hash] Record attributes
      # @param _model_name [String] Model name (reserved for per-model redaction rules)
      # @return [Hash] Redacted copy of the hash
      def redact(hash, _model_name = nil)
        return hash if @redacted_columns.empty?

        hash.transform_keys(&:to_s).each_with_object({}) do |(key, value), redacted|
          redacted[key] = @redacted_columns.include?(key) ? '[REDACTED]' : value
        end
      end

      private

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
