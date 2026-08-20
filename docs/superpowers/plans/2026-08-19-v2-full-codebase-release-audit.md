# Woods v2 Full-Codebase Release Audit Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` for independent audit/remediation packages and `superpowers:verification-before-completion` before closing each package. Track work with checkbox (`- [ ]`) syntax. Read-only audit agents must stop at 60 minutes and return partial findings rather than continue indefinitely.

**Goal:** Prove that Woods 2.0.0 is correct, supportable, secure, documented, and releasable across every shipped entry point and subsystem before creating the v2 tag.

**Architecture:** Run the review in two stages. Stage 1 reproduces and resolves known release-blocking contract failures. Stage 2 inventories and tests every remaining subsystem, public endpoint, output shape, supported environment, package artifact, and document. Parallel workers own disjoint areas; the lead reviewer validates shared boundaries after every batch and owns the final release decision.

**Tech Stack:** Ruby 3.0-4.0, Rails 6.0-8.1, RSpec, SimpleCov, Appraisal, RuboCop, GitHub Actions, MCP Ruby SDK 1.2.x, MCP 2026-07-28, MCP Inspector v2, SQLite, PostgreSQL/pgvector, Qdrant, Rack/Puma.

**Spec:** This plan is the release-review specification. It is grounded in `main` at `8fea1922886ac34991820ddf6a97dae94fe06fa3` and the merged v2 changelog dated 2026-08-19.

## Global Constraints

- Work from a new branch created from current `origin/main`; do not commit directly to `main`.
- Preserve the pre-existing untracked `HANDOFF-release-2.0.0.md`; do not add it to commits.
- Never publish, tag, or push a gem until every acceptance gate in this plan passes.
- Never put private host-app names or details in code, tests, documentation, issues, commits, or PR text.
- Do not use private applications for validation unless isolated fixtures and the dummy Rails app cannot reproduce the behavior. Any private-app changes must remain uncommitted and be discarded.
- Do not add AI attribution or signoffs to commits, PRs, comments, or documentation.
- Treat MCP 2026-07-28 and `mcp >= 1.2, < 2.0` as release contracts. Verify protocol behavior with official primary sources and a real client, not only SDK internals.
- Every finding must include severity, affected public behavior, a reproducer, file/line evidence, and a disposition: fixed, documented limitation, deferred with issue, or rejected with evidence.
- P0 and P1 findings block the v2 tag. P2 findings may be deferred only when they do not contradict public claims and have an issue with a concrete acceptance test.
- Keep fixes atomic and scoped. Each commit must have one behavior change plus its tests or one coherent documentation correction.

## Starting Evidence

- `origin/main` and local `main` point to `8fea192`.
- Main CI run `32302116061` passed all 21 jobs: Ruby 3.0-4.0 unit suites, nine booted Rails/Ruby rows, real pgvector/Qdrant, HTTP E2E, coverage, lint, security, and build.
- The default suite contains 6,304 examples and four pending examples.
- A local coverage run measured 91.17% line coverage, but opt-in integration suites were excluded from that result.
- The repository contains 240 production files, 327 spec files, 51 files under `docs/`, five executables, 34 registered extractors, 29 possible Index MCP tools, and 31 Console MCP tool schemas.
- Known confirmed concerns include unreachable or overstated Console bridge behavior, non-operative task cancellation, provider/storage configuration mismatches, incomplete packaged-document links, and a release workflow that does not gate on the full CI surface.

---

### Task 1: Establish The Auditable Release Branch And Evidence Ledger

**Files:**
- Create: `.Codex/backlog.json`
- Create: `.Codex/release-v2/surface-inventory.json`
- Create: `.Codex/release-v2/findings.json`
- Create: `.Codex/release-v2/verification.md`

**Produces:** A machine-readable inventory and finding ledger used by every later task.

