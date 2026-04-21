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
require_relative 'redactor'
require_relative 'response_context'
require_relative 'tool_specs'

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
      class << self # rubocop:disable Metrics/ClassLength
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
          log_gate_method = method(:log_table_gate_rejection)
          dispatch_method = method(:dispatch_tool)
          integer_keys = integer_property_keys(spec.properties)

          server.define_tool(name: tool_name, description: spec.description,
                             input_schema: schema) do |server_context:, **args|
            coerce_method.call(args, integer_keys)
            dispatch_method.call(log_gate_method, tool_name, ctx, args) do
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
        def dispatch_tool(log_gate_method, tool_name, ctx, args)
          ctx.enforce!(args)
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

        def send_to_bridge(conn_mgr, request, ctx = NullResponseContext.instance, renderer: nil)
          response = conn_mgr.send_request(request)
          if response['ok']
            result = ctx.redact(response['result'])
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
        # (or the original when the scanner is not configured — NullResponseContext
        # returns an empty counts hash, which suppresses logging).
        def scan_for_credentials(result, request, ctx)
          scanned, counts = ctx.scan(result)
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

        # Legacy delegate to {Redactor.apply} — kept so the server's class-level
        # spec can drive redaction without constructing a ResponseContext.
        def apply_redaction(result, ctx)
          Redactor.apply(result, ctx)
        end

        def build_console_renderer
          format = if Woods.respond_to?(:configuration)
                     Woods.configuration&.context_format || :markdown
                   else
                     :markdown
                   end
          format == :json ? JsonConsoleRenderer.new : ConsoleResponseRenderer.new
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
