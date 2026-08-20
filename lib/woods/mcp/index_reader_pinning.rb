# frozen_string_literal: true

require 'set'

module Woods
  module MCP
    # Pins reader-backed MCP handlers to one cached generation per request.
    # Installed on each built server's singleton class so the captured reader
    # never leaks to another Woods server or a foreign MCP::Server instance.
    #
    # Coverage is derived from every tool the server actually has registered
    # at install time, not a hand-maintained allowlist. A static list of
    # "reader tools" silently stopped covering new tools the moment one was
    # added and nobody remembered to update the list — the pin wrapper once
    # covered 14 of 28 non-reload tools this way, leaving retrieval,
    # pipeline, snapshot, and feedback calls free to run concurrently with an
    # exclusive reload. Pinning a handler that turns out not to touch the
    # reader costs an uncontended mutex + refcount bump; leaving one
    # unpinned that does touch it is the correctness bug. Default to pinned.
    module IndexReaderPinning
      # Tools deliberately left outside the pin gate, each with its own
      # justification — anything not listed here is pinned by construction.
      #
      # `reload` — the exclusive writer `with_pinned_generation` exists to
      # hold readers back from. Pinning its own handler would acquire a pin
      # first and then, inside the same call, ask `with_exclusive_reload` to
      # wait for every outstanding pin to drain — including the one the
      # handler itself is still holding. Self-deadlock, not missed coverage.
      #
      # No other registered tool qualifies as of this audit round. The
      # operator/feedback/snapshot handlers read their own collaborators
      # (StatusReporter, the feedback store, the snapshot store) rather than
      # the shared `reader`, so pinning them is a no-op today — but it is a
      # free no-op, and the alternative is a hand-maintained allowlist that
      # silently stops covering a handler the moment it starts reading
      # `reader` too. Default to pinned; name the exception, don't guess it.
      NON_READER_TOOL_NAMES = Set.new(
        %w[
          reload
        ]
      ).freeze

      class << self
        # @param server [MCP::Server]
        # @param reader [Woods::MCP::IndexReader]
        # @return [MCP::Server]
        def install(server, reader:)
          server.singleton_class.prepend(Dispatch)
          server.instance_variable_set(:@woods_index_reader, reader)
          server.instance_variable_set(
            :@woods_index_reader_tool_names,
            (server.tools.keys.to_set - NON_READER_TOOL_NAMES).freeze
          )
          server
        end
      end

      module Dispatch
        private

        def call_tool(request, **kwargs)
          reader = @woods_index_reader
          tool_names = @woods_index_reader_tool_names
          return super unless reader && tool_names&.include?(request[:name])

          reader.with_pinned_generation { super }
        end

        def read_resource_contents(request, **kwargs)
          reader = @woods_index_reader
          return super unless reader

          reader.with_pinned_generation { super }
        end
      end
    end
  end
end