- [x] Create `audit/v2-final-release` from current `origin/main`; record the base SHA in `.Codex/release-v2/verification.md`.
- [x] Build `surface-inventory.json` directly from code: configuration attributes, presets, 34 extractor registrations, rake tasks, five executables, 29 possible Index MCP tools and their conditions, Index resources/templates, 31 Console schemas and tiers, Tasks methods, storage/provider/export adapters, and public `Woods` methods.
- [x] Seed `findings.json` with the confirmed concerns in Tasks 2-5. Use stable IDs, severities, evidence paths, reproduction commands, owner, status, and release-blocking boolean.
- [x] Record exact commands, Ruby version, dependency bundle, random seed, coverage result, and CI URLs in `verification.md`; do not rely on prose claims without reproducible evidence.
- [x] Add a CI check that regenerates the public-surface inventory and fails when code-derived counts drift from documentation or contract specs.
- [x] Commit only the audit scaffolding and inventory check.

### Task 2: Close Publishing And Packaged-Gem Release Blockers

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `.github/workflows/ci.yml`
- Modify: `woods.gemspec`
- Modify: `spec/spec_helper.rb`
- Create: `spec/integration/packaged_gem_spec.rb`
- Test: `.github/workflows/release.yml` with `actionlint`

**Produces:** One immutable, verified gem artifact whose tag, version, changelog, package contents, and full-CI SHA agree.

- [ ] Add a failing workflow validation for a tag that does not equal `v#{Woods::VERSION}`, lacks a matching dated changelog section, is not reachable from `main`, or names an already-published version.
- [ ] Make release publication depend on the successful full CI workflow for the exact tag SHA, including Rails matrix, live backends, HTTP E2E, coverage, security, lint, and build.
- [ ] Build once with `gem build --strict`, store the `.gem` and SHA-256 as workflow artifacts, test that artifact, then publish that same byte-for-byte artifact.
- [ ] Add package-manifest assertions for the five executables, runtime files, license/community files, and every README target intended to work from an unpacked gem.
- [ ] Install the built gem into clean temporary Ruby 3.0 and Ruby 4.0 environments without the repository on `$LOAD_PATH`; smoke `require "woods"`, all five executables, both generators, rake-task loading, extraction against the dummy app, and Index MCP startup.
- [ ] Resolve README/package navigation by either packaging the supported user docs or making package-visible links absolute. Test the chosen contract from the unpacked gem.
- [ ] Make source/changelog/documentation metadata version-aware and verify it resolves for `v2.0.0`.
- [ ] Run `actionlint`, `bundle exec bundle-audit check --update`, `gem build --strict woods.gemspec`, the package spec, and the full CI suite; commit the release-pipeline change separately.

### Task 3: Repair Console MCP Capability And Safety Contracts

**Files:**
- Modify: `exe/woods-console-mcp`
- Modify: `lib/woods/console/connection_manager.rb`
- Modify: `lib/woods/console/bridge.rb` or remove it from the supported path
- Modify: `lib/woods/console/dispatch_pipeline.rb`
- Modify: `lib/woods/console/tool_specs.rb`
- Modify: `lib/woods/console/embedded_executor.rb`
- Modify: `lib/woods/console/rack_middleware.rb`
- Test: `spec/console/**/*_spec.rb`
- Create: `spec/console/cli_integration_spec.rb`

**Produces:** An executable and documented Console surface in which every advertised tool is actually available in the advertised mode and every safety claim is enforceable.

