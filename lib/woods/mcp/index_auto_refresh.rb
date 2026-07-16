# frozen_string_literal: true

module Woods
  module MCP
    # Prepended onto a built +MCP::Server+ instance (alongside
    # {VersionAwareToolDispatch}) so every tools/call first reconciles the
    # in-memory index with disk:
    #
    # 1. **Auto-reload.** {IndexReader#refresh_if_stale!} stats manifest.json
    #    (one stat per tool call) and drops the reader's caches when the file
    #    changed — a long-lived MCP connection serves the current index after
    #    every re-extraction with no manual +reload+ call and no reconnect.
    # 2. **No-index guidance.** When no manifest exists yet (the server was
    #    registered in an editor/agent config and launched before the first
    #    extraction), index-backed tools answer with "run woods:extract"
    #    guidance instead of erroring — and the same staleness check picks
    #    the index up automatically once it appears.
    #
    # The reader and index dir are carried on the server instance as
    # +@woods_index_reader+ / +@woods_index_dir+ (set by {Server.build}).
    #
    # Note: this hook covers tools/call — the primary agent surface. MCP
    # resource reads go through a separate handler and still reflect boot-time
    # state until any tool call triggers the refresh.
    module IndexAutoRefresh
      # Tools that read the on-disk extraction output and are meaningless
      # without it. Everything else (woods_status, reload, pipeline_* — which
      # can CREATE the index —, feedback and snapshot tools, session_trace)
      # stays callable so agents can diagnose and bootstrap.
      INDEX_REQUIRED_TOOLS = %w[
        lookup search dependencies dependents structure graph_analysis
        domain_clusters pagerank framework recent_changes trace_flow
        codebase_retrieve notion_sync
      ].freeze

      # @param request [Hash] the tools/call params (carries +:name+)
      # @return [MCP::Tool::Response]
      def call_tool(request, **)
        reader = @woods_index_reader
        if reader
          begin
            reader.refresh_if_stale!
          rescue StandardError => e
            # A refresh hiccup (e.g. a half-written manifest mid-extraction)
            # must not take the tool call down — serve the cached index.
            warn "[woods-mcp] index refresh check failed: #{e.class}: #{e.message}"
          end

          if !reader.index_present? && INDEX_REQUIRED_TOOLS.include?(request[:name].to_s)
            # call_tool's contract is the serialized hash (the gem calls
            # Tool::Response#to_h on its own short-circuit paths too).
            return Server.no_index_response(request[:name].to_s, @woods_index_dir).to_h
          end
        end

        super
      end
    end
  end
end
