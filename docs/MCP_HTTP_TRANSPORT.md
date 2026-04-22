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
server = Woods::MCP::Server.build(index_dir: index_dir)
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

## Implementation for Woods

### Option A: Standalone HTTP Executable (Recommended)

Add `exe/woods-mcp-http` alongside the existing stdio executable:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "rackup"
require_relative "../lib/woods"
require_relative "../lib/woods/mcp/server"
# ... other requires ...

index_dir = ARGV[0] || ENV["WOODS_DIR"] || Dir.pwd
port = (ENV["PORT"] || 9292).to_i

server = Woods::MCP::Server.build(index_dir: index_dir, retriever: retriever)
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
# lib/woods/mcp/rack_middleware.rb
module Woods
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

A single `woods-mcp` executable that supports both transports:

```
woods-mcp                     # stdio (default, backward compatible)
woods-mcp --http              # HTTP on port 9292
woods-mcp --http --port 8080  # HTTP on custom port
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
- **Files changed**: 1 new (`exe/woods-mcp-http`), 1 modified (`woods.gemspec` to register the new executable)
- **Test coverage**: The existing `spec/mcp/server_spec.rb` covers all tool behavior; transport-level testing would be integration-only (Rack test with mock requests)

### MCP Ecosystem Context

- The MCP specification (2025-03-26) designates Streamable HTTP as the standard remote transport, replacing the earlier SSE-only transport
- The next spec release (~June 2026) is expected to further formalize stateless transport patterns for horizontal scaling
- The `mcp` gem tracks the spec closely; v0.6.0 already implements the full Streamable HTTP spec including stateless mode

## Security

The MCP gem does not authenticate at the transport layer, so `exe/woods-mcp-http` enforces authentication itself. The rules:

| `HOST`                            | `WOODS_MCP_HTTP_TOKEN` set? | Result                                                      |
|-----------------------------------|------------------------------|-------------------------------------------------------------|
| `localhost` / `127.0.0.1` / `::1` | no                           | Boots with a warning; unauthenticated loopback access only  |
| `localhost` / `127.0.0.1` / `::1` | yes                          | Boots; every request must present `Authorization: Bearer …` |
| anything else                     | no                           | **Refuses to boot** — aborts with a pointer to this section |
| anything else                     | yes                          | Boots; every request must present `Authorization: Bearer …` |

This matches the posture used by other unauthenticated local servers (Redis `protected-mode`, Postgres `listen_addresses`): loopback works freely, non-loopback requires an explicit credential.

### Generating a token

```bash
bundle exec rake woods:generate_token
# prints a 64-char hex token to stdout
```

Any cryptographically random string works; `openssl rand -hex 32` is equivalent.

### Running the server with a token

```bash
export WOODS_MCP_HTTP_TOKEN=$(bundle exec rake woods:generate_token 2>/dev/null)
HOST=0.0.0.0 PORT=9292 bundle exec woods-mcp-http
```

Clients must send `Authorization: Bearer $WOODS_MCP_HTTP_TOKEN` on every request. Missing or mismatched tokens get `HTTP 401` with a `WWW-Authenticate: Bearer` header; comparison is constant-time (`Rack::Utils.secure_compare`).

### Known limitations

- **Plaintext tokens on the wire.** Bearer auth over HTTP leaks the token to anything on the network path. Terminate TLS at a reverse proxy (nginx, Caddy, Cloudflare) for any deployment beyond a single trusted host.
- **No rotation primitive.** There is one static token. Rotating it requires restarting the server and updating clients. A rotation story is tracked separately and will likely arrive with a broader OAuth-shaped design.
- **No per-client identity.** Every valid request is equally trusted; there are no scopes or audit trails. Treat the token as a shared secret for a trust boundary you already control.