- [ ] Reproduce that `woods-console-mcp` checks the default-disabled global configuration before reading its YAML and that docs use a different environment variable. Define one configuration source and precedence contract, then test startup from the packaged executable.
- [ ] Choose and implement one honest bridge disposition: complete a real all-tier bridge, or remove/mark the stub path unsupported and stop advertising Tier 2-3 as executable. Do not ship static empty responses as live query results.
- [ ] Build a 31-row contract matrix from `TOOL_SPECS`: mode, required arguments, valid output, invalid input, authorization, table gate, redaction, credential scan, confirmation requirement, and audit behavior.
- [ ] Fix `console_query.having` so its JSON Schema accepts exactly the safe Hash/parameterized-array shapes the executor accepts; reject schema-valid-but-unexecutable inputs.
- [ ] Replace permissive `String#to_i` coercion with strict integer parsing and enforce lower and upper bounds for IDs, limits, depths, and timeouts.
- [ ] Enforce confirmation and audit semantics for every operation that claims them, or narrow documentation to the operations that actually receive those controls.
- [ ] Make bridge requests synchronized, correlate response IDs, bound disconnect waits, handle EOF/EPIPE consistently, and prove retry exhaustion rather than resetting the retry counter after each reconnect.
- [ ] Decide and test modern stateless behavior for Console HTTP. Ensure Index and Console HTTP differ only when an explicit compatibility setting requires it.
- [ ] Add subprocess tests for stdio startup, HTTP startup, INT/TERM/EOF shutdown, blocked child shutdown, concurrent requests, malformed responses, and one real supported query per executable mode.
- [ ] Run the complete Console suite plus a booted Rails/database integration row before committing.

### Task 4: Make MCP 2026-07-28 Tasks And Transport Semantics Real

**Files:**
- Modify: `lib/woods/mcp/protocol_policy.rb`
- Modify: `lib/woods/mcp/server.rb`
- Modify: `lib/woods/mcp/tasks/extension.rb`
- Modify: `lib/woods/mcp/tasks/store.rb`
- Modify: `exe/woods-mcp`
- Modify: `exe/woods-mcp-http`
- Test: `spec/mcp/**/*_spec.rb`
- Create: `spec/integration/mcp_inspector_contract_spec.rb`

**Produces:** Protocol-correct stdio and HTTP servers validated by the Ruby SDK client and official MCP Inspector v2.

- [ ] Add a failing cancellation test that blocks extraction or embedding, invokes `tasks/cancel`, and asserts work stops, the pipeline lock releases, and no generation is published. Implement cancellation or remove the false cancellation capability.
- [ ] Test task creation, get, update, cancellation, failure, expiry, process death, corrupt records, read-only task directories, concurrent polling, and restart durability through the actual MCP transport.
- [ ] Verify client opt-in and protocol-version gating for Tasks. A legacy or non-opted-in client must receive the documented synchronous/fire-and-forget behavior and must not receive a task handle.
- [ ] Enumerate all 29 possible Index tools and test each registered and unavailable state. Every row must cover valid output, missing/wrong/unknown arguments, boundary values, missing collaborators, corrupt artifacts, and stable error metadata.
- [ ] Test both static resources and both resource templates for success, missing targets, malformed URIs, content type, and path traversal.
- [ ] Define stable structured output where MCP supports `outputSchema`/`structuredContent`; where text rendering is intentional, test JSON, Markdown, plain, and Claude renderers against the same semantic payload.
- [ ] Drive stdio and HTTP with the official Ruby client and MCP Inspector v2 CLI under protocol `2026-07-28`; verify `server/discover`, stateless headers, auth, origin policy, unsupported legacy methods, malformed envelopes, and restart behavior.
- [ ] Run the MCP unit suite, HTTP socket suite, Inspector contract suite, and packaged executable smoke before committing.

### Task 5: Correct Configuration, Provider, Storage, And Persistence Contracts

**Files:**
- Modify: `lib/woods.rb`
- Modify: `lib/woods/builder.rb`
- Modify: `lib/woods/resolved_config.rb`
- Modify: `lib/woods/mcp/config_resolver.rb`
- Modify: `lib/woods/storage/metadata_store.rb`
- Modify: `lib/woods/storage/qdrant.rb`
- Modify: `lib/woods/temporal/snapshot_store.rb`
- Modify: `lib/woods/temporal/json_snapshot_store.rb`
- Test: `spec/builder_spec.rb`, `spec/resolved_config_spec.rb`, `spec/storage/**/*_spec.rb`, `spec/temporal/**/*_spec.rb`
- Test: `spec/integration/live_backends_spec.rb`

