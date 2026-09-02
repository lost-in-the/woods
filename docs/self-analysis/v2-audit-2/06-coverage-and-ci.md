# 06. Coverage, CI, and spec quality

## Suite baseline at HEAD (this audit's run)

`bin/rspec` (default lane), POSIX locale, run as root:

- **7254 examples, 4 failures, 2 pending** (4m 38s).
- 1 real failure: `index_reader_spec.rb:1087`: finding R2-3, the locale-fragile P5 guard spec. Fails on any C-locale host; passes on UTF-8 CI runners.
- 3 environment artifacts: `pipeline_guard_spec.rb:51, 93` and `pipeline_tasks_spec.rb:261` assert unreadable-file behavior via chmod, which cannot fail for root. Not code bugs. Worth a `skip_if_root` guard so container runs stay clean.
- 2 pending: the known Inspector conformance pendings (B-117).

Slice re-runs during the audit: ~2,900 additional examples across agents, all green except the one above.

## Specs that pin bugs

A spec that asserts wrong behavior makes the bug invisible to CI and ratifies it. Seven found:

| Spec | Pins | Finding |
|---|---|---|
| `spec/extractors/job_extractor_spec.rb:329` | `retry_config[:error] == 'Net'` for `Net::OpenTimeout` | EXTA-10 |
| `spec/ruby_analyzer/mermaid_renderer_spec.rb:140-153` | legacy bare-string edges a current graph never produces | EXTB-6 |
| `spec/mcp/tasks/store_spec.rb:364-374` | foreign-boot working record stays working forever | MCP-4 |
| `spec/db/migration_schema_spec.rb:100-124` | a legacy fixture state the legacy gem never produced | STO-1 |
| `spec/storage/metadata_store_spec.rb:409-415` | InMemory symbol round-trip under a SQLite-parity title | STO-8 |
| `spec/operator/pipeline_guard_spec.rb:177-187` | `reset!` unable to repair the one state needing repair | INF-6 |
| `spec/notion/mappers/migration_mapper_spec.rb:9-57` | extracted_at == migration timestamp, hiding the wrong field | EXP-3 |

Also: `spec/mcp/index_reader_freshness_spec.rb:228-255` pins the two-pin ride-the-old-generation behavior that MCP-5 shows is unbounded under sustained overlap.

## Tests that cannot fail

- `spec/storage/snapshotter/vector_spec.rb:680-717`: a tolerance block ("does NOT guard against truncation") that passes whether or not the load raises, stale since the M10 fix (STO-12).
- `spec/mcp/server_spec.rb:472-492`: "picks up changed data after reload" builds a server without a reloader, a configuration no packaged executable produces (MCP-2's cover).
- `builder_spec.rb:884-891`: the Ollama "no budget" title asserts a state the constructor cannot produce (STO observation).

## Coverage promised by the remediation and delivered

All verified present and running (see 01): watcher backend-selection spec, live-Redis specs plus the redis CI service, packaged-gem smoke on every PR, `perf.yml` (dispatch + nightly), InputContract spec, AstSourceExtraction direct spec, migration column asserts, Notion truncation spec, encoding specs. `fail_if_no_examples` still guards every opt-in lane name.

## Where the new-finding coverage is thinnest

1. **Encoding under C locale outside IndexReader.** Feedback store, session-tracer FileStore, evaluation QuerySet have zero non-ASCII fixtures. The suite runs under US-ASCII (the live canary), but ASCII-only fixtures never trip it. One shared "record non-ASCII, read under forced US-ASCII" helper would cover the family.
2. **The block-keyword line-parser family.** Four hand-rolled copies (SourceNesting, RakeTaskExtractor, FactoryExtractor, SemanticChunker) have no comment/string/heredoc adversarial fixtures anywhere. Each copy broke differently (EXTA-1, EXTB-1, EXTB-2, STO-3).
3. **Missing-baseline incremental.** No spec exercises `extract_changed` or `woods:incremental` over an empty output dir (CORE-2). The equivalence harness always baselines with `extract_all`.
4. **Transport-path console validation.** No spec drives `console_sql` through DispatchPipeline with a non-SQLite dialect; the only MySQL-dialect spec bypasses the handler (CON-2).
5. **Reload against ordinary host shapes.** No spec reloads a retriever-wired server with no promoted dump (MCP-1) or a flat index through the packaged wiring (MCP-2).
6. **Exit codes for embed/notion.** The publication exit-code spec family covers only the extraction tasks (INF-4).
7. **Duplicate result headers in the redactor.** No spec feeds duplicate column names (CON-1).

## Lanes not executed in this audit

Recorded, not run, because the Docker testbed and live services are unavailable in this environment:

- `:booted_app` (incremental equivalence, booted extraction, watch daemon integration, multi-worktree, wrapper fixtures across Rails 6.0-8.1).
- `:live_backends` (pgvector, Qdrant, Redis, Solid Cache).
- `:mcp_inspector` (also pending upstream, B-117).
- MySQL-dialect console validation against a live server (testbed-only by design; CON-2 makes this lane more important).
- `:http_server` WAS executed here (green), as were the packaged-gem-adjacent unit specs.

## CI observations

- The default GitHub runners use a UTF-8 locale, so R2-3 and any future C-locale regression are invisible to PR CI. A cheap `LC_ALL=C bin/rspec spec/mcp spec/feedback spec/session_tracer spec/evaluation` job would hold the canary honestly.
- The root-runner artifacts above suggest the three permission specs need a non-root guard for container-based CI portability.
