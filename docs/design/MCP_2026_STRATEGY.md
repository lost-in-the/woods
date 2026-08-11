# MCP 2026-07-28 Support Strategy

Status: **proposal** — no code changed yet. Research completed 2026-08-11 against
the [2026-07-28 specification](https://modelcontextprotocol.io/specification/2026-07-28)
and the [`mcp` Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk) as of v1.1.0.

This document answers three questions: what actually changed in the protocol,
what that means for Woods' two MCP servers and the people running them, and
what we should build in what order.

---

## 1. The headline

Woods writes **no protocol code**. Both servers — `Woods::MCP::Server` (index,
29 tools) and `Woods::Console::Server` (console, 31 tools) — are `MCP::Server`
instances from the official `mcp` gem, driven by `StdioTransport` or
`StreamableHTTPTransport`. Lifecycle, framing, capability negotiation, error
codes and version headers are all the SDK's.

That means the migration is not "implement a new protocol". It is:

1. **Lift one version pin** (`mcp >= 0.9.2, < 1.0` in the gemspec).
2. **Stop pinning the protocol backwards** (`exe/woods-mcp-start` hard-defaults
   `MCP_PROTOCOL_VERSION=2024-11-05`).
3. **Opt in to the four new capabilities that pay for themselves** — statelessness,
   Tasks, cache hints, subscriptions.

The gem cap is the whole blocker. `mcp` 1.1.0 (2026-08-01) added 2026-07-28 as
its latest protocol version; `< 1.0` holds Woods at 0.25.0, one minor release
short. The SDK reached the new spec incrementally, which is why the surface we
have to touch is small:

| SDK version | Date | What it added that matters here |
|---|---|---|
| 0.23.0 | 2026-07-07 | Stateless request handling via ephemeral sessions; deprecated Roots/Sampling/Logging per SEP-2577 |
| 0.24.0 | 2026-07-12 | `server/discover`, stateless lifecycle error codes, MRTR `input_required` results, `ttlMs`/`cacheScope` cache hints |
| 0.25.0 | 2026-07-18 | Client-side sampling; better handling of unknown/expired sessions |
| 1.0.0 | 2026-07-24 | API declared stable; breaking changes only in majors |
| 1.1.0 | 2026-08-01 | **2026-07-28 as the latest protocol version** |

The APIs Woods actually calls — `MCP::Server.new(name:, version:, resources:,
resource_templates:)`, `server.define_tool`, `MCP::Tool::Response`,
`MCP::Configuration.new(protocol_version:)`, both transports — are unchanged
across that range. The removals in 0.10.0 (`notify_progress` broadcast,
undocumented handler overrides) and 0.15.0 (`MCP::Transports`) predate our
floor. **We are already past every breaking change on the path.**

---

## 2. What changed in the protocol

### 2.1 The nine major changes

1. **Sessions are gone.** No `Mcp-Session-Id` header, no session-scoped state.
   List endpoints no longer vary per connection. Cross-call state must be an
   explicit, server-minted handle passed as an ordinary tool argument (SEP-2567).
2. **MCP is stateless.** No `initialize` / `notifications/initialized` handshake.
   Every request carries `io.modelcontextprotocol/protocolVersion` and
   `io.modelcontextprotocol/clientCapabilities` in `_meta`; clients SHOULD send
   `clientInfo`, servers SHOULD stamp `serverInfo` into each result's `_meta` (SEP-2575).
3. **`server/discover` is mandatory.** Servers MUST implement it. It returns
   `supportedVersions`, `capabilities`, `instructions`, and cache hints in one call.
4. **`subscriptions/listen` replaces the HTTP GET stream and
   `resources/subscribe`.** One long-lived POST-response stream; the client opts
   in to specific notification types (`toolsListChanged`, `promptsListChanged`,
   `resourcesListChanged`, `resourceSubscriptions`). Request-scoped notifications
   (`progress`, `message`) still flow on their own request's response stream.
5. **`ping`, `logging/setLevel` and `notifications/roots/list_changed` removed.**
   Log level is per-request via `io.modelcontextprotocol/logLevel`.
6. **Tasks moved out of core into an official extension**
   (`io.modelcontextprotocol/tasks`): polling via `tasks/get`, client input via
   `tasks/update`, no `tasks/list`, and servers may return task handles unsolicited.
7. **MRTR replaces server-initiated requests.** Instead of the server sending
   `sampling/createMessage` or `elicitation/create`, it returns an
   `InputRequiredResult` and the client retries the original request with
   `inputResponses` (SEP-2322).
8. **All results carry `resultType`** (`"complete"` or `"input_required"`).
   Absent means `"complete"` for older servers.
9. **SSE resumability removed.** No `Last-Event-ID`, no event IDs, no redelivery.
   A broken stream loses the in-flight request; the client re-issues with a new ID.

### 2.2 Minor changes that matter to us

- `CacheableResult`: **`ttlMs` and `cacheScope` are now required** on `tools/list`,
  `prompts/list`, `resources/list`, `resources/read` and `resources/templates/list`.
- Servers **SHOULD** return `tools/list` in deterministic order — explicitly to
  improve client caching and LLM prompt-cache hit rates.
- `Mcp-Method` and `Mcp-Name` headers required on Streamable HTTP POSTs;
  optional `x-mcp-header` mirrors tool parameters into `Mcp-Param-*`.
- Error codes renumbered into a reserved range: `HeaderMismatch` `-32020`,
  `MissingRequiredClientCapability` `-32021`, `UnsupportedProtocolVersion` `-32022`.
  Resource-not-found moves `-32002` → `-32602`.
- `inputSchema`/`outputSchema` loosened to any JSON Schema 2020-12; `$ref` must
  not be auto-dereferenced over the network.
- OpenTelemetry `traceparent`/`tracestate`/`baggage` reserved in `_meta`.

### 2.3 Deprecated (12-month window, still functional)

Roots, Sampling, Logging; the HTTP+SSE transport; `includeContext` values
`"thisServer"`/`"allServers"`; OAuth Dynamic Client Registration.

**Woods uses none of them.** A grep across `lib/woods/mcp/`, `lib/woods/console/`
and `exe/` finds no `sampling`, `roots/list`, `logging/setLevel`, `ping`, or
`elicitation` usage. Every hit is an unrelated substring. Woods logs to `stderr`
already, which is exactly the suggested migration for the Logging feature. This
is a genuinely clean position — the deprecation window costs us nothing.

---

## 3. Where Woods stands today

### 3.1 The protocol pin is backwards

```bash
# exe/woods-mcp-start, line 54
export MCP_PROTOCOL_VERSION="${MCP_PROTOCOL_VERSION:-2024-11-05}"
```

`woods-mcp-start` is the **documented `.mcp.json` entry point** — the self-healing
wrapper users are told to register. It pins the *oldest* protocol version in
existence, four revisions behind. `exe/woods-mcp` is better (it only sets
`MCP::Configuration` when the env var is present, otherwise inheriting the SDK
default), but anyone following the setup docs goes through the wrapper.

The comment says "for Claude Code compatibility". That was true when it was
written. Today it means every Woods user is opted out of protocol version
negotiation, cache hints, `server/discover`, and everything else, by default.

### 3.2 The HTTP server is session-bound

`exe/woods-mcp-http` constructs `StreamableHTTPTransport.new(server)` with no
`stateless:` flag, so it mints `Mcp-Session-Id`, tracks sessions server-side,
honours DELETE for teardown, and serves the GET SSE endpoint.
`docs/MCP_HTTP_TRANSPORT.md` documents `Access-Control-Expose-Headers: Mcp-Session-Id`
as part of the CORS contract.

Practical consequence: **restarting `woods-mcp-http` invalidates every client
session.** Given the index server gets restarted whenever the gem updates, the
machine sleeps, or a worktree is rebuilt, that is a routine event that currently
forces every connected client through a re-initialize.

### 3.3 `pipeline_extract` is a fire-and-forget thread

```ruby
Thread.new do
  ... Woods::Coordination::LockHeartbeat.run(lock) { run_extraction.call } ...
end
respond.call(JSON.pretty_generate({ status: 'started', ... }))
```

The tool returns `{status: "started"}` and the agent never hears from it again.
To find out what happened it must poll `pipeline_status`. If the MCP server
process dies mid-run, the thread dies with it and there is no durable record
that the extraction was ever attempted. Around this sit `@pipeline_mutex`,
`@pipeline_in_flight`, `pipeline_start`/`pipeline_finish`, `PIPELINE_LOCK_WAIT`,
`acquire_lock_briefly`, and the `pipeline_status`/`pipeline_diagnose`/`pipeline_repair`
tool trio — a hand-rolled async job protocol.

This is precisely what the Tasks extension standardises.

### 3.4 Freshness is pull-only

`Generation` is bumped last and only on success, so it is an exact "the index
changed" signal. Today nothing pushes it: `IndexReader#ensure_fresh!` stats
`generation.json` at the top of every public read, and the `reload` tool exists
as a manual optimisation. The watch daemon can rewrite the whole index and the
agent finds out at its next tool call.

---

## 4. What we should build

Four workstreams, ordered by ratio of payoff to risk. Each maps to at least one
of the acceptance axes in the brief.

### Phase 1 — Unblock and stop pinning backwards
*Axes: disconnect/reconnect, performance, features (all of them are gated on this)*

- Lift the gemspec pin to `mcp >= 1.1, < 2.0`. Dropping `>= 0.9.2` compatibility
  is the right call: the SDK's own versioning policy now guarantees stability
  within a major, and supporting both 0.x and 1.x means branching on SDK
  internals for no user benefit.
- Delete the `MCP_PROTOCOL_VERSION` default from `exe/woods-mcp-start`. Keep the
  env var as an **escape hatch** — a user on a stubborn legacy client can still
  pin — but the default must be "let the SDK negotiate".
- Verify the Ruby floor holds. `mcp` 1.1.0 declares `required_ruby_version >= 2.7.0`;
  Woods declares `>= 3.0.0`. **No floor change.** The `rails-6.0` testbed variant
  boots on Ruby 3.0 and stays supported. Add a CI row that asserts this rather
  than trusting it.
- Confirm dual-era behaviour end-to-end against the testbed and at least one
  legacy client.

**Acceptance:** a legacy client and a modern client both work against one
unmodified `woods-mcp` process; `server/discover` returns Woods' capabilities;
no Ruby or Rails floor moves.

### Phase 2 — Stateless HTTP
*Axis: disconnect/reconnect (the big one)*

- Pass `stateless: true` to `StreamableHTTPTransport` in `exe/woods-mcp-http`,
  behind `WOODS_MCP_HTTP_STATELESS` defaulting to **on**, with session mode
  available for one deprecation window.
- Update `docs/MCP_HTTP_TRANSPORT.md`: drop `Mcp-Session-Id` from the documented
  CORS contract, document that GET/DELETE now answer `405`, and document that
  streams are not resumable.

What this buys: a restart of `woods-mcp-http` becomes **invisible to clients**.
No session to invalidate, no re-initialize, no 404-then-reconnect dance. It also
makes the HTTP server horizontally deployable for the first time — any POST can
land on any instance — which matters for the Docker split-architecture and
multi-worktree setups where several consumers read one volume-mounted index.

The honest cost: **losing SSE resumability**. For Woods this is close to free.
Every index tool is a short JSON read; the only long operations are
`pipeline_extract`/`pipeline_embed`, which are already fire-and-forget and are
about to become Tasks — which survive disconnects *better* than resumable SSE did.

### Phase 3 — Tasks for the pipeline tools
*Axes: disconnect/reconnect, code bloat, features*

Advertise `io.modelcontextprotocol/tasks`. When a client declares support,
`pipeline_extract` and `pipeline_embed` return a `CreateTaskResult` with a durable
`taskId`, `ttlMs` and `pollIntervalMs` instead of `{status: "started"}`. Serve
`tasks/get`, `tasks/update` and `tasks/cancel`. When the client does *not*
declare support, fall back to today's behaviour verbatim — the spec requires
never returning a task to a client that did not opt in, and that fallback is our
old-client compatibility story.

What this buys:

- **A real completion signal.** The agent learns that extraction succeeded or
  failed, with the error, instead of polling `pipeline_status` and guessing.
- **Disconnect survival.** A task ID is durable. Client restarts, resumes polling,
  gets the result. Today a dropped client plus a dead server loses the run silently.
- **Cooperative cancellation** — `tasks/cancel` against a `LockHeartbeat`-guarded
  extraction, which we cannot express at all right now.
- **Deletion of bespoke machinery.** `@pipeline_in_flight`, `pipeline_start`/
  `pipeline_finish` and the `already_running` error path become the task registry's
  job. `pipeline_status` narrows to reporting *index* state rather than doubling
  as a job-status endpoint.

Sequencing note: the durable task store must outlive the process to deliver the
crash-resilience claim. The obvious substrate is the index directory Woods
already owns and already writes atomically (`AtomicFile`, `Generation`,
`status.json`). Any new writer against that directory **must take `PipelineLock`** —
see the CLAUDE.md gotcha; unlocked writers are how #169/#170 happened.

### Phase 4 — Cache hints, deterministic ordering, subscriptions
*Axes: performance, features*

**Cache hints and ordering** are the cheapest performance win available:

- Sort `tools/list` deterministically. The spec calls this out specifically for
  LLM prompt-cache hit rates. Woods registers 14 always-on tools plus up to 15
  wiring-conditional ones, so today's order is a function of which integrations
  happen to be configured.
- Set `ttlMs` from `Generation`. Woods knows *exactly* when the index changed —
  that is what the generation counter is for. Tool and resource lists are stable
  between generations.
- Set `cacheScope: "private"` everywhere, without exception. Woods' resources
  expose the user's own source code and dependency graph; `"public"` would
  authorise shared intermediaries to cache it. This is a security-relevant
  default, not a tuning knob.

**Subscriptions** are the natural pairing with the watch daemon. When the daemon
bumps the generation, the index server pushes `notifications/resources/updated`
(and `tools/list_changed` if wiring-conditional tools appeared) instead of
waiting for the agent's next read to discover it via `ensure_fresh!`.

Two caveats worth stating plainly. This needs a generation-watcher in the MCP
server process — modest, but new concurrency in a component whose threading
model is already load-bearing (refcounted pins, per-reader mutex, HTTP request
threads). And client support for `subscriptions/listen` is not universal yet.
So: gate it, ship it last, and keep `ensure_fresh!` as the correctness path with
subscriptions as the optimisation — exactly the relationship the `reload` tool
has today.

### Explicitly out of scope

- **MRTR / elicitation for the index server.** No index tool needs user input.
- **`x-mcp-header`.** Woods has no intermediary doing header-based routing.
- **MCP Apps.** Interesting for dependency-graph and ERD visualisation, but
  speculative and unrelated to this migration.

One flagged opportunity, deliberately not scheduled: the **console server's Tier 4
guarded tools** currently confirm out-of-band via `Console::Confirmation`
(`:auto_approve` / `:auto_deny` / `:callback`) — there is no way to ask the actual
human. MRTR elicitation, or Tasks' `input_required` state, is the right shape for
that. It is a real improvement to a real gap, but it is a console-server feature
rather than a protocol migration, so it belongs in its own item.

---

## 5. Compatibility: who breaks, and who does not

The spec's compatibility matrix has exactly one failing combination that we
control: **legacy client + modern-only server**. Legacy clients have no
fall-forward mechanism — they send `initialize`, get an error, and stop.

The mitigation is to be **dual-era, never modern-only**, and the Ruby SDK server
is dual-era by construction: it serves `server/discover` and per-request `_meta`
for modern clients while still answering `initialize` for legacy ones. Woods gets
this by upgrading the gem and *not* pinning a protocol version. The corollary is
that the `MCP_PROTOCOL_VERSION` default in `woods-mcp-start` is not merely
suboptimal — pinning is the one action that could turn a working dual-era server
into a single-era one.

| Environment | Impact |
|---|---|
| Legacy MCP client (older Claude Code, Cursor, Zed, custom) | **No change.** Dual-era server keeps answering `initialize`. |
| Modern MCP client | Gains `server/discover`, cache hints, negotiation; no config change. |
| Ruby 3.0 / 3.1 hosts | **No change.** `mcp` 1.1.0 needs `>= 2.7.0`; Woods stays `>= 3.0.0`. |
| Rails 6.0 testbed variant (Ruby 3.0) | **No change.** Still within the floor. |
| stdio users (`woods-mcp`, `woods-console-mcp`) | Unaffected mechanically; gain faster restart recovery — no handshake to redo. |
| Docker split architecture (host reads volume-mounted output) | Unaffected; benefits from stateless HTTP if using the HTTP server. |
| Multi-worktree setups | Benefit. Stateless HTTP means a restarted server does not invalidate other worktrees' clients. |
| `woods-mcp-http` users relying on `Mcp-Session-Id` | **The one real break.** GET/DELETE become `405`; the header disappears. Mitigated by keeping session mode behind a flag for a deprecation window. |
| Clients relying on SSE `Last-Event-ID` resumability | Removed by the spec, not by us. Low impact — Woods tool calls are short; long operations move to Tasks. |

Two things worth being explicit about, because they are easy to assume away:

- **Nothing here requires re-extraction or re-embedding.** No on-disk artifact
  format changes. `_index.json`, `dependency_graph.json`, `metadata.msgpack`,
  the dump directories and `generation.json` are all untouched.
- **Nothing here changes the Ruby or Rails support matrix.** Verify it in CI
  rather than asserting it in a doc.

---

## 6. Suggested backlog items

Added to `docs/backlog.json` as B-108 through B-111, one per phase, so they can
be picked up independently. B-108 gates the other three.

---

## 7. Sources

- [MCP 2026-07-28 specification](https://modelcontextprotocol.io/specification/2026-07-28)
- [Key Changes / changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
- [Base protocol, statelessness and `_meta`](https://modelcontextprotocol.io/specification/2026-07-28/basic/index)
- [Versioning and compatibility, incl. the era matrix](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
- [Streamable HTTP transport](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
- [stdio transport](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)
- [`server/discover`](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)
- [`subscriptions/listen`](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions)
- [Tasks extension](https://modelcontextprotocol.io/extensions/tasks/overview)
- [`mcp` Ruby SDK releases](https://github.com/modelcontextprotocol/ruby-sdk/releases) and [gem versions](https://rubygems.org/gems/mcp/versions)