**Produces:** Every documented preset and option constructs the intended provider/store, survives process boundaries as claimed, and cold-starts against real services.

- [ ] Add executable tests proving `embedding_model` and provider-specific model options select the actual OpenAI/Ollama model and that resolved configuration records the model used, not a disconnected default.
- [ ] Correct the documented OpenAI dimension option to match the provider API or implement supported dimensions explicitly; reject unknown keys with a useful configuration error.
- [ ] Give SQLite metadata one documented keyword contract and test file-backed persistence through Builder and a second process. Ensure presets claiming durability never silently select `:memory:`.
- [ ] Test every preset (`local`, `shared_filesystem`, `postgresql`, `production`) from configuration through Builder, snapshot/bootstrap, and retrieval. Record which external settings must be supplied at serve time.
- [ ] Make Qdrant Builder cold-start create or verify its collection; test empty service, existing compatible collection, dimension mismatch, auth failure, permission failure, TLS, timeout, 429/503, malformed JSON, and ambiguous writes.
- [ ] Test pgvector schema creation, duplicate IDs, dimensions, transaction boundaries, permissions, connection loss, and retry posture against the live PostgreSQL service.
- [ ] Make temporal SQLite capture atomic across snapshot row creation, unit replacement, pruning, and diff update. Add rollback and concurrent-writer tests.
- [ ] Use atomic writes for temporal JSON and exporter manifests; test interruption, corrupt input, Unicode, fixed-temp-name collisions, and recovery.
- [ ] Test cache/session stores for TTL, serializer failures, non-injective IDs, concurrent updates, growth bounds, and Redis/Solid Cache dependency absence.
- [ ] Run isolated adapter specs, process-boundary persistence, and live backends before committing each adapter family.

### Task 6: Audit Full Extraction, Incremental Maintenance, Graphs, And Flows

**Files:**
- Review: `lib/woods/extractor.rb`
- Review: `lib/woods/extractors/**/*.rb`
- Review: `lib/woods/path_dispatcher.rb`, `lib/woods/change_set.rb`, `lib/woods/index_artifact.rb`
- Review: `lib/woods/dependency_graph.rb`, `lib/woods/graph_analyzer.rb`
- Review: `lib/woods/flow_*.rb`, `lib/woods/flow_analysis/**/*.rb`
- Review: `lib/woods/watch/**/*.rb`, `lib/woods/coordination/**/*.rb`
- Test: matching unit and integration specs under `spec/extractors`, `spec/integration`, `spec/watch`, and graph/flow specs

**Produces:** Deterministic, atomic, equivalent full/incremental output across all 34 registered extractors and every supported Rails row.

- [ ] Generate a 34-row extractor matrix from the registry. For every extractor, verify empty input, normal input, namespaces, multiple units per file, malformed/non-UTF-8 source, optional dependency absent/present, duplicate identifiers, dynamic DSLs, comments/heredocs, and deterministic serialization.
- [ ] Add direct contract coverage for shared extractor support modules, not only same-name extractor specs.
- [ ] Inject one extractor failure in sequential and concurrent modes. A partial extraction must not be published as a successful complete generation unless the manifest explicitly records degradation and readers honor it.
- [ ] Inject failures at every artifact boundary: unit write, graph write/read, manifest, analysis, orphan sweep, generation pointer, snapshot, and cleanup. Prove readers see either the old complete generation or the new complete generation.
- [ ] Extend the differential harness across create, modify, delete, rename, type change, multi-unit file, route/middleware/engine changes, symlinks, awkward paths, and worktree concurrency. Compare normalized full and incremental artifacts after every operation.
- [ ] Test graph identifiers that collide across types, ambiguous suffix resolution, duplicate registration, mutation after analyzer memoization, cycles, depth limits, relocation, missing nodes, and stale graph artifacts.
- [ ] Test flow assembly for route/controller/action resolution, callbacks, jobs, mailers, redirects/renders, cycles, truncation, missing operations, and portable source paths.
- [ ] Test watch crash/restart, concurrent readers/writers, PID reuse, stale locks, pending-path durability, stop signals, polling/listen parity, and full-restart triggers.
- [ ] Run all extractor specs plus every Rails matrix row's booted extraction, incremental equivalence, watch daemon, and multi-worktree suites before closing this package.

