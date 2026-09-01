# 02. Contracts probed and held

What was attacked and survived. This is the evidence that the remediation held under adversarial probing, not just under its own specs.

Roughly 300 probe shapes executed across nine agents plus the synthesizing session. Probe scripts are listed in 08.

## Console security (the H2/M4/M5 remediation)

All [executed] against the real validator, executor, redactor, and scanner classes:

- **SqlValidator, 97+ shapes.** Writable CTE in every WITH position, nested CTEs, WITH-attached top-level DML, comment and newline splits of lock clauses under both dialects, all five lock-clause forms with OF/NOWAIT/SKIP LOCKED, mid-body bare DML, dollar-quoted literals (no false positives, no smuggling), E-strings, U&'' strings, BOM, executable comments plain and versioned, DML keyword as CTE name, `VALUES`/`TABLE`/`EXECUTE`/`HANDLER`/`DO`/`LOAD DATA`/`COPY`, quoted dangerous functions, function allowlist. Identifier-shaped columns (`for_update`, `updated_at`, `merge`, `do`, `lock`) all accepted.
- **Redaction, 44+ shapes.** Alias forms (lowercase, qualified, quoted, implicit no-AS), aggregates over protected columns, EAV alias/aggregate/orphan-value on select and columns paths, concat/comment/nested-function smuggles, case-variant predicate columns, `console_sql` outer-select rule against subquery/CTE/ORDER BY/window-function oracles. One hole found: CON-1.
- **TableGate.** Executable-comment lead at FROM/JOIN/subquery, comment-in-string confusion, escape-dialect unions, schema-qualified wildcards.
- **CredentialScanner.** JWT, connection URLs, PEM, base64- and URL-encoded keys, regex-special secrets through CredentialIndex.
- **BearerAuth/OriginGuard.** Constant-time compare, fail-closed short/nil tokens, loopback handling, path scoping.

## Extraction naming (the G-1 remediation)

- **41 nesting shapes** [executed]: deep class-in-class, compact + wrapper mixes, sibling files, wrapper-as-target, `::TopLevel` prefixes, conditional wrappers, `Struct.new` assignment, reopened classes, digit segments, acronym declines that fall back safely, unmanaged paths.
- **Collision fail-closed**: names both files; same-file re-derivation still dedups silently.
- **ModelNameCache**: metachar escaping, longest-first alternation, ambiguity skip, quote-aware comment stripping, interpolated constantize rejected.
- Holes found in the neighbourhood: EXTA-1 (trailing comments), EXTA-14 (non-ASCII identifiers), EXTA-7 (old zeitwerk).

## Publication, durability, coordination

