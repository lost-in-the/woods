# MCP 2026-07-28: what's left, and how to finish it

Companion to [MCP_2026_STRATEGY.md](MCP_2026_STRATEGY.md), which covers what
changed in the protocol and why. **This document is the handoff**: what is done,
what is deliberately not done, and what an agent with a full local development
environment should do next.

Read this first if you are picking the work up. It is written to be actionable
without re-deriving the research.

---

## 1. State of play

| Item | Status |
|---|---|
| B-108 gem cap lifted, protocol un-pinned | ✅ shipped |
| B-109 stateless Streamable HTTP | ✅ shipped |
| B-110 Tasks extension | ✅ shipped (Woods-side implementation) |
| B-111 deterministic tool order + cache hints | ✅ shipped |
| B-111 generation-driven change notifications | ⛔ **blocked on the SDK** |
| Strict per-request envelope validation | ⚠️ **not conformant** — see §3.1 |
| `resultType` on results | ⚠️ **not conformant** — see §3.2 |
| Booted-Rails validation of any of it | ❌ **never run** — see §4.1 |

Everything shipped is covered by unit specs plus a real-subprocess HTTP
end-to-end spec. Nothing has been validated against a booted Rails host,
because the environment that produced it had no Docker daemon.

---

## 2. The SDK is the binding constraint

The single most useful thing to internalise: **`mcp` 1.1.0's client half is well
along, and its server half is mostly not.** Several 2026-07-28 constructs are
*defined* in the gem and referenced by nothing on the server path. Do not
infer support from the presence of a constant — grep for its callers, or probe.

| Construct | Defined | Wired server-side |
|---|---|---|
| `server/discover` | ✅ | ✅ |
| `stateless:` on `StreamableHTTPTransport` | ✅ | ✅ |
| `ttl_ms` / `cache_scope` | ✅ | ✅ |
| `2026-07-28` in `SUPPORTED_STABLE_PROTOCOL_VERSIONS` | ✅ | ✅ |
| `MCP::RequestEnvelope` | ✅ | ❌ referenced only by its own file + the autoload |
| `UnsupportedProtocolVersionError` (`-32022`) | ✅ | ❌ raised only from `RequestEnvelope#parse!`, which nothing calls |
| `MCP::ResultType` | ✅ | ❌ referenced only in `client.rb` |
| `ErrorCodes::HEADER_MISMATCH` (`-32020`) | ✅ | ❌ constant only, never raised |
| `Mcp-Method` / `Mcp-Name` / `x-mcp-header` | ✅ | ❌ `client/http.rb` only; the server never validates |
| Tasks extension | ❌ | ❌ — Woods implements it |
| `subscriptions/listen` | ❌ | ❌ — blocks the remaining feature |

**Reproduce the headline finding in ten seconds** — an unsupported protocol
version is served rather than refused:

```ruby
# bundle exec ruby -e '...'
require 'mcp'; require 'json'
srv = MCP::Server.new(name: 'probe', version: '1.0')
srv.define_tool(name: 't', description: 't', input_schema: { type: 'object', properties: {} }) { |**| MCP::Tool::Response.new([]) }
meta = {
  'io.modelcontextprotocol/protocolVersion' => '1900-01-01',
  'io.modelcontextprotocol/clientInfo' => { 'name' => 'x', 'version' => '1' },
  'io.modelcontextprotocol/clientCapabilities' => {}
}
puts srv.handle_json(JSON.generate(
  { jsonrpc: '2.0', id: 1, method: 'tools/list', params: { _meta: meta } }
))
# => a normal tools/list result. Expected: UnsupportedProtocolVersionError (-32022).
```

---

## 3. Work that is possible now, in priority order

### 3.1 Per-request envelope validation — **recommended**

*Effort: small. Risk: low. Conformance: real.*

The spec requires a server to reject a request whose `protocolVersion` it does
not support, with `-32022` and a `supported` list. Woods currently serves it.

The SDK ships everything needed except the call: `RequestEnvelope.modern?`,
`RequestEnvelope.parse!` and `Server::UnsupportedProtocolVersionError` all
exist and are correct — `parse!` is simply never invoked.