### Task 7: Audit Embedding, Retrieval, Evaluation, Caching, And Output Quality

**Files:**
- Review: `lib/woods/embedding/**/*.rb`, `lib/woods/chunking/**/*.rb`
- Review: `lib/woods/retriever.rb`, `lib/woods/retrieval/**/*.rb`
- Review: `lib/woods/evaluation/**/*.rb`, `lib/tasks/woods_evaluation.rake`
- Review: `lib/woods/cache/**/*.rb`, `lib/woods/resilience/**/*.rb`
- Review: `lib/woods/formatting/**/*.rb`, `lib/woods/mcp/renderers/**/*.rb`
- Test: corresponding specs and `spec/integration/evaluation_harness_spec.rb`

**Produces:** Measured retrieval quality and deterministic, bounded, schema-valid output under success and degradation.

- [ ] Add standalone-load coverage for every independently requireable production file; fix `evaluation/metrics.rb` requiring `set` before using `to_set`.
- [ ] Apply the same intent/scope validation to loaded query-set files as to programmatically added queries; reject malformed, duplicate, empty, and unknown records with line-level diagnostics.
- [ ] Test embedding provider response cardinality, vector type/dimensions, empty/malformed vectors, oversize input, rate limits, timeouts, partial batches, duplicate chunk IDs, identifiers ending in `#chunk_N`, checkpoint recovery, and backend/dump divergence.
- [ ] Test retrieval with blank/Unicode/oversized queries, zero/negative budgets and limits, every strategy and classifier intent, stale graph candidates, missing metadata, provider failure, store failure, formatter failure, and deterministic tie-breaking.
- [ ] Define and version a representative evaluation corpus. Run keyword, vector, graph, hybrid, and fallback strategies; record precision, recall, MRR, latency, and actual token use rather than result-count estimates.
- [ ] Set release quality thresholds from the checked-in v2 baseline: no metric regression beyond an explicitly reviewed tolerance, no invalid query silently accepted, and no provider outage producing a false-success empty answer.
- [ ] Test cache key isolation by provider/model/config, TTL, corruption, serializer errors, single-flight races, waiter cancellation, provider failure, and Redis/Solid Cache absence.
- [ ] Snapshot semantic output for representative tools across all renderers. Assert identifiers, counts, partial/degraded flags, truncation, escaping, and error metadata rather than only matching text fragments.
- [ ] Run evaluation, retrieval, embedding, cache, resilience, formatter, and integration suites before committing.

### Task 8: Make Coverage And Compatibility Evidence Complete

**Files:**
- Modify: `spec/spec_helper.rb`
- Modify: `.github/workflows/ci.yml`
- Modify: `Appraisals`
- Modify: `gemfiles/*.gemfile`
- Modify: `.rubocop.yml`
- Test: all `spec/**/*_spec.rb`

**Produces:** Coverage and compatibility reports that include every production file and release-critical branch, with no silently skipped surface.

