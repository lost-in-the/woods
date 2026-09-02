# frozen_string_literal: true

module Woods
  module Console
    module Tools
      # Tier 4: Guarded tools requiring confirmation or SQL validation.
      #
      # - `console_eval` — Arbitrary Ruby execution with confirmation + timeout
      # - `console_sql` — Read-only SQL (validated by SqlValidator)
      # - `console_query` — Enhanced query builder with joins/grouping
      #
      # Each method builds a bridge request hash. The bridge executes against
      # the live Rails environment.
      #
      module Tier4
        MAX_EVAL_TIMEOUT = 30
        MIN_EVAL_TIMEOUT = 1
        DEFAULT_EVAL_TIMEOUT = 10
        MAX_SQL_LIMIT = 10_000
        MAX_QUERY_LIMIT = 10_000

        module_function

        # Arbitrary Ruby evaluation with timeout.
        #
        # @param code [String] Ruby code to execute
        # @param timeout [Integer] Execution timeout in seconds (default 10, max 30)
        # @param guard [#check!, nil] Optional EvalGuard instance. When present,
        #   the payload is parsed and refused before the bridge request is
        #   built — surfacing credential/reflection escapes as a clean MCP
        #   error instead of relying on the bridge's own enforcement.
        # @return [Hash] Bridge request
        # @raise [Woods::Console::ForbiddenExpressionError] if guard rejects
        def console_eval(code:, timeout: DEFAULT_EVAL_TIMEOUT, guard: nil)
          guard&.check!(code)
          timeout = timeout.clamp(MIN_EVAL_TIMEOUT, MAX_EVAL_TIMEOUT)
          { tool: 'eval', params: { code: code, timeout: timeout } }
        end

        # Read-only SQL execution.
        #
        # SQL validation belongs to whoever knows the host's dialect. The
        # embedded executor re-validates with `SqlValidator.new(dialect:
        # sql_dialect)` from the live adapter and raises
        # {Woods::Console::SqlValidationError}, so the registered handler
        # passes no validator: a handler-stage `SqlValidator.new` is the
        # conservative postgres+mysql union, and on a MySQL host its
        # PostgreSQL view of `\'` rejected dialect-valid statements before the
        # executor could accept them (CON-2). `validator:` stays available for
        # callers that own their own gate — the bridge path, and specs that
        # exercise the validator in isolation.
        #
        # @param sql [String] SQL query (must be SELECT or WITH...SELECT)
        # @param validator [SqlValidator, nil] Optional pre-dispatch validator.
        #   Leave nil to let the executor validate with the adapter's dialect.
        # @param limit [Integer, nil] Optional row limit (max 10000)
        # @return [Hash] Bridge request
        # @raise [SqlValidationError] if a validator was supplied and refuses
        def console_sql(sql:, validator: nil, limit: nil)
          validator&.validate!(sql)
          { tool: 'sql', params: { sql: sql, limit: limit }.compact }
        end

        # Enhanced query builder with joins and grouping.
        #
        # @param model [String] Model name
        # @param select [Array<String>] Columns to select
        # @param joins [Array<String>, nil] Associations to join
        # @param group_by [Array<String>, nil] Columns to group by
        # @param having [String, nil] HAVING clause
        # @param order [Hash, nil] Order specification (e.g., { id: :desc })
        # @param scope [Hash, nil] Filter conditions
        # @param limit [Integer, nil] Row limit (max 10000)
        # @return [Hash] Bridge request
        # rubocop:disable-next Metrics/ParameterLists
        def console_query(model:, select:, joins: nil, group_by: nil, having: nil, order: nil, scope: nil, limit: nil)
          {
            tool: 'query',
            params: {
              model: model,
              select: select,
              joins: joins,
              group_by: group_by,
              having: having,
              order: order,
              scope: scope,
              limit: limit
            }.compact
          }
        end
      end
    end
  end
end