**Approach.** A prepend on the built server, alongside the two Woods already
uses (`VersionAwareToolDispatch`, `Tasks::RequestCapture`). Wrap `handle_request`
(or `handle`), and when `RequestEnvelope.modern?(params)` is true, call
`parse!` and let it raise. Keep it to *modern* requests only — a legacy client
sends no envelope and must keep working, which is exactly what `modern?`
already discriminates.

**Watch out for:** `server/discover` must stay exempt. It is the
backward-compatibility probe, and a client uses it precisely when it does not
yet know which versions you support — rejecting it on version grounds would
break the negotiation it exists to enable.

**Acceptance:** the probe in §2 returns `-32022` with a `supported` array; a
legacy `initialize` flow and a modern request at `2026-07-28` are both
unaffected; `server/discover` answers regardless of the version claimed.

### 3.2 Emit `resultType` on results — **optional**

*Effort: small. Risk: low. Value: conformance only.*

The spec makes `resultType` required on every result. Woods emits none. This is
benign in practice — clients **MUST** treat an absent `resultType` as
`"complete"` — so it costs nothing today and is worth doing only if you want
strict conformance, or if a validator is complaining.

`MCP::ResultType::COMPLETE` is already defined. The same prepend seam as §3.1
can stamp results on the way out. Note that Woods' Tasks path already sets
`resultType` explicitly (`"task"` / `"complete"`), so any blanket stamping must
not clobber a result that already carries one.

### 3.3 Header validation for Streamable HTTP — **skip unless you deploy an intermediary**

`Mcp-Method` and `Mcp-Name` are REQUIRED on POSTs, and a server MUST reject a
header/body mismatch with `-32020`. Woods does not check. This only matters if
something in front of `woods-mcp-http` routes or rate-limits on those headers —
the mismatch is a security boundary precisely when a load balancer trusts the
header while the server executes the body. No current deployment does this.
Revisit if a gateway lands in front of the HTTP server.

### 3.4 Generation-driven change notifications — **blocked, do not attempt yet**

Two independent walls:

1. **Stateless HTTP has no notification channel.** The SDK's `send_notification`
   opens with `return false if @stateless`. No session, no standalone GET
   stream, nothing to push on.
2. **No conforming opt-in exists.** `subscriptions/listen` is how a 2026-07-28
   client subscribes, the spec says a server **MUST NOT** send notification
   types the client has not explicitly requested, and the SDK does not
   implement it. There is no way for a client to ask, so any push violates
   that MUST.

Implementing it anyway means building a long-lived SSE response stream inside a
transport deliberately built to hold none — forking SDK transport internals to
re-add what the revision removed, for an optimisation.

**Do not do this.** The cost of waiting is bounded and well understood:
`IndexReader#ensure_fresh!` is the *correctness* path and is untouched, so an
agent never reads a stale index — it learns about a change on its next call
rather than immediately. That is the same relationship the `reload` tool
already has.

**Revisit when** the SDK ships `subscriptions/listen`. The signal to hang it
off (`Generation`, bumped last and only on success) already exists, so the work
is then genuinely small: watch the generation file, push
`notifications/resources/updated`, and gate on the acknowledged filter.

### 3.5 Upstream the gaps — **highest leverage**

