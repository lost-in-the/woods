# frozen_string_literal: true

module Woods
  module MCP
    # Protocol-level policy shared by both MCP servers (index and console).
    #
    # Everything here is a decision the MCP 2026-07-28 revision asks a server to
    # make but the SDK cannot make for us: how long a list/read result stays
    # fresh, who is allowed to cache it, and what order tools are advertised in.
    #
    # @see docs/design/MCP_2026_STRATEGY.md
    module ProtocolPolicy
      # SEP-2549 `cacheScope`. **Always `"private"`, deliberately not configurable.**
      #
      # Every result Woods can return describes the user's own codebase — tool
      # descriptions naming their models, resource reads carrying their source.
      # `"public"` authorises shared intermediaries (a corporate proxy, a gateway,
      # a CDN in front of `woods-mcp-http`) to cache and re-serve that to other
      # callers. The SDK's fallback when only `ttl_ms` is set is `"public"`, so
      # setting the ttl and leaving the scope alone is the one combination that
      # silently opts into the bad outcome — which is exactly why this is pinned
      # rather than defaulted.
      CACHE_SCOPE = 'private'

      # SEP-2549 `ttlMs`, a freshness hint with max-age semantics (0 = do not cache).
      #
      # The SDK applies one server-level value to `tools/list`, `prompts/list`,
      # `resources/list`, `resources/read` and `resources/templates/list` alike,
      # so this has to be safe for the most volatile of them — a `resources/read`
      # against an index a watch daemon may rewrite seconds from now.
      #
      # Ten seconds collapses the burst of list calls an agent makes when it
      # opens a session without letting a daemon-driven index change go unseen
      # for meaningfully longer than the poll interval that produced it. Callers
      # that never run a daemon can raise it via WOODS_MCP_CACHE_TTL_MS.
      DEFAULT_TTL_MS = 10_000

      # Environment override for {DEFAULT_TTL_MS}. `0` disables caching.
      TTL_ENV_KEY = 'WOODS_MCP_CACHE_TTL_MS'

      class << self
        # Resolved `ttlMs` for this process.
        #
        # A malformed or negative value falls back to the default rather than
        # raising: this is a cache hint on a server an agent is mid-conversation
        # with, and refusing to boot over a typo'd env var trades a mild
        # performance regression for a total outage.
        #
        # @return [Integer] non-negative milliseconds
        def ttl_ms
          raw = ENV.fetch(TTL_ENV_KEY, nil)
          return DEFAULT_TTL_MS if raw.nil? || raw.strip.empty?

          value = Integer(raw, exception: false)
          return DEFAULT_TTL_MS if value.nil? || value.negative?

          value
        end

        # Keyword arguments for `MCP::Server.new` carrying the cache hints.
        #
        # @return [Hash{Symbol => Object}]
        def cache_hints
          { ttl_ms: ttl_ms, cache_scope: CACHE_SCOPE }
        end

        # Sort a built server's tools by name, in place.
        #
        # MCP 2026-07-28 asks servers to return `tools/list` in a deterministic
        # order, explicitly so clients can cache the list and so the tool block
        # lands identically in an LLM's prompt cache across turns. The SDK lists
        # `@tools.values` — Hash insertion order — and Woods registers 14
        # always-on tools followed by up to 15 more gated on which collaborators
        # happen to be wired. Two hosts with different integrations therefore
        # advertise the same tools in different orders, and enabling an
        # integration reorders the block for everyone on that host.
        #
        # Sorting also fixes cursor pagination, which the SDK implements by
        # offset over that same unordered collection.
        #
        # This reaches into an SDK ivar because `define_tool` is the only
        # registration API and it appends. The reach is contained here and
        # no-ops if the internal shape ever changes, so a future SDK refactor
        # degrades to "unsorted, as before" rather than breaking the server.
        #
        # @param server [MCP::Server]
        # @return [MCP::Server] the same server, for chaining
        def sort_tools!(server)
          tools = server.instance_variable_get(:@tools)
          return server unless tools.is_a?(Hash)

          server.instance_variable_set(:@tools, tools.sort_by { |name, _| name.to_s }.to_h)
          server
        end
      end
    end
  end
end
