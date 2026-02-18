# MCP HTTP Transport Evaluation

## Current State

- **mcp gem version**: 0.6.0 (pinned `~> 0.6` in gemspec)
- **Available transports**:
  - `MCP::Server::Transports::StdioTransport` — stdin/stdout JSON-RPC (current default)
  - `MCP::Server::Transports::StreamableHTTPTransport` — HTTP POST/GET with optional SSE streaming
- **MCP protocol version**: 2025-03-26 (Streamable HTTP is the standard remote transport)

## HTTP/SSE Transport Support

**Native support: YES.** The `mcp` gem v0.6.0 ships `StreamableHTTPTransport` with full Rack compatibility.

### What's Available Out of the Box

The transport (`lib/mcp/server/transports/streamable_http_transport.rb`) provides:

- **Rack-compatible request handler**: `transport.handle_request(rack_request)` returns `[status, headers, body]`
- **Session management**: Assigns `Mcp-Session-Id` header on initialization, tracks sessions server-side
- **Stateless mode**: `StreamableHTTPTransport.new(server, stateless: true)` for multi-node deployments
- **SSE streaming**: GET requests establish SSE connections with keepalive pings (30s interval)
- **Server-to-client notifications**: `transport.send_notification(method, params, session_id:)` pushes events to connected SSE streams
- **Session cleanup**: DELETE requests terminate sessions and close SSE streams

### Usage Pattern

The gem includes example servers (`examples/http_server.rb`, `examples/streamable_http_server.rb`) demonstrating the Rack integration:

```ruby
# Build the MCP server (same as stdio)
server = CodebaseIndex::MCP::Server.build(index_dir: index_dir)
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
server.transport = transport

# Wrap in a Rack app
app = proc do |env|
  request = Rack::Request.new(env)
  transport.handle_request(request)
end

# Run with any Rack-compatible server (Puma, Falcon, WEBrick)
Rackup::Handler.get("puma").run(app, Port: 9292, Host: "localhost")
```

### Rails Controller Integration

For embedding in a Rails app, the `Server#handle_json` method enables a minimal controller:

```ruby
class McpController < ApplicationController
  skip_before_action :verify_authenticity_token

  def handle
    response = @mcp_server.handle_json(request.body.read)
    render json: response
  end
end
```

This provides non-streaming Streamable HTTP transport (POST-only, no SSE).

## Implementation for CodebaseIndex

### Option A: Standalone HTTP Executable (Recommended)

Add `exe/codebase-index-mcp-http` alongside the existing stdio executable:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "rackup"
require_relative "../lib/codebase_index"
require_relative "../lib/codebase_index/mcp/server"
# ... other requires ...

index_dir = ARGV[0] || ENV["CODEBASE_INDEX_DIR"] || Dir.pwd
port = (ENV["PORT"] || 9292).to_i

server = CodebaseIndex::MCP::Server.build(index_dir: index_dir, retriever: retriever)
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
server.transport = transport

app = proc { |env| transport.handle_request(Rack::Request.new(env)) }
Rackup::Handler.get("puma").run(app, Port: port, Host: "localhost")
```

**Complexity**: Low — ~30 lines, mirrors the existing exe structure.

**Dependencies**: Requires `rackup` gem + a Rack server (e.g., `puma`). The gemspec already has `puma` as a dev dependency. For production use, `rackup` would need to be added as an optional dependency or documented as a user-provided requirement.

### Option B: Rack Middleware (for embedding in host Rails apps)

A Rack middleware that mounts the MCP server at a configurable path:

```ruby
# lib/codebase_index/mcp/rack_middleware.rb
module CodebaseIndex
  module MCP
    class RackMiddleware
      def initialize(app, index_dir:, path: "/mcp")
        @app = app
        @path = path
        server = Server.build(index_dir: index_dir)
        @transport = ::MCP::Server::Transports::StreamableHTTPTransport.new(server)
        server.transport = @transport
      end

      def call(env)
        if env["PATH_INFO"].start_with?(@path)
          @transport.handle_request(Rack::Request.new(env))
        else
          @app.call(env)
        end
      end
    end
  end
end
```

**Complexity**: Low-medium — adds a mountable middleware class. Useful for host apps that want to expose MCP alongside their existing routes.

### Option C: Combined Executable with Transport Flag

A single `codebase-index-mcp` executable that supports both transports:

```
codebase-index-mcp                     # stdio (default, backward compatible)
codebase-index-mcp --http              # HTTP on port 9292
codebase-index-mcp --http --port 8080  # HTTP on custom port
```

**Complexity**: Low — add CLI flag parsing to existing exe.

## Recommendation

**Start with Option A** (standalone HTTP executable). Rationale:

1. **Zero risk to existing users** — the stdio exe is untouched
2. **Minimal code** — the `mcp` gem already provides the full transport; we just need a thin wrapper
3. **No new gem dependencies** — `rackup`/`puma` are already dev dependencies; users wanting HTTP would install them
4. **Natural upgrade path** — Option B (middleware) can be added later if Rails embedding demand appears

### Implementation Effort

- **Effort**: ~1 hour
- **Files changed**: 1 new (`exe/codebase-index-mcp-http`), 1 modified (`codebase_index.gemspec` to register the new executable)
- **Test coverage**: The existing `spec/mcp/server_spec.rb` covers all tool behavior; transport-level testing would be integration-only (Rack test with mock requests)

### MCP Ecosystem Context

- The MCP specification (2025-03-26) designates Streamable HTTP as the standard remote transport, replacing the earlier SSE-only transport
- The next spec release (~June 2026) is expected to further formalize stateless transport patterns for horizontal scaling
- The `mcp` gem tracks the spec closely; v0.6.0 already implements the full Streamable HTTP spec including stateless mode
