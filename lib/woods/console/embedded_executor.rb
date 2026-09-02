# frozen_string_literal: true

require 'timeout'

require_relative 'audit_logger'
require_relative 'bridge_protocol'
require_relative 'confirmation'
require_relative 'credential_scanner'
require_relative 'eval_guard'
require_relative 'input_contract'
require_relative 'model_validator'
require_relative 'safe_context'
require_relative 'scope_predicate_parser'
require_relative 'sql_validator'
require_relative 'sql_noise_stripper'
require_relative 'table_gate'
require_relative 'tool_specs'

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
      TIER1_TOOLS = BridgeProtocol::TIER1_TOOLS

      # Tools gated behind the read_tools_enabled flag.
      # sql/query have existing safety gates (SqlValidator, SafeContext rollback)
      # but require explicit opt-in for embedded mode.
      EMBEDDED_READ_TOOLS = %w[sql query].freeze

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

        normalize_params!(tool, params)
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
          "[Woods::Console] execution error: #{error.class}: #{scan_log_text(error.message)}"
        )
      rescue StandardError
        # Never let logging break the request path.
      end

      # Layer 2 applied to server-side log text (L11). The client response for
      # this branch is already sanitized down to the class name, but the log
      # line carries the adapter's own message — and PG/Mysql2 errors embed the
      # rejected SQL and, for constraint violations, the offending literal. A
      # secret pasted into a WHERE clause therefore landed unscanned in the
      # server log while the response path was scanned. Failure falls back to a
      # sentinel rather than raw text, mirroring {AuditLogger#redact}.
      def scan_log_text(text)
        scanned, = error_log_scanner.scan(text.to_s)
        scanned
      rescue StandardError
        '[REDACTION_FAILED]'
      end

      def error_log_scanner
        @error_log_scanner ||= CredentialScanner.new
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
      # `sql`/`query` are gated behind `embedded_read_tools: true`. Everything
      # else outside Tier 1 is unavailable through a supported server mode.
      #
      # The flag has two names depending on transport: `embedded_read_tools:`
      # on `Woods::Console::RackMiddleware` (HTTP), or
      # `config.console_embedded_read_tools` read by `exe/woods-console`
      # (stdio). This executor runs under both, so the message names both —
      # naming only one leaves an operator on the other transport with no
      # idea what to set.
      #
      # @param tool [String] Tool name that was rejected
      # @return [String] Actionable error message
      def unsupported_message(tool)
        if EMBEDDED_READ_TOOLS.include?(tool)
          "Tool '#{tool}' requires embedded_read_tools: true on " \
            'Woods::Console::RackMiddleware, or config.console_embedded_read_tools = true ' \
            'for the stdio server (exe/woods-console). ' \
            'See docs/CONSOLE_MCP_SETUP.md.'
        else
          "Tool '#{tool}' is not available in a supported Console MCP mode."
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
          console_eval is not available in a supported Console MCP mode.
          Use console_query (model + select + joins/group_by/having/order) or console_sql
          for anything you were about to run. Both already support aggregates and scoping.
          If you believe eval is still necessary, SHOW your proposed Ruby snippet to the
          user first and let them run it manually — do not retry console_eval automatically.
          WOODS_CONSOLE_UNSAFE_EVAL and the legacy collaborator options fail closed at boot.
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

      def eval_timeout_from(raw)
        raw || DEFAULT_EVAL_TIMEOUT
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

      def normalize_params!(tool, params)
        spec = Server::TOOL_SPECS.find { |candidate| candidate.name == "console_#{tool}" }
        return unless spec

        registered = Server::EXECUTABLE_MODES.values.any? { |names| names.include?(spec.name) }
        if registered
          spec.validate_arguments!(params)
        else
          # Unregistered specs (console_eval today) never run the full public
          # JSON Schema here, so without this check a well-formed numeric
          # string (e.g. `timeout: "15"`) sails straight into normalize!'s
          # coercion below — silently accepting input the declared schema's
          # `type: integer` would reject outright. This closes that gap
          # without changing normalize!'s own messages for malformed/
          # out-of-bounds values, which are asserted verbatim elsewhere.
          InputContract.reject_string_typed_integers!(params, spec.properties)
        end
        InputContract.normalize!(params, spec.properties)
      rescue InputContract::ValidationError => e
        raise ValidationError, e.message
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
        limit = params.fetch('limit', 5)
        scope = apply_scope(model, params['scope'], model_name: params['model'])
        scope = apply_columns(scope, params['columns'])
        records = scope.order(random_function).limit(limit)
        { 'records' => serialize_records(records, params['columns']) }
      end

      def handle_find(params)
        validate_find_locator!(params)
        if params['by']
          by_columns = params['by'].keys.map(&:to_s)
          @model_validator.validate_columns!(params['model'], by_columns)
          by_columns.each { |column| refuse_protected_predicate_column!(column) }
        end
        validate_select_columns!(params)
        model = resolve_model(params['model'])
        record = params['id'] ? model.find_by(id: params['id']) : model.find_by(params['by'])
        { 'record' => record ? serialize_record(record, params['columns']) : nil }
      end

      # Require exactly one non-empty locator: `id` or a non-empty `by` hash.
      # `find_by({})` returns an arbitrary row when neither is supplied, and
      # `find_by` with an empty `by` hash is indistinguishable from that:
      # both must be refused before any query runs. Defense-in-depth against
      # the public schema's `oneOf`/`minProperties` constraint (ToolSpec
      # for console_find), for callers that reach this handler directly.
      #
      # @param params [Hash]
      # @raise [ValidationError] when zero or both locator forms are present
      def validate_find_locator!(params)
        has_id = !params['id'].nil?
        has_by = params['by'].is_a?(Hash) && params['by'].any?
        return if has_id ^ has_by

        raise ValidationError, 'console_find requires exactly one non-empty locator: id or by' unless has_id && has_by

        raise ValidationError, 'console_find accepts only one locator at a time: id or by, not both'
      end

      def handle_pluck(params)
        columns = params['columns']
        raise ValidationError, 'columns must contain at least one item' if columns && columns.empty?

        @model_validator.validate_columns!(params['model'], columns) if columns
        refuse_orphan_eav_value_selection!(Array(columns)) if columns
        model = resolve_model(params['model'])
        limit = params.fetch('limit', 100)
        scope = apply_scope(model, params['scope'], model_name: params['model'])
        scope = scope.distinct if params['distinct']
        values = scope.limit(limit).pluck(*columns.map(&:to_sym))
        { 'columns' => Array(columns), 'values' => values }
      end

      def handle_aggregate(params)
        column = params['column']
        function = params['function']
        if column
          @model_validator.validate_column!(params['model'], column)
          refuse_redacted_aggregate_expression!(column)
        end

        unless Server::AGGREGATE_FUNCTIONS.include?(function)
          raise ValidationError, "Invalid aggregate function: #{function}. " \
                                 "Allowed: #{Server::AGGREGATE_FUNCTIONS.join(', ')}"
        end
        raise ValidationError, "column is required for #{function} aggregate" if function != 'count' && column.nil?

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
        association_name = params['association']
        reflection = model.reflect_on_association(association_name.to_sym)

        raise ValidationError, "Unknown association '#{association_name}' on #{params['model']}" unless reflection

        # Defense-in-depth: the parent model passed validate_model!'s
        # gate_model! check, but the association may target a different
        # table that's on console_blocked_tables (e.g. `Post belongs_to
        # :user` where `users` is blocked). Gate the association target
        # explicitly before reading any rows from it.
        gate_association!(params['model'], association_name)

        # Validate every request-controlled scope column against the
        # association's own model before any database I/O runs (not just
        # before the association is read): `model.find` below is itself a
        # query, and a request with a bad scope should never reach it.
        validate_scope_columns!(params['scope'], reflection.klass.name) if params['scope']

        record = model.find(params['id'])
        scope = record.public_send(association_name)
        scope = apply_scope(scope, params['scope'], model_name: reflection.klass.name) if params['scope']
        gate_association_sql!(scope)
        { 'count' => scope.count }
      end

      # Defense-in-depth: gate_association! (called by
      # {#handle_association_count} before this) only proves the
      # association's OWN target table isn't blocked. A through-association,
      # default_scope, or an applied scope can still render SQL that reaches
      # a blocked table via a less-obvious join — mirrors handle_query's
      # re-check of the final rendered SQL. Only renders `to_sql` when a
      # gate is actually configured — it is otherwise unnecessary AR work on
      # every request.
      def gate_association_sql!(scope)
        gate_sql!(scope.to_sql) if @table_gate
      end

      # Pure column-name validation for a scope Hash, no relation is built
      # and no query runs. Reuses ScopePredicateParser's own suffix grammar
      # so the two never drift.
      #
      # @param scope [Hash, nil]
      # @param model_name [String]
      # @raise [ValidationError] on an unknown column
      def validate_scope_columns!(scope, model_name)
        return unless scope.is_a?(Hash)

        scope.each_key do |raw_key|
          column = scope_key_column(raw_key)
          @model_validator.validate_column!(model_name, column)
          refuse_protected_predicate_column!(column)
        end
      end

      # Strip a Ransack-style predicate suffix (e.g. `_matches`, `_gt`) from a
      # scope Hash key, returning the bare column name underneath.
      #
      # @param raw_key [String, Symbol]
      # @return [String]
      def scope_key_column(raw_key)
        key = raw_key.to_s
        match = ScopePredicateParser::SUFFIX_PATTERN.match(key)
        match ? key.delete_suffix(match[1]) : key
      end

      # Refuse a column that is configured as redacted
      # (`console_redacted_columns`). {SafeContext#redact} only scrubs
      # sensitive values from serialized *output* — accepting the same
      # column as a scope/filter key, a find locator, an aggregate target,
      # or an order_by column lets a caller read its plaintext value via a
      # comparison, aggregate, or sort-order oracle before redaction ever
      # runs.
      #
      # Matching is case-insensitive: unquoted SQL identifiers are
      # case-insensitive, so a case variant of a redacted column (`AMOUNT`,
      # `Password_Digest`) must get this typed refusal rather than fall
      # through to an existence check.
      #
      # @param column [String] bare column name (no schema/table qualifier)
      # @raise [ValidationError] if the column is on console_redacted_columns
      def refuse_redacted_column!(column)
        return unless @safe_context.redacted_columns.any? { |name| name.to_s.casecmp?(column.to_s) }

        raise ValidationError,
              "Rejected: column '#{column}' is redacted (console_redacted_columns) and cannot be used " \
              'as a scope, filter, aggregate, find, or order key.'
      end

      # Refuse a predicate column protected by either redaction layer. This
      # is narrower than EAV alias/aggregate protection: the key column is
      # the selector used to identify sensitive rows and remains a valid
      # predicate, while the value column is the secret-bearing field.
      #
      # Both layers match case-insensitively (see {#refuse_redacted_column!}):
      # a case variant of a protected column must keep the typed refusal.
      #
      # @param column [String, Symbol] already-normalized bare or qualified column name
      # @raise [ValidationError] when the column is protected for predicates
      def refuse_protected_predicate_column!(column)
        base = base_column_name(column.to_s)
        return refuse_redacted_column!(base) if @safe_context.redacted_columns.any? { |name| name.to_s.casecmp?(base) }
        return unless redacted_eav_value_columns.any? { |name| name.to_s.casecmp?(base) }

        raise ValidationError,
              "Rejected: EAV value column '#{base}' is redacted (console_redacted_key_values) and cannot " \
              'be used as a scope, filter, or having predicate.'
      end

      # Refuse every column referenced by a scope Hash that is protected for
      # predicates, honoring predicate suffixes (`email_matches`,
      # `salary_gt`, etc.) the same way {#validate_scope_columns!} does.
      #
      # @param scope [Hash]
      # @raise [ValidationError] on the first protected column found
      def refuse_redacted_scope_keys!(scope)
        scope.each_key { |raw_key| refuse_protected_predicate_column!(scope_key_column(raw_key)) }
      end

      # The value columns of every configured EAV redaction pair.
      #
      # @return [Array<String>]
      def redacted_eav_value_columns
        @safe_context.redacted_key_values.filter_map { |pattern| pattern['value_column'] }
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
        limit = params.fetch('limit', 10)

        @model_validator.validate_column!(params['model'], order_by)
        refuse_redacted_column!(order_by)
        unless %w[asc desc].include?(direction)
          raise ValidationError, "direction must be asc or desc (got #{direction.inspect})"
        end

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
        SqlValidator.new(dialect: sql_dialect).validate!(sql)
        validate_protected_sql_usage!(sql)
        # Post-validation, pre-execution TableGate — blocks every configured
        # table even if the sql is otherwise well-formed.
        gate_sql!(sql)

        limit = params['limit']
        # EXPLAIN's output is plan rows, not the query's own row set: wrapping
        # it as `SELECT * FROM (EXPLAIN ...) AS _limited LIMIT n` is invalid
        # SQL that fails as a generic adapter error. Reject the combination
        # with a typed error instead of advertising a limit EXPLAIN can't honor.
        if limit && explain_statement?(sql)
          raise ValidationError, 'limit is not supported with EXPLAIN (EXPLAIN output is plan rows, ' \
                                 'not the query result set, so it cannot be wrapped and limited). ' \
                                 'Resubmit without limit.'
        end

        query_sql = limit ? "SELECT * FROM (#{sql}) AS _limited LIMIT #{limit}" : sql
        result = active_connection.select_all(query_sql)

        { 'columns' => result.columns, 'rows' => result.rows, 'count' => result.rows.size }
      rescue SqlValidationError => e
        raise ValidationError, e.message
      end

      # @param sql [String] Validated SQL (already passed SqlValidator)
      # @return [Boolean] true when the statement starts with EXPLAIN
      def explain_statement?(sql)
        sql.strip.match?(/\AEXPLAIN\b/i)
      end

      # The SQL dialect the active connection will parse the statement
      # under, for {SqlValidator}'s dialect-aware lock-clause check. MySQL
      # and PostgreSQL quote/comment grammars differ (`\'` escapes, `#`
      # comments); validating with the matching dialect accepts dialect-valid
      # literals and still rejects every known bypass form. Unknown adapters
      # return nil and get the conservative both-dialect union.
      #
      # @return [Symbol, nil]
      def sql_dialect
        adapter = active_connection.adapter_name.to_s.downcase
        return :mysql if adapter.include?('mysql')
        return :postgres if adapter.include?('postgre')

        nil
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
        clauses = validated_query_clauses(model, params)
        relation = apply_query_clauses(model, params, clauses)
        limit = params.fetch('limit', 10_000)
        relation.limit(limit)
      end

      # Validate every structured query clause before any ActiveRecord
      # relation method can run. This keeps redaction-oracle refusals typed
      # and prevents malformed predicates from reaching Arel/adapter code.
      #
      # @param model [Class] ActiveRecord model class
      # @param params [Hash]
      # @return [Hash] normalized, validated query clauses
      def validated_query_clauses(model, params)
        model_name = params['model']
        {
          select: params['select'] ? validated_select(params['select'], model_name) : nil,
          joins: validated_query_joins(model, params['joins']),
          scope: params.key?('scope') ? validated_query_scope(params['scope'], model_name, model) : nil,
          group_by: params['group_by']&.any? ? validated_columns(params['group_by'], model_name) : nil,
          having: params['having'] ? validated_having(params['having'], model_name) : nil,
          order: params['order'] ? validated_order(params['order'], model_name) : nil
        }
      end

      def validated_query_joins(model, joins)
        return nil unless joins&.any?

        validate_joins!(model, joins)
        joins.map(&:to_sym)
      end

      # Optional aggregate-expression wrappers accepted inside a `select`.
      # Anything else must be a bare column name validated against the model.
      # Matching is case-insensitive; the trailing `AS alias` is optional and
      # the alias itself must be an identifier — it can't carry SQL.
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
      # @param clauses [Hash] prevalidated query clauses
      # @return [ActiveRecord::Relation]
      # @raise [ValidationError] on unsafe column/expression input
      def apply_query_clauses(model, params, clauses)
        model_name = params['model']
        relation = model.all

        relation = relation.select(*clauses[:select]) if clauses[:select]
        relation = relation.joins(clauses[:joins]) if clauses[:joins]
        relation = apply_scope(relation, clauses[:scope], model_name: model_name) if params.key?('scope')
        relation = relation.group(*clauses[:group_by]) if clauses[:group_by]
        relation = relation.having(*clauses[:having]) if clauses[:having]
        relation = relation.order(clauses[:order]) if clauses[:order]
        relation
      end

      # Normalize `select:` into an array of safe expressions. Each element
      # must be a column name (optionally qualified and/or aliased) or a
      # whitelisted aggregate call over a column. The list is then validated
      # as a set: positional EAV redaction resolves key/value columns by
      # header name and needs BOTH headers present, so a value column
      # selected without its paired key column would return plaintext.
      #
      # @param select [String, Array<String>]
      # @param model_name [String]
      # @return [Array<String>]
      def validated_select(select, model_name)
        expressions = Array(select).map do |expr|
          validate_select_expression!(expr.strip, model_name)
        end
        refuse_orphan_eav_value_selection!(expressions)
        expressions
      end

      # Refuse an EAV value column whose paired key column is missing from
      # the select set. The per-expression checks ({#validate_select_expression!})
      # already refused aliases and aggregates over protected columns, so
      # what reaches here unaliased can only be direct column selection —
      # and the positional redactor masks the value cell only when the key
      # column is in the same header. Requiring the key column keeps direct
      # EAV reads working ({Woods::Console::Redactor} masks the value);
      # refusing outright would break legitimate key/value reads.
      #
      # @param expressions [Array<String>] validated select expressions
      # @raise [ValidationError] when a value column is selected without its key
      def refuse_orphan_eav_value_selection!(expressions)
        selected = directly_selected_columns(expressions)

        @safe_context.redacted_key_values.each do |pattern|
          next unless selected.include?(pattern['value_column'])
          next if selected.include?(pattern['key_column'])

          raise ValidationError,
                "Rejected: selecting EAV value column '#{pattern['value_column']}' without its paired " \
                "key column '#{pattern['key_column']}' bypasses redaction; select both columns so the " \
                'value can be masked.'
        end
      end

      # The bare, unaliased columns referenced by a validated select list.
      # Aggregates and aliases cannot appear here — the per-expression
      # validation refuses them over protected columns before this runs.
      #
      # @param expressions [Array<String>]
      # @return [Array<String>]
      def directly_selected_columns(expressions)
        expressions.filter_map do |expr|
          match = Server::SELECT_EXPRESSION_REGEXP.match(expr)
          next unless match

          fn_arg, bare_col, alias_name = match.captures[1..]
          next if fn_arg || alias_name

          base_column_name(bare_col)
        end
      end

      # Validate one select expression against the model and the redaction
      # configuration.
      #
      # Exactly four shapes are refused (redaction stays positional by
      # output header — {Woods::Console::Redactor} masks by column name, so
      # any construct that renames or shadows an output header would carry
      # plaintext past it):
      #   1. an `AS` alias over a `console_redacted_columns` column
      #      (`password_digest AS note` returns plaintext under the `note`
      #      header, which no redaction rule matches);
      #   2. an aggregate over a `console_redacted_columns` column, aliased
      #      or bare (`SUM(salary)` leaks the aggregate of a column whose
      #      individual values are masked — {#handle_aggregate} refuses the
      #      same column via {#refuse_redacted_column!});
      #   3. an `AS` alias over either column of a
      #      `console_redacted_key_values` pair (the positional EAV rule
      #      resolves key/value columns by header name, so renaming either
      #      header silently disarms it);
      #   4. any `AS` alias whose NAME collides with a protected header
      #      (`id AS value` duplicates the EAV value header; positional
      #      index resolution could then mask the shadow instead of the
      #      secret — the aliased source being harmless is exactly what
      #      makes the shape dangerous).
      #
      # Direct, unaliased selection of a redacted column REMAINS ALLOWED:
      # the output header keeps the column's real name, and the positional
      # redactor masks the value. Aliasing a non-redacted column stays
      # allowed.
      #
      # @param expr [String] a single select expression
      # @param model_name [String]
      # @return [String] the expression, unchanged, once validated
      # @raise [ValidationError] on an unsafe expression or a refused shape
      def validate_select_expression!(expr, model_name)
        match = Server::SELECT_EXPRESSION_REGEXP.match(expr)
        raise ValidationError, "Rejected select expression: #{expr.inspect}" unless match

        refuse_redacted_select_shapes!(match.captures, model_name)
        expr
      end

      # Column-existence check plus the three redaction-refusal shapes; see
      # {#validate_select_expression!} for the shape list.
      #
      # @param captures [Array] {Server::SELECT_EXPRESSION_REGEXP} captures
      # @param model_name [String]
      # @raise [ValidationError] on an unknown column or a refused shape
      def refuse_redacted_select_shapes!(captures, model_name)
        fn, fn_arg, bare_col, alias_name = captures
        column = bare_col || fn_arg
        validate_column_reference!(column, model_name) unless column == '*'

        refuse_protected_alias_target!(alias_name) if alias_name
        refuse_redacted_select_alias!(bare_col, alias_name) if alias_name
        refuse_redacted_aggregate_expression!(fn_arg) if fn
      end

      # Refuse an `AS` alias whose NAME collides with a protected output
      # header (shape 4 in {#validate_select_expression!}). The positional
      # redactor resolves masks by header name; an alias naming a redacted
      # or EAV column duplicates that header, and the duplicate can steal
      # the mask from the real column's cell. Case-insensitive: unquoted
      # SQL identifiers fold, so a case-variant alias lands on the same
      # output header.
      #
      # @param alias_name [String] the `AS` alias
      # @raise [ValidationError] when the alias names a protected header
      def refuse_protected_alias_target!(alias_name)
        return unless protected_column_name?(alias_name)

        raise ValidationError,
              "Rejected: alias '#{alias_name}' names a protected output header; an alias must not " \
              'collide with a redacted or EAV column name.'
      end

      # @param name [String]
      # @return [Boolean] whether either redaction layer protects the name
      def protected_column_name?(name)
        casecmp_member?(@safe_context.redacted_columns, name) ||
          casecmp_member?(redacted_kv_columns, name)
      end

      # Case-insensitive membership, matching unquoted SQL identifier
      # semantics (the predicate refusals already compare this way).
      #
      # @param list [Array<String>]
      # @param name [String]
      # @return [Boolean]
      def casecmp_member?(list, name)
        list.any? { |entry| entry.to_s.casecmp?(name.to_s) }
      end

      # Refuse an `AS` alias over a column protected by either redaction
      # layer. A no-op when +alias_name+ is nil. See
      # {#validate_select_expression!} for why the alias is refused while
      # direct selection is not.
      #
      # @param column [String, nil] bare or qualified column reference
      # @param alias_name [String, nil] the `AS` alias
      # @raise [ValidationError] when the aliased column is protected
      def refuse_redacted_select_alias!(column, alias_name)
        return unless column

        base = base_column_name(column)
        if casecmp_member?(@safe_context.redacted_columns, base)
          raise ValidationError,
                "Rejected: aliasing redacted column '#{base}' as '#{alias_name}' bypasses output " \
                'redaction. Select it unaliased; the value is masked.'
        end

        return unless casecmp_member?(redacted_kv_columns, base)

        raise ValidationError,
              "Rejected: aliasing redacted key/value column '#{base}' as '#{alias_name}' bypasses " \
              'EAV output redaction. Select it unaliased.'
      end

      # Refuse an aggregate call over a column protected by either redaction
      # layer, mirroring {#handle_aggregate}'s {#refuse_redacted_column!} for
      # the aggregate expressions accepted inside `select`. The EAV check
      # covers both columns of every `console_redacted_key_values` pair: an
      # aggregate over the value column (e.g. `MAX(amount)` over the rows a
      # sensitive key selects) reads the redacted value itself, and the key
      # column is refused for symmetry with the alias rule.
      #
      # @param column [String, nil] aggregate argument (`*` is never redacted)
      # @raise [ValidationError] when the aggregated column is protected
      def refuse_redacted_aggregate_expression!(column)
        return if column.nil? || column == '*'

        base = base_column_name(column)
        if casecmp_member?(@safe_context.redacted_columns, base)
          raise ValidationError,
                "Rejected: aggregating redacted column '#{base}' reads its value; it cannot be used " \
                'as an aggregate input.'
        end

        return unless casecmp_member?(redacted_kv_columns, base)

        raise ValidationError,
              "Rejected: aggregating redacted key/value column '#{base}' reads its value; it cannot " \
              'be used as an aggregate input.'
      end

      # The key and value columns of every configured EAV redaction pair.
      #
      # @return [Array<String>]
      def redacted_kv_columns
        @safe_context.redacted_key_values
                     .flat_map { |pattern| [pattern['key_column'], pattern['value_column']] }
      end

      # Strip a `table.` qualifier, returning the bare column name that
      # redaction configuration is keyed on.
      #
      # @param column [String]
      # @return [String]
      def base_column_name(column)
        column.split('.').last
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
          refuse_protected_predicate_column!(col)
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
      def validated_having(having, model_name)
        case having
        when Hash
          raise ValidationError, 'having: empty hash' if having.empty?

          having.each_key do |k|
            validate_column_reference!(k.to_s, model_name)
            refuse_protected_predicate_column!(k)
          end
          [having]
        when Array
          validated_having_array!(having, model_name)
        else
          raise ValidationError, "having: unsupported type #{having.class}"
        end
      end

      # Validate the `[template, bind]` array form of `having:`.
      #
      # @param having [Array] `[template, bind]`
      # @param model_name [String]
      # @return [Array] `having`, unchanged, once validated
      def validated_having_array!(having, model_name)
        unless having.length == 2 && having.first.is_a?(String)
          raise ValidationError, 'having must contain exactly one template and one bind value'
        end

        template = having.first
        match = Server::HAVING_TEMPLATE_REGEXP.match(template)
        raise ValidationError, "having: unsupported SQL template #{template.inspect}" unless match

        # Validate any referenced columns through ModelValidator so
        # aggregate args can't reach the db without a column check.
        col = match[1] || match[3]
        validate_column_reference!(col, model_name) if col && col != '*'
        refuse_protected_having_reference!(match)
        validate_having_bind!(having.last)

        having
      end

      # Redaction oracle refusal for a HAVING template. A predicate over a
      # protected column leaks its value through repeated guesses — the
      # response reveals whether any row satisfied the comparison.
      # Aggregates are refused over both redaction layers (the EAV pair
      # columns, matching {#refuse_redacted_aggregate_expression!} for
      # select); bare-column predicates are refused over protected
      # predicate columns: console_redacted_columns and EAV value columns.
      #
      # @param match [MatchData] {Server::HAVING_TEMPLATE_REGEXP} match
      # @raise [ValidationError] when the referenced column is protected
      def refuse_protected_having_reference!(match)
        return refuse_protected_predicate_column!(match[1]) if match[1]
        return if match[3].nil? || match[3] == '*'

        refuse_redacted_aggregate_expression!(match[3])
      end

      # Defense-in-depth: the public schema already restricts the bind to a
      # scalar JSON type (see tool_specs.rb), but a container (Hash/Array)
      # bind that reaches AR's `?` placeholder fails as a generic adapter
      # error, not a typed one: reject it here too, mirroring
      # apply_query_scope's bind check.
      def validate_having_bind!(bind)
        case bind
        when String, Numeric, true, false, nil
          nil
        else
          raise ValidationError, 'having bind must be a string, number, boolean, or null'
        end
      end

      # Apply the public console_query scope contract. Query arrays are
      # intentionally narrower than the legacy Tier 1 executor form: exactly
      # one safe column comparison template and one bind value.
      def apply_query_scope(relation, scope, model_name)
        apply_scope(relation, validated_query_scope(scope, model_name, nil), model_name: model_name)
      end

      # Validate a console_query scope. +model+ is the already-resolved
      # ActiveRecord class: its own table name lets a `table.column`
      # placeholder scope validate the column against the model's own
      # columns (public/executor parity) even when the ModelValidator
      # carries no table_names mapping. A nil +model+ falls back to the
      # strict qualified-reference resolution.
      def validated_query_scope(scope, model_name, model)
        if scope.is_a?(Hash)
          validate_scope_columns!(scope, model_name)
          return scope
        end

        unless scope.is_a?(Array) && scope.length == 2 && scope.first.is_a?(String)
          raise ValidationError, 'scope must be an object or exact ["column OP ?", bind] array'
        end

        case scope.last
        when String, Numeric, true, false, nil
          nil
        else
          raise ValidationError, 'scope bind must be a string, number, boolean, or null'
        end

        match = Server::QUERY_SCOPE_TEMPLATE_REGEXP.match(scope.first)
        raise ValidationError, "scope: unsupported SQL template #{scope.first.inspect}" unless match

        # Redaction refusal runs BEFORE column resolution: a redacted column
        # referenced through any case variant (`Users.Password_Digest = ?`)
        # must get the typed redaction refusal, never a pass-through to the
        # existence check (whose case-sensitive column lookup would report a
        # generic "Unknown column" instead).
        refuse_protected_predicate_column!(match[1])
        validate_column_reference!(match[1], model_name, own_table: own_table_name(model))
        scope
      end

      # The queried model's own table name, when resolvable. Test doubles
      # may not implement `table_name`; a nil result keeps the strict
      # qualified-reference resolution instead of the own-table shortcut.
      #
      # @param model [Class, nil]
      # @return [String, nil]
      def own_table_name(model)
        return nil unless model.respond_to?(:table_name)

        model.table_name.to_s
      end

      # Validate `order:` — only Hash `{col => :asc|:desc}` or bare column name.
      def validated_order(order, model_name)
        case order
        when Hash
          order.each_key do |key|
            validate_column_reference!(key.to_s, model_name)
            refuse_protected_predicate_column!(key)
          end
          order.transform_values do |dir|
            unless dir.to_s.match?(Server::ORDER_DIRECTION_REGEXP)
              raise ValidationError, "order direction must be :asc or :desc (got #{dir.inspect})"
            end

            dir.to_s.downcase.to_sym
          end
        when String, Symbol
          col = order.to_s.strip
          validate_column_reference!(col, model_name)
          refuse_protected_predicate_column!(col)
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
      #
      # +own_table+ is the queried model's own table name, supplied by the
      # console_query scope path: a `table.column` reference whose table is
      # the model's own table validates the column against that same model,
      # exactly like the bare form. This cannot smuggle a foreign table
      # (the qualifier is checked for equality, not looked up), so redaction
      # and TableGate still apply to the reference as a whole. Any other
      # qualified reference keeps the strict cross-table resolution through
      # {ModelValidator#validate_table_column!}, which fails closed when the
      # table side cannot be proven.
      #
      # @param column [String] bare or `table.column` reference
      # @param model_name [String]
      # @param own_table [String, nil] the queried model's own table name
      def validate_column_reference!(column, model_name, own_table: nil)
        if column.include?('.')
          validate_qualified_column_reference!(column, model_name, own_table)
        else
          raise ValidationError, "Rejected column reference: #{column.inspect}" unless safe_identifier?(column)

          @model_validator.validate_column!(model_name, column)
        end
      end

      # The qualified `table.column` half of {#validate_column_reference!}.
      # The table half must be a safe identifier and unblocked (TableGate)
      # before column ownership is resolved: +own_table+ (the queried
      # model's own table name) short-circuits resolution to that model's
      # own columns, exactly like the bare form; the qualifier is compared
      # case-insensitively (unquoted SQL identifiers are case-insensitive)
      # against that one table name, never looked up, so this cannot
      # smuggle a foreign table and redaction still applies to the
      # reference as a whole. The column half keeps ModelValidator's exact
      # existence check, identical to the bare-column form. Anything else
      # resolves through {ModelValidator#validate_table_column!}, which
      # fails closed when the table side cannot be proven.
      #
      # @param column [String] a `table.column` reference
      # @param model_name [String]
      # @param own_table [String, nil] the queried model's own table name
      def validate_qualified_column_reference!(column, model_name, own_table)
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

        if own_table && table.casecmp?(own_table)
          # TableGate only proves `table` isn't *blocked* — it says nothing
          # about whether `col` actually exists there. Validate ownership
          # against the real schema before this reference can reach SQL.
          @model_validator.validate_column!(model_name, col)
        else
          @model_validator.validate_table_column!(table, col)
        end
      end

      def safe_identifier?(name)
        name.is_a?(String) && name.match?(Server::SAFE_IDENTIFIER_REGEXP)
      end

      def validate_joins!(model, joins)
        joins.each do |association|
          next if model.reflect_on_association(association.to_sym)

          raise ValidationError, "Unknown association '#{association}' on #{model.name}"
        end
      end

      # ── Helpers ──────────────────────────────────────────────────────────

      # Apply scope conditions (WHERE clauses) to a relation.
      #
      # Accepts Hash form for equality or Ransack-style predicate suffixes
      # (e.g., `{total_refund_gt: 0, status_in: ['paid','refunded']}`). The
      # array branch is used only after console_query's narrower contract has
      # validated an exact `["column OP ?", bind]` pair.
      #
      # When `model_name` is supplied, ScopePredicateParser validates every
      # equality and predicate column before applying the scope.
      #
      # @param relation [ActiveRecord::Relation, Class] Model or relation
      # @param scope [Hash, Array, nil] Filter conditions
      # @param model_name [String, nil] Model name for Hash key validation
      # @return [ActiveRecord::Relation]
      def apply_scope(relation, scope, model_name: nil)
        case scope
        when Hash
          return relation unless scope.any?

          refuse_redacted_scope_keys!(scope)
          if model_name
            parser = ScopePredicateParser.new(model_name: model_name, model_validator: @model_validator)
            parser.parse(relation, scope)
          else
            relation.where(scope)
          end
        when Array
          return relation unless scope.any?

          # Keep defense-in-depth validation here even though the registered
          # query schema and apply_query_scope enforce a narrower array form.
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
        unless placeholder_count == bind_count
          raise ValidationError,
                "scope template expects #{placeholder_count} bind(s), got #{bind_count}"
        end

        refuse_protected_predicate_references!(template)
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
        refuse_orphan_eav_value_selection!(params['columns'])
      end

      # Raw SQL preserves redaction identity only for direct, unaliased
      # protected columns in the outer SELECT list. Aliases, aggregates,
      # predicates, CTEs, and other result shapes can rename a protected
      # value or turn it into an oracle, so they fail closed before execution.
      def validate_protected_sql_usage!(sql)
        protected = (@safe_context.redacted_columns + redacted_kv_columns).uniq
        referenced = protected.select { |column| sql_identifier_referenced?(sql, column) }
        return if referenced.empty?

        stripped = SqlNoiseStripper.strip_noise(sql, dialect: sql_dialect || :postgres)
        expressions, tail = protected_sql_projection(stripped)
        selected = expressions.filter_map { |expression| direct_sql_column_name(expression) }
        unsafe = unsafe_protected_sql_column(referenced, expressions, selected, tail)
        return unless unsafe

        raise ValidationError,
              "Rejected: console_sql uses protected column '#{unsafe}' in an alias, aggregate, predicate, or " \
              'unpaired EAV shape that cannot preserve redaction identity. Select protected columns directly ' \
              'and unaliased, or use a structured Console tool.'
      end

      def unsafe_protected_sql_column(referenced, expressions, selected, tail)
        referenced.find do |column|
          unsafe_protected_sql_reference?(column, expressions, selected, tail)
        end || orphan_eav_sql_value(selected)
      end

      def protected_sql_projection(stripped)
        match = /\ASELECT\s+(.*?)\s+FROM\b/im.match(stripped)
        return [[], stripped] unless match

        [sql_projection_expressions(match[1]), stripped[match.end(1)..]]
      end

      def unsafe_protected_sql_reference?(column, expressions, selected, tail)
        unsafe_projection = expressions.any? do |expression|
          sql_identifier_referenced?(expression, column) && direct_sql_column_name(expression) != column
        end
        unsafe_tail = protected_sql_predicate_column?(column) && sql_identifier_referenced?(tail, column)
        !selected.include?(column) || unsafe_projection || unsafe_tail
      end

      def protected_sql_predicate_column?(column)
        @safe_context.redacted_columns.include?(column) || redacted_eav_value_columns.include?(column)
      end

      def orphan_eav_sql_value(selected)
        pattern = @safe_context.redacted_key_values.find do |candidate|
          selected.include?(candidate['value_column']) && !selected.include?(candidate['key_column'])
        end
        pattern&.fetch('value_column')
      end

      def sql_projection_expressions(projection)
        projection.split(',').map(&:strip)
      end

      def direct_sql_column_name(expression)
        identifier = /(?:[A-Za-z_]\w*|"(?:""|[^"])+"|`(?:``|[^`])+`)/
        match = /\A(?:#{identifier}\.)?(#{identifier})\z/.match(expression)
        return unless match

        match[1].sub(/\A["`]/, '').sub(/["`]\z/, '').gsub('""', '"').gsub('``', '`')
      end

      # Defense-in-depth for legacy Tier 1 scope arrays with more than one
      # bind. The public schema currently admits only Hash scopes, but direct
      # bridge callers still reach this validator.
      def refuse_protected_predicate_references!(template)
        protected = (@safe_context.redacted_columns + redacted_eav_value_columns).uniq
        referenced = protected.find { |column| sql_identifier_referenced?(template, column) }
        refuse_protected_predicate_column!(referenced) if referenced
      end

      def sql_identifier_referenced?(sql, column)
        stripped = SqlNoiseStripper.strip_noise(sql, dialect: sql_dialect || :postgres)
        stripped.match?(/(?<![A-Za-z0-9_$])#{Regexp.escape(column)}(?![A-Za-z0-9_$])/i)
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
