# frozen_string_literal: true

require_relative '../deprecation'

module Woods
  # @see Woods::Console::Server
  module Console
    # The one line every Console entry point prints, once per process, on stderr.
    DEPRECATION_MESSAGE = 'The Console MCP server is deprecated and will be removed in Woods 3.0. ' \
                          'Existing setups keep working through 2.x; use the Index Server for structural ' \
                          'questions (see docs/CONSOLE_MCP_SETUP.md).'

    # Print {DEPRECATION_MESSAGE} unless this process already has.
    #
    # @return [void]
    def self.warn_deprecated
      Woods::Deprecation.warn_once(:console_mcp, DEPRECATION_MESSAGE)
    end
  end
end
