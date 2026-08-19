# frozen_string_literal: true

require_relative 'extension'

module Woods
  module MCP
    module Tasks
      # Makes the current request's Tasks opt-in visible to a tool handler.
      #
      # A tool block is called with the request's `arguments` and nothing else —
      # the surrounding params, where `_meta` lives, never reach it. But whether
      # to answer with a task handle instead of a synchronous result is a
      # property of the *client*, not of the arguments, so the handler has to be
      # able to ask.
      #
      # Prepended onto a built server instance so it wraps `call_tool`, the same
      # seam {VersionAwareToolDispatch} uses (and which the HTTP and stdio
      # transports both dispatch through).
      #
      # State is thread-local because `woods-mcp-http` runs tool handlers on its
      # Rack server's request threads, and it is cleared in an `ensure` because
      # those threads are pooled and reused — a leaked flag would make the next
      # call on that thread hand a task to a client that never opted in and
      # cannot poll for it.
      module RequestCapture
        THREAD_KEY = :woods_mcp_tasks_requested

        # @return [Boolean] whether the in-flight request's client declared the
        #   Tasks extension. False outside any request.
        def self.tasks_requested?
          Thread.current[THREAD_KEY] == true
        end

        # @param request [Hash] the `tools/call` params, carrying `_meta`
        def call_tool(request, **)
          previous = Thread.current[THREAD_KEY]
          Thread.current[THREAD_KEY] = Extension.client_opted_in?(request)
          super
        ensure
          Thread.current[THREAD_KEY] = previous
        end
      end
    end
  end
end
