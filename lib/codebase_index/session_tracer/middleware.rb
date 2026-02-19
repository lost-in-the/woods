# frozen_string_literal: true

require 'time'

module CodebaseIndex
  module SessionTracer
    # Rack middleware that captures request metadata for session tracing.
    #
    # Wraps `@app.call(env)`, records after response. Extracts controller/action
    # from `env['action_dispatch.request.path_parameters']`. Session ID from
    # `X-Trace-Session` header first, falls back to `request.session.id`.
    #
    # Fire-and-forget writes — `rescue StandardError` on recording, never breaks the request.
    #
    # @example Inserting into a Rails middleware stack
    #   app.middleware.insert_after ActionDispatch::Session::CookieStore,
    #                               CodebaseIndex::SessionTracer::Middleware
    #
    class Middleware
      # @param app [#call] The downstream Rack application
      # @param store [Store] Session trace store backend
      # @param session_id_proc [Proc, nil] Custom session ID extraction (receives env)
      # @param exclude_paths [Array<String>] Path prefixes to skip
      def initialize(app, store:, session_id_proc: nil, exclude_paths: [])
        @app = app
        @store = store
        @session_id_proc = session_id_proc
        @exclude_paths = exclude_paths
      end

      # @param env [Hash] Rack environment
      # @return [Array] Rack response triple [status, headers, body]
      def call(env)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        status, headers, body = @app.call(env)
        duration_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - start_time

        begin
          record_request(env, status, duration_ms)
        rescue StandardError
          # Fire-and-forget — recording failures never break the request
        end

        [status, headers, body]
      end

      private

      # Record the request metadata to the store.
      #
      # @param env [Hash] Rack environment
      # @param status [Integer] HTTP response status
      # @param duration_ms [Integer] Request duration in milliseconds
      # rubocop:disable Metrics/MethodLength
      def record_request(env, status, duration_ms)
        path = env['PATH_INFO'] || ''
        return if excluded?(path)

        session_id = extract_session_id(env)
        return unless session_id

        path_params = env['action_dispatch.request.path_parameters'] || {}
        controller = path_params[:controller]
        action = path_params[:action]
        return unless controller

        # Classify controller name (e.g., "orders" -> "OrdersController")
        controller_class = classify_controller(controller)

        request_data = {
          'session_id' => session_id,
          'trace_tag' => env['HTTP_X_TRACE_SESSION'],
          'timestamp' => Time.now.utc.iso8601,
          'method' => env['REQUEST_METHOD'],
          'path' => path,
          'controller' => controller_class,
          'action' => action.to_s,
          'status' => status.to_i,
          'duration_ms' => duration_ms.to_i,
          'format' => extract_format(env)
        }

        @store.record(session_id, request_data)
      end
      # rubocop:enable Metrics/MethodLength

      # Extract session ID: X-Trace-Session header first, then session cookie, then fallback.
      #
      # @param env [Hash] Rack environment
      # @return [String, nil] Session identifier
      def extract_session_id(env)
        return @session_id_proc.call(env) if @session_id_proc

        # 1. X-Trace-Session header (explicit trace tag doubles as session ID)
        trace_header = env['HTTP_X_TRACE_SESSION']
        return trace_header if trace_header && !trace_header.empty?

        # 2. Rack session ID
        session = env['rack.session']
        session_id = session&.id || session&.dig('session_id')
        return session_id.to_s if session_id

        nil
      end

      # Check if the path should be excluded from tracing.
      #
      # @param path [String] Request path
      # @return [Boolean]
      def excluded?(path)
        @exclude_paths.any? { |prefix| path.start_with?(prefix) }
      end

      # Classify a Rails controller path segment into a controller class name.
      #
      # @param controller [String] e.g., "orders" or "admin/orders"
      # @return [String] e.g., "OrdersController" or "Admin::OrdersController"
      def classify_controller(controller)
        parts = controller.to_s
                          .split('/')
                          .map { |segment| segment.split('_').map(&:capitalize).join }
        "#{parts.join('::')}Controller"
      end

      # Extract response format from the Rack env.
      #
      # @param env [Hash] Rack environment
      # @return [String] Format string (e.g., "html", "json")
      def extract_format(env)
        # Check action_dispatch format first
        path_params = env['action_dispatch.request.path_parameters'] || {}
        return path_params[:format].to_s if path_params[:format]

        # Infer from content type or Accept header
        accept = env['HTTP_ACCEPT'] || ''
        return 'json' if accept.include?('application/json')
        return 'html' if accept.include?('text/html')

        'html'
      end
    end
  end
end
