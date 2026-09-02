# frozen_string_literal: true

require 'json'
require_relative 'response_context'
require_relative 'input_contract'

module Woods
  module Console
    # Per-tool dispatch flow for the Console MCP server.
    #
    # Encapsulates everything that happens between MCP's `define_tool` block
    # firing and the `MCP::Tool::Response` returning to the client:
    #
    #   1. Strictly parse integer strings and enforce schema bounds.
    #   2. Run the Layer 1 table gate ({ResponseContext#enforce!}).
    #   3. Translate the tool args into a bridge/executor request via the
    #      handler proc supplied in the {ToolSpec}.
    #   4. Send the request through the connection manager / embedded executor.
    #   5. Apply Layer 3 column + EAV redaction to the result
    #      ({ResponseContext#redact}).
    #   6. Apply Layer 2 credential scanning to the result and/or error text
    #      ({ResponseContext#scan}), logging hit counts when any fire.
    #   7. Render the result via the optional renderer or JSON, wrap in a
    #      response object.
    #
    # Previously this flow lived inline in `Server.register` with four
    # `method(:...)` captures closing over module-level methods. Pulling it
    # into a first-class object collapses that wiring, removes the need for
    # the captures, and makes the pipeline directly testable without going
    # through the full server build path.
    class DispatchPipeline
      # @param tool_name [String]
      # @param handler [#call] Maps a Hash of tool args to a bridge request Hash.
      # @param properties [Hash] ToolSpec JSON Schema properties.
      # @param conn_mgr [#send_request] ConnectionManager or EmbeddedExecutor.
      # @param ctx [ResponseContext] Bundles the three response-safety layers.
      #   Defaults to the Null context so tests can stub minimally.
      # @param renderer [#render_default, nil] Optional response renderer.
      # @param logger [#warn, nil] Structured logger used for credential-scan
      #   and table-gate telemetry. Failures are swallowed so observability
      #   issues never break a tool response.
      def initialize(tool_name:, handler:, properties:, conn_mgr:, # rubocop:disable Metrics/ParameterLists
                     ctx: NullResponseContext.instance, renderer: nil, logger: nil)
        @tool_name = tool_name
        @handler = handler
        @properties = properties
        @conn_mgr = conn_mgr
        @ctx = ctx
        @renderer = renderer
        @logger = logger
      end

      # Run the full dispatch pipeline for a single tool call.
      #
      # @param args [Hash] Tool arguments (symbol keys from MCP).
      # @return [MCP::Tool::Response]
      def call(args)
        InputContract.normalize!(args, @properties)
        @ctx.enforce!(args)
        request = @handler.call(args).transform_keys(&:to_s)
        send_to_bridge(request)
      rescue TableGateError => e
        log_table_gate_rejection(args, e)
        error_response(scan_early_error(e.message))
      rescue InputContract::ValidationError, SqlValidationError, ForbiddenExpressionError => e
        error_response(scan_early_error(e.message))
      rescue StandardError => e
        # Catch-all for pipeline bugs — a renderer NoMethodError, an encoding
        # oddity, a handler defect (L9). Without it the exception escaped into
        # the `mcp` gem's own handling of a raising tool block, which can echo
        # `Class: message` to the client: a leak channel the executor's
        # responses are already sanitized against. Answer with the same
        # sanitized shape the executor uses (class name only, details logged
        # server-side), still routed through the credential scan so nothing an
        # exception message picked up reaches the client either.
        log_unexpected_error(e)
        error_response(scan_early_error(sanitized_unexpected_error(e)))
      end

      private

      # Client-safe stand-in for an unexpected exception. Names the tool so an
      # agent can retry or report, and nothing else — the class and message
      # go to the log instead.
      def sanitized_unexpected_error(_error)
        "Internal error in #{@tool_name} (details logged server-side)"
      end

      def log_unexpected_error(error)
        return unless @logger

        @logger.warn(
          'console.dispatch.unexpected_error',
          tool: @tool_name,
          error_class: error.class.name,
          message: error.message
        )
      rescue StandardError
        nil
      end

      def send_to_bridge(request)
        response = @conn_mgr.send_request(request)
        return error_from_response(response, request) unless response['ok']

        result = @ctx.redact(response['result'])
        result = scan_for_credentials(result, request)
        text = @renderer ? @renderer.render_default(result) : JSON.pretty_generate(result)
        success_response(text)
      rescue ConnectionError => e
        scanned = scan_for_credentials("Connection error: #{e.message}", request)
        error_response(scanned)
      end

      def error_from_response(response, request)
        error_text = "#{response['error_type']}: #{response['error']}"
        error_text = scan_for_credentials(error_text, request)
        error_response(error_text)
      end

      def scan_for_credentials(result, request)
        scanned, counts = @ctx.scan(result)
        log_credential_hits(request, counts) unless counts.empty?
        scanned
      end

      def scan_early_error(message)
        scan_for_credentials(message, 'tool' => @tool_name.delete_prefix('console_'))
      end

      def log_credential_hits(request, counts)
        return unless @logger

        @logger.warn(
          'console.credential_scan.hits',
          tool: request['tool'],
          counts: counts.transform_keys(&:to_s),
          total: counts.values.sum
        )
      rescue StandardError
        nil
      end

      def log_table_gate_rejection(args, error)
        return unless @logger

        @logger.warn(
          'console.table_gate.rejected',
          tool: @tool_name,
          model: args[:model],
          table: args[:table],
          has_sql: args[:sql] ? true : false,
          message: error.message
        )
      rescue StandardError
        nil
      end

      def success_response(text)
        ::MCP::Tool::Response.new([{ type: 'text', text: text }])
      end

      def error_response(text)
        ::MCP::Tool::Response.new([{ type: 'text', text: text }], error: true)
      end
    end
  end
end
