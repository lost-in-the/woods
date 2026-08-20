# frozen_string_literal: true

require 'set'

module Woods
  module MCP
    # Pins reader-backed MCP handlers to one cached generation per request.
    # Installed on each built server's singleton class so the captured reader
    # never leaks to another Woods server or a foreign MCP::Server instance.
    module IndexReaderPinning
      READER_TOOL_NAMES = Set.new(
        %w[
          lookup search dependencies dependents structure graph_analysis
          domain_clusters pagerank framework recent_changes trace_flow
          session_trace notion_sync woods_status
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
            READER_TOOL_NAMES.intersection(server.tools.keys.to_set).freeze
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
