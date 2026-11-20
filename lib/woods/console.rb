# frozen_string_literal: true

module Woods
  # The Console MCP server was removed in Woods 2.2.0. What remains are the
  # names an application written for an earlier release may still reach, so
  # an upgrade stops with {REMOVED_MESSAGE} instead of a NameError: this
  # module, {RackMiddleware}, `exe/woods-console`, `exe/woods-console-mcp`,
  # `rake woods:console` and the former `console_*` configuration setters.
  module Console
    # The one line every former Console entry point prints or raises.
    REMOVED_MESSAGE = 'The Woods Console MCP server was removed in Woods 2.2.0. ' \
                      'See docs/CONSOLE_REMOVED.md for the cleanup steps.'

    # Former Rack endpoint of the Console. A host application that still
    # mounts it stops at boot, when Rails builds the middleware stack.
    class RackMiddleware
      # @raise [Woods::ConfigurationError] always, with {REMOVED_MESSAGE}
      def initialize(*_args, **_options)
        raise Woods::ConfigurationError, REMOVED_MESSAGE
      end
    end
  end
end
