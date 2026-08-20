# frozen_string_literal: true

require 'timeout'

require_relative 'audit_logger'
require_relative 'bridge_protocol'
require_relative 'confirmation'
require_relative 'eval_guard'
require_relative 'model_validator'
require_relative 'safe_context'
require_relative 'scope_predicate_parser'
require_relative 'sql_noise_stripper'
require_relative 'table_gate'

module Woods
  module Console
    # Executes supported Console requests directly through ActiveRecord in a
    # booted Rails process. Server registration limits callers to the subset
    # this executor can run with the configured safety controls.
    #
    # @example
    #   executor = EmbeddedExecutor.new(model_validator: validator, safe_context: ctx)
    #   response = executor.send_request({ 'tool' => 'count', 'params' => { 'model' => 'User' } })
    #   # => { 'ok' => true, 'result' => { 'count' => 42 }, 'timing_ms' => 1.2 }
    #
    class EmbeddedExecutor # rubocop:disable Metrics/ClassLength
      AGGREGATE_FUNCTIONS = %w[sum average minimum maximum count].freeze

      TIER1_TOOLS = BridgeProtocol::TIER1_TOOLS

      # Tools gated behind the read_tools_enabled flag.
      # sql/query have existing safety gates (SqlValidator, SafeContext rollback)
      # but require explicit opt-in for embedded mode.
      EMBEDDED_READ_TOOLS = %w[sql query].freeze

      MAX_SQL_LIMIT = 10_000
      MAX_QUERY_LIMIT = 10_000

      MIN_EVAL_TIMEOUT = 1
      MAX_EVAL_TIMEOUT = 30
      DEFAULT_EVAL_TIMEOUT = 10

      # @param model_validator [ModelValidator] Validates model/column names
      # @param safe_context [SafeContext] Wraps execution in rolled-back transaction
      # @param connection [Object, nil] Database connection for adapter detection
      # @param read_tools_enabled [Boolean] Enable sql/query tools in embedded mode (default: false)
      # @param table_gate [TableGate, nil] Enforces console_blocked_tables on every
      #   model/join/association/SQL access pre-execution. When nil, no table-level
      #   gate runs — an explicit signal from the server builder that no tables are
      #   configured as blocked. Callers should pass the live gate from
      #   {Server#build_response_context} so embedded mode matches the bridge's
      #   defense-in-depth posture.
      # @param eval_guard [#check!, nil] EvalGuard for the `console_eval` opt-in
      #   path. Required when `unsafe_eval_enabled` is true; nil otherwise.
      # @param confirmation [Confirmation, nil] Human-in-the-loop approval for
      #   `console_eval`. Required when `unsafe_eval_enabled` is true; nil
      #   otherwise.
      # @param audit_logger [AuditLogger, nil] Logs every `console_eval` attempt
      #   (refused, denied, or executed). Required when `unsafe_eval_enabled` is
      #   true; nil otherwise.
      # @param unsafe_eval_enabled [Boolean] When true, the executor wires the
      #   five-control eval path (guard + confirmation + SafeContext + timeout +
      #   audit). When false, `console_eval` returns the hard `eval_disabled`
      #   refusal as before.
      def initialize(model_validator:, safe_context:, connection: nil, read_tools_enabled: false, # rubocop:disable Metrics/ParameterLists
                     table_gate: nil, eval_guard: nil, confirmation: nil, audit_logger: nil,
                     unsafe_eval_enabled: false)
        @model_validator = model_validator
        @safe_context = safe_context
        @connection = connection
        @read_tools_enabled = read_tools_enabled
        @table_gate = table_gate
        @eval_guard = eval_guard
        @confirmation = confirmation
        @audit_logger = audit_logger
        @unsafe_eval_enabled = unsafe_eval_enabled
      end

      # Execute a tool request and return a response hash.
      #
      # Compatible with ConnectionManager#send_request — Server's `send_to_bridge`
      # calls this method and expects `{ 'ok' => true/false, ... }`.
      #
      # @param request [Hash] Request with 'tool' and 'params' keys
      # @return [Hash] Response with 'ok', 'result'/'error', and 'timing_ms'
      def send_request(request)
        # Deep-stringify keys — Tier1 tool builders use symbol keys, but the bridge
        # path naturally stringifies via JSON round-trip. Replicate that here.
        request = deep_stringify_keys(request)
        tool = request['tool']
        params = request['params'] || {}

        refusal = refusal_for(tool)
        return refusal if refusal

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = @safe_context.execute { dispatch(tool, params) }
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)

        { 'ok' => true, 'result' => result, 'timing_ms' => elapsed }
      rescue ValidationError => e
        # Validation messages are author-controlled — safe to return as-is so
        # callers can correct their request.
        { 'ok' => false, 'error' => e.message, 'error_type' => 'validation' }
      rescue StandardError => e
        # Execution errors come from adapters and can embed fragments of the
        # rejected SQL, schema names, column names, or partial table contents
        # (`PG::UndefinedColumn`, `Mysql2::Error`, etc.). Return a generic
        # reason to the client; log the full detail via Rails.logger when
        # available so operators can still debug.
        log_execution_error(e)
        { 'ok' => false, 'error' => sanitize_execution_error(e), 'error_type' => 'execution' }
      end

      private

      def sanitize_execution_error(error)
        klass = error.class.name
        # Well-known AR wrappers that contain the adapter error as their cause —
        # still surface the class name so logs can route, but don't echo the
        # message.
        "#{klass}: execution failed (details logged server-side)"
      end

      def log_execution_error(error)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        Rails.logger.warn(
          "[Woods::Console] execution error: #{error.class}: #{error.message}"
        )
      rescue StandardError
        # Never let logging break the request path.
      end

      # Return a pre-dispatch refusal hash for tools the executor cannot or
      # will not run, else nil to let dispatch proceed.
      #
      # `eval` is refused unconditionally when the opt-in is off. When the
      # opt-in is on, this returns nil and `handle_eval` runs the full
      # five-control path (guard → confirmation → SafeContext → timeout →
      # audit). See `Server.unsafe_eval_enabled?` for the flag semantics.
      #
      # @param tool [String] Tool name
      # @return [Hash, nil]
      def refusal_for(tool)
        if tool == 'eval'
          return nil if @unsafe_eval_enabled

          { 'ok' => false, 'error' => eval_disabled_message, 'error_type' => 'eval_disabled' }
        elsif !(TIER1_TOOLS.include?(tool) || (@read_tools_enabled && EMBEDDED_READ_TOOLS.include?(tool)))
          { 'ok' => false, 'error' => unsupported_message(tool), 'error_type' => 'unsupported' }
        end
      end

      # Self-describing error for tools the embedded executor cannot run.
      #
      # `sql`/`query` are gated behind `embedded_read_tools: true` — point the
      # caller at the flag. Everything else (Tier 2–4 domain/analytics tools)
      # requires the bridge architecture.
      #
      # @param tool [String] Tool name that was rejected
      # @return [String] Actionable error message
      def unsupported_message(tool)
        if EMBEDDED_READ_TOOLS.include?(tool)
          "Tool '#{tool}' requires embedded_read_tools: true on " \
            'Woods::Console::RackMiddleware, or use the bridge (Option D). ' \
            'See docs/CONSOLE_MCP_SETUP.md.'
        else
          "Tool '#{tool}' is not available in embedded mode — it requires the " \
            'bridge architecture (Option D in docs/CONSOLE_MCP_SETUP.md).'
        end
      end

      # Instructional error payload for console_eval when the opt-in is off.
      # The default posture is still "refused" — the opt-in must be enabled
      # explicitly (env var + fail-closed collaborators) before any Ruby runs.
      # The message:
      #   1. names why eval is off (default-off opt-in),
      #   2. points the agent at console_query / console_sql as the usual
      #      substitute (both already handle group_by/having/aggregates),
      #   3. tells the agent to surface its proposed Ruby snippet to the
      #      human before any retry — never silently re-invoke,
      #   4. tells operators exactly which flag + collaborators to wire to
      #      turn it on.
      #
      # @return [String] Multi-line actionable message.
      def eval_disabled_message
        <<~MSG.strip
          console_eval is disabled — the unsafe-eval opt-in is off by default.
          Use console_query (model + select + joins/group_by/having/order) or console_sql
          for anything you were about to run. Both already support aggregates and scoping.
          If you believe eval is still necessary, SHOW your proposed Ruby snippet to the
          user first and let them run it manually — do not retry console_eval automatically.
          Operators: set WOODS_CONSOLE_UNSAFE_EVAL=true (or console_unsafe_eval_enabled = true)
          AND wire console_unsafe_eval_confirmation + console_unsafe_eval_audit_log_path.
          The server refuses to boot with the flag on in Rails.env.production?, and refuses
          to boot with the flag on but any collaborator missing (fail-closed).
          See docs/CONSOLE_MCP_SETUP.md "console_eval opt-in" for the full checklist.
        MSG
      end

      # Handle the `console_eval` request on the opt-in path.
      #
      # Runs the five-control contract in order:
      #   1. EvalGuard.check! — parse-time AST denylist (credentials,
      #      reflection escapes, network, file-IO for credentials, shell).
      #   2. Confirmation.request_confirmation — human-in-the-loop approval.
      #      Callback mode lets the host route through a real approval UI;
      #      auto-deny is the fail-closed default when the host didn't wire one.
      #   3. SafeContext.execute — runs the code inside a rolled-back
      #      transaction so any writes are discarded.
      #   4. Timeout.timeout — clamps wall-clock time to MIN..MAX seconds.
      #   5. AuditLogger.log — records every outcome (refused/denied/ok/error)
      #      with CredentialScanner redaction on params and result_summary.
      #
      # Every exit path writes exactly one audit entry. Refusals caused by
      # missing collaborators ("eval_misconfigured") never reach here — the
      # server refuses to boot in that state.
      #
      # @param params [Hash] Must contain 'code'; optional 'timeout'
      # @return [Hash] { 'result' => <inspect of return value> }
      # @raise [ValidationError] on guard refusal, confirmation denial, or
      #   timeout. `send_request` turns these into { ok: false } responses.
      def handle_eval(params)
        code = params['code']
        raise ValidationError, 'Missing required parameter: code' if code.nil? || code.to_s.strip.empty?

        timeout = eval_timeout_from(params['timeout'])
        audit_params = { code: code, timeout: timeout }

        # guard_check! / confirm! each audit on refusal before re-raising,
        # so we only need an execution-time rescue around the eval itself.
        guard_check!(code, audit_params)
        confirm!(code, audit_params)

        execute_and_audit(code, timeout, audit_params)
      end

      def execute_and_audit(code, timeout, audit_params)
        result = run_eval_with_timeout(code, timeout)
        summary = audit_summary(result)
        audit(params: audit_params, confirmed: true, result_summary: summary)
        { 'result' => summary }
      rescue StandardError => e
        audit(params: audit_params, confirmed: true,
              result_summary: "error:#{e.class}:#{truncate(e.message)}")
        raise
      end

      # Validate + clamp the user-supplied timeout. Accepts a positive
      # Integer (or nil → default). Everything else is rejected so a
      # caller passing `timeout: 0` or `timeout: "forever"` hears about
      # it instead of silently getting MIN_EVAL_TIMEOUT.
      def eval_timeout_from(raw)
        return DEFAULT_EVAL_TIMEOUT if raw.nil?

        unless raw.is_a?(Integer) && raw.positive?
          raise ValidationError,
                "timeout must be a positive integer (#{MIN_EVAL_TIMEOUT}..#{MAX_EVAL_TIMEOUT})"
        end

        raw.clamp(MIN_EVAL_TIMEOUT, MAX_EVAL_TIMEOUT)
      end

      def guard_check!(code, audit_params)
        @eval_guard.check!(code)
      rescue ForbiddenExpressionError => e
        audit(params: audit_params, confirmed: false,
              result_summary: "guard-refused:#{truncate(e.message)}")
        raise ValidationError, "console_eval refused by EvalGuard: #{e.message}"
      end

      # Route approval through the host-supplied {Confirmation}. Passes
      # the FULL code (bounded at 1 KB) as the description so the
      # approval UI renders what was actually proposed, not just the
      # first line. `params:` carries the same full code so callbacks
      # that want to show more can dig into it.
      def confirm!(code, audit_params)
        @confirmation.request_confirmation(
          tool: 'console_eval',
          description: truncate(code, 1024),
          params: audit_params
        )
      rescue ConfirmationDeniedError => e
        audit(params: audit_params, confirmed: false,
              result_summary: "denied:#{truncate(e.message)}")
        raise ValidationError, 'console_eval denied by confirmation callback'
      end

      # Wrap the eval in a wall-clock timeout.
      #
      # `Timeout.timeout` on MRI uses a watchdog thread that calls
      # `Thread#raise` — a well-known footgun because the target thread can
      # be interrupted mid-operation and leak resource state. We accept the
      # risk here because the only resource held is the AR connection inside
      # SafeContext's transaction, which rolls back on any exception; the
      # connection is returned to the pool by the surrounding
      # `pool.with_connection` block. There is no safer stdlib primitive
      # for "bound arbitrary Ruby to N seconds wall-clock" on MRI today.
      def run_eval_with_timeout(code, timeout)
        Timeout.timeout(timeout) { eval_in_sandbox(code) }
      end

      # The literal `eval` call. Kept in its own method so the policy
      # decision (we *do* run arbitrary Ruby on the opt-in path) is visible
      # at one grep-able location. All five controls must have passed to
      # reach this method — callers other than `handle_eval` must not
      # invoke it.
      #
      # We eval via `Object.new.instance_eval` rather than `eval(code,
      # binding)` so `self` is a throwaway receiver, not the executor.
      # Without this isolation, a payload like `@audit_logger = nil; 1`
      # would silence the audit log by writing to the executor's own
      # instance variables (EvalGuard denies the reflection APIs but does
      # not catch the syntactic `@ivar = value` form on its own — that's
      # plugged separately in {EvalGuard#scan_assignment_nodes}).
      # Top-level constants (User, Rails, ActiveRecord::Base, etc.) still
      # resolve because constant lookup on `instance_eval(String)` uses
      # the receiver's class hierarchy, and Object (the throwaway's class)
      # holds every top-level constant.
      #
      # SyntaxError / ScriptError don't descend from StandardError, so
      # they'd otherwise escape every rescue in `execute_and_audit` and
      # `send_request` — crashing the MCP dispatch loop. EvalGuard's
      # parser should reject unparseable payloads upstream, but Prism's
      # parser and Ruby's parser don't always agree; we translate the
      # script-level errors to ValidationError so the normal refusal
      # path owns them.
      def eval_in_sandbox(code)
        Object.new.instance_eval(code, '(console_eval)', 1)
      rescue ScriptError => e
        raise ValidationError, "console_eval payload could not be parsed by Ruby: #{e.class}: #{e.message}"
      end

      def audit(params:, confirmed:, result_summary:)
        return unless @audit_logger

        @audit_logger.log(
          tool: 'console_eval',
          params: params,
          confirmed: confirmed,
          result_summary: result_summary
        )
      rescue StandardError
        # Never let audit failures break the request path; a separate
        # operator alert covers audit-log write failures.
      end

      # Build the audit-log `result_summary` without triggering side-effects.
      #
      # Naive `result.inspect` on an `ActiveRecord::Relation` materializes
      # the query — a second SQL round-trip that happens *after* the
      # `Timeout.timeout` clamp and that can be arbitrarily expensive. We
      # stringify primitives (safe, informative) and reduce complex
      # objects to their class name so the audit entry is useful without
      # costing extra I/O.
      PRIMITIVE_AUDIT_TYPES = [
        String, Numeric, Symbol, TrueClass, FalseClass, NilClass
      ].freeze
      private_constant :PRIMITIVE_AUDIT_TYPES

      def audit_summary(result)
        if PRIMITIVE_AUDIT_TYPES.any? { |type| result.is_a?(type) }
          truncate(result.inspect)
        else
          "#<#{result.class.name}>"
        end
      rescue StandardError => e
        "inspect-failed:#{e.class}"
      end

      def truncate(str, limit = 512)
        s = str.to_s
        s.length > limit ? "#{s[0, limit]}…" : s
      end

      # Route a tool name to its handler.
      #
      # @param tool [String] Tool name
      # @param params [Hash] Tool parameters
      # @return [Hash] Tool result
      def dispatch(tool, params)
        case tool
        when 'status' then handle_status
        when 'schema' then handle_schema(params)
        when 'sql'    then handle_sql(params)
        when 'query'  then handle_query(params)
        when 'eval'   then handle_eval(params)
        else
          validate_model!(params)
          send(:"handle_#{tool}", params)
        end
      end

      # @param params [Hash] Must contain 'model' key
      # @raise [ValidationError]
      def validate_model!(params)
        model = params['model']
        raise ValidationError, 'Missing required parameter: model' unless model

        @model_validator.validate_model!(model)
        # Pre-execution table-gate check: refuse every tool invocation that
        # targets a model backed by a blocked table.
        gate_model!(model)
      end

      # Apply the TableGate (if wired) to model/SQL/join access. Raises
      # {ValidationError} with the TableGate's message so refusals look
      # identical to ModelValidator violations at the protocol boundary.
      def gate_model!(model)
        return unless @table_gate

        begin
          @table_gate.check_model!(model)
        rescue TableGateError => e
          raise ValidationError, e.message
        end
      end

      def gate_sql!(sql)
        return unless @table_gate

        begin
          @table_gate.check_sql!(sql)
        rescue TableGateError => e
          raise ValidationError, e.message
        end
      end

      def gate_joins!(model, joins)
        return unless @table_gate && joins

        begin
          @table_gate.check_joins!(model, joins)
        rescue TableGateError => e
          raise ValidationError, e.message
        end
      end

      # Resolve a model name string to an ActiveRecord class.
      #
      # @param name [String] Model class name (e.g., 'User', 'Admin::Account')
      # @return [Class] The ActiveRecord model class
      def resolve_model(name)
        name.constantize
      end

      # ── Tier 1 Handlers ──────────────────────────────────────────────────

      def handle_count(params)
        model = resolve_model(params['model'])
        scope = apply_scope(model, params['scope'], model_name: params['model'])
        { 'count' => scope.count }
      end

      def handle_sample(params)
        validate_select_columns!(params)
        model = resolve_model(params['model'])
        limit = [params.fetch('limit', 5).to_i, 25].min
        scope = apply_scope(model, params['scope'], model_name: params['model'])
        scope = apply_columns(scope, params['columns'])
        records = scope.order(random_function).limit(limit)
        { 'records' => serialize_records(records, params['columns']) }
      end

      def handle_find(params)
        model = resolve_model(params['model'])
        record = if params['id']
                   model.find_by(id: params['id'])
                 elsif params['by']
                   model.find_by(params['by'])
                 end
        { 'record' => record ? serialize_record(record, params['columns']) : nil }
      end

      def handle_pluck(params)
        columns = params['columns']
        @model_validator.validate_columns!(params['model'], columns) if columns
        model = resolve_model(params['model'])
        limit = [params.fetch('limit', 100).to_i, 1000].min
        scope = apply_scope(model, params['scope'], model_name: params['model'])
        scope = scope.distinct if params['distinct']
        values = scope.limit(limit).pluck(*columns.map(&:to_sym))
        { 'columns' => Array(columns), 'values' => values }
      end

      def handle_aggregate(params)
        column = params['column']
        function = params['function']
        @model_validator.validate_column!(params['model'], column) if column

        unless AGGREGATE_FUNCTIONS.include?(function)
          raise ValidationError, "Invalid aggregate function: #{function}. " \
                                 "Allowed: #{AGGREGATE_FUNCTIONS.join(', ')}"
        end

        model = resolve_model(params['model'])
        scope = apply_scope(model, params['scope'], model_name: params['model'])

        value = if function == 'count'
                  column ? scope.count(column.to_sym) : scope.count
                else
                  scope.send(function.to_sym, column.to_sym)
                end
        { 'value' => value }
      end

      def handle_association_count(params)
        model = resolve_model(params['model'])
        record = model.find(params['id'])
        association_name = params['association']

        unless model.reflect_on_association(association_name.to_sym)
          raise ValidationError, "Unknown association '#{association_name}' on #{params['model']}"
        end

        # Defense-in-depth: the parent model passed validate_model!'s
        # gate_model! check, but the association may target a different
        # table that's on console_blocked_tables (e.g. `Post belongs_to
        # :user` where `users` is blocked). Gate the association target
        # explicitly before reading any rows from it.
        gate_association!(params['model'], association_name)

        scope = record.public_send(association_name)
        scope = apply_scope(scope, params['scope'])
        { 'count' => scope.count }
      end

      def gate_association!(model_name, association)
        return unless @table_gate && association

        begin
          @table_gate.check_association!(model_name, association)
        rescue TableGateError => e
          raise ValidationError, e.message
        end
      end

      def handle_schema(params)
        model_name = params['model']
        raise ValidationError, 'Missing required parameter: model' unless model_name

        @model_validator.validate_model!(model_name)
        model = resolve_model(model_name)

        columns = model.columns_hash.transform_values do |col|
          { 'type' => col.type.to_s, 'null' => col.null, 'default' => col.default&.to_s }
        end

        result = { 'columns' => columns }

        if params['include_indexes']
          indexes = model.connection.indexes(model.table_name).map do |idx|
            { 'name' => idx.name, 'columns' => idx.columns, 'unique' => idx.unique }
          end
          result['indexes'] = indexes
        end

        result
      end

      def handle_recent(params)
        validate_select_columns!(params)
        model = resolve_model(params['model'])
        order_by = params.fetch('order_by', 'created_at')
        direction = params.fetch('direction', 'desc')
        limit = [params.fetch('limit', 10).to_i, 50].min

        @model_validator.validate_column!(params['model'], order_by)
        direction = 'desc' unless %w[asc desc].include?(direction)

        scope = apply_scope(model, params['scope'], model_name: params['model'])
        scope = apply_columns(scope, params['columns'])
        records = scope.order(order_by => direction.to_sym).limit(limit)
        { 'records' => serialize_records(records, params['columns']) }
      end

      def handle_status
        adapter = begin
          active_connection.adapter_name
        rescue StandardError
          'unknown'
        end
        { 'status' => 'ok', 'models' => @model_validator.model_names, 'adapter' => adapter }
      end

      # ── Read tools (sql/query, gated by read_tools_enabled) ────────────

      # Execute validated read-only SQL via ActiveRecord's select_all.
      #
      # @param params [Hash] Must contain 'sql'; optional 'limit'
      # @return [Hash] Columns and rows
      def handle_sql(params)
        sql = params['sql']
        raise ValidationError, 'Missing required parameter: sql' unless sql

        require_relative 'sql_validator'
        SqlValidator.new.validate!(sql)
        # Post-validation, pre-execution TableGate — blocks every configured
        # table even if the sql is otherwise well-formed.
        gate_sql!(sql)

        limit = params['limit'] ? [params['limit'].to_i, MAX_SQL_LIMIT].min : nil
        query_sql = limit ? "SELECT * FROM (#{sql}) AS _limited LIMIT #{limit}" : sql
        result = active_connection.select_all(query_sql)

        { 'columns' => result.columns, 'rows' => result.rows, 'count' => result.rows.size }
      rescue SqlValidationError => e
        raise ValidationError, e.message
      end

      # Build and execute a structured ActiveRecord query.
      #
      # @param params [Hash] Must contain 'model' and 'select'
      # @return [Hash] Columns and rows
      def handle_query(params)
        validate_model!(params)
        gate_joins!(params['model'], params['joins'])
        model = resolve_model(params['model'])
        relation = build_query_relation(model, params)
        sql = relation.to_sql
        # Defense-in-depth: re-run TableGate on the final rendered SQL. The
        # per-clause validators above are the primary defense; this catches
        # anything they missed (e.g. AR rewriting a scope into a subquery
        # that touches a blocked table through a less-obvious join).
        gate_sql!(sql)
        result = active_connection.select_all(sql)
        { 'columns' => result.columns, 'rows' => result.rows, 'count' => result.rows.size }
      end

      # Build an ActiveRecord relation from structured query parameters.
      #
      # @param model [Class] ActiveRecord model class
      # @param params [Hash] Query parameters (select, joins, scope, group_by, having, order, limit)
      # @return [ActiveRecord::Relation]
      def build_query_relation(model, params)
        relation = apply_query_clauses(model, params)
        limit = params['limit'] ? [params['limit'].to_i, MAX_QUERY_LIMIT].min : MAX_QUERY_LIMIT
        relation.limit(limit)
      end

      # Optional aggregate-expression wrappers accepted inside a `select`.
      # Anything else must be a bare column name validated against the model.
      # Matching is case-insensitive; the trailing `AS alias` is optional and
      # the alias itself must be an identifier — it can't carry SQL.
      SAFE_SELECT_EXPR = /
        \A\s*
        (?:(SUM|AVG|MIN|MAX|COUNT)\s*\(\s*(\*|\w+(?:\.\w+)?)\s*\)|(\w+(?:\.\w+)?))
        (?:\s+AS\s+(\w+))?
        \s*\z
      /ix
      private_constant :SAFE_SELECT_EXPR

      # Apply select/joins/scope/group/having/order clauses to a relation.
      #
      # Validates every user-supplied column/alias through the ModelValidator
      # and limits aggregate expressions to a small allowlist. Without this
      # pass, `select`/`having`/`order`/`group_by` strings reach AR as raw SQL
      # fragments and an attacker can exfiltrate columns via a crafted
      # `having: "1=1 UNION SELECT password_digest FROM users"`. SafeContext
      # rollback does not stop SELECT-based reads.
      #
      # @param model [Class] ActiveRecord model class
      # @param params [Hash]
      # @return [ActiveRecord::Relation]
      # @raise [ValidationError] on unsafe column/expression input
      def apply_query_clauses(model, params) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize
        model_name = params['model']
        relation = model.all

        relation = relation.select(*validated_select(params['select'], model_name)) if params['select']
        relation = relation.joins(params['joins'].map(&:to_sym)) if params['joins']&.any?
        relation = apply_scope(relation, params['scope'], model_name: model_name)
        relation = relation.group(*validated_columns(params['group_by'], model_name)) if params['group_by']&.any?
        relation = relation.having(*validated_having(params['having'], model_name)) if params['having']
        relation = relation.order(validated_order(params['order'], model_name)) if params['order']
        relation
      end

      # Normalize `select:` into an array of safe expressions. Each element
      # must be a column name (optionally qualified and/or aliased) or a
      # whitelisted aggregate call over a column.
      #
      # @param select [String, Array<String>]
      # @param model_name [String]
      # @return [Array<String>]
      def validated_select(select, model_name)
        Array(select).flat_map { |s| s.to_s.split(',') }.map do |expr|
          validate_select_expression!(expr.strip, model_name)
        end
      end

      def validate_select_expression!(expr, model_name)
        match = SAFE_SELECT_EXPR.match(expr)
        raise ValidationError, "Rejected select expression: #{expr.inspect}" unless match

        _fn, fn_arg, bare_col, _alias = match.captures
        column = bare_col || fn_arg
        validate_column_reference!(column, model_name) unless column == '*'
        expr
      end

      # Validate group_by entries — bare columns only (no functions, no SQL).
      #
      # @param columns [String, Array<String>]
      # @param model_name [String]
      # @return [Array<String>]
      def validated_columns(columns, model_name)
        Array(columns).flat_map { |c| c.to_s.split(',') }.map do |col|
          col = col.strip
          validate_column_reference!(col, model_name)
          col
        end
      end

      # Validate and bind-wrap `having:` so nothing reaches SQL as raw string
      # fragments. Accepts:
      #   - Hash (e.g. `{total: 100}`) — AR builds a `=` predicate safely.
      #   - Array `[sql, *binds]` where the sql string is either
      #     `"<col> <op> ?"` or `"<AGG>(<col_or_*>) <op> ?"` with a known
      #     operator and validated column.
      # Anything else is rejected — raw strings (e.g. `"1=1 UNION SELECT
      # password_digest FROM users"`) used to flow straight through and
      # enable SELECT-based exfiltration despite the SafeContext rollback.
      HAVING_AGG_TEMPLATE = /
        \A\s*
        (?:
          (?<col>\w+(?:\.\w+)?)
          |
          (?<agg>SUM|AVG|MIN|MAX|COUNT)\s*\(\s*(?<arg>\*|\w+(?:\.\w+)?)\s*\)
        )
        \s*(?<op>=|!=|<>|<=|>=|<|>)\s*\?\s*\z
      /ix
      private_constant :HAVING_AGG_TEMPLATE

      def validated_having(having, model_name) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        case having
        when Hash
          raise ValidationError, 'having: empty hash' if having.empty?

          having.each_key { |k| validate_column_reference!(k.to_s, model_name) }
          [having]
        when Array
          raise ValidationError, 'having: array must be [sql_with_placeholders, *binds]' if having.empty?

          template = having.first.to_s
          match = HAVING_AGG_TEMPLATE.match(template)
          raise ValidationError, "having: unsupported SQL template #{template.inspect}" unless match

          # Validate any referenced columns through ModelValidator so
          # aggregate args can't reach the db without a column check.
          col = match[:col] || match[:arg]
          validate_column_reference!(col, model_name) if col && col != '*'

          having
        else
          raise ValidationError, "having: unsupported type #{having.class}"
        end
      end

      # Validate `order:` — only Hash `{col => :asc|:desc}` or bare column name.
      def validated_order(order, model_name)
        case order
        when Hash
          order.each_key { |k| validate_column_reference!(k.to_s, model_name) }
          order.transform_values do |dir|
            dir_sym = dir.to_s.downcase.to_sym
            unless %i[asc desc].include?(dir_sym)
              raise ValidationError, "order direction must be :asc or :desc (got #{dir.inspect})"
            end

            dir_sym
          end
        when String, Symbol
          col = order.to_s.strip
          validate_column_reference!(col, model_name)
          col
        else
          raise ValidationError, "order: unsupported type #{order.class}"
        end
      end

      # Strict column-reference check. `table.col` is allowed only when the
      # table identifier is a safe Ruby identifier AND is not on
      # `console_blocked_tables` (via TableGate). Earlier iterations checked
      # only `safe_identifier?` on both halves, so a caller could smuggle a
      # blocked-table reference into `select`/`order`/`having` via a
      # qualified column like `users.password_digest`. Bare columns validate
      # against the active model through ModelValidator.
      def validate_column_reference!(column, model_name)
        if column.include?('.')
          table, col = column.split('.', 2)
          unless safe_identifier?(table) && safe_identifier?(col)
            raise ValidationError, "Rejected column reference: #{column.inspect}"
          end

          # Gate the table side through TableGate if one is configured.
          begin
            @table_gate&.check_table!(table)
          rescue TableGateError => e
            raise ValidationError, e.message
          end
        else
          raise ValidationError, "Rejected column reference: #{column.inspect}" unless safe_identifier?(column)

          @model_validator.validate_column!(model_name, column)
        end
      end

      def safe_identifier?(name)
        name.is_a?(String) && name.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
      end

      # ── Helpers ──────────────────────────────────────────────────────────

      # Apply scope conditions (WHERE clauses) to a relation.
      #
      # Accepts Hash form for equality or Ransack-style predicate suffixes
      # (e.g., `{total_refund_gt: 0, status_in: ['paid','refunded']}`), or
      # Array form for parameterized SQL (e.g., JSON column queries like
      # ["preferences->>'theme' = ?", "dark"]).
      #
      # When `model_name` is supplied and the Hash contains at least one key
      # with a recognised predicate suffix, the ScopePredicateParser builds
      # safe Arel nodes. Plain equality hashes skip the parser entirely.
      #
      # @param relation [ActiveRecord::Relation, Class] Model or relation
      # @param scope [Hash, Array, nil] Filter conditions
      # @param model_name [String, nil] Model name for column validation (predicate path only)
      # @return [ActiveRecord::Relation]
      def apply_scope(relation, scope, model_name: nil)
        case scope
        when Hash
          return relation unless scope.any?

          if model_name && predicate_suffix?(scope)
            parser = ScopePredicateParser.new(model_name: model_name, model_validator: @model_validator)
            parser.parse(relation, scope)
          else
            relation.where(scope)
          end
        when Array
          return relation unless scope.any?

          # Array form is `[template, *binds]`. The previous implementation
          # splatted directly into `where(*scope)`, which is the
          # `where(raw_sql_string)` arity — unbounded SQL injection. A
          # caller could pass `["EXISTS (SELECT 1 FROM users WHERE
          # password_digest LIKE 'a%')"]` and turn `console_count` /
          # `console_pluck` into a boolean exfiltration oracle against
          # any table the DB user can read (TableGate doesn't fire on
          # the rendered Tier-1 SQL). Validate the template now.
          validate_scope_array!(scope)
          relation.where(*scope)
        else
          relation
        end
      end

      # Forbidden SQL keywords inside a scope template — same set as
      # SqlValidator's body check, sized to the WHERE-fragment context
      # (no DML/DDL keywords because AR will syntax-fail on them anyway,
      # but a SELECT subquery is the live exfiltration vector).
      SCOPE_TEMPLATE_FORBIDDEN = /
        \b(?:
          SELECT | INSERT | UPDATE | DELETE | MERGE | UPSERT |
          UNION | INTERSECT | EXCEPT | INTO |
          DROP | ALTER | TRUNCATE | CREATE | RENAME |
          EXEC | EXECUTE | CALL | DO | COPY |
          GRANT | REVOKE | SET | RESET | LISTEN | NOTIFY |
          PG_SLEEP | PG_TERMINATE_BACKEND | PG_CANCEL_BACKEND |
          LOAD_FILE | INTO\s+OUTFILE | INTO\s+DUMPFILE |
          BENCHMARK | SLEEP
        )\b
      /ix
      private_constant :SCOPE_TEMPLATE_FORBIDDEN

      # Validate an `[template, *binds]` scope array. Rejects when:
      # - The first element isn't a String (Arel.sql / raw nodes are
      #   indistinguishable from raw SQL once they reach AR).
      # - The template contains any forbidden keyword (subquery
      #   exfiltration, multi-statement, time-based oracles).
      # - The template contains a semicolon (statement chaining).
      # - The number of `?` placeholders doesn't match the number of
      #   binds — AR would error anyway, but failing fast surfaces the
      #   mismatch as a validation error rather than an execution one.
      def validate_scope_array!(scope)
        template = scope.first
        unless template.is_a?(String)
          raise ValidationError, "scope[0] must be a String template (got #{template.class})"
        end

        raise ValidationError, 'scope template must not contain `;` (statement chaining)' if template.include?(';')

        # Strip SQL comments + string literals BEFORE the keyword scan.
        # Defense-in-depth: a payload like `id IN (/* x */ SELECT password
        # FROM users)` would actually be rejected by the database parser
        # too (SQL treats block comments as whitespace, so the SELECT is
        # tokenised correctly there) — but stripping comments first lets
        # the validator give a clear "forbidden SQL keywords" error
        # instead of a confusing adapter-level syntax failure. It also
        # neutralises `--` line comments and PostgreSQL dollar-quoted
        # strings that could carry forbidden keywords past a naive scan.
        # `SqlNoiseStripper` is the same module SqlValidator uses. The
        # combined single-pass strip_noise resolves comments and literals
        # together so a comment marker inside a literal can't hide a keyword.
        stripped = SqlNoiseStripper.strip_noise(template)
        if SCOPE_TEMPLATE_FORBIDDEN.match?(stripped)
          raise ValidationError,
                'scope template contains forbidden SQL keywords ' \
                '(subqueries, UNION, time-based functions, DML/DDL are not allowed). ' \
                'Use a parameterised comparison like `["col = ?", value]`.'
        end

        placeholder_count = template.scan('?').size
        bind_count = scope.length - 1
        return if placeholder_count == bind_count

        raise ValidationError,
              "scope template expects #{placeholder_count} bind(s), got #{bind_count}"
      end

      # Returns true if any key in the hash has a recognised predicate suffix.
      #
      # @param scope [Hash]
      # @return [Boolean]
      def predicate_suffix?(scope)
        scope.any? { |k, _| ScopePredicateParser::SUFFIX_PATTERN.match?(k.to_s) }
      end

      # Validate that any requested +columns+ are real model columns before
      # they reach +apply_columns+. ActiveRecord treats string args to
      # +.select+ as raw SQL fragments, so an unvalidated column smuggles a
      # subquery into the SELECT list (the sample/recent tools skip
      # +check_sql!+, so this is their only gate). Mirrors +handle_pluck+.
      #
      # @param params [Hash] Tool params (uses 'model' and 'columns')
      # @raise [ArgumentError] if any column is not declared on the model
      def validate_select_columns!(params)
        return unless params['columns']

        @model_validator.validate_columns!(params['model'], params['columns'])
      end

      # Apply column selection to a relation.
      #
      # @param relation [ActiveRecord::Relation] The relation
      # @param columns [Array<String>, nil] Columns to select
      # @return [ActiveRecord::Relation]
      def apply_columns(relation, columns)
        return relation unless columns.is_a?(Array) && columns.any?

        relation.select(columns)
      end

      # Serialize a single record to a Hash.
      #
      # @param record [ActiveRecord::Base] The record
      # @param columns [Array<String>, nil] Columns to include
      # @return [Hash]
      def serialize_record(record, columns = nil)
        if columns.is_a?(Array) && columns.any?
          record.attributes.slice(*columns)
        else
          record.attributes
        end
      end

      # Serialize multiple records.
      #
      # @param records [ActiveRecord::Relation] The records
      # @param columns [Array<String>, nil] Columns to include
      # @return [Array<Hash>]
      def serialize_records(records, columns = nil)
        records.map { |r| serialize_record(r, columns) }
      end

      # DB-dialect-aware random ordering function.
      #
      # @return [Arel::Nodes::SqlLiteral]
      def random_function
        adapter = active_connection.adapter_name.downcase
        func = adapter.include?('mysql') ? 'RAND' : 'RANDOM'
        Arel.sql("#{func}()")
      end

      # Return the database connection for the in-flight request.
      #
      # Resolution order:
      # 1. The connection leased by SafeContext for the current execute
      #    block, published via `Thread.current[:woods_console_leased_connection]`.
      #    This is the normal path under RackMiddleware — every dispatch
      #    runs inside `SafeContext#execute`, which leases from
      #    `ActiveRecord::Base.connection_pool` once per request and keeps
      #    that connection on the calling thread until the rolled-back
      #    transaction completes.
      # 2. The connection injected at construction time (test fixtures,
      #    bridge mode, anywhere SafeContext was built with `connection:`).
      # 3. As a last resort, lease one from the writing pool. We do *not*
      #    return the leased connection out of its `with_connection` block
      #    (that would release it back to the pool while the caller still
      #    holds the reference); instead, when nothing else has leased a
      #    connection, fall through to `ActiveRecord::Base.lease_connection`
      #    if it exists (Rails 7.2+) or `connection` (Rails <= 7.1).
      #    Both paths keep the connection checked out for the calling
      #    thread, which is correct outside the SafeContext lease.
      #
      # @return [Object] Database connection
      def active_connection
        leased = Thread.current[SafeContext::LEASED_CONNECTION_KEY]
        return leased if leased
        return @connection if @connection

        pool = ActiveRecord::Base.connection_pool
        pool.respond_to?(:lease_connection) ? pool.lease_connection : ActiveRecord::Base.connection
      end

      # Recursively convert all Hash keys to strings.
      #
      # @param obj [Object] The object to stringify
      # @return [Object] Object with string keys
      def deep_stringify_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify_keys(v) }
        when Array
          obj.map { |item| deep_stringify_keys(item) }
        else
          obj
        end
      end
    end
  end
end