- [ ] Configure SimpleCov `track_files 'lib/**/*.rb'`, branch coverage, named groups, and result collation for default, booted Rails, live backend, and HTTP subprocess lanes.
- [ ] Require overall line coverage of at least 90%, no production file at 0%, and at least 70% line coverage per non-declarative production file. Review declarative migrations/constants manually and list any justified exclusions explicitly.
- [ ] Require branch coverage of at least 80% in release-critical orchestration: MCP, Console, Builder/configuration, Tasks, storage adapters, extraction publication, and release/version checks.
- [ ] Require a contract test row for 100% of executables, rake tasks, registered extractors, possible MCP tools, Console tool schemas, resources/templates, presets, providers, stores, and exporters.
- [ ] Fail CI on unexpected pending examples. Convert intentional optional-dependency cases into explicit versioned allowlists or dedicated jobs; add a stable performance lane for the existing `:perf` suite.
- [ ] Add minimum-dependency resolution for runtime dependency floors, Appraisal/gemfile consistency checks, and representative latest-compatible resolution.
- [ ] Confirm Rails 6.0-8.1 and Ruby 3.0-4.0 support boundaries, including Rails 8.1 docs. Add only combinations that test a distinct boundary; document unsupported combinations explicitly.
- [ ] Load RuboCop RSpec/Rake plugins intentionally, add workflow linting, and decide whether static typing/SAST/license/SBOM checks provide actionable v2 gates. Do not add ceremonial tools without enforced findings.
- [ ] Publish coverage artifacts and a short per-subsystem summary on pull requests.

### Task 9: Review And Rebuild The Entire Documentation Set

**Files:**
- Review/modify: all 80 tracked Markdown files
- Modify: `README.md`, `CHANGELOG.md`, `SECURITY.md`, `CONTRIBUTING.md`
- Modify: `docs/*.md`, `docs/design/README.md`, `docs/self-analysis/*.md`
- Modify: `AGENTS.md`, `CLAUDE.md`, `.claude/**/*.md`
- Modify: `plugin/skills/**/SKILL.md`
- Create: `docs/UPGRADING_TO_2.md`
- Test: documentation links, anchors, snippets, and code-derived tables

**Produces:** A concise, accurate, navigable documentation set at the standard of a leading Ruby gem repository.

- [ ] Classify every Markdown file as current user guide, contributor reference, generated artifact, historical design/decision record, test fixture, or obsolete. Current docs must not rely on historical plans as operational guidance.
- [ ] Make README the concise evaluation, installation, quick-start, MCP setup, compatibility, security-warning, upgrade, and navigation surface. Move deep examples and architecture detail to focused guides.
- [ ] Correct the Console capability model everywhere: 31 schemas do not mean 31 executable tools in every mode. Remove unsupported bridge setup until it is real.
- [ ] Replace absolute rollback/read-only assurances with precise controls and escape paths. State that extracted output is source-equivalent and may contain secrets already present in source or fixtures.
- [ ] Correct `config.extractors` semantics everywhere. Do not claim it limits full extraction unless production code does so.
- [ ] Generate extractor counts, tool tables/signatures, presets, backend status, configuration attributes, and task lists from code. Separate shipped/tested, custom extension, experimental, and planned tooling.
- [ ] Remove runnable setup snippets for unimplemented adapters. Correct SQLite, Qdrant, OpenAI/Ollama, MCP, Console, client-path, and environment-variable examples against executable tests.
- [ ] Write `UPGRADING_TO_2.md`: breaking changes, clean re-indexing, backups, store/dimension migration, exporter reconciliation, MCP 1.2/2026-07-28 client requirements, known limitations, rollback/downgrade constraints, and failure recovery.
- [ ] Rewrite the 2.0 changelog section into user-visible changes, breaking changes, security posture, known limitations, and upgrade steps while retaining issue/PR attribution. Keep the release date 2026-08-19.
- [ ] Add provenance to self-analysis output or remove it from current navigation. Mark design/security plans as historical with status, date, and superseding documents.
- [ ] Validate every local link and GitHub anchor, every JSON/YAML snippet with a parser, every Ruby snippet with syntax checks or executable examples, and every shell/rake command in an isolated temporary project.
- [ ] Test all README links from both the repository and the unpacked gem. Verify current MCP claims against official MCP 2026-07-28, Ruby SDK, and Inspector documentation.
- [ ] Run a dedicated readability pass for scanning, retrieval, duplication, heading clarity, and concise examples; then have a second reviewer check factual accuracy against code.
- [ ] Commit documentation by coherent audience area, not as one unreviewable rewrite.

