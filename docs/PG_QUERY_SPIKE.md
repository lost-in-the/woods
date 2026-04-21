# pg_query Spike: AST-Based SQL Identifier Extraction

**Status:** Evaluation / design doc. No code yet.
**Scope:** Console MCP server — the `SqlTableScanner` identifier-extraction path.
**Pair:** Optional, additive to the existing regex scanner. Not a replacement.

---

## TL;DR

Adding [`pg_query`](https://github.com/pganalyze/pg_query) as an **optional** runtime dependency would give PostgreSQL hosts AST-grade table/identifier extraction for the `SqlTableScanner` step of SQL validation, closing every class of regex bypass that requires a literal-injection gadget or a syntactic edge case (CTEs whose alias collides with a reserved word, nested subqueries with uncommon quoting, comments not handled by `SqlNoiseStripper`, etc.).

MySQL hosts cannot use it — `pg_query` embeds the PostgreSQL parser, which rejects MySQL-specific syntax (`STRAIGHT_JOIN`, backtick identifiers in many positions, `ENGINE=InnoDB` hints if they ever leaked into a scanned fragment). Those hosts stay on the regex path, which is unchanged.

**Recommendation: green-light the integration.** The cost is low (one optional gem, ~30 lines of bridge code, one new spec file). The gain is meaningful defense-in-depth on the most exposed attack surface (user-supplied SQL via `console_sql`), and the optional-dep pattern means zero impact on hosts that don't opt in.

---

## Why This Exists

### The current state

After PR #44 the identifier-extraction path is owned by `Woods::Console::SqlTableScanner` — a small, auditable module that walks a SQL string with regex and returns the set of identifiers referenced. It feeds `TableGate`, which is the enforcement point that decides whether a query is allowed to touch a given table.

The scanner is good at what it does:

- `SqlNoiseStripper` is run first, so comments, string literals, and dollar-quoted bodies never reach the identifier regex.
- Both JOIN-style and ANSI-89 comma joins are handled.
- Every MySQL / PostgreSQL quoting style is matched (`` ` ``, `"`, bare, and the mixed forms).
- Schema-qualified identifiers are emitted as `schema.table` so `TableGate` can match against either form.

### The residual risk

Regex is structurally blind to things a real parser understands:

1. **New syntax.** Each Postgres release adds grammar. `MERGE` (PG 15), `JSON_TABLE` (PG 17), `XMLTABLE`, `LATERAL`, `TABLESAMPLE`, `GROUPS BETWEEN` frames — none of these are in the scanner's vocabulary. Most are read-only and therefore safe, but "safe by accident" is not a posture.
2. **Escaping edge cases.** Any bug in `SqlNoiseStripper` — a comment form we missed, a quote escape we didn't normalize, a dialect-specific literal prefix — immediately becomes a regex bypass. The noise stripper is careful but it's still a regex.
3. **Semantic equivalence.** `FROM schema.table`, `FROM "schema"."table"`, `FROM ONLY schema.table`, `FROM schema.table AS t`, `FROM schema.table t FORCE INDEX (...)` — the scanner handles all of these, but the list is open-ended. Every time the list grows, we're racing against the grammar.

The existing approach is fine as a **first** line of defense. It's not good enough as the **only** one, especially now that `console_sql` is the first feature that accepts user-supplied SQL.

### What AST gets us

A real parser turns the SQL into a tree of `RangeVar` nodes (and their equivalents). Asking "which tables does this query reference?" becomes a tree-walk, not a regex match. The answer is dialect-correct for every syntactic form the parser accepts, and new grammar is added by upgrading the gem, not by patching our regex.

---

## Feasibility

### The gem

[`pg_query`](https://rubygems.org/gems/pg_query) is a Ruby binding over libpg_query — the PostgreSQL parser extracted as a standalone library. It's maintained by [pganalyze](https://pganalyze.com/), heavily used in production (Heroku's pgAnalyze, Datadog's Postgres integration, many others), and published as source with native extension build.

Relevant properties:

- **Pure parser.** It doesn't connect to a database. No credentials, no network, no side effects. Input is a string, output is a parse tree.
- **Statically linked grammar.** The gem ships the PostgreSQL grammar for a specific major version. We get AST fidelity for that version regardless of the host Postgres.
- **Native extension.** Requires a C toolchain at install time. This is the main friction and the reason it must be optional.
- **License.** BSD-3-Clause. Compatible with our MIT license.

### The optional-dep pattern

We already do this once — `Woods::SessionTracer::RedisStore` requires the `redis` gem at runtime and raises a clear error if it's missing:

```ruby
unless defined?(::Redis)
  raise SessionTracerError, 'The redis gem is required for RedisStore. ...'
end
```

The `pg_query` integration follows the same shape:

```ruby
begin
  require 'pg_query'
  PG_QUERY_AVAILABLE = true
rescue LoadError
  PG_QUERY_AVAILABLE = false
end
```

…and the scanner checks `PG_QUERY_AVAILABLE` (plus the configured adapter) before attempting AST extraction. Regex is always the fallback.

No change to the gemspec — `pg_query` is an **opt-in suggestion**, not a hard dependency. Hosts that want it add `gem 'pg_query'` to their Gemfile.

### What we don't inherit

A few things `pg_query` does not give us for free and are explicitly out of scope for this spike:

- **Rewriting.** `pg_query` can rewrite AST back to SQL. We don't want this. Identifier extraction only.
- **Semantic validation.** The AST tells us what tables are referenced. It doesn't know whether they exist in the schema — that's not our job here anyway.
- **SQL execution planning.** `pg_query` is not a query planner. No EXPLAIN equivalence, no cost estimation.

---

## Threat Model Improvement

### Before (regex only)

| Attack class | Current coverage | Residual risk |
|---|---|---|
| Comment-hidden tables (`/* FROM blocked */`) | Stripped by `SqlNoiseStripper` | Low — depends on stripper regex |
| String-literal-hidden tables (`'FROM blocked'`) | Stripped by `SqlNoiseStripper` | Low — depends on stripper regex |
| Dollar-quoted bodies (`$$ SELECT * FROM blocked $$`) | Stripped (mysql dialect pass skips this; postgres dialect handles it) | Medium — dialect-specific |
| Unusual quoting (`"schema"."table"`, mixed forms) | Matched | Low |
| Schema-qualified (`schema.table`) | Matched | Low |
| ANSI-89 comma joins (`FROM a, b, c`) | Matched | Low |
| JOIN-style (`INNER JOIN`, `STRAIGHT_JOIN`) | Matched | Low |
| PG inheritance `ONLY` keyword | Stripped before match | Low |
| New PG grammar not yet in scanner (`MERGE`, `JSON_TABLE`, etc.) | Unknown — depends on whether the grammar uses a recognized keyword | **Medium** — silent gap |
| Nested subqueries in FROM clause | Matched (H-3 bypass closed in PR #44) | Low |
| Writable CTEs (`WITH x AS (DELETE ...)`) | Rejected by `SqlValidator` (separate pre-check) | Low |
| Set operators (`UNION`, `INTERSECT`, `EXCEPT`) | Rejected by `SqlValidator` (body forbidden) | Low |

The scanner is in good shape. The honest residual risk is **"new grammar we haven't seen yet"** and **"stripper regex bugs we haven't found yet"** — both are medium-probability, medium-impact silent gaps.

### After (AST on PG; regex on MySQL)

| Attack class | PG host | MySQL host |
|---|---|---|
| Any literal-injection gadget | Neutralized — parser sees the literal as a literal | Same as today |
| Any comment variant | Neutralized — parser discards comments | Same as today |
| New PG grammar | Covered — parser recognizes it | N/A |
| New MySQL grammar | N/A | Same as today |
| Grammar ambiguity between dialects | AST on PG; regex defers to MySQL vocabulary | N/A |
| Parse failure on MySQL-specific syntax running on PG host | **Falls back to regex, logs a debug line** | N/A |

The last row is important: `pg_query` **will** fail on MySQL syntax. Our integration must degrade, not error. See "Failure modes" below.

---

## Dialect Coverage Matrix

| Dialect | AST extraction | Regex fallback | Notes |
|---|---|---|---|
| PostgreSQL (`pg` adapter) | Available if `pg_query` installed | Always | AST is primary; regex is belt-and-braces |
| PostgreSQL (host without `pg_query`) | — | Always | Same posture as today |
| MySQL (any variant) | — | Always | pg_query cannot parse MySQL |
| SQLite | — | Always | Same as MySQL — not a PG grammar |
| Other (Oracle, MSSQL, Trino) | — | Always | Not supported by `pg_query` |

**Selection rule.** The scanner chooses AST when all of:

1. `pg_query` is loadable (`PG_QUERY_AVAILABLE == true`).
2. The active ActiveRecord adapter reports a Postgres-family name (`postgresql`, `postgis`).
3. `pg_query.parse` succeeds on the input.

On any failure it falls back to regex and emits a structured debug log. Regex is **always** run in addition, so the identifier set is a union — the AST can only make the union larger (more tables caught), never smaller (missed tables).

### Rationale for union, not replacement

If AST returns `{users}` and regex returns `{users, orders}`, we want `TableGate` to see both. Two independent extractors disagreeing is a signal that one of them is wrong. Rather than silently pick a winner, we gate on the union — if the user tried to reference `orders`, we catch it regardless of which extractor spotted it.

The cost is a marginally larger identifier set passed to `TableGate`, which is cheap (set comparison against the configured allow/block lists).

---

## Integration Plan (if green-lit)

### Scope

One new module, one integration point, one new spec file. No changes to `SqlValidator`, `SafeContext`, `CredentialScanner`, or the gemspec.

### Files

| File | Change |
|---|---|
| `lib/woods/console/sql_table_scanner.rb` | Accept an optional `ast_extractor:` injection; call it alongside regex; union the results |
| `lib/woods/console/pg_query_extractor.rb` (new) | Wraps `pg_query`; returns `[]` on parse failure; gated by `PG_QUERY_AVAILABLE` |
| `spec/console/pg_query_extractor_spec.rb` (new) | Covers: parse success, parse failure → empty array, missing gem → empty array, identifier extraction for CTEs, subqueries, JOINs, schema-qualified names |
| `spec/console/sql_table_scanner_spec.rb` | One added context: "with AST extractor injected, results are unioned" |
| `docs/CONSOLE_MCP_SETUP.md` | Short "Optional: AST-grade SQL scanning" section explaining how to enable |
| `CHANGELOG.md` | `### Added` entry |

No changes to `Gemfile` / `woods.gemspec`. `pg_query` stays out-of-tree.

### Sketch — `PgQueryExtractor`

```ruby
# frozen_string_literal: true

begin
  require 'pg_query'
  WOODS_PG_QUERY_AVAILABLE = true
rescue LoadError
  WOODS_PG_QUERY_AVAILABLE = false
end

module Woods
  module Console
    # AST-based identifier extractor for PostgreSQL SQL.
    #
    # Returns the set of tables referenced by a SELECT/WITH/EXPLAIN
    # statement, extracted from the pg_query parse tree. Returns [] if
    # parsing fails or the pg_query gem is not installed — callers must
    # union this result with the regex scanner's output.
    #
    module PgQueryExtractor
      def self.available?
        WOODS_PG_QUERY_AVAILABLE
      end

      def self.identifiers_in(sql)
        return [] unless available?
        return [] if sql.nil? || sql.empty?

        tree = PgQuery.parse(sql)
        tree.tables(:select) # returns relnames as "schema.table" or "table"
      rescue PgQuery::ParseError
        []
      end
    end
  end
end
```

### Sketch — wiring into `SqlTableScanner`

```ruby
# in SqlTableScanner.identifiers_in:
results = []
collect_join_identifiers(stripped, results)
collect_from_identifiers(stripped, results)

if ast_enabled?
  results.concat(PgQueryExtractor.identifiers_in(sql))
end

results.uniq
```

`ast_enabled?` checks `PgQueryExtractor.available?` **and** the adapter via a thin probe. Dependency injection keeps this testable without monkey-patching `ActiveRecord`.

### Failure modes

| Scenario | Behavior |
|---|---|
| `pg_query` gem missing | `available? == false`; AST branch skipped; regex only |
| PG-family adapter but gem missing | Same — regex only; no error |
| Non-PG adapter with gem present | Adapter probe disables AST; regex only |
| `PgQuery::ParseError` on valid MySQL syntax | Caught; returns `[]`; regex only for that query |
| `PgQuery::ParseError` on malformed SQL | Caught; returns `[]`; `SqlValidator` or database driver surfaces the syntax error downstream |
| Parser segfault (shouldn't happen) | Uncaught, process crashes. Unlikely — `pg_query` is widely used and stable. If observed, ship a fix in the gem or drop the integration. |

### Rollout

1. Ship behind an opt-in config flag: `config.console_sql_ast_enabled = false` by default.
2. Document the flag + `gem 'pg_query'` addition in `docs/CONSOLE_MCP_SETUP.md`.
3. Once soaked in a real host (validation-checklist item), flip the default to `true` **when** `PgQueryExtractor.available?` is true. Hosts that didn't opt into the gem see no change.

### What would make me change my mind

- If `pg_query` native-extension build breaks commonly across the Rails/Ruby matrix we support. Not expected — the gem has broad coverage — but it's worth a pre-flight `bundle install` check on CI before merge.
- If `PgQuery.parse` shows pathological latency on specific query shapes (recursive CTEs, very long IN-lists). Benchmark during implementation. If p99 is bad, introduce a length cap and fall back to regex for oversized inputs.
- If we discover a meaningful class of **MySQL** bypass that the existing regex misses. That's a different project — AST doesn't help MySQL hosts — and it would reprioritize this spike downward.

---

## Open Questions

1. **Do we ever want to surface the AST beyond identifier extraction?** E.g., "did this query call a dangerous function" or "does this query have a writable CTE"? `SqlValidator` already handles those with regex and has been robust. For now: no. Revisit only if a concrete bypass shows up.
2. **Should we support a second parser for MySQL?** `sql_parse` or similar? Mixed feelings — the MySQL parsing-library ecosystem is thinner and less well maintained. Deferring to "MySQL hosts keep regex" is the honest answer.
3. **Is `pg_query.tables(:select)` stable API?** Yes — documented and used by pganalyze. Pin to `pg_query >= 5.0` in the docs and CI suggestions.

---

## Decision

Proceed with the integration as described. Optional dependency, regex fallback, union semantics, opt-in flag at first. Revisit defaults after the live-validation checklist run.