- **Generation bump-last-only-on-success** on all four rake entry points and the daemon degrade path (#270 wiring traced end-to-end).
- **B-134 symlink boundary** [executed]: root-alias allowed; escaping child, relative, and nested-chain symlinks refused; re-validation at write time.
- **B-136 cross-process pinning** [executed]: FD balance over 100 cycles, nested pins, exception release, pin-during-flip, prune-retry, external flock exclusion.
- **PipelineLock** [executed specs]: token-verified touch, three-state ownership, fork-based two-contender reclaim races. Holes at the edges: INF-7 (ENOSPC 0-byte lock), MCP-3 (in-flight flag leak above the lock).
- **WVF1 corruption family** [executed]: truncated blob, truncated idx, count mismatch both directions, oversized length fields, truncated header. All typed `UnsupportedArtifact`. The metadata twin is weaker: STO-4.
- **Checkpoint-vs-durability** [executed]: ENOSPC ordering, interval-save suppression on the dump path, self-heal into re-embed, identity-stamp discard, chunk-suffix collision refusal.
- **B-069 vanished-unit gate** [executed]: no-op runs write no dump, purge guards on both paths, `WOODS_ALLOW_PURGE` override, stale chunk pruning.

## MCP servers

- **M7 reload transaction** [executed]: build-then-swap under the writer lock, both identity rechecks, old-or-new-never-empty, torn-halves refusal, bounded 2s poll against a held writer lock (no deadlock).
- **Pin refcounting and freshness** [executed]: `[mtime, size, ino]` signature, same-size republish, token collision, exclusive-reload gating.
- **ToolContract** against real mcp 1.4.0: closed schemas, bounds, limit guard before schema validation, corrupt-artifact mapping.
- **cache_scope private + sort_tools!** verified on the wire (http e2e lane, executed here).
- **Tasks store** [executed specs]: terminal-is-terminal, pid-reuse discrimination, corrupt-record sweep, opt-in gating. Hole: MCP-4 (reboot orphan).
- **update_check** neighbours: prerelease versions, malformed registry, corrupt cache.
- **H1 encoding** [executed]: all four IndexReader spec files green under `LC_ALL=C`; no bare artifact reads remain in mcp/ or retrieval/.

## Graph, AST, flow

- **PageRank mass conservation** [executed]: duplicates, dangling, self-loop, all-orphan, empty, 5000-node cycle. Sum = 1.0 everywhere.
- **#225 typed collision variants** [executed]: round-trip, typed remove, union edges.
- **GraphAnalyzer#analyze rotation determinism**: the spec compares exactly (not deep-sorted). `domain_clusters` is the exception: EXTB-7.
- **Flow fail-closed family**: all four abort paths pinned; routes-wholesale cascade flows through the incremental refresh.
- **L2 neighbours** [executed]: elsif chains, ternary, rescue/ensure, endless defs, operator defs, numbered params. `unless` was the untested neighbour and is broken: EXTB-4.

## Storage and embedding

- **UUIDv5** [executed]: RFC 4122 reference vectors, namespace literal equals its derivation, latin1 transcode, integer/UUID passthrough, delete symmetry.
- **CircuitBreaker** [executed]: 8-thread half-open race admits exactly one probe.
- **RetryAfter / RetryableProvider** [executed]: delta and HTTP-date, 120s cap, garbage fallback, verb-aware POST no-retry.
- **SQLite hardening** [executed]: hostile field names, busy retry, empty fields, literal wildcards.
- **CachedEmbeddingProvider single-flight**: no deadlock on duplicate texts; inflight cleanup on success/error/Interrupt.

## Exporters

- **Rate limiter pacing** [executed]: 20 calls at 10 rps took 1.903s; 50 calls across 10 threads at 100 rps took 0.499s. Monotonic, no drift.
- **Verb-aware retry** on both clients: POST/PATCH not retried on read-timeout; 503 on create raises the ambiguous-outcome error.
- **Purge guards**: strict > 0.30, floor >= 10, ownership sentinel, error-free-run requirement. Boundary math exact at 30% and at 9/10 docs.
- **Manifest degrade**: corrupt, unreadable, foreign-schema, non-ASCII-under-LANG=C all degrade to full re-push with a warning.
- **Psych frontmatter**: YAML-hostile and YAML-1.1-ambiguous scalars round-trip; `\n---\n` injection not expressible.
- **Obsidian sweep conservatism** and path-traversal chokepoint held (except EXP-6's glob metacharacters).

## Daemon and infra

- **ScriptError rescued** at every reload site.
- **Catch-up ordering** [executed specs]: watcher-before-catch-up, mid-catch-up events, storm threshold, deletion reconciliation with absolutized paths, out-of-root exclusion.
- **Status host-identity-before-pid**, injected clock on both sides, heartbeat inside the staleness window.
- **tail-M1 exit-code matrix** [executed specs]: running vs degraded stand-down, failed-range ordering, rename/UTF-8 parse.
- **Temporal L20 + P8**: distinct-SHA diffing, retention tie-breaking, fork-based SQLite contention.

## Suspicions probed and falsified

- `IndexArtifact#atomic_write` without binmode corrupting UTF-8 config: falsified by probe.
- `GraphAnalyzer#analyze` rotation spec being deep-sorted (blind): falsified; it compares exactly.
- Payload-retention TOCTOU against the reader pin: closed by the post-lock re-read; probe held.
- P1/P2/P9a memoization serving stale content across runs: falsified; caches are per-run on every entry point.
- Exporter mutation of the P6 frozen graph: falsified; edge maps allocate fresh hashes.
