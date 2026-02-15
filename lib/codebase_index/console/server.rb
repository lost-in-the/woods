# frozen_string_literal: true

require 'mcp'
require_relative 'connection_manager'
require_relative 'model_validator'
require_relative 'safe_context'
require_relative 'tools/tier1'

module CodebaseIndex
  module Console
    # Console MCP Server — queries live Rails application state.
    #
    # Communicates with a bridge process running inside the Rails environment
    # via JSON-lines over stdio. Exposes Tier 1 read-only tools through MCP.
    #
    # @example
    #   server = CodebaseIndex::Console::Server.build(config: config)
    #   transport = MCP::Server::Transports::StdioTransport.new(server)
    #   transport.open
    #
    module Server # rubocop:disable Metrics/ModuleLength
      TIER1_TOOLS = %w[count sample find pluck aggregate association_count schema recent status].freeze

      class << self # rubocop:disable Metrics/ClassLength
        # Build a configured MCP::Server with console tools.
        #
        # @param config [Hash] Configuration hash (from YAML or env)
        # @return [MCP::Server] Configured server ready for transport
        def build(config:)
          connection_config = config['console'] || config
          conn_mgr = ConnectionManager.new(config: connection_config)

          server = ::MCP::Server.new(
            name: 'codebase-console',
            version: defined?(CodebaseIndex::VERSION) ? CodebaseIndex::VERSION : '0.1.0'
          )

          register_tier1_tools(server, conn_mgr)
          server
        end

        # Register Tier 1 read-only tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager] Bridge connection
        # @return [void]
        def register_tier1_tools(server, conn_mgr)
          TIER1_TOOLS.each { |tool| send(:"define_#{tool}", server, conn_mgr) }
        end

        private

        def respond(text)
          ::MCP::Tool::Response.new([{ type: 'text', text: text }])
        end

        def send_to_bridge(conn_mgr, request)
          response = conn_mgr.send_request(request)
          if response['ok']
            respond(JSON.pretty_generate(response['result']))
          else
            ::MCP::Tool::Response.new(
              [{ type: 'text', text: "#{response['error_type']}: #{response['error']}" }],
              is_error: true
            )
          end
        rescue ConnectionError => e
          ::MCP::Tool::Response.new([{ type: 'text', text: "Connection error: #{e.message}" }], is_error: true)
        end

        def define_count(server, conn_mgr)
          define_console_tool(server, conn_mgr, 'console_count', 'Count records matching scope conditions',
                              properties: { model: str_prop('Model name'), scope: obj_prop('Filter conditions') },
                              required: ['model']) do |args|
            Tools::Tier1.console_count(model: args[:model], scope: args[:scope])
          end
        end

        def define_sample(server, conn_mgr)
          define_console_tool(server, conn_mgr, 'console_sample', 'Random sample of records',
                              properties: {
                                model: str_prop('Model name'), limit: int_prop('Max records (default 5, max 25)'),
                                columns: arr_prop('Columns to include'), scope: obj_prop('Filter conditions')
                              }, required: ['model']) do |args|
            Tools::Tier1.console_sample(
              model: args[:model], scope: args[:scope], limit: args[:limit] || 5, columns: args[:columns]
            )
          end
        end

        def define_find(server, conn_mgr)
          define_console_tool(server, conn_mgr, 'console_find',
                              'Find a single record by primary key or unique column',
                              properties: {
                                model: str_prop('Model name'), id: int_prop('Primary key value'),
                                by: obj_prop('Unique column lookup'),
                                columns: arr_prop('Columns to include')
                              }, required: ['model']) do |args|
            Tools::Tier1.console_find(model: args[:model], id: args[:id], by: args[:by], columns: args[:columns])
          end
        end

        def define_pluck(server, conn_mgr)
          define_console_tool(server, conn_mgr, 'console_pluck', 'Extract column values from records',
                              properties: {
                                model: str_prop('Model name'), columns: arr_prop('Column names to pluck'),
                                scope: obj_prop('Filter conditions'),
                                limit: int_prop('Max records (default 100, max 1000)'),
                                distinct: bool_prop('Return unique values only')
                              }, required: %w[model columns]) do |args|
            Tools::Tier1.console_pluck(
              model: args[:model], columns: args[:columns], scope: args[:scope],
              limit: args[:limit] || 100, distinct: args[:distinct] || false
            )
          end
        end

        def define_aggregate(server, conn_mgr)
          define_console_tool(server, conn_mgr, 'console_aggregate',
                              'Run aggregate function (sum/avg/min/max) on a column',
                              properties: {
                                model: str_prop('Model name'),
                                function: str_prop('Aggregate function: sum, avg, minimum, maximum'),
                                column: str_prop('Column to aggregate'), scope: obj_prop('Filter conditions')
                              }, required: %w[model function column]) do |args|
            Tools::Tier1.console_aggregate(
              model: args[:model], function: args[:function], column: args[:column], scope: args[:scope]
            )
          end
        end

        def define_association_count(server, conn_mgr)
          define_console_tool(server, conn_mgr, 'console_association_count',
                              'Count associated records for a specific record',
                              properties: {
                                model: str_prop('Model name'), id: int_prop('Record primary key'),
                                association: str_prop('Association name'),
                                scope: obj_prop('Filter on association')
                              }, required: %w[model id association]) do |args|
            Tools::Tier1.console_association_count(
              model: args[:model], id: args[:id], association: args[:association], scope: args[:scope]
            )
          end
        end

        def define_schema(server, conn_mgr)
          define_console_tool(server, conn_mgr, 'console_schema', 'Get database schema for a model',
                              properties: {
                                model: str_prop('Model name'),
                                include_indexes: bool_prop('Include index information')
                              }, required: ['model']) do |args|
            Tools::Tier1.console_schema(model: args[:model], include_indexes: args[:include_indexes] || false)
          end
        end

        def define_recent(server, conn_mgr)
          define_console_tool(server, conn_mgr, 'console_recent', 'Recently created/updated records',
                              properties: {
                                model: str_prop('Model name'),
                                order_by: str_prop('Column to sort by (default: created_at)'),
                                direction: str_prop('Sort direction: asc or desc (default: desc)'),
                                limit: int_prop('Max records (default 10, max 50)'),
                                scope: obj_prop('Filter conditions'), columns: arr_prop('Columns to include')
                              }, required: ['model']) do |args|
            Tools::Tier1.console_recent(
              model: args[:model], order_by: args[:order_by] || 'created_at',
              direction: args[:direction] || 'desc', limit: args[:limit] || 10,
              scope: args[:scope], columns: args[:columns]
            )
          end
        end

        def define_status(server, conn_mgr)
          define_console_tool(server, conn_mgr, 'console_status',
                              'System health check - list models and connection status',
                              properties: {}) do |_args|
            Tools::Tier1.console_status
          end
        end

        # Shared tool definition helper that wires block -> bridge -> response.
        # rubocop:disable Metrics/ParameterLists
        def define_console_tool(server, conn_mgr, name, description, properties:, required: nil, &tool_block)
          mgr = conn_mgr
          schema = { properties: properties }
          schema[:required] = required if required&.any?
          server.define_tool(name: name, description: description, input_schema: schema) do |_server_context:, **args|
            request = tool_block.call(args)
            send_to_bridge(mgr, request.transform_keys(&:to_s))
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
