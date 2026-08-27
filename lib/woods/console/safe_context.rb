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
    # - Statement timeout cannot leak to the next pool consumer: PostgreSQL
    #   uses `SET LOCAL`, which self-discards at transaction end; MySQL has
    #   no LOCAL equivalent, so its session-scoped `max_execution_time` is
    #   read before the override and restored in an `ensure` instead
    # - Column redaction replaces sensitive values with "[REDACTED]"
    #
    # == What SafeContext does NOT cover
    #
    # The rolled-back transaction is a strong guardrail but not absolute.
    # Known escape paths — callers of {#execute} should assume anything
    # below is effectively live:
    # - `ActiveJob` / `ActionMailer` async deliveries. Earlier versions
    #   tried to swap the global queue_adapter/delivery_method to `:test`
    #   for the block's duration, but those settings are process-wide
    #   class state: in a Puma worker serving both the host app and the
    #   Console MCP, a concurrent host request would briefly see the
    #   test adapter and silently drop real jobs / mail. We now leave
    #   them alone — treat callback-triggered enqueues / deliveries as
    #   live.
    # - `after_rollback` callbacks (fire on rollback, can still enqueue
    #   jobs or call external services).
    # - `Thread.new` / `Fiber.new` inside the block — they lease a fresh
    #   connection outside the transaction.
    # - Direct HTTP egress (Net::HTTP, Faraday, HTTP gem, ...).
    # - File I/O / shell-outs initiated from within AR callbacks.
    # - Writes through a different pool or shard than the one this
    #   SafeContext was built with.
    # - `raw_connection.execute` on some adapters when the adapter's
    #   transaction bookkeeping is out-of-band.
    #
    # Treat SafeContext as "rolls back the database", not "prevents every
    # side effect" — operators must still apply the upstream defenses
    # (TableGate, SqlValidator, EvalGuard, BearerAuth).
    #
    # Two construction modes are supported:
    #
    # - `connection:` — wraps the supplied connection in a single-use pool
    #   adapter so the execution path is identical to the `pool:` form.
    #   Useful in tests and for callers that already manage their own
    #   connection lifecycle (e.g. bridge mode, `exe/woods-console`).
    # - `pool:` — each call to {#execute} leases a fresh connection via
    #   `pool.with_connection { |c| ... }`, so the connection is returned
    #   to the pool immediately after the block. The leased connection is
    #   also exposed via `Thread.current[:woods_console_leased_connection]`
    #   so dispatch handlers (e.g. EmbeddedExecutor#active_connection) can
    #   reuse the same connection without re-leasing.
    #
    # In both forms the connection is resolved *per {#execute} call* —
    # SafeContext never holds a connection ivar. This is the key invariant
    # for multi-DB / sharded hosts: if you supply a shard pool (or shard
    # connection), the rolled-back transaction is opened on that shard's
    # connection, not on the default pool.
    #
    # @example connection: form
    #   ctx = SafeContext.new(connection: conn, timeout_ms: 5000, redacted_columns: %w[ssn])
    #   ctx.execute { |c| c.execute("SELECT count(*) FROM users") }
    #
    # @example pool: form (per-request lease)
    #   ctx = SafeContext.new(pool: ActiveRecord::Base.connection_pool)
    #   ctx.execute { |c| c.select_all("SELECT count(*) FROM users") }
    #
    # @example Shard pool — rollback covers the shard
    #   shard_pool = ShardedModel.connection_pool
    #   ctx = SafeContext.new(pool: shard_pool)
    #   ctx.execute { |c| c.select_all("SELECT * FROM shard_table") }
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
      # Thread-local key that exposes the connection currently leased for
      # the in-flight #execute block. Handlers should prefer this over
      # acquiring their own connection so every request stays on a single
      # leased connection inside the rolled-back transaction.
      LEASED_CONNECTION_KEY = :woods_console_leased_connection

      # Thin adapter that makes a bare connection look like a connection pool
      # with a `with_connection` interface. Used internally when callers pass
      # `connection:` so that {#execute} always flows through a single code
      # path regardless of construction form.
      #
      # @api private
      SingleConnectionPool = Struct.new(:connection) do
        # @yield [Object] the wrapped connection
        def with_connection(&block)
          block.call(connection)
        end
      end

      # @return [Array<String>] Column names whose values are replaced with "[REDACTED]"
      attr_reader :redacted_columns

      # @return [Array<Hash>] Normalized EAV redaction patterns. Each entry has
      #   string keys: 'key_column', 'value_column', 'sensitive_keys'.
      attr_reader :redacted_key_values

      # @param connection [Object, nil] Database connection (or mock).
      #   Mutually exclusive with `pool:` — pass one or the other (or
      #   neither, if this SafeContext is only being used for #redact).
      #   The connection is wrapped in {SingleConnectionPool} so execution
      #   always flows through `pool.with_connection`.
      # @param pool [#with_connection, nil] Connection pool to lease from
      #   per request. Each {#execute} call wraps `pool.with_connection`.
      # @param timeout_ms [Integer] Statement timeout in milliseconds
      # @param redacted_columns [Array<String>] Column names whose values should be redacted
      # @param redacted_key_values [Array<Hash>] EAV-style redaction patterns.
      #   Each pattern: {key_column: 'key', value_column: 'value',
      #   sensitive_keys: %w[stripe_access_token ...]}. When a row's
      #   `key_column` cell matches one of `sensitive_keys`, the same row's
      #   `value_column` cell is replaced with "[REDACTED]".
      def initialize(connection: nil, pool: nil, timeout_ms: 5000,
                     redacted_columns: [], redacted_key_values: [])
        @pool = pool || (connection && SingleConnectionPool.new(connection))
        @timeout_ms = timeout_ms
        @redacted_columns = redacted_columns.map(&:to_s)
        @redacted_key_values = normalize_key_value_patterns(redacted_key_values)
      end

      # Execute a block within a rolled-back transaction with statement timeout.
      #
      # The transaction is always rolled back to ensure read-only behavior.
      # A fresh connection is leased from the pool on every call via
      # `pool.with_connection`. The leased connection is published as
      # `Thread.current[LEASED_CONNECTION_KEY]` for the duration of the
      # block and cleared in `ensure` (even on exceptions) so dispatch
      # handlers can pick it up without re-leasing.
      #
      # @yield [connection] The database connection
      # @return [Object] The block's return value
      # @raise [ArgumentError] when neither `connection:` nor `pool:` was
      #   supplied at construction time. Deferred to #execute so callers
      #   that only use #redact can construct with neither.
      def execute(&block)
        raise ArgumentError, 'SafeContext#execute requires connection: or pool: at construction time' unless @pool

        # NOTE: on async side effects: earlier iterations of SafeContext
        # tried to swap `ActiveJob::Base.queue_adapter` / `ActionMailer::Base
        # .delivery_method` to `:test` for the duration of this block.
        # That's unsafe — those settings are process-wide class state, so
        # any concurrent request served by the SAME Puma worker (the host
        # app running alongside the Console MCP) would race and briefly
        # see the test adapter, silently dropping real jobs and mail.
        # The gap is documented in the class docstring instead; operators
        # must treat callback-triggered enqueues / deliveries as live.
        @pool.with_connection { |conn| run_with_timeout(conn, &block) }
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

      # Wrap one connection in a rolled-back transaction with timeout, and
      # publish it via Thread.current so handlers can reuse it. Always
      # clears the thread-local in ensure so a raise mid-block cannot leak
      # a stale connection reference into the next request on this thread.
      def run_with_timeout(connection)
        previous_lease = Thread.current[LEASED_CONNECTION_KEY]
        Thread.current[LEASED_CONNECTION_KEY] = connection
        result = nil
        connection.transaction do
          restore_timeout = set_timeout(connection)
          begin
            result = yield(connection)
          ensure
            restore_timeout&.call
          end
          raise ActiveRecord::Rollback
        end
        result
      ensure
        Thread.current[LEASED_CONNECTION_KEY] = previous_lease
      end

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
      # PostgreSQL uses `SET LOCAL statement_timeout` so the setting is
      # scoped to the surrounding transaction and is automatically
      # discarded on rollback — without LOCAL the timeout would persist on
      # the pooled connection and bleed into the next consumer (host app
      # request, background job, etc.). Safe here because every #execute
      # is wrapped in a transaction.
      #
      # MySQL has no per-statement equivalent of `SET LOCAL`: `SET
      # max_execution_time` (applies to SELECT only — DDL and DML statements
      # cannot be time-limited via this variable) is SESSION scope and
      # survives ROLLBACK, so left alone it would leak onto the next request
      # served from the same pooled connection. {#set_mysql_timeout} reads
      # the session's current value first and returns a Proc that restores
      # it; the caller runs that Proc in an +ensure+ around the yielded
      # block.
      #
      # @return [Proc, nil] a restore callback for MySQL, or nil when no
      #   restoration is needed (PostgreSQL's LOCAL scope self-discards; an
      #   unsupported adapter sets nothing to restore).
      def set_timeout(connection, timeout_ms = @timeout_ms)
        adapter = connection.adapter_name.downcase
        if adapter.include?('mysql')
          set_mysql_timeout(connection, timeout_ms)
        else
          connection.execute("SET LOCAL statement_timeout = '#{timeout_ms.to_i}ms'")
          nil
        end
      rescue StandardError => e
        # Unsupported adapter (SQLite, Trilogy on unsupported version, Oracle) —
        # timeout enforcement is best-effort, but operators need to know their
        # rollback fence is narrower than advertised. Log once per adapter via
        # Rails.logger when available; otherwise swallow as before.
        warn_timeout_unsupported(adapter, e)
        nil
      end

      # Read MySQL's current session-scoped `max_execution_time`, override
      # it, and return a Proc that restores the value read here. There is no
      # per-statement `SET LOCAL` on MySQL, so the override otherwise
      # outlives this transaction's rollback and bleeds onto whatever the
      # pooled connection serves next.
      #
      # @return [Proc] restores the previous session value
      def set_mysql_timeout(connection, timeout_ms)
        previous_value = connection.select_value('SELECT @@SESSION.max_execution_time').to_i
        connection.execute("SET max_execution_time = #{timeout_ms.to_i}")
        -> { connection.execute("SET max_execution_time = #{previous_value}") }
      end

      def warn_timeout_unsupported(adapter, error)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        @warned_adapters ||= {}
        return if @warned_adapters[adapter]

        @warned_adapters[adapter] = true
        Rails.logger.warn(
          '[Woods::Console::SafeContext] statement timeout not supported on ' \
          "adapter #{adapter.inspect}: #{error.class}: #{error.message}. " \
          'Queries will run without a per-statement time limit.'
        )
      rescue StandardError
        # Last-resort swallow — never let telemetry failure break execution.
      end
    end
  end
end