### Task 10: Adversarial Cross-Boundary Review And Final Release Decision

**Files:**
- Review: all changes on `audit/v2-final-release` versus `main`
- Update: `.Codex/release-v2/findings.json`
- Update: `.Codex/release-v2/verification.md`
- Modify only when required by a reproduced final finding

**Produces:** Independent evidence that the remediated system works as a whole and a binary release/no-release decision.

- [ ] Dispatch an adversarial Ruby-gem reviewer with the final diff, package artifact, surface inventory, coverage reports, and known-finding ledger. Cap the run at 60 minutes.
- [ ] Dispatch focused reviewers for MCP protocol/transport, Rails extraction, persistence/concurrency, security, and documentation. Give each disjoint scope and require file/line evidence and reproducers.
- [ ] Have the lead validate interactions the scoped reviewers cannot own: extraction publication to IndexReader, Builder/resolved config to serving, MCP Tasks to pipeline locks, Console transport to safety layers, and package contents to docs/release workflow.
- [ ] Re-run every P0/P1 reproducer after fixes. Reject tests that only assert mocks, static source strings, or successful exit without validating output.
- [ ] Run the full matrix from a clean checkout and install the final built artifact in clean Ruby floor/latest environments. Record exact totals, pending allowlist, coverage, artifact SHA-256, and CI URL.
- [ ] Scan tracked files, package contents, PR text, and release notes for private names, credentials, generated attribution, stale versions/dates, and unsupported claims.
- [ ] Verify version `2.0.0`, changelog date `2026-08-19`, tag `v2.0.0`, artifact metadata, and release notes agree. Confirm the tag does not yet exist and the version is not already published.
- [ ] Mark release accepted only when P0/P1 counts are zero, all acceptance gates below pass, and the worktree contains no unexplained tracked or generated changes.

## Release Acceptance Gates

- All 21 current CI jobs pass for the final SHA, plus packaged-gem, Inspector/client, documentation, branch-coverage, and release-workflow validation jobs added by this plan.
- Every one of the five executables starts from the installed gem and has tested success, invalid-input, missing-dependency/configuration, and shutdown behavior.
- Every documented rake task loads and either completes against its fixture/dummy environment or exits nonzero with a stable actionable error.
- All 34 extractor registrations, 29 possible Index tools, 31 Console schemas, Tasks methods, resources/templates, presets, providers, stores, exporters, and public configuration attributes appear in the generated inventory and have contract coverage.
- Advertised Console tools are executable in the advertised mode; no stub/static response is presented as live data.
- Task cancellation either stops work and prevents publication or is not advertised as cancellation.
- Overall tracked line coverage is at least 90%; no production file is 0%; per-file and critical branch floors in Task 8 pass.
- Retrieval evaluation meets the checked-in v2 baseline with no unexplained quality regression and reports actual query/output metrics.
- Every current documentation claim is traceable to code or an executable validation; all links, anchors, snippets, package-visible references, support tables, and upgrade steps pass automated checks.
- The release workflow validates the exact tag SHA, builds one strict artifact, tests it, records its checksum, and publishes that artifact only after full CI.
- P0 and P1 finding counts are zero. Any deferred P2 has an issue, owner, accurate public documentation, and no conflict with release claims.

## Execution Strategy

Use **audit-first waves** on one release branch. In each wave, parallel read-only reviewers produce evidence first; one worker then owns each disjoint fix set; the lead reviews shared boundaries and runs the integrated gate. This is slower than immediately editing in parallel, but it prevents overlapping fixes from hiding contract failures and keeps the release decision evidence-based.

Suggested waves:

1. Tasks 1-5: release blockers and public contracts.
2. Tasks 6-8: full subsystem, compatibility, and coverage sweep.
3. Task 9: complete documentation rebuild after behavior is settled.
4. Task 10: adversarial review, clean artifact validation, and release decision.
