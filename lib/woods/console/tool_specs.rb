# frozen_string_literal: true

# This file is a pure data table — 31 ToolSpec entries across 4 tiers
# (9 read-only / 9 domain-aware / 10 analytics / 3 guarded).
# Metrics/ModuleLength is disabled here because the module body is almost
# entirely declarative data, not imperative logic. Decomposition would just
# scatter the tool catalogue across many files with no readability gain.
# rubocop:disable Metrics/ModuleLength
module Woods
  module Console
    module Server
      TIER1_TOOLS = %w[count sample find pluck aggregate association_count schema recent status].freeze
      TIER2_TOOLS = %w[diagnose_model data_snapshot validate_record check_setting update_setting
                       check_policy validate_with check_eligibility decorate].freeze
      TIER3_TOOLS = %w[slow_endpoints error_rates throughput job_queues job_failures job_find
                       job_schedule redis_info cache_stats channel_status].freeze
      TIER4_TOOLS = %w[eval sql query].freeze

      MIN_INTEGER_INPUT = 1
      MAX_RECORD_ID = 9_223_372_036_854_775_807

      # Authoritative grammar shared by the public JSON Schema and executor.
      # Schema and Ruby use different end-anchor syntax, but the executable
      # template body is defined once so accepted SQL cannot drift.
      HAVING_TEMPLATE_GRAMMAR =
        '\\s*(?:([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)?)|' \
        '(SUM|AVG|MIN|MAX|COUNT)\\s*\\(\\s*' \
        '(\\*|[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)?)\\s*\\))' \
        '\\s*(=|!=|<>|<=|>=|<|>)\\s*\\?\\s*'
      HAVING_TEMPLATE_SCHEMA_PATTERN = "^(?:#{HAVING_TEMPLATE_GRAMMAR})$(?![\\s\\S])".freeze
      HAVING_TEMPLATE_REGEXP = Regexp.new("\\A(?:#{HAVING_TEMPLATE_GRAMMAR})\\z").freeze

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

      # All 31 possible Console tool specifications, grouped by tier. Runtime
      # registration is derived separately in EXECUTABLE_MODES: Tier 1 is
      # executable in both embedded modes, and sql/query are executable only
      # in explicit embedded-read mode. Tier 2, Tier 3, and eval remain an
      # unregistered inventory until real executors and enforceable controls
      # exist for them.
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
            limit: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 25,
                     description: 'Max records (default 5, max 25)' },
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
            id: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: MAX_RECORD_ID,
                  description: 'Primary key value' },
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
            limit: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 1000,
                     description: 'Max records (default 100, max 1000)' },
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
            id: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: MAX_RECORD_ID,
                  description: 'Record primary key' },
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
            limit: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 50,
                     description: 'Max records (default 10, max 50)' },
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
            sample_size: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 25,
                           description: 'Sample records (default 5, max 25)' }
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
            id: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: MAX_RECORD_ID,
                  description: 'Record primary key' },
            associations: { type: 'array', items: { type: 'string' }, description: 'Association names to include' },
            depth: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 3,
                     description: 'Association depth (default 1, max 3)' }
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
            id: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: MAX_RECORD_ID,
                  description: 'Record primary key' },
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
            id: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: MAX_RECORD_ID,
                  description: 'Record primary key' },
            user_id: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: MAX_RECORD_ID,
                       description: 'User to check' },
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
            id: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: MAX_RECORD_ID,
                  description: 'Record primary key' },
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
            id: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: MAX_RECORD_ID,
                  description: 'Record primary key' },
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
            limit: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 100,
                     description: 'Max endpoints (default 10, max 100)' },
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
            limit: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 100,
                     description: 'Max failures (default 10, max 100)' },
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
            limit: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 100,
                     description: 'Max jobs (default 20, max 100)' }
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
            timeout: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 30,
                       description: 'Timeout in seconds (default 10, max 30)' }
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
            limit: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 10_000,
                     description: 'Max rows returned (default unlimited, max 10000)' }
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
            having: { type: %w[object array],
                      oneOf: [
                        { type: 'object', minProperties: 1 },
                        {
                          type: 'array', minItems: 2, maxItems: 2,
                          prefixItems: [{ type: 'string', pattern: HAVING_TEMPLATE_SCHEMA_PATTERN }, {}]
                        }
                      ],
                      description: 'HAVING condition object or parameterized [template, bind] array' },
            order: { type: 'object',
                     description: 'Order specification as {column => direction} (e.g. {"created_at" => "desc"})' },
            scope: { type: 'object',
                     description: 'WHERE conditions as {column => value} or [sql, bind] array' },
            limit: { type: 'integer', minimum: MIN_INTEGER_INPUT, maximum: 10_000,
                     description: 'Maximum rows to return (default 10000, hard max 10000)' }
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

      EXECUTABLE_MODES = {
        embedded: TIER1_TOOLS.map { |name| "console_#{name}" }.freeze,
        embedded_read: (TIER1_TOOLS + %w[sql query]).map { |name| "console_#{name}" }.freeze
      }.freeze

      REPRESENTATIVE_ARGUMENT_VALUES = {
        model: 'Post', columns: ['id'], id: 1, function: 'count', association: 'comments',
        key: 'feature_flag', value: 'enabled', user_id: 1, action: 'show',
        attributes: { 'title' => 'Example' }, feature: 'preview', job_id: 'job-1',
        code: '1 + 1', sql: 'SELECT 1', select: ['id']
      }.freeze

      INVALID_ARGUMENT_VALUES = {
        'string' => [], 'integer' => 'not-an-integer', 'boolean' => 'not-a-boolean',
        'object' => [], 'array' => {}
      }.freeze

      SEMANTIC_OUTPUT_SHAPES = {
        'console_count' => { count: :integer },
        'console_sample' => { records: :array_of_records },
        'console_find' => { record: :record_or_null },
        'console_pluck' => { columns: :array_of_strings, values: :array },
        'console_aggregate' => { value: :number_or_null },
        'console_association_count' => { count: :integer },
        'console_schema' => { columns: :column_metadata_by_name, indexes: :optional_index_metadata },
        'console_recent' => { records: :array_of_records },
        'console_status' => { status: :string, models: :array_of_strings, adapter: :string },
        'console_diagnose_model' => { diagnostic: :count_recent_and_aggregates },
        'console_data_snapshot' => { record: :record, associations: :records_by_association },
        'console_validate_record' => { valid: :boolean, errors: :validation_errors },
        'console_check_setting' => { setting: :key_value },
        'console_update_setting' => { updated: :boolean, setting: :key_value },
        'console_check_policy' => { allowed: :boolean },
        'console_validate_with' => { valid: :boolean, errors: :validation_errors },
        'console_check_eligibility' => { eligible: :boolean },
        'console_decorate' => { record: :record, computed: :object },
        'console_slow_endpoints' => { endpoints: :performance_rows },
        'console_error_rates' => { error_rates: :rate_rows },
        'console_throughput' => { throughput: :time_series },
        'console_job_queues' => { queues: :queue_statistics },
        'console_job_failures' => { failures: :job_failure_rows },
        'console_job_find' => { job: :job_or_null, retried: :optional_boolean },
        'console_job_schedule' => { jobs: :scheduled_job_rows },
        'console_redis_info' => { info: :redis_section_map },
        'console_cache_stats' => { stats: :cache_statistics },
        'console_channel_status' => { channels: :channel_status_rows },
        'console_eval' => { value: :ruby_value },
        'console_sql' => { columns: :array_of_strings, rows: :array_of_arrays, count: :integer },
        'console_query' => { columns: :array_of_strings, rows: :array_of_arrays, count: :integer }
      }.transform_values(&:freeze).freeze

      TABLE_GATE_CONTRACTS = {
        'console_count' => :model_before_execution,
        'console_sample' => :model_before_execution,
        'console_find' => :model_before_execution,
        'console_pluck' => :model_before_execution,
        'console_aggregate' => :model_before_execution,
        'console_association_count' => :model_and_association_before_execution,
        'console_schema' => :model_before_execution,
        'console_recent' => :model_before_execution,
        'console_status' => :not_applicable_status_metadata,
        'console_sql' => :sql_before_execution,
        'console_query' => :model_joins_and_rendered_sql_before_execution
      }.freeze

      REDACTION_CONTRACTS = {
        'console_count' => :not_applicable_scalar_count,
        'console_sample' => :record_columns_and_eav,
        'console_find' => :record_columns_and_eav,
        'console_pluck' => :positional_columns_and_eav,
        'console_aggregate' => :not_applicable_scalar_aggregate,
        'console_association_count' => :not_applicable_scalar_count,
        'console_schema' => :not_applicable_schema_metadata,
        'console_recent' => :record_columns_and_eav,
        'console_status' => :not_applicable_status_metadata,
        'console_sql' => :positional_columns_and_eav,
        'console_query' => :positional_columns_and_eav
      }.freeze

      TRANSPORT_AUTHORIZATION = {
        stdio: :host_process_access,
        railtie_http: :bearer_token_required
      }.freeze

      CONFIRMATION_REQUIREMENTS = {
        'console_update_setting' => :required_before_registration,
        'console_job_find' => :required_for_retry_before_registration,
        'console_eval' => :required_before_registration
      }.freeze

      AUDIT_REQUIREMENTS = {
        'console_eval' => :required_before_registration
      }.freeze

      # Code-derived inventory of all 31 possible Console tools. Argument
      # names, constraints, and representative schema cases come directly
      # from TOOL_SPECS. Only output semantics and control behavior that cannot
      # be inferred from JSON Schema are declared above.
      # rubocop:disable Metrics/BlockLength
      CONTRACT_MATRIX = TOOL_SPECS.map do |spec|
        modes = EXECUTABLE_MODES.filter_map { |mode, names| mode if names.include?(spec.name) }.freeze
        executable = modes.any?
        required = Array(spec.required).freeze
        optional = (spec.properties.keys.map(&:to_s) - required).freeze
        valid_input = required.to_h do |name|
          [name.to_sym, REPRESENTATIVE_ARGUMENT_VALUES.fetch(name.to_sym)]
        end.freeze

        invalid_arguments = if required.any?
                              valid_input.reject { |name, _value| name == required.first.to_sym }.freeze
                            elsif spec.properties.any?
                              name, definition = spec.properties.first
                              { name => INVALID_ARGUMENT_VALUES.fetch(Array(definition.fetch(:type)).first) }.freeze
                            else
                              [].freeze
                            end

        {
          name: spec.name,
          executable_modes: modes,
          arguments: {
            required: required,
            optional: optional,
            constraints: spec.properties
          }.freeze,
          representative_valid_input: valid_input,
          representative_invalid_input: {
            arguments: invalid_arguments,
            error_class: 'MCP::Tool::InputSchema::ValidationError'
          }.freeze,
          semantic_output: {
            availability: executable ? :executable : :inventory_only,
            shape: SEMANTIC_OUTPUT_SHAPES.fetch(spec.name)
          }.freeze,
          authorization: executable ? TRANSPORT_AUTHORIZATION : :not_applicable_unregistered,
          table_gate: executable ? TABLE_GATE_CONTRACTS.fetch(spec.name) : :not_active_unregistered,
          redaction: executable ? REDACTION_CONTRACTS.fetch(spec.name) : :not_active_unregistered,
          credential_scan: executable ? :response_and_error_text_when_enabled : :not_active_unregistered,
          confirmation: CONFIRMATION_REQUIREMENTS.fetch(spec.name, :not_required),
          audit: AUDIT_REQUIREMENTS.fetch(spec.name, executable ? :not_recorded : :not_active_unregistered)
        }.freeze
      end.freeze
      # rubocop:enable Metrics/BlockLength
    end
  end
end
# rubocop:enable Metrics/ModuleLength
