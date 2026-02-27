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

module CodebaseIndex
  module Console
    # Console MCP Server — queries live Rails application state.
    #
    # Communicates with a bridge process running inside the Rails environment
    # via JSON-lines over stdio. Exposes Tier 1-4 tools (read-only, domain, analytics, guarded) through MCP.
    #
    # @example
    #   server = CodebaseIndex::Console::Server.build(config: config)
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
          safe_ctx = redacted_columns.any? ? SafeContext.new(connection: nil, redacted_columns: redacted_columns) : nil

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
        # @return [MCP::Server] Configured server ready for transport
        def build_embedded(model_validator:, safe_context:, redacted_columns: [], connection: nil)
          require_relative 'embedded_executor'

          executor = EmbeddedExecutor.new(
            model_validator: model_validator, safe_context: safe_context, connection: connection
          )
          redact_ctx = if redacted_columns.any?
                         SafeContext.new(connection: nil,
                                         redacted_columns: redacted_columns)
                       end

          build_server(executor, redact_ctx)
        end

        # Register Tier 1 read-only tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager] Bridge connection
        # @param safe_ctx [SafeContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier1_tools(server, conn_mgr, safe_ctx = nil, renderer: nil)
          TIER1_TOOLS.each { |tool| send(:"define_#{tool}", server, conn_mgr, safe_ctx, renderer: renderer) }
        end

        # Register Tier 2 domain-aware tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager] Bridge connection
        # @param safe_ctx [SafeContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier2_tools(server, conn_mgr, safe_ctx = nil, renderer: nil)
          TIER2_TOOLS.each { |tool| send(:"define_#{tool}", server, conn_mgr, safe_ctx, renderer: renderer) }
        end

        # Register Tier 3 analytics tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager] Bridge connection
        # @param safe_ctx [SafeContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier3_tools(server, conn_mgr, safe_ctx = nil, renderer: nil)
          TIER3_TOOLS.each { |tool| send(:"define_#{tool}", server, conn_mgr, safe_ctx, renderer: renderer) }
        end

        # Register Tier 4 guarded tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager] Bridge connection
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
            name: 'codebase-console',
            version: defined?(CodebaseIndex::VERSION) ? CodebaseIndex::VERSION : '0.1.0'
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

        # Apply SafeContext column redaction to a result value.
        #
        # Handles Hash (single record) and Array<Hash> (multiple records).
        # Non-Hash values are returned unchanged.
        #
        # @param result [Object] The result from the bridge
        # @param safe_ctx [SafeContext] The context with redacted_columns configured
        # @return [Object] Redacted result
        def apply_redaction(result, safe_ctx)
          case result
          when Array
            result.map { |item| item.is_a?(Hash) ? safe_ctx.redact(item) : item }
          when Hash
            safe_ctx.redact(result)
          else
            result
          end
        end

        def build_console_renderer
          format = if CodebaseIndex.respond_to?(:configuration)
                     CodebaseIndex.configuration&.context_format || :markdown
                   else
                     :markdown
                   end
          format == :json ? JsonConsoleRenderer.new : ConsoleResponseRenderer.new
        end

        def define_count(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_count', 'Count records matching scope conditions',
                              properties: { model: str_prop('Model name'), scope: obj_prop('Filter conditions') },
                              required: ['model'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier1.console_count(model: args[:model], scope: args[:scope])
          end
        end

        def define_sample(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_sample', 'Random sample of records',
                              properties: {
                                model: str_prop('Model name'), limit: int_prop('Max records (default 5, max 25)'),
                                columns: arr_prop('Columns to include'), scope: obj_prop('Filter conditions')
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
          define_console_tool(server, conn_mgr, 'console_pluck', 'Extract column values from records',
                              properties: {
                                model: str_prop('Model name'), columns: arr_prop('Column names to pluck'),
                                scope: obj_prop('Filter conditions'),
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
                              'Run aggregate function (sum/avg/min/max) on a column',
                              properties: {
                                model: str_prop('Model name'),
                                function: str_prop('Aggregate function: sum, avg, minimum, maximum'),
                                column: str_prop('Column to aggregate'), scope: obj_prop('Filter conditions')
                              }, required: %w[model function column], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier1.console_aggregate(
              model: args[:model], function: args[:function], column: args[:column], scope: args[:scope]
            )
          end
        end

        def define_association_count(server, conn_mgr, safe_ctx = nil, renderer: nil)
          define_console_tool(server, conn_mgr, 'console_association_count',
                              'Count associated records for a specific record',
                              properties: {
                                model: str_prop('Model name'), id: int_prop('Record primary key'),
                                association: str_prop('Association name'),
                                scope: obj_prop('Filter on association')
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
          define_console_tool(server, conn_mgr, 'console_recent', 'Recently created/updated records',
                              properties: {
                                model: str_prop('Model name'),
                                order_by: str_prop('Column to sort by (default: created_at)'),
                                direction: str_prop('Sort direction: asc or desc (default: desc)'),
                                limit: int_prop('Max records (default 10, max 50)'),
                                scope: obj_prop('Filter conditions'), columns: arr_prop('Columns to include')
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
          define_console_tool(server, conn_mgr, 'console_sql',
                              'Execute read-only SQL (SELECT/WITH...SELECT only)',
                              properties: {
                                sql: str_prop('SQL query (SELECT or WITH...SELECT only)'),
                                limit: int_prop('Max rows returned (default unlimited, max 10000)')
                              }, required: ['sql'], safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier4.console_sql(sql: args[:sql], validator: validator, limit: args[:limit])
          end
        end

        def define_query(server, conn_mgr, safe_ctx = nil, renderer: nil)
          props = {
            model: str_prop('Model name'), select: arr_prop('Columns to select'),
            joins: arr_prop('Associations to join'), group_by: arr_prop('Columns to group by'),
            having: str_prop('HAVING clause'), order: obj_prop('Order specification'),
            scope: obj_prop('Filter conditions'), limit: int_prop('Max rows (max 10000)')
          }
          define_console_tool(server, conn_mgr, 'console_query',
                              'Enhanced query builder with joins and grouping',
                              properties: props, required: %w[model select],
                              safe_ctx: safe_ctx, renderer: renderer) do |args|
            Tools::Tier4.console_query(
              model: args[:model], select: args[:select], joins: args[:joins],
              group_by: args[:group_by], having: args[:having],
              order: args[:order], scope: args[:scope], limit: args[:limit]
            )
          end
        end

        # Shared tool definition helper that wires block -> bridge -> response.
        # rubocop:disable Metrics/ParameterLists
        def define_console_tool(server, conn_mgr, name, description, properties:, required: nil,
                                safe_ctx: nil, renderer: nil, &tool_block)
          mgr = conn_mgr
          ctx = safe_ctx
          rdr = renderer
          bridge_method = method(:send_to_bridge)
          schema = { properties: properties }
          schema[:required] = required if required&.any?
          server.define_tool(name: name, description: description, input_schema: schema) do |server_context:, **args|
            request = tool_block.call(args)
            bridge_method.call(mgr, request.transform_keys(&:to_s), ctx, renderer: rdr)
          end
        end
        # rubocop:enable Metrics/ParameterLists

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
