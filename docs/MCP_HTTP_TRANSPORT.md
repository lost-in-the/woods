# MCP HTTP Transport

Reference for `exe/woods-mcp-http`, the Index Server's HTTP transport, for hosts where a stdio subprocess isn't practical (shared access, multiple clients, a remote agent).

## What's shipped

- **`exe/woods-mcp-http`**: the only HTTP entry point. There is no `--http` flag on `woods-mcp` and no `Woods::MCP::RackMiddleware` for the Index Server (the Console Server has its own separate `RackMiddleware`, see [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md)).
- Built on `MCP::Server::Transports::StreamableHTTPTransport` from the `mcp` gem (`>= 1.2, < 2.0`), which implements MCP protocol version 2026-07-28 (legacy `initialize` still served for older clients).
- **Stateless by default.** `WOODS_MCP_HTTP_STATELESS=0` restores legacy session mode.
- **Bearer auth** (`WOODS_MCP_HTTP_TOKEN`) and an **origin guard** (`WOODS_MCP_HTTP_ALLOWED_ORIGINS`), see [Security](#security).
- Needs a Rack-compatible server (e.g. `puma`) in the host bundle. Uses the `rackup` gem when present, falls back to Rack 2's handler registry otherwise.

## Running it

```bash
bundle exec woods-mcp-http ./tmp/woods                          # loopback, stateless, no auth
HOST=0.0.0.0 PORT=9292 WOODS_MCP_HTTP_TOKEN=$(bundle exec rake woods:generate_token 2>/dev/null) \
  bundle exec woods-mcp-http ./tmp/woods                        # non-loopback requires a token
```

| Env var | Default | Meaning |
|---|---|---|
| `PORT` | `9292` | Listen port |
| `HOST` | `localhost` | Listen host. Anything non-loopback requires `WOODS_MCP_HTTP_TOKEN` (server refuses to boot otherwise) |
| `WOODS_MCP_HTTP_TOKEN` | unset | Bearer token required on every request when set |
| `WOODS_MCP_HTTP_STATELESS` | `1` | `0` restores legacy session mode (`Mcp-Session-Id`, GET SSE stream, DELETE teardown) |
| `WOODS_MCP_HTTP_ALLOWED_ORIGINS` | unset (loopback origins only) | Comma-separated origin allow-list for the `Origin` header guard |
| `WOODS_DIR` / `ARGV[0]` | cwd | Index directory to serve |

## Statelessness

MCP 2026-07-28 ([SEP-2567](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2567)) removes protocol-level sessions, and `woods-mcp-http` runs stateless by default.

For this server the session was never carrying anything: the index lives on disk, `IndexReader` self-refreshes off the published generation, and no tool holds per-client state. What the session *did* do was tie every client to one server process, so restarting the server (gem upgrade, machine sleep, worktree rebuild) invalidated every session and forced each client through a re-initialize. Stateless makes a restart invisible, and lets several instances serve one volume-mounted index without sticky routing.

What changes in stateless mode:

| Behaviour | Stateless (default) | Session mode (`=0`) |
|---|---|---|
| `Mcp-Session-Id` | never issued or required | issued on `initialize`, required after |
| `GET` on the MCP endpoint | `405 Method Not Allowed` | opens a standalone SSE stream |
| `DELETE` on the MCP endpoint | `200` no-op (see note) | terminates the session |
| A request carrying a stale `Mcp-Session-Id` | ignored, served normally | `404`, client must re-initialize |
| Server-initiated notifications | **not delivered**: there is no stream to push on | delivered to the session's SSE stream |
| Server restart | invisible to clients | every client must re-initialize |
| Horizontal scaling | any POST may hit any instance | requires sticky routing |

> **`Mcp-Session-Id` and CORS.** In stateless mode the header is neither read nor emitted, so it is absent from `Access-Control-Expose-Headers`. A client that depends on it needs `WOODS_MCP_HTTP_STATELESS=0`, a transitional escape hatch, since the header is gone from the specification.

> **DELETE returns 200, not 405.** The specification says a server supporting only this revision *should* answer `405` to DELETE; the `mcp` gem instead answers `200 {"success": true}` in stateless mode. This is the SDK's call, not Woods', there is no session to terminate either way, so the request is a no-op whichever status it carries.

The last row is the one that matters in practice: a client holding a session id from *before* a restart is simply served, rather than getting a `404` and having to re-initialize.

> **Notifications and long-running tools.** Stateless mode has no channel to push server-initiated notifications on at all (no `Last-Event-ID` resumability either, per SEP-2567). Woods' packaged Index tools are short reads. Custom embedded servers that wire pipeline tools use durable task polling rather than depending on a push; those tools are not registered by the normal packaged executable.

## Security

The `mcp` gem does not authenticate at the transport layer, so `exe/woods-mcp-http` enforces authentication itself:

| `HOST`                            | `WOODS_MCP_HTTP_TOKEN` set? | Result                                                      |
|-----------------------------------|------------------------------|---------------------------------------------------------------|
| `localhost` / `127.0.0.1` / `::1` | no                           | Boots with a warning; unauthenticated loopback access only  |
| `localhost` / `127.0.0.1` / `::1` | yes                          | Boots; every request must present `Authorization: Bearer …` |
| anything else                     | no                           | **Refuses to boot**: aborts with a pointer to this section |
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
HOST=0.0.0.0 PORT=9292 bundle exec woods-mcp-http ./tmp/woods
```

Clients must send `Authorization: Bearer $WOODS_MCP_HTTP_TOKEN` on every request. Missing or mismatched tokens get `HTTP 401` with a `WWW-Authenticate: Bearer` header; comparison is constant-time (`Rack::Utils.secure_compare`).

### Browser origins (DNS rebinding defense)

A second middleware, `Woods::MCP::OriginGuard`, rejects requests whose `Origin` header is outside an allow-list. Requests without an `Origin` header (curl, MCP stdio clients, server-to-server) pass through, bearer auth still gates them.

| Scenario          | `WOODS_MCP_HTTP_ALLOWED_ORIGINS`      | Origins accepted                                                |
|--------------------|-----------------------------------------|-------------------------------------------------------------------|
| default            | unset                                    | `http(s)://localhost`, `127.0.0.1`, `::1` (any port)              |
| explicit list      | `https://app.example.com`                | exactly `https://app.example.com`, loopback no longer allowed  |
| multiple origins   | `https://a.example,https://b.example`    | each listed origin                                                |

`OPTIONS` preflights are answered with the matching `Access-Control-Allow-*` headers; successful responses carry `Access-Control-Allow-Origin` and `Vary: Origin`. `Access-Control-Expose-Headers: Mcp-Session-Id` appears only in legacy session mode (`WOODS_MCP_HTTP_STATELESS=0`).

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
- **No rotation primitive.** There is one static token. Rotating it requires restarting the server and updating clients.
- **No per-client identity.** Every valid request is equally trusted; there are no scopes or audit trails. Treat the token as a shared secret for a trust boundary you already control.
- **No in-process TLS.** TLS is a reverse-proxy concern. Caddy/nginx/Cloudflare handle certs, HSTS, and cipher policy better than a Rack-level implementation would.
