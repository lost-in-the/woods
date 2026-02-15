# frozen_string_literal: true

module CodebaseIndex
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
        # @return [Hash] Bridge request
        def console_eval(code:, timeout: DEFAULT_EVAL_TIMEOUT)
          timeout = timeout.clamp(MIN_EVAL_TIMEOUT, MAX_EVAL_TIMEOUT)
          { tool: 'eval', params: { code: code, timeout: timeout } }
        end

        # Read-only SQL execution with validation.
        #
        # @param sql [String] SQL query (must be SELECT or WITH...SELECT)
        # @param validator [SqlValidator] SQL validator instance
        # @param limit [Integer, nil] Optional row limit (max 10000)
        # @return [Hash] Bridge request
        # @raise [SqlValidationError] if SQL is not read-only
        def console_sql(sql:, validator:, limit: nil)
          validator.validate!(sql)
          limit = [limit, MAX_SQL_LIMIT].min if limit
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
        # rubocop:disable Metrics/ParameterLists
        def console_query(model:, select:, joins: nil, group_by: nil, having: nil, order: nil, scope: nil, limit: nil)
          limit = [limit, MAX_QUERY_LIMIT].min if limit
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
        # rubocop:enable Metrics/ParameterLists
      end
    end
  end
end
