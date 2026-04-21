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
require_relative 'credential_scanner'
require_relative 'eval_guard'
require_relative 'table_gate'
require_relative 'response_context'

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
    module Server
      TIER1_TOOLS = %w[count sample find pluck aggregate association_count schema recent status].freeze
      TIER2_TOOLS = %w[diagnose_model data_snapshot validate_record check_setting update_setting
                       check_policy validate_with check_eligibility decorate].freeze
      TIER3_TOOLS = %w[slow_endpoints error_rates throughput job_queues job_failures job_find
                       job_schedule redis_info cache_stats channel_status].freeze
      TIER4_TOOLS = %w[eval sql query].freeze

      # Value object that holds a single MCP tool's declarative specification.
      #
      # @!attribute [r] name
      #   @return [String] MCP tool name (e.g. "console_count")
      # @!attribute [r] description
      #   @return [String] Human-readable description shown to the LLM
      # @!attribute [r] properties
      #   @return [Hash] JSON Schema property definitions (name => {type:, description:})
      # @!attribute [r] required
      #   @return [Array<String>, nil] Required property names, or nil
      # @!attribute [r] tier
      #   @return [Integer] Tier number (1-4)
      # @!attribute [r] handler
      #   @return [Proc] Lambda called with symbolised args hash; returns the
      #     request Hash forwarded to the bridge/executor. Any tier-specific
      #     objects (validators, guards) are captured in the lambda's closure.
      ToolSpec = Struct.new(:name, :description, :properties, :required, :tier, :handler, keyword_init: true)

      # All 29 console tool specifications, grouped by tier.
      # Each spec is a ToolSpec; the handler lambda captures any objects that
      # must be built once at spec-definition time (validators, guards).
      TOOL_SPECS = [
        # ── Tier 1: read-only ─────────────────────────────────────────────────
        ToolSpec.new(
          name: 'console_count',
          description: 'Count records matching scope conditions.',
          properties: {
            model: { type: 'string', description: 'Model name' },
            scope: { type: 'object', description: 'Filter: {status: "paid", total_refund_gt: 0, ' \
                                                  'transaction_id_not_null: true}. ' \
                                                  'Suffixes: _eq _gt _lt _in _null _present. ' \
                                                  'Complex queries: use console_query.' }
          },
          required: ['model'],
          tier: 1,
          handler: ->(args) { Tools::Tier1.console_count(model: args[:model], scope: args[:scope]) }
        ),
        ToolSpec.new(
          name: 'console_sample',
          description: 'Random sample of records.',
          properties: {
            model: { type: 'string', description: 'Model name' },
            limit: { type: 'integer', description: 'Max records (default 5, max 25)' },
            columns: { type: 'array', items: { type: 'string' }, description: 'Columns to include' },
            scope: { type: 'object', description: 'Filter: {status: "paid", amount_gt: 100}. ' \
                                                  'Suffixes: _eq _gt _lt _in _null _present. ' \
                                                  'Complex queries: use console_query.' }
          },
          required: ['model'],
          tier: 1,
          handler: lambda { |args|
            Tools::Tier1.console_sample(
              model: args[:model], scope: args[:scope], limit: args[:limit] || 5, columns: args[:columns]
            )
          }
        ),
        ToolSpec.new(
          name: 'console_find',
          description: 'Find a single record by primary key or unique column',
          properties: {
            model: { type: 'string', description: 'Model name' },
            id: { type: 'integer', description: 'Primary key value' },
            by: { type: 'object', description: 'Unique column lookup' },
            columns: { type: 'array', items: { type: 'string' }, description: 'Columns to include' }
          },
          required: ['model'],
          tier: 1,
          handler: lambda { |args|
            Tools::Tier1.console_find(
              model: args[:model], id: args[:id], by: args[:by], columns: args[:columns]
            )
          }
        ),
        ToolSpec.new(
          name: 'console_pluck',
          description: 'Extract column values from records.',
          properties: {
            model: { type: 'string', description: 'Model name' },
            columns: { type: 'array', items: { type: 'string' }, description: 'Column names to pluck' },
            scope: { type: 'object', description: 'Filter: {status_in: ["paid","refunded"], amount_gt: 0}. ' \
                                                  'Suffixes: _eq _gt _lt _in _null _present. ' \
                                                  'Complex queries: use console_query.' },
            limit: { type: 'integer', description: 'Max records (default 100, max 1000)' },
            distinct: { type: 'boolean', description: 'Return unique values only' }
          },
          required: %w[model columns],
          tier: 1,
          handler: lambda { |args|
            Tools::Tier1.console_pluck(
              model: args[:model], columns: args[:columns], scope: args[:scope],
              limit: args[:limit] || 100, distinct: args[:distinct] || false
            )
          }
        ),
        ToolSpec.new(
          name: 'console_aggregate',
          description: 'Run aggregate function on a column. ' \
                       'count omits column to count all rows. ' \
                       'Supports scope predicates: {status: "paid", total_gt: 0}. ' \
                       'For complex queries use console_query.',
          properties: {
            model: { type: 'string', description: 'Model name' },
            function: { type: 'string', description: 'Aggregate function: sum, average, minimum, maximum, count' },
            column: { type: 'string', description: 'Column to aggregate (optional for count)' },
            scope: { type: 'object', description: 'Filter conditions: {col: val} or predicate suffixes ' \
                                                  '(_gt, _lt, _in, _null, etc.)' }
          },
          required: %w[model function],
          tier: 1,
          handler: lambda { |args|
            Tools::Tier1.console_aggregate(
              model: args[:model], function: args[:function], column: args[:column], scope: args[:scope]
            )
          }
        ),
        ToolSpec.new(
          name: 'console_association_count',
          description: 'Count associated records for a specific record.',
          properties: {
            model: { type: 'string', description: 'Model name' },
            id: { type: 'integer', description: 'Record primary key' },
            association: { type: 'string', description: 'Association name' },
            scope: { type: 'object', description: 'Filter on association: {status: "paid", amount_gt: 0}. ' \
                                                  'Suffixes: _eq _gt _lt _in _null _present. ' \
                                                  'Complex queries: use console_query.' }
          },
          required: %w[model id association],
          tier: 1,
          handler: lambda { |args|
            Tools::Tier1.console_association_count(
              model: args[:model], id: args[:id], association: args[:association], scope: args[:scope]
            )
          }
        ),
        ToolSpec.new(
          name: 'console_schema',
          description: 'Get database schema for a model',
          properties: {
            model: { type: 'string', description: 'Model name' },
            include_indexes: { type: 'boolean', description: 'Include index information' }
          },
          required: ['model'],
          tier: 1,
          handler: lambda { |args|
            Tools::Tier1.console_schema(model: args[:model], include_indexes: args[:include_indexes] || false)
          }
        ),
        ToolSpec.new(
          name: 'console_recent',
          description: 'Recently created/updated records.',
          properties: {
            model: { type: 'string', description: 'Model name' },
            order_by: { type: 'string', description: 'Column to sort by (default: created_at)' },
            direction: { type: 'string', description: 'Sort direction: asc or desc (default: desc)' },
            limit: { type: 'integer', description: 'Max records (default 10, max 50)' },
            scope: { type: 'object', description: 'Filter: {status: "paid", total_gt: 0}. ' \
                                                  'Suffixes: _eq _gt _lt _in _null _present. ' \
                                                  'Complex queries: use console_query.' },
            columns: { type: 'array', items: { type: 'string' }, description: 'Columns to include' }
          },
          required: ['model'],
          tier: 1,
          handler: lambda { |args|
            Tools::Tier1.console_recent(
              model: args[:model], order_by: args[:order_by] || 'created_at',
              direction: args[:direction] || 'desc', limit: args[:limit] || 10,
              scope: args[:scope], columns: args[:columns]
            )
          }
        ),
        ToolSpec.new(
          name: 'console_status',
          description: 'System health check - list models and connection status',
          properties: {},
          required: nil,
          tier: 1,
          handler: ->(_args) { Tools::Tier1.console_status }
        ),

        # ── Tier 2: domain-aware ──────────────────────────────────────────────
        ToolSpec.new(
          name: 'console_diagnose_model',
          description: 'Diagnose a model: count, recent records, aggregates',
          properties: {
            model: { type: 'string', description: 'Model name' },
            scope: { type: 'object', description: 'Filter conditions' },
            sample_size: { type: 'integer', description: 'Sample records (default 5, max 25)' }
          },
          required: ['model'],
          tier: 2,
          handler: lambda { |args|
            Tools::Tier2.console_diagnose_model(
              model: args[:model], scope: args[:scope], sample_size: args[:sample_size] || 5
            )
          }
        ),
        ToolSpec.new(
          name: 'console_data_snapshot',
          description: 'Snapshot a record with associations for debugging',
          properties: {
            model: { type: 'string', description: 'Model name' },
            id: { type: 'integer', description: 'Record primary key' },
            associations: { type: 'array', items: { type: 'string' }, description: 'Association names to include' },
            depth: { type: 'integer', description: 'Association depth (default 1, max 3)' }
          },
          required: %w[model id],
          tier: 2,
          handler: lambda { |args|
            Tools::Tier2.console_data_snapshot(
              model: args[:model], id: args[:id],
              associations: args[:associations], depth: args[:depth] || 1
            )
          }
        ),
        ToolSpec.new(
          name: 'console_validate_record',
          description: 'Run validations on an existing record',
          properties: {
            model: { type: 'string', description: 'Model name' },
            id: { type: 'integer', description: 'Record primary key' },
            attributes: { type: 'object', description: 'Attributes to set before validating' }
          },
          required: %w[model id],
          tier: 2,
          handler: lambda { |args|
            Tools::Tier2.console_validate_record(
              model: args[:model], id: args[:id], attributes: args[:attributes]
            )
          }
        ),
        ToolSpec.new(
          name: 'console_check_setting',
          description: 'Check a configuration setting value',
          properties: {
            key: { type: 'string', description: 'Setting key' },
            namespace: { type: 'string', description: 'Setting namespace' }
          },
          required: ['key'],
          tier: 2,
          handler: ->(args) { Tools::Tier2.console_check_setting(key: args[:key], namespace: args[:namespace]) }
        ),
        ToolSpec.new(
          name: 'console_update_setting',
          description: 'Update a configuration setting (requires confirmation)',
          properties: {
            key: { type: 'string', description: 'Setting key' },
            value: { type: 'string', description: 'New value' },
            namespace: { type: 'string', description: 'Setting namespace' }
          },
          required: %w[key value],
          tier: 2,
          handler: lambda { |args|
            Tools::Tier2.console_update_setting(
              key: args[:key], value: args[:value], namespace: args[:namespace]
            )
          }
        ),
        ToolSpec.new(
          name: 'console_check_policy',
          description: 'Check authorization policy for a record and user',
          properties: {
            model: { type: 'string', description: 'Model name' },
            id: { type: 'integer', description: 'Record primary key' },
            user_id: { type: 'integer', description: 'User to check' },
            action: { type: 'string', description: 'Policy action' }
          },
          required: %w[model id user_id action],
          tier: 2,
          handler: lambda { |args|
            Tools::Tier2.console_check_policy(
              model: args[:model], id: args[:id], user_id: args[:user_id], action: args[:action]
            )
          }
        ),
        ToolSpec.new(
          name: 'console_validate_with',
          description: 'Validate attributes against a model without persisting',
          properties: {
            model: { type: 'string', description: 'Model name' },
            attributes: { type: 'object', description: 'Attributes to validate' },
            context: { type: 'string', description: 'Validation context' }
          },
          required: %w[model attributes],
          tier: 2,
          handler: lambda { |args|
            Tools::Tier2.console_validate_with(
              model: args[:model], attributes: args[:attributes], context: args[:context]
            )
          }
        ),
        ToolSpec.new(
          name: 'console_check_eligibility',
          description: 'Check feature eligibility for a record',
          properties: {
            model: { type: 'string', description: 'Model name' },
            id: { type: 'integer', description: 'Record primary key' },
            feature: { type: 'string', description: 'Feature name' }
          },
          required: %w[model id feature],
          tier: 2,
          handler: lambda { |args|
            Tools::Tier2.console_check_eligibility(
              model: args[:model], id: args[:id], feature: args[:feature]
            )
          }
        ),
        ToolSpec.new(
          name: 'console_decorate',
          description: 'Invoke a decorator on a record and return computed attributes',
          properties: {
            model: { type: 'string', description: 'Model name' },
            id: { type: 'integer', description: 'Record primary key' },
            methods: { type: 'array', items: { type: 'string' }, description: 'Decorator methods to call' }
          },
          required: %w[model id],
          tier: 2,
          handler: lambda { |args|
            Tools::Tier2.console_decorate(model: args[:model], id: args[:id], methods: args[:methods])
          }
        ),

        # ── Tier 3: analytics ─────────────────────────────────────────────────
        ToolSpec.new(
          name: 'console_slow_endpoints',
          description: 'List slowest endpoints by response time',
          properties: {
            limit: { type: 'integer', description: 'Max endpoints (default 10, max 100)' },
            period: { type: 'string', description: 'Time period (default: 1h)' }
          },
          required: nil,
          tier: 3,
          handler: lambda { |args|
            Tools::Tier3.console_slow_endpoints(limit: args[:limit] || 10, period: args[:period] || '1h')
          }
        ),
        ToolSpec.new(
          name: 'console_error_rates',
          description: 'Get error rates by controller or overall',
          properties: {
            period: { type: 'string', description: 'Time period (default: 1h)' },
            controller: { type: 'string', description: 'Filter by controller' }
          },
          required: nil,
          tier: 3,
          handler: lambda { |args|
            Tools::Tier3.console_error_rates(period: args[:period] || '1h', controller: args[:controller])
          }
        ),
        ToolSpec.new(
          name: 'console_throughput',
          description: 'Get request throughput over time',
          properties: {
            period: { type: 'string', description: 'Time period (default: 1h)' },
            interval: { type: 'string', description: 'Aggregation interval (default: 5m)' }
          },
          required: nil,
          tier: 3,
          handler: lambda { |args|
            Tools::Tier3.console_throughput(
              period: args[:period] || '1h', interval: args[:interval] || '5m'
            )
          }
        ),
        ToolSpec.new(
          name: 'console_job_queues',
          description: 'Get job queue statistics',
          properties: {
            queue: { type: 'string', description: 'Filter by queue name' }
          },
          required: nil,
          tier: 3,
          handler: ->(args) { Tools::Tier3.console_job_queues(queue: args[:queue]) }
        ),
        ToolSpec.new(
          name: 'console_job_failures',
          description: 'List recent job failures',
          properties: {
            limit: { type: 'integer', description: 'Max failures (default 10, max 100)' },
            queue: { type: 'string', description: 'Filter by queue name' }
          },
          required: nil,
          tier: 3,
          handler: lambda { |args|
            Tools::Tier3.console_job_failures(limit: args[:limit] || 10, queue: args[:queue])
          }
        ),
        ToolSpec.new(
          name: 'console_job_find',
          description: 'Find a job by ID, optionally retry it (requires confirmation)',
          properties: {
            job_id: { type: 'string', description: 'Job identifier' },
            retry: { type: 'boolean', description: 'Retry the job (requires confirmation)' }
          },
          required: ['job_id'],
          tier: 3,
          handler: ->(args) { Tools::Tier3.console_job_find(job_id: args[:job_id], retry_job: args[:retry]) }
        ),
        ToolSpec.new(
          name: 'console_job_schedule',
          description: 'List scheduled/upcoming jobs',
          properties: {
            limit: { type: 'integer', description: 'Max jobs (default 20, max 100)' }
          },
          required: nil,
          tier: 3,
          handler: ->(args) { Tools::Tier3.console_job_schedule(limit: args[:limit] || 20) }
        ),
        ToolSpec.new(
          name: 'console_redis_info',
          description: 'Get Redis server information',
          properties: {
            section: { type: 'string', description: 'INFO section (e.g., memory, stats)' }
          },
          required: nil,
          tier: 3,
          handler: ->(args) { Tools::Tier3.console_redis_info(section: args[:section]) }
        ),
        ToolSpec.new(
          name: 'console_cache_stats',
          description: 'Get cache store statistics',
          properties: {
            namespace: { type: 'string', description: 'Cache namespace filter' }
          },
          required: nil,
          tier: 3,
          handler: ->(args) { Tools::Tier3.console_cache_stats(namespace: args[:namespace]) }
        ),
        ToolSpec.new(
          name: 'console_channel_status',
          description: 'Get ActionCable channel status',
          properties: {
            channel: { type: 'string', description: 'Filter by channel name' }
          },
          required: nil,
          tier: 3,
          handler: ->(args) { Tools::Tier3.console_channel_status(channel: args[:channel]) }
        ),

        # ── Tier 4: guarded ───────────────────────────────────────────────────
        ToolSpec.new(
          name: 'console_eval',
          description: [
            'Propose arbitrary Ruby for execution against the live Rails runtime.',
            'CURRENTLY DISABLED in embedded mode — the call will always return an instructional refusal.',
            'Before invoking this tool, SHOW the user your proposed Ruby snippet and let them run it ' \
            'manually. Do not retry on failure, and do not hide the snippet behind the tool call.',
            'For most cases use console_query (model + select + joins/group_by/having/order) or ' \
            'console_sql instead — both already support aggregates and scoped filters.'
          ].join(' '),
          properties: {
            code: { type: 'string',
                    description: 'Ruby code you propose to run (will be surfaced to the user first)' },
            timeout: { type: 'integer', description: 'Timeout in seconds (default 10, max 30)' }
          },
          required: ['code'],
          tier: 4,
          handler: begin
            config = Woods.configuration if Woods.respond_to?(:configuration)
            guard = EvalGuard.new if config&.console_credential_defense_enabled
            ->(args) { Tools::Tier4.console_eval(code: args[:code], timeout: args[:timeout] || 10, guard: guard) }
          end
        ),
        ToolSpec.new(
          name: 'console_sql',
          description: [
            'Execute read-only SQL against the live database (SELECT/WITH...SELECT only).',
            'SqlValidator blocks all DML/DDL. Every query runs inside a rolled-back transaction — no writes persist.',
            'Requires embedded_read_tools: true in the rack middleware (see docs/CONSOLE_MCP_SETUP.md).',
            'Use console_query instead when you want ActiveRecord query builder rather than raw SQL.'
          ].join(' '),
          properties: {
            sql: { type: 'string', description: 'SQL query (SELECT or WITH...SELECT only)' },
            limit: { type: 'integer', description: 'Max rows returned (default unlimited, max 10000)' }
          },
          required: ['sql'],
          tier: 4,
          handler: begin
            validator = SqlValidator.new
            ->(args) { Tools::Tier4.console_sql(sql: args[:sql], validator: validator, limit: args[:limit]) }
          end
        ),
        ToolSpec.new(
          name: 'console_query',
          description: [
            'Build and run a structured ActiveRecord query with optional joins, grouping, and ordering.',
            'Example: {model: "Order", select: ["status", "COUNT(*) AS n"], group_by: ["status"]}.',
            'Use console_count or console_aggregate for simple aggregates without a custom SELECT.',
            'Use console_sql when you need raw SQL that the query builder cannot express.',
            'Requires embedded_read_tools: true in the rack middleware (see docs/CONSOLE_MCP_SETUP.md).',
            'Max 10,000 rows returned. Returns columns + rows arrays like a SQL result set.'
          ].join(' '),
          properties: {
            model: { type: 'string', description: 'ActiveRecord model name (e.g. "Order")' },
            select: { type: 'array', items: { type: 'string' },
                      description: 'Columns or expressions to select (e.g. ["status", "COUNT(*) AS n"])' },
            joins: { type: 'array', items: { type: 'string' },
                     description: 'Association names to JOIN (e.g. ["line_items", "user"])' },
            group_by: { type: 'array', items: { type: 'string' },
                        description: 'Columns to GROUP BY (e.g. ["status", "user_id"])' },
            having: { type: 'string',
                      description: 'HAVING filter applied after GROUP BY (e.g. "COUNT(*) > 5")' },
            order: { type: 'object',
                     description: 'Order specification as {column => direction} (e.g. {"created_at" => "desc"})' },
            scope: { type: 'object',
                     description: 'WHERE conditions as {column => value} or [sql, bind] array' },
            limit: { type: 'integer', description: 'Maximum rows to return (default 10000, hard max 10000)' }
          },
          required: %w[model select],
          tier: 4,
          handler: lambda { |args|
            Tools::Tier4.console_query(
              model: args[:model], select: args[:select], joins: args[:joins],
              group_by: args[:group_by], having: args[:having],
              order: args[:order], scope: args[:scope], limit: args[:limit]
            )
          }
        )
      ].freeze

      class << self
        # Rebuild the boot-time credential index from fresh Rails credentials
        # and hot-swap it into the active scanner without restarting the process.
        #
        # Host rotation jobs should call this immediately after `rails credentials:edit`
        # changes are deployed. The swap is atomic on MRI (GVL) — in-flight scans see
        # either the old or the new index, never a partial one.
        #
        # Returns nil when:
        # - `console_credential_defense_enabled` is false
        # - No server has been built yet in this process (`build` / `build_embedded`
        #   have not been called)
        #
        # Existing callers of `build` / `build_embedded` are unaffected — this is an
        # additive class method with no required arguments beyond `rails_app`.
        #
        # @param rails_app [#credentials] The Rails application to re-read.
        #   Defaults to `Rails.application` when `Rails` is defined, otherwise
        #   the caller must supply it explicitly.
        # @return [CredentialIndex, nil] The newly built index, or nil when
        #   the rebuild was skipped.
        def rebuild_credential_index(rails_app: nil)
          return nil unless credential_defense_enabled?
          return nil unless @active_scanner

          target_app = rails_app || default_rails_app
          return nil unless target_app

          new_index = CredentialIndex.build(rails_app: target_app)
          @active_scanner.replace_index!(new_index)
          new_index
        end

        # True when Woods is configured and credential defense is on.
        def credential_defense_enabled?
          config = Woods.configuration if Woods.respond_to?(:configuration)
          config&.console_credential_defense_enabled ? true : false
        end

        # True when the caller has opted into the unsafe `console_eval`
        # scaffolding via `WOODS_CONSOLE_UNSAFE_EVAL=true` or an explicit
        # `config.console_unsafe_eval_enabled = true`. Explicit config wins
        # over the env var in both directions.
        #
        # NOTE: returning true here does NOT enable eval execution. The
        # execution path is deliberately unimplemented (backlog
        # unsafe-eval-opt-in). This predicate only governs the boot-time
        # banner and the production-environment refusal below.
        #
        # @return [Boolean]
        def unsafe_eval_enabled?
          config = Woods.configuration if Woods.respond_to?(:configuration)
          explicit = config&.console_unsafe_eval_enabled
          return explicit if [true, false].include?(explicit)

          ENV['WOODS_CONSOLE_UNSAFE_EVAL'] == 'true'
        end

        # Enforce the `console_eval` opt-in safety contract at boot.
        #
        # When `WOODS_CONSOLE_UNSAFE_EVAL` is on:
        # - refuse outright in `Rails.env.production?` (non-negotiable),
        # - otherwise emit a LOUD stderr banner so operators know the flag
        #   is live even though eval remains unimplemented.
        #
        # Safe when Rails is not loaded (specs, non-Rails hosts).
        #
        # @return [void]
        # @raise [Woods::ConfigurationError] when the flag is on in production.
        def enforce_unsafe_eval_contract!
          return unless unsafe_eval_enabled?

          if defined?(Rails) && Rails.respond_to?(:env) && Rails.env.respond_to?(:production?) &&
             Rails.env.production?
            raise Woods::ConfigurationError,
                  'WOODS_CONSOLE_UNSAFE_EVAL is set but Rails.env.production? is true. ' \
                  'console_eval cannot be opted into in production. Unset the flag or ' \
                  'restart in a non-production environment.'
          end

          warn unsafe_eval_banner
        end

        # Resolves `Rails.application` when available, else nil.
        def default_rails_app
          return nil unless defined?(Rails) && Rails.respond_to?(:application)

          Rails.application
        end

        # Build a configured MCP::Server with console tools using the bridge protocol.
        #
        # ⚠ Layer 1 limitation in bridge mode:
        # The server side of the bridge has no access to the remote app's
        # `ActiveRecord::Base.descendants`, so model_tables and model_reflections
        # are empty. `TableGate#check_sql!` still fires against the raw SQL
        # argument of `console_sql`, but `check_model!`, `check_joins!`, and
        # `check_association!` are effectively no-ops for tools that receive a
        # model name rather than SQL (find, sample, count, etc.). A bridge-mode
        # deployment therefore relies on Layer 2 (credential scanning) + Layer 3
        # (column/EAV redaction) + Layer 4 (SqlValidator + SafeContext rollback)
        # for non-SQL tool calls. If you need full Layer 1 coverage, use
        # `build_embedded` (the stdio entry point `exe/woods-console` does this).
        #
        # See docs/CONSOLE_MCP_SETUP.md "Bridge vs. embedded defense coverage"
        # for the full matrix.
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
          safe_ctx = build_safe_context(redacted_columns, redacted_key_values)
          ctx = build_response_context(safe_ctx: safe_ctx, model_tables: {}, model_reflections: {})

          build_server(conn_mgr, ctx)
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
                           read_tools_enabled: false, model_tables: {},
                           model_reflections: {})
          require_relative 'embedded_executor'
          enforce_unsafe_eval_contract!

          executor = EmbeddedExecutor.new(
            model_validator: model_validator, safe_context: safe_context,
            connection: connection, read_tools_enabled: read_tools_enabled
          )
          safe_ctx = build_safe_context(redacted_columns, redacted_key_values)
          ctx = build_response_context(safe_ctx: safe_ctx, model_tables: model_tables,
                                       model_reflections: model_reflections)

          build_server(executor, ctx)
        end

        # Register all tool specs for a given tier on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param ctx [ResponseContext, nil] Optional context bundling response-safety layers
        # @param tier [Integer] Tier number (1-4)
        # @param renderer [ConsoleResponseRenderer, nil] Optional response renderer
        # @return [void]
        def register_tier_tools(server, conn_mgr, ctx, tier:, renderer: nil)
          TOOL_SPECS.select { |spec| spec.tier == tier }.each do |spec|
            register(spec, server, conn_mgr, ctx, renderer: renderer)
          end
        end

        # Register Tier 1 read-only tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param ctx [ResponseContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier1_tools(server, conn_mgr, ctx = nil, renderer: nil)
          register_tier_tools(server, conn_mgr, ctx, tier: 1, renderer: renderer)
        end

        # Register Tier 2 domain-aware tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param ctx [ResponseContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier2_tools(server, conn_mgr, ctx = nil, renderer: nil)
          register_tier_tools(server, conn_mgr, ctx, tier: 2, renderer: renderer)
        end

        # Register Tier 3 analytics tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param ctx [ResponseContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier3_tools(server, conn_mgr, ctx = nil, renderer: nil)
          register_tier_tools(server, conn_mgr, ctx, tier: 3, renderer: renderer)
        end

        # Register Tier 4 guarded tools on the server.
        #
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param ctx [ResponseContext, nil] Optional context for column redaction
        # @return [void]
        def register_tier4_tools(server, conn_mgr, ctx = nil, renderer: nil)
          register_tier_tools(server, conn_mgr, ctx, tier: 4, renderer: renderer)
        end

        private

        # Register a single ToolSpec on the MCP server.
        #
        # Wires the spec's handler through the bridge/executor pipeline, table gate,
        # integer coercion, and credential scanning. This is the single registration
        # point that replaces the 29 individual define_<tool> methods.
        #
        # @param spec [ToolSpec] The tool specification
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param ctx [ResponseContext, nil] Response context (table gate, scanner, safe_ctx)
        # @param renderer [ConsoleResponseRenderer, nil] Optional response renderer
        # @return [void]
        def register(spec, server, conn_mgr, ctx, renderer: nil)
          schema = spec_schema(spec)
          tool_name = spec.name
          handler = spec.handler
          bridge_method = method(:send_to_bridge)
          coerce_method = method(:coerce_integer_args!)
          gate_method = method(:enforce_table_gate!)
          log_gate_method = method(:log_table_gate_rejection)
          dispatch_method = method(:dispatch_tool)
          integer_keys = integer_property_keys(spec.properties)

          server.define_tool(name: tool_name, description: spec.description,
                             input_schema: schema) do |server_context:, **args|
            coerce_method.call(args, integer_keys)
            dispatch_method.call(gate_method, log_gate_method, tool_name, ctx, args) do
              bridge_method.call(conn_mgr, handler.call(args).transform_keys(&:to_s), ctx, renderer: renderer)
            end
          end
        end

        # Build the JSON Schema object for a ToolSpec.
        #
        # @param spec [ToolSpec]
        # @return [Hash]
        def spec_schema(spec)
          schema = { properties: spec.properties }
          schema[:required] = spec.required if spec.required&.any?
          schema
        end

        # Run the table-gate check then dispatch the tool handler, translating
        # TableGateError, SqlValidationError, and ForbiddenExpressionError into
        # MCP error responses.
        #
        # @param gate_method [Method]
        # @param log_gate_method [Method]
        # @param tool_name [String]
        # @param ctx [ResponseContext, nil]
        # @param args [Hash]
        # @yield Executes the tool dispatch when gate passes
        # @return [MCP::Tool::Response]
        def dispatch_tool(gate_method, log_gate_method, tool_name, ctx, args)
          gate_method.call(ctx&.table_gate, args)
          yield
        rescue TableGateError => e
          log_gate_method.call(tool_name, args, e)
          ::MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
        rescue SqlValidationError, ForbiddenExpressionError => e
          ::MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
        end

        # Build a SafeContext (Layer 3) from redaction settings, or nil when nothing is configured.
        #
        # @param redacted_columns [Array<String>]
        # @param redacted_key_values [Array<Hash>]
        # @return [SafeContext, nil]
        def build_safe_context(redacted_columns, redacted_key_values)
          return nil unless redacted_columns.any? || redacted_key_values.any?

          SafeContext.new(
            connection: nil,
            redacted_columns: redacted_columns,
            redacted_key_values: redacted_key_values
          )
        end

        # Bundle the three response-safety layers into a ResponseContext the
        # server can thread through every tool. Returns nil when every layer is
        # absent so callers can skip wiring.
        #
        # @param safe_ctx [SafeContext, nil] Layer 3 (column + EAV redaction)
        # @param model_tables [Hash{String=>String}] Model => table registry for Layer 1
        # @param model_reflections [Hash{String=>Hash{String=>String}}] Model => { association => table }
        # @return [ResponseContext, nil]
        def build_response_context(safe_ctx:, model_tables:, model_reflections: {})
          config = Woods.configuration if Woods.respond_to?(:configuration)
          blocked = Array(config&.console_blocked_tables)
          table_gate = if blocked.any?
                         TableGate.new(blocked_tables: blocked, model_tables: model_tables,
                                       model_reflections: model_reflections)
                       end

          secret_index = build_credential_index(config)
          scanner = if config.nil? || config.console_credential_scanning_enabled != false
                      CredentialScanner.new(
                        disabled_patterns: Array(config&.console_disabled_scanner_patterns),
                        secret_index: secret_index
                      )
                    end
          @active_scanner = scanner

          ResponseContext.build(safe_ctx: safe_ctx, table_gate: table_gate, credential_scanner: scanner)
        end

        # Build the boot-time credential index from Rails.application's encrypted
        # credentials. Returns nil when credential defense is disabled or when no
        # Rails application is reachable (specs, non-Rails hosts) — the scanner
        # then falls back to its pattern-only behavior.
        #
        # When `console_credential_rotation_warning` is enabled (default: true),
        # also emits a structured log warning if any credentials file on disk was
        # modified after this process started — a strong signal that credentials
        # were rotated without restarting the MCP process. Disable with:
        #
        #   config.console_credential_rotation_warning = false
        #
        # @param config [Woods::Configuration, nil]
        # @return [CredentialIndex, nil]
        def build_credential_index(config)
          return nil unless config&.console_credential_defense_enabled
          return nil unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

          index = CredentialIndex.build(rails_app: Rails.application)
          maybe_warn_rotation(config, Rails.application)
          index
        end

        # Emit a boot-time rotation warning when the credentials file mtime is
        # newer than the process start time, indicating a rotation that was not
        # followed by a restart. Only fires when Rails.root is available and
        # `console_credential_rotation_warning` is not false.
        #
        # @param config [Woods::Configuration, nil]
        # @param rails_app [#root] The Rails application (used to locate credential files).
        # @return [void]
        def maybe_warn_rotation(config, rails_app)
          return if config&.console_credential_rotation_warning == false
          return unless rails_app.respond_to?(:root) && rails_app.root

          root = rails_app.root
          candidates = [
            root.join('config/credentials.yml.enc').to_s,
            root.join("config/credentials/#{ENV.fetch('RAILS_ENV', 'production')}.yml.enc").to_s
          ]

          CredentialIndex.warn_if_credentials_rotated(
            credentials_files: candidates,
            process_start: CredentialIndex::PROCESS_START,
            logger: structured_logger
          )
        rescue StandardError => e
          handle_observability_failure(e)
        end

        # Shared server construction used by both build() and build_embedded().
        #
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Any object with send_request(Hash) -> Hash
        # @param ctx [ResponseContext, nil] Optional context bundling response-safety layers
        # @return [MCP::Server]
        def build_server(conn_mgr, ctx)
          server = ::MCP::Server.new(
            name: 'woods-console',
            version: defined?(Woods::VERSION) ? Woods::VERSION : '0.1.0'
          )

          renderer = build_console_renderer

          register_tier1_tools(server, conn_mgr, ctx, renderer: renderer)
          register_tier2_tools(server, conn_mgr, ctx, renderer: renderer)
          register_tier3_tools(server, conn_mgr, ctx, renderer: renderer)
          register_tier4_tools(server, conn_mgr, ctx, renderer: renderer)
          server
        end

        def respond(text)
          ::MCP::Tool::Response.new([{ type: 'text', text: text }])
        end

        def send_to_bridge(conn_mgr, request, ctx = nil, renderer: nil)
          response = conn_mgr.send_request(request)
          if response['ok']
            result = response['result']
            result = apply_redaction(result, ctx.safe_ctx) if ctx&.safe_ctx
            result = scan_for_credentials(result, request, ctx)
            text = renderer ? renderer.render_default(result) : JSON.pretty_generate(result)
            respond(text)
          else
            error_text = "#{response['error_type']}: #{response['error']}"
            error_text = scan_for_credentials(error_text, request, ctx)
            ::MCP::Tool::Response.new(
              [{ type: 'text', text: error_text }],
              error: true
            )
          end
        rescue ConnectionError => e
          scanned = scan_for_credentials("Connection error: #{e.message}", request, ctx)
          ::MCP::Tool::Response.new([{ type: 'text', text: scanned }], error: true)
        end

        # Run Layer 2 against the result and emit a structured log line when
        # the scanner actually redacted anything. Returns the scanned result
        # (or the original when the scanner isn't configured).
        def scan_for_credentials(result, request, ctx)
          return result unless ctx&.credential_scanner

          scanned, counts = ctx.credential_scanner.scan(result)
          log_credential_hits(request, counts) unless counts.empty?
          scanned
        end

        def log_credential_hits(request, counts)
          structured_logger.warn(
            'console.credential_scan.hits',
            tool: request['tool'],
            counts: counts.transform_keys(&:to_s),
            total: counts.values.sum
          )
        rescue StandardError => e
          handle_observability_failure(e)
        end

        # Loud multi-line banner surfaced to stderr when the opt-in flag is
        # recognised outside of production. Operators should see this every
        # boot so an accidentally-persistent env var cannot go unnoticed.
        #
        # @return [String]
        def unsafe_eval_banner
          <<~BANNER

            ================================================================================
             WOODS_CONSOLE_UNSAFE_EVAL IS SET
             console_eval opt-in scaffolding is active. Execution is STILL NOT IMPLEMENTED
             (backlog: unsafe-eval-opt-in). The flag will also refuse to boot in
             Rails.env.production?. If you did not mean to set this, unset the env var.
            ================================================================================
          BANNER
        end

        def structured_logger
          @structured_logger ||= begin
            require 'woods/observability/structured_logger'
            Woods::Observability::StructuredLogger.new
          end
        end

        # Swallow observability failures so they never break a tool response,
        # but emit a single warn so operators can see if the structured
        # logging pipeline is broken. Subsequent failures stay silent to
        # avoid flooding stderr.
        def handle_observability_failure(error)
          return if @observability_failure_reported

          @observability_failure_reported = true
          warn '[woods-console] structured logger failed ' \
               "(#{error.class}: #{error.message}); further failures will be silent."
        rescue StandardError
          nil
        end

        # Data-shape keys used by console tool responses. When any of these keys
        # appear at the top of a Hash result we treat the value as row data and
        # descend into it instead of redacting at the envelope level.
        #
        # Full recursive descent is intentionally NOT used here. Some tools return
        # Hashes whose keys happen to be column names but whose values are metadata
        # objects, not row data — e.g. `console_schema` returns
        # {columns: {col_name => {type:..., null:...}}}. Recursing into that Hash
        # would incorrectly replace schema metadata with "[REDACTED]" whenever a
        # column name matches a redacted_columns entry. Keeping a closed list of
        # envelope keys that carry actual row data is therefore the safer choice.
        #
        # When adding a new Tier 2/3 tool that returns row data under a new envelope
        # key, add that key here AND add a matching `when` branch in
        # `redact_envelope_value` that applies the appropriate redaction strategy.
        DATA_ENVELOPE_KEYS = %w[record records rows values associations].freeze
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
        # @param ctx [SafeContext] The context with redacted_columns configured
        # @return [Object] Redacted result, same shape as input
        def apply_redaction(result, ctx)
          case result
          when Array
            result.map { |item| item.is_a?(Hash) ? apply_redaction(item, ctx) : item }
          when Hash
            redact_hash(result, ctx)
          else
            result
          end
        end

        def redact_hash(hash, ctx)
          string_keyed = hash.transform_keys(&:to_s)
          return ctx.redact(string_keyed) unless (string_keyed.keys & DATA_ENVELOPE_KEYS).any?

          plan = positional_plan(string_keyed['columns'], ctx)
          string_keyed.each_with_object({}) do |(key, value), out|
            out[key] = redact_envelope_value(key, value, plan, ctx)
          end
        end

        def redact_envelope_value(key, value, plan, ctx)
          case key
          when 'record'         then value.is_a?(Hash) ? ctx.redact(value) : value
          when 'records'        then redact_hash_array(value, ctx)
          when 'rows', 'values' then redact_positional(value, plan)
          when 'associations'   then redact_association_map(value, ctx)
          else                       value
          end
        end

        def redact_hash_array(value, ctx)
          Array(value).map { |row| row.is_a?(Hash) ? ctx.redact(row) : row }
        end

        # Redact an associations map returned by console_data_snapshot.
        #
        # The associations payload has the shape:
        #   { "assoc_name" => [Hash, ...], ... }
        # Each value is an Array of record Hashes. We redact each record
        # the same way we handle `records` (column-name + EAV rules).
        #
        # @param value [Hash, nil] Association map
        # @param ctx [SafeContext]
        # @return [Hash, nil]
        def redact_association_map(value, ctx)
          return value unless value.is_a?(Hash)

          value.each_with_object({}) do |(assoc_name, assoc_records), out|
            out[assoc_name] = redact_hash_array(assoc_records, ctx)
          end
        end

        # Precompute everything needed to redact positional rows for a given
        # `columns` header: the column-name mask plus any EAV key-value rules
        # resolved to column indexes. Returns a plain Hash so callers can pass
        # it around without extra struct ceremony.
        def positional_plan(columns, ctx)
          { mask: positional_mask(columns, ctx),
            kv_rules: positional_kv_rules(columns, ctx) }
        end

        # Precompute the positional redaction mask from a `columns` header.
        # Returns nil when there is nothing to redact so callers can short-circuit.
        def positional_mask(columns, ctx)
          return nil unless columns.is_a?(Array)

          redacted = ctx.redacted_columns
          return nil if redacted.empty?

          mask = columns.map { |name| redacted.include?(name.to_s) }
          mask.any? ? mask : nil
        end

        # Resolve EAV patterns against a `columns` header into concrete index
        # pairs. A rule only fires when both key_column and value_column are
        # present in the header, and costs nothing per row otherwise.
        def positional_kv_rules(columns, ctx)
          return [] unless columns.is_a?(Array)

          index = columns.each_with_index.to_h { |name, idx| [name.to_s, idx] }
          ctx.redacted_key_values.filter_map do |pattern|
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

        # Run the Layer 1 blocked-table gate against the arguments a tool was
        # invoked with. Tools may arrive at tables through five different
        # arg shapes — SQL string, model name, raw table, joined associations,
        # or a single association name — so the gate checks every variant that's
        # present. A no-op when the gate is nil.
        #
        # @param gate [TableGate, nil]
        # @param args [Hash] Tool arguments (symbol keys from MCP dispatch)
        # @raise [TableGateError] if any referenced identifier is blocked
        def enforce_table_gate!(gate, args) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          return unless gate

          gate.check_sql!(args[:sql]) if args[:sql]
          gate.check_model!(args[:model]) if args[:model]
          gate.check_table!(args[:table]) if args[:table]
          gate.check_joins!(args[:model], args[:joins]) if args[:model] && args[:joins]
          return unless args[:model] && args[:association]

          gate.check_association!(args[:model], args[:association])
        end

        def log_table_gate_rejection(tool_name, args, error)
          structured_logger.warn(
            'console.table_gate.rejected',
            tool: tool_name,
            model: args[:model],
            table: args[:table],
            has_sql: args[:sql] ? true : false,
            message: error.message
          )
        rescue StandardError => e
          handle_observability_failure(e)
        end

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
      end
    end
  end
end
