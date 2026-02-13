# frozen_string_literal: true

module CodebaseIndex
  module FlowAnalysis
    # Maps render/redirect AST nodes to HTTP status codes.
    #
    # Uses a built-in STATUS_CODES hash rather than depending on Rack at runtime.
    # Handles explicit status kwargs, render_<status> conventions, head calls,
    # and redirect_to defaults.
    #
    # @example Resolving a render call
    #   ResponseCodeMapper.resolve_method("render_created", arguments: []) #=> 201
    #   ResponseCodeMapper.resolve_method("redirect_to", arguments: ["/home"]) #=> 302
    #   ResponseCodeMapper.resolve_method("head", arguments: [":no_content"]) #=> 204
    #
    class ResponseCodeMapper
      # Subset of Rack::Utils::SYMBOL_TO_STATUS_CODE, inlined to avoid runtime Rack dependency.
      STATUS_CODES = {
        continue: 100,
        switching_protocols: 101,
        processing: 102,
        early_hints: 103,
        ok: 200,
        created: 201,
        accepted: 202,
        non_authoritative_information: 203,
        no_content: 204,
        reset_content: 205,
        partial_content: 206,
        multi_status: 207,
        already_reported: 208,
        im_used: 226,
        multiple_choices: 300,
        moved_permanently: 301,
        found: 302,
        see_other: 303,
        not_modified: 304,
        use_proxy: 305,
        temporary_redirect: 307,
        permanent_redirect: 308,
        bad_request: 400,
        unauthorized: 401,
        payment_required: 402,
        forbidden: 403,
        not_found: 404,
        method_not_allowed: 405,
        not_acceptable: 406,
        proxy_authentication_required: 407,
        request_timeout: 408,
        conflict: 409,
        gone: 410,
        length_required: 411,
        precondition_failed: 412,
        payload_too_large: 413,
        uri_too_long: 414,
        unsupported_media_type: 415,
        range_not_satisfiable: 416,
        expectation_failed: 417,
        misdirected_request: 421,
        unprocessable_entity: 422,
        locked: 423,
        failed_dependency: 424,
        too_early: 425,
        upgrade_required: 426,
        precondition_required: 428,
        too_many_requests: 429,
        request_header_fields_too_large: 431,
        unavailable_for_legal_reasons: 451,
        internal_server_error: 500,
        not_implemented: 501,
        bad_gateway: 502,
        service_unavailable: 503,
        gateway_timeout: 504,
        http_version_not_supported: 505,
        variant_also_negotiates: 506,
        insufficient_storage: 507,
        loop_detected: 508,
        not_extended: 510,
        network_authentication_required: 511
      }.freeze

      # Resolve a render/redirect/head method call to an HTTP status code.
      #
      # Strategies tried in order:
      # 1. Explicit status kwarg: `render json: x, status: :created` -> 201
      # 2. render_<status> convention: `render_created` -> 201
      # 3. head with status arg: `head :no_content` -> 204
      # 4. redirect_to default: 302
      #
      # @param method_name [String] The method name (render, redirect_to, head, render_created, etc.)
      # @param arguments [Array<String>] Argument representations from AST
      # @return [Integer, nil] HTTP status code or nil if unresolvable
      def self.resolve_method(method_name, arguments: [])
        # Case 1: Look for explicit status kwarg in arguments
        status_from_kwarg = extract_status_from_args(arguments)
        return resolve_status(status_from_kwarg) if status_from_kwarg

        # Case 2: render_<status> convention
        if method_name.start_with?('render_')
          status_name = method_name.delete_prefix('render_')
          code = STATUS_CODES[status_name.to_sym]
          return code if code
        end

        # Case 3: head :status
        if method_name == 'head' && arguments.first
          return resolve_status(arguments.first)
        end

        # Case 4: redirect_to defaults to 302
        return 302 if method_name == 'redirect_to'

        nil
      end

      # Resolve a status value (symbol name, integer, or string) to an integer code.
      #
      # @param value [String, Integer, Symbol] Status representation
      # @return [Integer, nil] HTTP status code or nil
      def self.resolve_status(value)
        case value
        when Integer
          value
        when Symbol
          STATUS_CODES[value]
        when String
          # Strip leading colon from AST symbol representation (":created" -> "created")
          cleaned = value.delete_prefix(':')
          # Try as symbol name first
          code = STATUS_CODES[cleaned.to_sym]
          return code if code

          # Try as integer string
          return cleaned.to_i if cleaned.match?(/\A\d+\z/)

          nil
        else
          nil
        end
      end

      # Extract a status value from argument strings.
      #
      # Looks for patterns like "status: :created" or "status: 201" in argument list.
      #
      # @param arguments [Array<String>] Argument representations
      # @return [String, nil] The status value if found
      def self.extract_status_from_args(arguments)
        arguments.each do |arg|
          if arg.is_a?(String) && (match = arg.match(/status:\s*(.+)/))
            return match[1].strip
          end
        end
        nil
      end
    end
  end
end
