# frozen_string_literal: true

require_relative '../update_check'

module Woods
  module MCP
    # Prepended onto a built +MCP::Server+ instance so that a call to a tool the
    # installed gem does not define produces version-aware, self-healing
    # guidance instead of a bare "Tool not found".
    #
    # An agent following a newer version of the distributed guide skills may try
    # to call a tool that only exists in a later Woods release. The upstream
    # +mcp+ gem raises +RequestHandlerError("Tool not found: X")+ with no seam to
    # customize the message, so we intercept the built server's +call_tool+
    # (dispatched directly by +handle_request+, so a prepend on the instance is
    # honored on both the stdio and HTTP transports) and re-raise with the
    # installed version plus an update hint the agent can relay to the user.
    #
    # Only the genuine tool-not-found case is rewritten; every other
    # +RequestHandlerError+ (missing/invalid arguments, internal errors) is
    # re-raised untouched.
    module VersionAwareToolDispatch
      # @param request [Hash] the tools/call params (carries +:name+)
      # @return [MCP::Tool::Response] the tool result
      # @raise [MCP::Server::RequestHandlerError] rewritten for unknown tools
      def call_tool(request, **)
        super
      rescue ::MCP::Server::RequestHandlerError => e
        raise unless tool_not_found_error?(e)

        raise ::MCP::Server::RequestHandlerError.new(
          Woods::UpdateCheck.tool_not_found_message(request[:name]),
          request,
          error_type: :invalid_params,
          original_error: e
        )
      end

      private

      # The gem raises exactly this shape for an unregistered tool name.
      def tool_not_found_error?(error)
        error.error_type == :invalid_params && error.message.to_s.start_with?('Tool not found:')
      end
    end
  end
end