Most of §3 is Woods compensating for an incomplete SDK server. Filing issues
(or PRs) against
[`modelcontextprotocol/ruby-sdk`](https://github.com/modelcontextprotocol/ruby-sdk)
for envelope consumption, `resultType` emission, and `subscriptions/listen`
fixes it for every Ruby MCP server and lets Woods delete code rather than add
it. Woods' `Tasks::Extension` was written to be deletable for exactly this
reason — when the SDK ships native tasks, `install` goes away and the durable
`Store` (the part that actually buys crash resilience) is unaffected.

---

## 4. What a local development environment unlocks

This is the part that needs someone with a working local setup. None of it is
blocked on design — it is blocked on infrastructure the authoring environment
did not have.

### 4.1 Booted-Rails validation — **the biggest gap**

**Nothing in this work has been exercised against a booted Rails app.** The
authoring environment had the Docker binary but no daemon
(`/var/run/docker.sock` absent), so `woods-testbed` was unusable.

The unit suite covers the protocol behaviour well, but two things it cannot
reach:

- **`pipeline_extract` against a real extraction.** Every task-lifecycle spec
  stubs `Woods::Extractor`. Nothing has watched a genuine multi-second
  extraction move a task from `working` to `completed`, or confirmed that the
  `LockHeartbeat` + task-completion interleaving behaves under real timing.
- **The task store on a real index directory,** alongside a live watch daemon
  and the `PipelineLock` contention the two-writer rules exist for. The claim
  that task records need no lock is argued in the code and unit-tested, but not
  observed under concurrency.

```bash
cd woods-testbed && docker compose up -d rails-8.0
docker exec woods-testbed-rails-8.0 bash -lc 'cd /app && bin/rails woods:extract'
```

Then point an MCP client (or a hand-rolled JSON-RPC driver) at the index and
run a real `pipeline_extract` with the tasks capability declared.

**Suggested addition:** a smoke script in the testbed's `scripts/` — that
directory is mounted read-only into every variant, so one script validates
Rails 6.0, 7.2 and 8.0 unchanged.

### 4.2 A real MCP client

Everything here was verified by constructing JSON-RPC by hand. Worth doing with
an actual client (Claude Code, Cursor, MCP Inspector):

- Confirm a **legacy** client still connects to the un-pinned server. This is
  the compatibility claim the whole change rests on, and it has only been
  verified by driving `initialize` directly.
- Confirm the Tasks path against a client that genuinely declares
  `io.modelcontextprotocol/tasks`. No such client was available; the opt-in was
  exercised with hand-built `_meta`.
- Confirm the tool-order change is visible where it is supposed to pay off.

### 4.3 Measure the cache-hint and ordering win

`ttlMs`/`cacheScope` and deterministic tool order were adopted on the spec's
reasoning, **not on measurement**. Neither has been benchmarked. If they matter
to you, measure before tuning `WOODS_MCP_CACHE_TTL_MS` — and be willing to
conclude the ttl should be 0.

---

## 5. Environment notes

Things that cost time in the authoring environment; fix or be aware.

- **`bundle exec rake` and `bundle exec rspec` do not work** under Bundler
  4.0.9 — it does not expose gem binstubs, so both fail with
  `command not found`. **Use `bin/rake`, `bin/rspec`, `bin/rubocop`**, which
  work fine. Note that `CLAUDE.md`'s Commands section still says
  `bundle exec rake spec`; that is correct under Bundler 2.x and wrong under 4.
- **`puma` is now in the dev/test group** (added by this branch) so
  `exe/woods-mcp-http` can boot. Before this it could not — `Rackup::Handler.default`
  raised `LoadError`, which is why the executable had no end-to-end coverage.
- **Opt-in spec tags:**
  ```bash
  bin/rspec                                             # default unit suite
  WOODS_RUN_HTTP_SERVER=1 bin/rspec spec/mcp/http_server_e2e_spec.rb
  WOODS_RUN_BOOTED_APP=1  bin/rspec spec/integration/booted_extraction_spec.rb
  WOODS_RUN_PERF_SPECS=1  bin/rspec --tag perf
  ```
- **`tiktoken_ruby` is absent**, leaving two permanently-pending token-benchmark
  specs. Harmless.
- **The suite runs under `LANG=C` / US-ASCII**, which is a deliberate canary
  (see the `AtomicFile.read` gotcha in `CLAUDE.md`). Consequence for spec
  authors: reading a *source file* that contains an em dash needs
  `File.read(path, encoding: Encoding::UTF_8)`, or `match` raises instead of
  failing. That is correct — Ruby source is UTF-8 by definition — and is not
  the same thing as papering over the artifact-encoding canary.

---

## 6. Known divergences, accepted

- **`DELETE` returns `200`, not `405`.** The spec says a server supporting only
  this revision *should* answer `405`; the SDK answers `200 {"success": true}`
  in stateless mode. Benign — there is no session to terminate either way — and
  it is the SDK's call, not Woods'. Recorded so the next person does not
  "fix" it.
- **`@pipeline_in_flight` was kept.** B-110 originally proposed deleting the
  in-process pipeline mutex in favour of the task registry. The registry
  replaces the status-*reporting* half, but the mutex is still the cheapest
  correct same-process exclusion and needs no disk read per call.
