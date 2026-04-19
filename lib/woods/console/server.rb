# frozen_string_literal: true

require 'mcp'
require_relative 'connection_manager'
require_relative 'model_validator'
require_relative 'safe_context'
require_relative 'tools/tier1'
require_relative 'tools/tier2'
require_relative 'tools/tier3'
require_relative 'tools/tier4'
require_relative 'sql_validator'
require_relative 'audit_logger'
require_relative 'confirmation'
require_relative 'console_response_renderer'

module Woods
  module Console
    # Console MCP Server — queries live Rails application state.
    #
    # Communicates with a bridge process running inside the Rails environment
    # via JSON-lines over stdio. Exposes Tier 1-4 tools (read-only, domain, analytics, guarded) through MCP.
    #
    # @example
    #   server = Woods::Console::Server.build(config: config)
    #   transport = MCP::Server::Transports::StdioTransport.new(server)
    #   transport.open
    #
    module Server # rubocop:disable Metrics/ModuleLength
      TIER1_TOOLS = %w[count sample find pluck aggregate association_count schema recent status].freeze
      TIER2_TOOLS = %w[diagnose_model data_snapshot validate_record check_setting update_setting
                       check_policy validate_with check_eligibility decorate].freeze
      TIER3_TOOLS = %w[slow_endpoints error_rates throughput job_queues job_failures job_find
                       job_schedule redis_info cache_stats channel_status].freeze
      TIER4_TOOLS = %w[eval sql query].freeze

      class << self # rubocop:disable Metrics/ClassLength
        # Build a configured MCP::Server with console tools using the bridge protocol.
        #
        # @param config [Hash] Configuration hash (from YAML or env)
        # @return [MCP::Server] Configured server ready for transport
        def build(config:)
          connection_config = config['console'] || config
          conn_mgr = ConnectionManager.new(config: connection_config)
          redacted_columns = Array(config['redacted_columns'] || connection_config['redacted_columns'])
          redacted_key_values = Array(
            config['redacted_key_values'] || connection_config['redacted_key_values']
          )
          safe_ctx = if redacted_columns.any? || redacted_key_values.any?
                       SafeContext.new(
                         connection: nil,
                         redacted_columns: redacted_columns,
                         redacted_key_values: redacted_key_values
                       )
                     end

          build_server(conn_mgr, safe_ctx)
        end

        # Build a configured MCP::Server using embedded ActiveRecord execution.
        #
        # No bridge process needed — queries run directly via ActiveRecord.
        # Pass the returned server to StdioTransport or StreamableHTTPTransport.
        #
        # @param model_validator [ModelValidator] Validates model/column names
        # @param safe_context [SafeContext] Wraps queries in rolled-back transactions
        # @param redacted_columns [Array<String>] Column names to redact from output
        # @param redacted_key_values [Array<Hash>] EAV redaction patterns. Each pattern:
        #   {key_column:, value_column:, sensitive_keys: []}. See SafeContext for semantics.
        # @param connection [Object, nil] Database connection for adapter detection
        # @param read_tools_enabled [Boolean] Enable sql/query tools in embedded mode (default: false)
        # @return [MCP::Server] Configured server ready for transport
        def build_embedded(model_validator:, safe_context:, redacted_columns: [], # rubocop:disable Metrics/ParameterLists
                           redacted_key_values: [], connection: nil,
                           read_tools_enabled: false)
          require_relative 'embedded_executor'

          executor = EmbeddedExecutor.new(
            model_validator: model_validator, safe_context: safe_context,
            connection: connection, read_tools_enabled: read_tools_enabled
          )
          redact_ctx = if redacted_columns.any? || redacted_key_values.any?
                         SafeContext.new(
                           connection: nil,
                           redacted_columns: redacted_columns,
                           redacted_key_values: redacted_key_values
                         )
                       end

          build_server(executor, redact_ctx)
        end

        # Register Tier 1 read-only tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param safe_ctx [SafeContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier1_tools(server, conn_mgr, safe_ctx = nil, renderer: nil)
          TIER1_TOOLS.each { |tool| send(:"define_#{tool}", server, conn_mgr, safe_ctx, renderer: renderer) }
        end

        # Register Tier 2 domain-aware tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param safe_ctx [SafeContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier2_tools(server, conn_mgr, safe_ctx = nil, renderer: nil)
          TIER2_TOOLS.each { |tool| send(:"define_#{tool}", server, conn_mgr, safe_ctx, renderer: renderer) }
        end

        # Register Tier 3 analytics tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param safe_ctx [SafeContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier3_tools(server, conn_mgr, safe_ctx = nil, renderer: nil)
          TIER3_TOOLS.each { |tool| send(:"define_#{tool}", server, conn_mgr, safe_ctx, renderer: renderer) }
        end

        # Register Tier 4 guarded tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param safe_ctx [SafeContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier4_tools(server, conn_mgr, safe_ctx = nil, renderer: nil)
          TIER4_TOOLS.each { |tool| send(:"define_#{tool}", server, conn_mgr, safe_ctx, renderer: renderer) }
        end

        private

        # Shared server construction used by both build() and build_embedded().
        #
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Any object with send_request(Hash) -> Hash
        # @param safe_ctx [SafeContext, nil] Optional context for column redaction
        # @return [MCP::Server]
        def build_server(conn_mgr, safe_ctx)
          server = ::MCP::Server.new(
            name: 'woods-console',
            version: defined?(Woods::VERSION) ? Woods::VERSION : '0.1.0'
          )

          renderer = build_console_renderer

          register_tier1_tools(server, conn_mgr, safe_ctx, renderer: renderer)
          register_tier2_tools(server, conn_mgr, safe_ctx, renderer: renderer)
          register_tier3_tools(server, conn_mgr, safe_ctx, renderer: renderer)
          register_tier4_tools(server, conn_mgr, safe_ctx, renderer: renderer)
          server
        end

        def respond(text)
          ::MCP::Tool::Response.new([{ type: 'text', text: text }])
        end

        def send_to_bridge(conn_mgr, request, safe_ctx = nil, renderer: nil)
          response = conn_mgr.send_request(request)
          if response['ok']
            result = response['result']
            result = apply_redaction(result, safe_ctx) if safe_ctx
            text = renderer ? renderer.render_default(result) : JSON.pretty_generate(result)
            respond(text)
          else
            error_text = "#{response['error_type']}: #{response['error']}"
            ::MCP::Tool::Response.new(
              [{ type: 'text', text: error_text }],
              error: error_text
            )
          end
        rescue ConnectionError => e
          ::MCP::Tool::Response.new([{ type: 'text', text: "Connection error: #{e.message}" }], error: e.message)
        end

        # Data-shape keys used by console tool responses. When any of these keys
        # appear at the top of a Hash result we treat the value as row data and
        # descend into it instead of redacting at the envelope level. Keeping
        # this list narrow avoids accidentally recursing into schema payloads
        # (e.g. `console_schema` returns {columns: {...}} where `columns` is a
        # Hash of column metadata, not row values).
        DATA_ENVELOPE_KEYS = %w[record records rows values].freeze
        private_constant :DATA_ENVELOPE_KEYS

        # Apply SafeContext column redaction to a result value.
        #
        # Redaction is shape-aware:
        #   - {record: Hash}          (find)         — redact the nested hash
        #   - {records: [Hash]}       (sample, recent) — redact each nested hash
        #   - {columns: [...], rows:   [[...]]}  (sql, query) — positional
        #   - {columns: [...], values: [...|[...]]} (pluck)  — positional
        #   - Plain Hash              — redact top-level keys
        #   - Array<Hash>             — redact each hash
        #
        # @param result [Object] The result from the bridge or embedded executor
        # @param safe_ctx [SafeContext] The context with redacted_columns configured
        # @return [Object] Redacted result, same shape as input
        def apply_redaction(result, safe_ctx)
          case result
          when Array
            result.map { |item| item.is_a?(Hash) ? apply_redaction(item, safe_ctx) : item }
          when Hash
            redact_hash(result, safe_ctx)
          else
            result
          end
        end

        def redact_hash(hash, safe_ctx)
          string_keyed = hash.transform_keys(&:to_s)
          return safe_ctx.redact(string_keyed) unless (string_keyed.keys & DATA_ENVELOPE_KEYS).any?

          plan = positional_plan(string_keyed['columns'], safe_ctx)
          string_keyed.each_with_object({}) do |(key, value), out|
            out[key] = redact_envelope_value(key, value, plan, safe_ctx)
          end
        end

        def redact_envelope_value(key, value, plan, safe_ctx)
          case key
          when 'record'         then value.is_a?(Hash) ? safe_ctx.redact(value) : value
          when 'records'        then redact_hash_array(value, safe_ctx)
          when 'rows', 'values' then redact_positional(value, plan)
          else                       value
          end
        end

        def redact_hash_array(value, safe_ctx)
          Array(value).map { |row| row.is_a?(Hash) ? safe_ctx.redact(row) : row }
        end

        # Precompute everything needed to redact positional rows for a given
        # `columns` header: the column-name mask plus any EAV key-value rules
        # resolved to column indexes. Returns a plain Hash so callers can pass
        # it around without extra struct ceremony.
        def positional_plan(columns, safe_ctx)
          { mask: positional_mask(columns, safe_ctx),
            kv_rules: positional_kv_rules(columns, safe_ctx) }
        end

        # Precompute the positional redaction mask from a `columns` header.
        # Returns nil when there is nothing to redact so callers can short-circuit.
        def positional_mask(columns, safe_ctx)
          return nil unless columns.is_a?(Array)

          redacted = safe_ctx.redacted_columns
          return nil if redacted.empty?

          mask = columns.map { |name| redacted.include?(name.to_s) }
          mask.any? ? mask : nil
        end

        # Resolve EAV patterns against a `columns` header into concrete index
        # pairs. A rule only fires when both key_column and value_column are
        # present in the header, and costs nothing per row otherwise.
        def positional_kv_rules(columns, safe_ctx)
          return [] unless columns.is_a?(Array)

          index = columns.each_with_index.to_h { |name, idx| [name.to_s, idx] }
          safe_ctx.redacted_key_values.filter_map do |pattern|
            key_idx = index[pattern['key_column']]
            val_idx = index[pattern['value_column']]
            next unless key_idx && val_idx

            { key_idx: key_idx, val_idx: val_idx, sensitive: pattern['sensitive_keys'] }
          end
        end

        # Redact positional row data using a precomputed plan. Handles both
        # nested arrays (multi-column pluck, sql/query rows) and flat scalar
        # arrays (pluck with a single column — Rails collapses the result).
        def redact_positional(rows, plan)
          return rows unless rows.is_a?(Array)
          return rows if plan[:mask].nil? && plan[:kv_rules].empty?

          rows.map do |row|
            row.is_a?(Array) ? redact_row(row, plan) : redact_scalar(row, plan[:mask])
          end
        end

        def redact_row(row, plan)
          result = apply_mask(row, plan[:mask])
          plan[:kv_rules].each do |rule|
            result[rule[:val_idx]] = '[REDACTED]' if rule[:sensitive].include?(row[rule[:key_idx]].to_s)
          end
          result
        end

        def apply_mask(row, mask)
          return row.dup unless mask

          row.each_with_index.map { |value, idx| mask[idx] ? '[REDACTED]' : value }
        end

        def redact_scalar(value, mask)
          return value unless mask

          mask.first ? '[REDACTED]' : value
        end

        def build_console_renderer
          format = if Woods.respond_to?(:configuration)
                     Woods.configuration&.context_format || :markdown
                   else
                     :markdown
                   end
          format == :json ? JsonConsoleRenderer.new : ConsoleResponseRenderer.new
        end

        def define_count(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_count', 'Count records matching scope conditions.',
                              properties: {
                                model: str_prop('Model name'),
                                scope: obj_prop('Filter: {status: "paid", total_refund_gt: 0, ' \
                                                'transaction_id_not_null: true}. ' \
                                                'Suffixes: _eq _gt _lt _in _null _present. ' \
                                                'Complex queries: use console_query.')
                              },
                              required: ['model'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier1.console_count(model: args[:model], scope: args[:scope])
          end
        end

        def define_sample(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_sample', 'Random sample of records.',
                              properties: {
                                model: str_prop('Model name'), limit: int_prop('Max records (default 5, max 25)'),
                                columns: arr_prop('Columns to include'),
                                scope: obj_prop('Filter: {status: "paid", amount_gt: 100}. ' \
                                                'Suffixes: _eq _gt _lt _in _null _present. ' \
                                                'Complex queries: use console_query.')
                              }, required: ['model'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier1.console_sample(
              model: args[:model], scope: args[:scope], limit: args[:limit] || 5, columns: args[:columns]
            )
          end
        end

        def define_find(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_find',
                              'Find a single record by primary key or unique column',
                              properties: {
                                model: str_prop('Model name'), id: int_prop('Primary key value'),
                                by: obj_prop('Unique column lookup'),
                                columns: arr_prop('Columns to include')
                              }, required: ['model'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier1.console_find(model: args[:model], id: args[:id], by: args[:by], columns: args[:columns])
          end
        end

        def define_pluck(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_pluck', 'Extract column values from records.',
                              properties: {
                                model: str_prop('Model name'), columns: arr_prop('Column names to pluck'),
                                scope: obj_prop('Filter: {status_in: ["paid","refunded"], amount_gt: 0}. ' \
                                                'Suffixes: _eq _gt _lt _in _null _present. ' \
                                                'Complex queries: use console_query.'),
                                limit: int_prop('Max records (default 100, max 1000)'),
                                distinct: bool_prop('Return unique values only')
                              }, required: %w[model columns], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier1.console_pluck(
              model: args[:model], columns: args[:columns], scope: args[:scope],
              limit: args[:limit] || 100, distinct: args[:distinct] || false
            )
          end
        end

        def define_aggregate(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_aggregate',
                              'Run aggregate function on a column. ' \
                              'count omits column to count all rows. ' \
                              'Supports scope predicates: {status: "paid", total_gt: 0}. ' \
                              'For complex queries use console_query.',
                              properties: {
                                model: str_prop('Model name'),
                                function: str_prop('Aggregate function: sum, average, minimum, maximum, count'),
                                column: str_prop('Column to aggregate (optional for count)'),
                                scope: obj_prop('Filter conditions: {col: val} or predicate suffixes ' \
                                                '(_gt, _lt, _in, _null, etc.)')
                              }, required: %w[model function], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier1.console_aggregate(
              model: args[:model], function: args[:function], column: args[:column], scope: args[:scope]
            )
          end
        end

        def define_association_count(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_association_count',
                              'Count associated records for a specific record.',
                              properties: {
                                model: str_prop('Model name'), id: int_prop('Record primary key'),
                                association: str_prop('Association name'),
                                scope: obj_prop('Filter on association: {status: "paid", amount_gt: 0}. ' \
                                                'Suffixes: _eq _gt _lt _in _null _present. ' \
                                                'Complex queries: use console_query.')
                              }, required: %w[model id association], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier1.console_association_count(
              model: args[:model], id: args[:id], association: args[:association], scope: args[:scope]
            )
          end
        end

        def define_schema(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_schema', 'Get database schema for a model',
                              properties: {
                                model: str_prop('Model name'),
                                include_indexes: bool_prop('Include index information')
                              }, required: ['model'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier1.console_schema(model: args[:model], include_indexes: args[:include_indexes] || false)
          end
        end

        def define_recent(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_recent', 'Recently created/updated records.',
                              properties: {
                                model: str_prop('Model name'),
                                order_by: str_prop('Column to sort by (default: created_at)'),
                                direction: str_prop('Sort direction: asc or desc (default: desc)'),
                                limit: int_prop('Max records (default 10, max 50)'),
                                scope: obj_prop('Filter: {status: "paid", total_gt: 0}. ' \
                                                'Suffixes: _eq _gt _lt _in _null _present. ' \
                                                'Complex queries: use console_query.'),
                                columns: arr_prop('Columns to include')
                              }, required: ['model'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier1.console_recent(
              model: args[:model], order_by: args[:order_by] || 'created_at',
              direction: args[:direction] || 'desc', limit: args[:limit] || 10,
              scope: args[:scope], columns: args[:columns]
            )
          end
        end

        def define_status(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_status',
                              'System health check - list models and connection status',
                              properties: {}, safe_ctx: safe_ctx, renderer: renderer) do |_args|
            Tools::Tier1.console_status
          end
        end

        # ── Tier 2 tool definitions ──────────────────────────────────────────

        def define_diagnose_model(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_diagnose_model',
                              'Diagnose a model: count, recent records, aggregates',
                              properties: {
                                model: str_prop('Model name'), scope: obj_prop('Filter conditions'),
                                sample_size: int_prop('Sample records (default 5, max 25)')
                              }, required: ['model'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier2.console_diagnose_model(
              model: args[:model], scope: args[:scope], sample_size: args[:sample_size] || 5
            )
          end
        end

        def define_data_snapshot(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_data_snapshot',
                              'Snapshot a record with associations for debugging',
                              properties: {
                                model: str_prop('Model name'), id: int_prop('Record primary key'),
                                associations: arr_prop('Association names to include'),
                                depth: int_prop('Association depth (default 1, max 3)')
                              }, required: %w[model id], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier2.console_data_snapshot(
              model: args[:model], id: args[:id],
              associations: args[:associations], depth: args[:depth] || 1
            )
          end
        end

        def define_validate_record(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_validate_record',
                              'Run validations on an existing record',
                              properties: {
                                model: str_prop('Model name'), id: int_prop('Record primary key'),
                                attributes: obj_prop('Attributes to set before validating')
                              }, required: %w[model id], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier2.console_validate_record(
              model: args[:model], id: args[:id], attributes: args[:attributes]
            )
          end
        end

        def define_check_setting(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_check_setting',
                              'Check a configuration setting value',
                              properties: {
                                key: str_prop('Setting key'), namespace: str_prop('Setting namespace')
                              }, required: ['key'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier2.console_check_setting(key: args[:key], namespace: args[:namespace])
          end
        end

        def define_update_setting(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_update_setting',
                              'Update a configuration setting (requires confirmation)',
                              properties: {
                                key: str_prop('Setting key'), value: str_prop('New value'),
                                namespace: str_prop('Setting namespace')
                              }, required: %w[key value], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier2.console_update_setting(
              key: args[:key], value: args[:value], namespace: args[:namespace]
            )
          end
        end

        def define_check_policy(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_check_policy',
                              'Check authorization policy for a record and user',
                              properties: {
                                model: str_prop('Model name'), id: int_prop('Record primary key'),
                                user_id: int_prop('User to check'), action: str_prop('Policy action')
                              }, required: %w[model id user_id action],
                              safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier2.console_check_policy(
              model: args[:model], id: args[:id], user_id: args[:user_id], action: args[:action]
            )
          end
        end

        def define_validate_with(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_validate_with',
                              'Validate attributes against a model without persisting',
                              properties: {
                                model: str_prop('Model name'), attributes: obj_prop('Attributes to validate'),
                                context: str_prop('Validation context')
                              }, required: %w[model attributes], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier2.console_validate_with(
              model: args[:model], attributes: args[:attributes], context: args[:context]
            )
          end
        end

        def define_check_eligibility(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_check_eligibility',
                              'Check feature eligibility for a record',
                              properties: {
                                model: str_prop('Model name'), id: int_prop('Record primary key'),
                                feature: str_prop('Feature name')
                              }, required: %w[model id feature], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier2.console_check_eligibility(
              model: args[:model], id: args[:id], feature: args[:feature]
            )
          end
        end

        def define_decorate(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_decorate',
                              'Invoke a decorator on a record and return computed attributes',
                              properties: {
                                model: str_prop('Model name'), id: int_prop('Record primary key'),
                                methods: arr_prop('Decorator methods to call')
                              }, required: %w[model id], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier2.console_decorate(model: args[:model], id: args[:id], methods: args[:methods])
          end
        end

        # ── Tier 3 tool definitions ──────────────────────────────────────────

        def define_slow_endpoints(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_slow_endpoints',
                              'List slowest endpoints by response time',
                              properties: {
                                limit: int_prop('Max endpoints (default 10, max 100)'),
                                period: str_prop('Time period (default: 1h)')
                              }, safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier3.console_slow_endpoints(limit: args[:limit] || 10, period: args[:period] || '1h')
          end
        end

        def define_error_rates(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_error_rates',
                              'Get error rates by controller or overall',
                              properties: {
                                period: str_prop('Time period (default: 1h)'),
                                controller: str_prop('Filter by controller')
                              }, safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier3.console_error_rates(period: args[:period] || '1h', controller: args[:controller])
          end
        end

        def define_throughput(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_throughput',
                              'Get request throughput over time',
                              properties: {
                                period: str_prop('Time period (default: 1h)'),
                                interval: str_prop('Aggregation interval (default: 5m)')
                              }, safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier3.console_throughput(
              period: args[:period] || '1h', interval: args[:interval] || '5m'
            )
          end
        end

        def define_job_queues(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_job_queues',
                              'Get job queue statistics',
                              properties: {
                                queue: str_prop('Filter by queue name')
                              }, safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier3.console_job_queues(queue: args[:queue])
          end
        end

        def define_job_failures(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_job_failures',
                              'List recent job failures',
                              properties: {
                                limit: int_prop('Max failures (default 10, max 100)'),
                                queue: str_prop('Filter by queue name')
                              }, safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier3.console_job_failures(limit: args[:limit] || 10, queue: args[:queue])
          end
        end

        def define_job_find(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_job_find',
                              'Find a job by ID, optionally retry it (requires confirmation)',
                              properties: {
                                job_id: str_prop('Job identifier'),
                                retry: bool_prop('Retry the job (requires confirmation)')
                              }, required: ['job_id'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier3.console_job_find(job_id: args[:job_id], retry_job: args[:retry])
          end
        end

        def define_job_schedule(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_job_schedule',
                              'List scheduled/upcoming jobs',
                              properties: {
                                limit: int_prop('Max jobs (default 20, max 100)')
                              }, safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier3.console_job_schedule(limit: args[:limit] || 20)
          end
        end

        def define_redis_info(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_redis_info',
                              'Get Redis server information',
                              properties: {
                                section: str_prop('INFO section (e.g., memory, stats)')
                              }, safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier3.console_redis_info(section: args[:section])
          end
        end

        def define_cache_stats(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_cache_stats',
                              'Get cache store statistics',
                              properties: {
                                namespace: str_prop('Cache namespace filter')
                              }, safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier3.console_cache_stats(namespace: args[:namespace])
          end
        end

        def define_channel_status(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_channel_status',
                              'Get ActionCable channel status',
                              properties: {
                                channel: str_prop('Filter by channel name')
                              }, safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier3.console_channel_status(channel: args[:channel])
          end
        end

        # ── Tier 4 tool definitions ──────────────────────────────────────────

        def define_eval(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_eval',
                              'Execute arbitrary Ruby code (requires confirmation)',
                              properties: {
                                code: str_prop('Ruby code to execute'),
                                timeout: int_prop('Timeout in seconds (default 10, max 30)')
                              }, required: ['code'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier4.console_eval(code: args[:code], timeout: args[:timeout] || 10)
          end
        end

        def define_sql(server, conn_mgr, safe_ctx = nil, renderer: nil)
          validator = SqlValidator.new
          sql_description = [
            'Execute read-only SQL against the live database (SELECT/WITH...SELECT only).',
            'SqlValidator blocks all DML/DDL. Every query runs inside a rolled-back transaction — no writes persist.',
            'Requires embedded_read_tools: true in the rack middleware (see docs/CONSOLE_MCP_SETUP.md).',
            'Use console_query instead when you want ActiveRecord query builder rather than raw SQL.'
          ].join(' ')
          define_console_tool(server, conn_mgr, 'console_sql', sql_description,
                              properties: {
                                sql: str_prop('SQL query (SELECT or WITH...SELECT only)'),
                                limit: int_prop('Max rows returned (default unlimited, max 10000)')
                              }, required: ['sql'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier4.console_sql(sql: args[:sql], validator: validator, limit: args[:limit])
          end
        end

        # rubocop:disable Metrics/MethodLength
        def define_query(server, conn_mgr, safe_ctx = nil, renderer: nil)
          query_description = [
            'Build and run a structured ActiveRecord query with optional joins, grouping, and ordering.',
            'Example: {model: "Order", select: ["status", "COUNT(*) AS n"], group_by: ["status"]}.',
            'Use console_count or console_aggregate for simple aggregates without a custom SELECT.',
            'Use console_sql when you need raw SQL that the query builder cannot express.',
            'Requires embedded_read_tools: true in the rack middleware (see docs/CONSOLE_MCP_SETUP.md).',
            'Max 10,000 rows returned. Returns columns + rows arrays like a SQL result set.'
          ].join(' ')
          props = {
            model: str_prop('ActiveRecord model name (e.g. "Order")'),
            select: arr_prop('Columns or expressions to select (e.g. ["status", "COUNT(*) AS n"])'),
            joins: arr_prop('Association names to JOIN (e.g. ["line_items", "user"])'),
            group_by: arr_prop('Columns to GROUP BY (e.g. ["status", "user_id"])'),
            having: str_prop('HAVING filter applied after GROUP BY (e.g. "COUNT(*) > 5")'),
            order: obj_prop('Order specification as {column => direction} (e.g. {"created_at" => "desc"})'),
            scope: obj_prop('WHERE conditions as {column => value} or [sql, bind] array'),
            limit: int_prop('Maximum rows to return (default 10000, hard max 10000)')
          }
          define_console_tool(server, conn_mgr, 'console_query', query_description,
                              properties: props, required: %w[model select],
                              safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier4.console_query(
              model: args[:model], select: args[:select], joins: args[:joins],
              group_by: args[:group_by], having: args[:having],
              order: args[:order], scope: args[:scope], limit: args[:limit]
            )
          end
        end
        # rubocop:enable Metrics/MethodLength

        # Shared tool definition helper that wires block -> bridge -> response.
        # rubocop:disable Metrics/ParameterLists
        def define_console_tool(server, conn_mgr, name, description, properties:, required: nil,
                                safe_ctx: nil, renderer: nil, &tool_block)
          bridge_method = method(:send_to_bridge)
          coerce_method = method(:coerce_integer_args!)
          integer_keys = integer_property_keys(properties)
          schema = { properties: properties }
          schema[:required] = required if required&.any?
          server.define_tool(name: name, description: description, input_schema: schema) do |server_context:, **args|
            coerce_method.call(args, integer_keys)
            request = tool_block.call(args)
            bridge_method.call(conn_mgr, request.transform_keys(&:to_s), safe_ctx, renderer: renderer)
          end
        end
        # rubocop:enable Metrics/ParameterLists

        # Pre-compute property keys declared as integer in a schema.
        #
        # @param properties [Hash] Tool schema properties
        # @return [Array<Symbol>]
        def integer_property_keys(properties)
          properties.select { |_k, v| v[:type] == 'integer' }.keys.map(&:to_sym)
        end

        # Coerce string values to integers for known integer keys.
        #
        # @param args [Hash] Tool arguments (mutated in place)
        # @param keys [Array<Symbol>] Keys that should be integers
        # @return [void]
        def coerce_integer_args!(args, keys)
          keys.each { |k| args[k] = args[k].to_i if args[k].is_a?(String) }
        end

        # Schema property helpers for concise tool definitions.
        def str_prop(desc)  = { type: 'string', description: desc }
        def int_prop(desc)  = { type: 'integer', description: desc }
        def obj_prop(desc)  = { type: 'object', description: desc }
        def bool_prop(desc) = { type: 'boolean', description: desc }
        def arr_prop(desc)  = { type: 'array', items: { type: 'string' }, description: desc }
      end
    end
  end
end
