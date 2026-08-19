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
- **Stateless mode** (Woods default since MCP 2026-07-28): each POST is self-contained, no session is issued or required
- **Session management** (legacy, opt-in): assigns `Mcp-Session-Id` on initialization, tracks sessions server-side, DELETE terminates
- **SSE streaming**: per-request response streams; the standalone GET stream is session-mode only

## Statelessness

MCP 2026-07-28 ([SEP-2567](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2567)) removes protocol-level sessions, and `woods-mcp-http` runs stateless by default.

For this server the session was never carrying anything: the index lives on disk, `IndexReader` self-refreshes off the published generation, and no tool holds per-client state. What the session *did* do was tie every client to one server process — so restarting the server (gem upgrade, machine sleep, worktree rebuild) invalidated every session and forced each client through a re-initialize. Stateless makes a restart invisible, and lets several instances serve one volume-mounted index without sticky routing.

```bash
woods-mcp-http                          # stateless (default)
WOODS_MCP_HTTP_STATELESS=0 woods-mcp-http   # legacy session mode
```

What changes in stateless mode:

| Behaviour | Stateless (default) | Session mode (`=0`) |
|---|---|---|
| `Mcp-Session-Id` | never issued or required | issued on `initialize`, required after |
| `GET` on the MCP endpoint | `405 Method Not Allowed` | opens a standalone SSE stream |
| `DELETE` on the MCP endpoint | `200` no-op (see note) | terminates the session |
| A request carrying a stale `Mcp-Session-Id` | ignored, served normally | `404` — client must re-initialize |
| Server-initiated notifications | **not delivered** — there is no stream to push on | delivered to the session's SSE stream |
| Server restart | invisible to clients | every client must re-initialize |
| Horizontal scaling | any POST may hit any instance | requires sticky routing |

> **`Mcp-Session-Id` and CORS.** In stateless mode the header is neither read nor emitted, so it is absent from `Access-Control-Expose-Headers`. A client that depends on it needs `WOODS_MCP_HTTP_STATELESS=0` — a transitional escape hatch, since the header is gone from the specification.

> **DELETE returns 200, not 405.** The specification says a server supporting only this revision *should* answer `405` to DELETE; the `mcp` gem instead answers `200 {"success": true}` in stateless mode. This is the SDK's call, not Woods', and it is benign — there is no session to terminate either way, so the request is a no-op whichever status it carries, and a legacy client tearing down a session it thinks it has gets a success rather than a confusing error. Noted here because the two disagree, not because it needs fixing.

The last row is the one that matters in practice: a client holding a session id from *before* a restart is simply served, rather than getting a `404` and having to re-initialize. That is the disconnect/reconnect improvement, and it is why stateless is the default.

> **Stream resumability.** MCP 2026-07-28 also removes `Last-Event-ID` resumability. A broken response stream loses the in-flight request and the client must re-issue it with a new request id. Woods' index tools are short reads, so this is near-free; the long-running `pipeline_extract` / `pipeline_embed` return a durable task handle instead (see [MCP_SERVERS.md](MCP_SERVERS.md#long-running-tools-and-the-tasks-extension)), which survives a dropped connection better than a resumable stream did.

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

### Browser origins (DNS rebinding defense)

A second middleware, `Woods::MCP::OriginGuard`, rejects requests whose `Origin` header is outside an allow-list. Requests without an `Origin` header (curl, MCP stdio clients, server-to-server) pass through — bearer auth still gates them.

| Scenario                         | `WOODS_MCP_HTTP_ALLOWED_ORIGINS`  | Origins accepted                                         |
|----------------------------------|------------------------------------|----------------------------------------------------------|
| default                          | unset                              | `http(s)://localhost`, `127.0.0.1`, `::1` (any port)     |
| explicit list                    | `https://app.example.com`          | exactly `https://app.example.com` — loopback no longer allowed |
| multiple origins                 | `https://a.example,https://b.example` | each listed origin                                    |

`OPTIONS` preflights are answered with the matching `Access-Control-Allow-*` headers; successful responses carry `Access-Control-Allow-Origin` and `Vary: Origin`. `Access-Control-Expose-Headers: Mcp-Session-Id` appears only in legacy session mode (`WOODS_MCP_HTTP_STATELESS=0`) — see [Statelessness](#statelessness).

### TLS termination

The server speaks plain HTTP. Any deployment beyond a single trusted host should front it with a reverse proxy that handles TLS, HTTP/2, and connection limits.

**Caddy** (automatic HTTPS via Let's Encrypt):

```caddyfile
mcp.example.com {
  reverse_proxy 127.0.0.1:9292
}
```

**nginx** (bring-your-own cert):

```nginx
server {
  listen 443 ssl http2;
  server_name mcp.example.com;

  ssl_certificate     /etc/letsencrypt/live/mcp.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/mcp.example.com/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:9292;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Connection "";

    # SSE streaming: disable buffering, raise timeouts
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  }
}
```

Bind `woods-mcp-http` to `HOST=127.0.0.1` when a proxy handles the public surface; keep `WOODS_MCP_HTTP_TOKEN` set so the proxy-to-app hop still requires a bearer.

### Known limitations

- **Plaintext tokens on the wire.** Bearer auth over HTTP leaks the token to anything on the network path. Terminate TLS at a reverse proxy (nginx, Caddy, Cloudflare) for any deployment beyond a single trusted host.
- **No rotation primitive.** There is one static token. Rotating it requires restarting the server and updating clients. A rotation story is tracked separately and will likely arrive with a broader OAuth-shaped design.
- **No per-client identity.** Every valid request is equally trusted; there are no scopes or audit trails. Treat the token as a shared secret for a trust boundary you already control.
- **No in-process TLS.** TLS is a reverse-proxy concern — Caddy/nginx/Cloudflare handle certs, HSTS, and cipher policy better than a Rack-level implementation would.

