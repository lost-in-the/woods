# frozen_string_literal: true

require 'mcp'
require_relative '../mcp/protocol_policy'
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
require_relative 'dispatch_pipeline'
require_relative 'tool_specs'

module Woods
  # Same conditional-define pattern used elsewhere in the gem (e.g.
  # Storage::MetadataStore) so this file can be required in isolation
  # without tripping NameError on the raise in Server.build below.
  class Error < StandardError; end unless defined?(Woods::Error)
  class ConfigurationError < Error; end unless defined?(Woods::ConfigurationError)

  module Console
    # Console MCP Server — queries live Rails application state.
    #
    # Executes against a booted Rails application. The default embedded mode
    # exposes 9 Tier 1 tools; explicit read-tool mode adds console_sql and
    # console_query. The full 31-tool catalogue remains inventory-only.
    #
    # @example
    #   server = Woods::Console::Server.build_embedded(
    #     model_validator: validator,
    #     safe_context: safe_context
    #   )
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
        # Returns nil when credential defense is disabled or no embedded server
        # has been built yet in this process.
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

        # True when legacy configuration requests the unsupported eval path.
        # Explicit config wins over the environment in both directions.
        #
        # @return [Boolean]
        def unsafe_eval_enabled?
          config = Woods.configuration if Woods.respond_to?(:configuration)
          explicit = config&.console_unsafe_eval_enabled
          return explicit if [true, false].include?(explicit)

          ENV['WOODS_CONSOLE_UNSAFE_EVAL'] == 'true'
        end

        # Fail closed because no supported MCP mode registers console_eval.
        def enforce_unsafe_eval_contract!(legacy_options_present: false)
          return unless unsafe_eval_enabled? || legacy_options_present

          raise Woods::ConfigurationError,
                'WOODS_CONSOLE_UNSAFE_EVAL is set, but console_eval is not available in a ' \
                'supported Console MCP mode. Unset the flag; use console_query or console_sql.'
        end

        # Resolves `Rails.application` when available, else nil.
        def default_rails_app
          return nil unless defined?(Rails) && Rails.respond_to?(:application)

          Rails.application
        end

        # The former JSON-lines bridge never executed live queries. Keep this
        # entry point fail-closed so legacy callers cannot receive fabricated
        # empty responses.
        # @param config [Hash] Configuration hash (from YAML or env)
        # @raise [Woods::ConfigurationError] always
        def build(config:) # rubocop:disable Lint/UnusedMethodArgument
          raise Woods::ConfigurationError,
                'The JSON-lines Console bridge is not supported. Use Server.build_embedded, ' \
                'rake woods:console, or Woods::Console::RackMiddleware.'
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
        # @param unsafe_eval_confirmation [Confirmation, nil] Retained for API compatibility;
        #   no supported mode registers console_eval.
        # @param unsafe_eval_audit_log_path [String, Pathname, nil] Retained for API compatibility.
        # @return [MCP::Server] Configured server ready for transport
        def build_embedded(model_validator:, safe_context:, redacted_columns: [], # rubocop:disable Metrics/ParameterLists
                           redacted_key_values: [], connection: nil,
                           read_tools_enabled: false, model_tables: {},
                           model_reflections: {},
                           unsafe_eval_confirmation: nil,
                           unsafe_eval_audit_log_path: nil)
          require_relative 'embedded_executor'
          enforce_unsafe_eval_contract!(
            legacy_options_present: unsafe_eval_confirmation || unsafe_eval_audit_log_path
          )

          safe_ctx, render_ctx = policy_contexts(safe_context, redacted_columns, redacted_key_values)
          ctx = build_response_context(safe_ctx: render_ctx, model_tables: model_tables,
                                       model_reflections: model_reflections)

          # Wire the same TableGate into the executor so sql/query are blocked
          # PRE-execution against console_blocked_tables (previously TableGate
          # was only consulted on the render path, leaving the defense inert
          # for the sql and query tools).
          executor = EmbeddedExecutor.new(
            model_validator: model_validator, safe_context: safe_ctx,
            connection: connection, read_tools_enabled: read_tools_enabled,
            table_gate: ctx&.table_gate
          )

          mode = read_tools_enabled ? :embedded_read : :embedded
          build_server(executor, ctx, tool_names: executable_tool_names(mode))
        end

        # Resolve the exact tool list for a supported embedded mode from the
        # same matrix used by tests and documentation evidence.
        def executable_tool_names(mode)
          CONTRACT_MATRIX.filter_map { |row| row[:name] if row[:executable_modes].include?(mode) }
        end

        private

        # Register a single ToolSpec on the MCP server.
        #
        # Hands every tool a dedicated {DispatchPipeline} that owns the full
        # args → gate → bridge → redact → scan → respond flow. The
        # `define_tool` block stays a one-liner that delegates to the pipeline.
        #
        # @param spec [ToolSpec] The tool specification
        # @param server [MCP::Server] The MCP server instance
        # @param conn_mgr [ConnectionManager, EmbeddedExecutor] Request executor
        # @param ctx [ResponseContext, nil] Response context (table gate, scanner, safe_ctx)
        # @param renderer [ConsoleResponseRenderer, nil] Optional response renderer
        # @return [void]
        def register(spec, server, conn_mgr, ctx, renderer: nil)
          pipeline = DispatchPipeline.new(
            tool_name: spec.name,
            handler: spec.handler,
            properties: spec.properties,
            conn_mgr: conn_mgr,
            ctx: ctx || NullResponseContext.instance,
            renderer: renderer,
            logger: structured_logger
          )

          server.define_tool(name: spec.name, description: spec.description,
                             input_schema: spec_schema(spec)) do |server_context:, **args|
            pipeline.call(args)
          end
        end

        # Build the JSON Schema object for a ToolSpec.
        #
        # @param spec [ToolSpec]
        # @return [Hash]
        def spec_schema(spec)
          spec.input_schema
        end

        # Build the SafeContext (Layer 3) pair the embedded server runs on:
        # [executor context, render context].
        #
        # Audit finding B1: the transport-provided SafeContext owns the
        # connection/pool, the statement timeout, and the rolled-back
        # transaction. Building a second, render-only SafeContext for the
        # redaction lists left the executor's context without the policy, so
        # every executor-side redaction-oracle refusal was dead on the real
        # transports. Whenever redaction is EFFECTIVELY configured — the
        # kwargs when either is supplied, otherwise the lists the supplied
        # context itself carries — derive ONE policy-complete context from
        # the transport context ({SafeContext#with_redaction_policy} — same
        # pool/timeout/transaction behavior, plus the effective lists) and
        # hand that single context to both the executor and the response
        # renderer. The executor refuses oracle shapes; the renderer masks
        # the direct unaliased selections that remain permitted.
        #
        # Fails closed ({Woods::ConfigurationError}) when redaction is
        # effectively configured but the supplied object cannot derive a
        # policy-complete context: the previous silent split wiring left the
        # renderer disabled while the executor still ran the policy. When
        # nothing is effectively configured — no kwargs, and a context that
        # cannot be inspected — the caller's context passes through
        # untouched and the render context stays nil (NullResponseContext).
        #
        # @param safe_context [SafeContext, nil] Transport-provided Layer 3
        # @param redacted_columns [Array<String>]
        # @param redacted_key_values [Array<Hash>]
        # @return [Array(SafeContext, SafeContext, nil)] executor and render contexts
        def policy_contexts(safe_context, redacted_columns, redacted_key_values)
          configured_columns, configured_key_values = effective_policy(
            safe_context, redacted_columns, redacted_key_values
          )
          return [safe_context, nil] unless configured_columns.any? || configured_key_values.any?
          unless safe_context.respond_to?(:with_redaction_policy)
            raise Woods::ConfigurationError,
                  'Console redaction is configured, but the supplied SafeContext cannot derive a ' \
                  'policy-complete context (SafeContext#with_redaction_policy). Construction fails ' \
                  'closed: the executor would run with the policy while the renderer stays disabled.'
          end

          derived = safe_context.with_redaction_policy(
            redacted_columns: configured_columns,
            redacted_key_values: configured_key_values
          )
          [derived, derived]
        end

        # The effective redaction policy: the kwargs when either is supplied
        # (the documented configuration surface), otherwise the lists the
        # supplied context itself carries. Returns empty lists when no kwargs
        # were supplied and the context cannot be inspected (nil, or a
        # duck-typed object without the redacted_* readers) — nothing is
        # effectively configured, so construction proceeds with the caller's
        # context untouched.
        #
        # @return [Array(Array, Array)] [columns, key_values]
        def effective_policy(safe_context, redacted_columns, redacted_key_values)
          return [redacted_columns, redacted_key_values] if redacted_columns.any? || redacted_key_values.any?
          return [[], []] unless safe_context.respond_to?(:redacted_columns) &&
                                 safe_context.respond_to?(:redacted_key_values)

          [Array(safe_context.redacted_columns), Array(safe_context.redacted_key_values)]
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
          disabled_patterns = Array(config&.console_disabled_scanner_patterns)
          scanner = if disabled_patterns.include?(:all)
                      nil
                    else
                      CredentialScanner.new(
                        disabled_patterns: disabled_patterns,
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
        # @param conn_mgr [EmbeddedExecutor] Request executor
        # @param ctx [ResponseContext, nil] Optional context bundling response-safety layers
        # @param tool_names [Array<String>] Exact executable tool names to advertise
        # @return [MCP::Server]
        def build_server(conn_mgr, ctx, tool_names:)
          server = ::MCP::Server.new(
            name: 'woods-console',
            version: defined?(Woods::VERSION) ? Woods::VERSION : '0.1.0',
            **Woods::MCP::ProtocolPolicy.cache_hints
          )

          renderer = build_console_renderer

          TOOL_SPECS.select { |spec| tool_names.include?(spec.name) }.each do |spec|
            register(spec, server, conn_mgr, ctx, renderer: renderer)
          end
          Woods::MCP::ProtocolPolicy.sort_tools!(server)
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
      end
    end
  end
end
