# MCP HTTP transport

The Index Server ships as `woods-mcp-http`; the default `woods-mcp` executable
uses stdio. HTTP requires the optional `rackup` gem and a Rack server such as
Puma in the application bundle. The maintenance dependency floor is
`mcp >= 0.23.0, < 1.0`, including the SDK server transport safeguards.

```bash
bundle exec woods-mcp-http /path/to/woods/index
```

`HOST` defaults to `localhost`; `PORT` defaults to `9292`. The executable reads
the published index without booting Rails. For a live Rails Console endpoint,
use the separate [Console HTTP setup](CONSOLE_MCP_SETUP.md#option-c-httprack-middleware).
The SDK provides Streamable HTTP initialization, sessions and SSE; leave its
protocol negotiation enabled.

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

**Unreleased diagnostic correction:** invalid origin encodings also refuse before
binding HTTP. `woods-mcp-http` exits 2 with one bounded `ConfigurationError`
message naming the invalid entry; re-enter that origin using an ASCII hostname
(or its Punycode form). No allowlist keeps the existing defaults. Explicit entries
are literal origins, not wildcard patterns. Retain the actual request Host through
a reverse proxy; forwarded headers do not replace it. When authentication is
configured, requests without Host still pass through bearer authentication.

A second middleware, `Woods::MCP::OriginGuard`, rejects requests whose `Origin` header is outside an allow-list. Requests without an `Origin` header still pass through Host validation and configured bearer authentication.

| Scenario                         | `WOODS_MCP_HTTP_ALLOWED_ORIGINS`  | Origins accepted                                         |
|----------------------------------|------------------------------------|----------------------------------------------------------|
| default                          | unset                              | same-origin loopback requests     |
| explicit list                    | `https://app.example.com`          | exactly `https://app.example.com` — loopback no longer allowed |
| multiple origins                 | `https://a.example,https://b.example` | each listed origin                                    |

Woods forwards the configured origins and their derived hostnames to the SDK's
independent DNS-rebinding guard. Neither guard is disabled. Configure the MCP
endpoint's public origin too when its Host differs from the browser origin.
For example, use `https://mcp.example.com,https://dashboard.example.com:8443`.
An allowlisted hostname does not bypass bearer authentication.

Cross-origin browser requests must include the **actual scheme, hostname and
port** in the configured origin. In particular, `http://localhost` does not
permit a browser at `http://localhost:3000` to call a server at port 9292;
configure `http://localhost:3000` explicitly. This is stricter than the older
Woods-only port-insensitive Origin check. In 1.6.4, preflight and SDK dispatch
share one immutable normalized policy. Default HTTP(S) ports match their omitted
form; explicit lists replace default browser origins. Invalid entries fail at
boot with the offending entry named. Restart after changing allowed origins.
No allowlist means the existing loopback defaults remain in effect.

`OPTIONS` preflights are answered with the matching `Access-Control-Allow-*` headers; successful responses carry `Access-Control-Allow-Origin`, `Access-Control-Expose-Headers: Mcp-Session-Id`, and `Vary: Origin`.

### Origin configuration compatibility

These details apply to the supporting security-patch revisions described above.

Configured origins are literal values, with lowercasing, one trailing slash
removed and HTTP(S) default-port normalization. Wildcard-looking hostnames are
literal hostnames, not patterns. A nonempty explicit list replaces browser-origin
defaults, including loopback; add the loopback browser origins you need. Console's
configured defaults are HTTP loopback; the Index defaults include HTTP and HTTPS
loopback. Loopback **Host** acceptance is separate from browser-origin acceptance.

Ruby-configured 2.x origin entries reject surrounding whitespace; 1.6.4 trims it.
The `woods-mcp-http` comma-separated environment setting trims each entry on both
lines. Use whitespace-free values for portable configuration. The exact-port and
same-authority rules above still apply; literal matching does not imply wildcard
or arbitrary cross-port access.

The guards read the actual `Origin` and `Host`; `Forwarded` and
`X-Forwarded-*` do not replace them. Preserve the public Host through a proxy.
A genuinely absent Host is accepted by the Host policy, but any supplied Origin
must still pass its own check. Console requests and token-configured Index
requests still require bearer authentication before dispatch. The loopback-only
Index mode without a token retains its documented unauthenticated behavior;
CORS preflights do not dispatch tools.

Malformed Origin/Host values receive constant `403` responses without reflecting
the values. Invalid Authorization receives `401` when it reaches the auth guard.
Malformed HTTP framing can instead receive Puma's `400` before Rack runs. Other
HTTP servers may reject framing at their own boundary.

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

