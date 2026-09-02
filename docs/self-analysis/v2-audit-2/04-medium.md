# 04. Medium findings

31 findings, grouped by layer. 22 executed, 9 traced. Every executed finding was re-run by the synthesizing session.

Reading key: each finding gives mechanism, evidence, spec coverage, fix shape (failing spec first), and dedupe status.

---

## Incremental extraction and the extraction core

### CORE-1. `prune_path_leftovers` skips by bare identifier; a stale sibling-type unit survives forever

- **Evidence**: [executed] (probe spec red as predicted). **Spec coverage**: none for the shape.
- **Files**: `lib/woods/extractor.rb:2244` (`produced` accumulates identifiers only), `:2313` (`next if produced.include?(identifier)`). Colliding producers: `policy_extractor.rb:53-67` and `pundit_extractor.rb:50-70`, both claiming `app/policies`.
- **Mechanism**: this is the #225 bug (prune by identifier instead of (identifier, type)) reproduced one method over. Edit a policy file so it stops matching the Pundit shape: the `:policy` unit is re-produced, the `:pundit_policy` unit is not, and the identifier-level skip protects both graph nodes. The stale `:pundit_policy` node and its JSON survive every incremental run. A full extraction produces neither. Permanent full/incremental divergence until the next full run's orphan sweep.
- **Fix shape**: failing spec in `extractor_spec.rb` seeding both typed nodes on one path, asserting `node_types('PostPolicy') == [:policy]` after reconciling. Code: track `produced` as (identifier, type) pairs; the removal call is already typed.
- **Dedupe**: reconciliation issue against the #225 CHANGELOG claim. Not in the backlog.

### EXTA-1. Trailing `#` comments corrupt SourceNesting depth tracking; a comment can change identifiers or abort extraction

- **Evidence**: [executed] end-to-end through a real ServiceExtractor, re-verified. **Spec coverage**: whole-line comments only.
- **Files**: `lib/woods/extractors/source_nesting.rb:173-177` (`block_opener?`), `:522-529` (only whole-line comments stripped), `:191-207`.
- **Mechanism**: two failure modes. (1) `module Api # TODO: rename at the end` fails `block_opener?` (the lookbehind fires on the comment's "end"), so the wrapper is never pushed: `app/services/api/payment_service.rb` extracts as bare `PaymentService` while its sibling gets `Api::RefundService`. Governed naming declines (no declaration matches), so the fallback is the broken parse. If any other file defines top-level `PaymentService`, the G-1 collision guard **aborts the whole extraction** over a comment. (2) `x = compute # do not memoize` pushes a phantom frame; a later top-level class inherits a stale wrapper prefix.
- **Fix shape**: failing specs for both shapes in `source_nesting_spec.rb`; strip trailing comments in `each_significant_line` using the quote-aware walker that already exists in `SharedDependencyScanner#strip_line_comment` (`shared_dependency_scanner.rb:103-128`).
- **Dedupe**: neighbouring-shape gap of the G-1/#174 fixes; new.

### EXTA-2. Dependency scanners record demodulized targets, so namespaced service/job/mailer edges dangle after G-1

- **Evidence**: [executed] mechanism, re-verified; [traced] impact. **Spec coverage**: none.
- **Files**: `lib/woods/extractors/shared_dependency_scanner.rb:161, 172, 183` (`(\w+Service)`, `(\w+Job)`, `(\w+Mailer)`: `\w` cannot cross `::`), `job_extractor.rb:364`, `callback_analyzer.rb:46, 194, 204`; impact at `dependency_graph.rb:70-73` (reverse index is exact-string keyed) and `:279-300` (`affected_by`).
- **Mechanism**: `Billing::ChargeService.call` yields `target: 'ChargeService'`. Since G-1, the unit's identifier is `Billing::ChargeService`, so the edge matches no node. `dependents` stays empty, PageRank sees the unit as unreferenced, and the incremental blast radius misses callers: editing the service does not re-extract the model that calls it by FQN. Models are immune (ModelNameCache handles FQNs); services, jobs, and mailers have no equivalent.
- **Fix shape**: failing scanner specs (`scan_service_dependencies('Billing::ChargeService.call')` includes the FQN); widen captures to `((?:\w+::)*\w+Service)` in all five sites.
- **Dedupe**: pre-existing capture behavior turned systematic by the G-1 identifier change. Not tracked anywhere.

### EXTA-3. Runtime-discovered jobs with unresolvable source get a fabricated convention path; the incremental sweep deletes them

- **Evidence**: [traced], key gates re-verified at HEAD. **Spec coverage**: none.
- **Files**: `job_extractor.rb:54-66` (class-based discovery pass), `:158-163` (`source_file_for` falls back to a convention path, never nil), `extractor.rb:2810-2812` (`convention_path_unit?` = `CLASS_BASED.key?(type)`; `CLASS_BASED` at `:191-195` has no `:job`), `:262+` (`CLASS_BASED_DISCOVERY` has no jobs entry).
- **Mechanism**: a gem-defined or dynamically defined `ApplicationJob` descendant gets `app/jobs/<name>.rb` as its registered path even though no such file exists. The sweep finds a registered, rule-claimed, nonexistent path and prunes the unit on the first incremental run. Nothing reconciles it back. This is the B-070/#171 GraphQL shape reproduced for jobs; GraphQL was fixed by returning nil.
- **Fix shape**: failing spec mirroring the GraphQL nil-path tests (unit with nonexistent file_path survives `prune_vanished_units` with an empty change set). Code: the class-discovery path of `source_file_for` returns nil when the convention fallback does not exist.
- **Dedupe**: mechanism documented as fixed for GraphQL; the jobs instance is unreported.

### EXTA-4. Job-enqueue edges missed for `*Worker` classes and `.set(...).perform_later` chains; three scanners disagree

- **Evidence**: [executed], re-verified. **Spec coverage**: Job-suffix cases only.
- **Files**: `shared_dependency_scanner.rb:171-175` (no Worker, no set), `job_extractor.rb:364` (set, no Worker), `callback_analyzer.rb:35, 46` (Worker, no set; adjacency-only so multiline chains miss).
- **Mechanism**: on a classic Sidekiq host, `HardWorker.perform_async` produces no edge from any model/controller/service scanner. `SyncJob.set(wait: 5).perform_later` produces none either. Worker units exist with no inbound edges: "what triggers this job" answers nothing.
- **Fix shape**: failing specs per scanner; unify on one shared pattern `(\w+(?:Job|Worker))\.(?:perform_later|perform_async|perform_in|perform_at|set\b)`.
- **Dedupe**: new.

### EXTA-5 (= R1-2). The fluent `require(...)\n.permit(...)` chain still yields empty permitted_params; M2's own finding named it

- **Evidence**: [executed], re-verified. **Spec coverage**: multi-line argument lists only.
- **Files**: `controller_extractor.rb:582` (no `\s*` between `require(...)` and `.permit`).
- **Mechanism**: the M2 fix made the argument list multi-line-capable; the call chain still must sit on one line. `params.require(:post)\n  .permit(:title, :body)`: the RuboCop-endorsed style in wide controllers, exactly the M2 population: returns `{}`. The CHANGELOG claim "multi-line strong params declarations are captured" over-reads.
- **Fix shape**: failing fluent-fixture spec; change the joint to `\)\s*\.\s*permit\(` (and the `expect` twin).
- **Dedupe**: downgrades M2 to closed-weak. Second half of the original finding.

### EXTA-6. CallbackAnalyzer misses `self.col ||=` and `self.col +=`, the most idiomatic callback writes

- **Evidence**: [executed], re-verified. **Spec coverage**: plain `=` only.
- **Files**: `callback_analyzer.rb:154` (`self\.(\w+)\s*=(?!=)`: `||=`/`+=`/`-=`/`&&=` all fail), `:32, 42-44` (`update`/`update!` absent; parens required).
- **Mechanism**: `self.token ||= SecureRandom.uuid` in a `before_create` reports `columns_written: []`. The behavioral-depth headline ("columns written") is silently wrong for the most common callback body in Rails apps.
- **Fix shape**: failing C1/C2 specs; widen to `self\.(\w+)\s*(?:\|\||&&|[+\-*\/])?=(?!=|~)`.
- **Dedupe**: new. String/comment false positives are the Low sibling (EXTA-8).

### EXTB-1. RakeTaskExtractor counts keywords inside comments, strings, and heredocs; identifiers and bodies corrupt

- **Evidence**: [executed] (probe spec pins the wrong output). **Spec coverage**: none for the shapes.
- **Files**: `rake_task_extractor.rb:338-342` (`block_opener?` with no neutralization), `:177-188`, `:305-330`.
- **Mechanism**: `# do not touch production` inside a task body inflates depth: the namespace stack stops popping and later tasks index under wrong identifiers (`cleanup:other:third` for `other:third`); the preceding task swallows the next task's body. A heredoc line starting with `end` truncates the body, and dependencies after it vanish. Stable across full and incremental runs: silently wrong, not divergent.
- **Fix shape**: failing specs (probe file shapes); skip comment lines and neutralize strings/heredocs before keyword checks, sharing EXTB-2's helper.
- **Dedupe**: neighbouring shape of #176; new.

### EXTB-2. FactoryExtractor drops a factory whose attribute strings contain two block-keyword words

- **Evidence**: [executed] (probe spec). **Spec coverage**: none.
- **Files**: `factory_extractor.rb:230-237, 131-134, 147-149`.
- **Mechanism**: `title { "things to do" }` matches `\bdo\b` and inflates depth. One such line self-heals; two (`"things to do"` + `"walk for a while"`) leave the factory unpopped at EOF and it is dropped entirely: zero units from a well-formed file. Lost `:factory_for` edges follow.
- **Fix shape**: failing spec asserting the `checklist` unit exists; strip inline `{...}` blocks and string literals before `block_opener?`.
- **Dedupe**: same family as EXTB-1 and STO-3 (chunker `=begin`); three copies of one heuristic, each broken differently.

### EXTB-3. EventExtractor misses Wisper's canonical paren form `broadcast(:event, ...)`

- **Evidence**: [executed] (probe spec). **Spec coverage**: space form only.
- **Files**: `event_extractor.rb:104-108` (`\b(?:publish|broadcast)\s+:` requires whitespace).
- **Mechanism**: `broadcast(:order_created, order)`: the Wisper README form: registers no publisher. With no subscriber naming the event, no event unit exists at all. The subscriber regex accepts parens; only the publish form does not.
- **Fix shape**: failing spec; `\s*\(?\s*:` in the pattern.
- **Dedupe**: new.

---

## AST, flow, graph

### EXTB-4. `unless` converts to `:if` with unswapped branches; every flow document inverts its semantics

- **Evidence**: [executed], re-verified. **Spec coverage**: none (the L2 fix pinned `if nil` only).
- **Files**: `ast/parser.rb:105` (IfNode and UnlessNode share `convert_prism_if`), `:327-350`; consumed at `flow_analysis/operation_extractor.rb:131-150`; rendered at `flow_document.rb:150-158`.
- **Mechanism**: `Prism::UnlessNode#statements` runs when the predicate is false, but the converter puts it in the then-slot with the raw predicate. Re-verified: `unless admin? … AuditService.log … else … PaymentService.charge` renders `condition: "admin?", then_ops: [AuditService.log]`: precisely inverted. Every flow artifact (woods:flow, precomputed flows, MCP flow tools) states the opposite of the code for every `unless`, including the modifier form. An agent-facing correctness lie.
- **Fix shape**: failing spec in `operation_extractor_spec.rb`; swap slots for UnlessNode (or emit `kind: 'unless'` and teach the renderer).
- **Dedupe**: the untested neighbour of L2. New.

### EXTB-5. Prism call arguments never become child nodes; `private def` methods are invisible to the whole AST layer

- **Evidence**: [executed], re-verified (`find_all(:def)` returns only the unwrapped method). **Spec coverage**: none on the AST side.
- **Files**: `ast/parser.rb:269-312` (`convert_prism_call`: args flattened to text, children = receiver only).
- **Mechanism**: `private def hidden; Secret.reveal; end` parses as a CallNode whose argument is the DefNode; the argument is stringified. Consequences: MethodAnalyzer emits no `ruby_method` unit for any `private def`-style method; `extract_method_source` returns nil; call sites inside any call argument (`foo(Bar.baz)`) are lost. The CHANGELOG's "`private def` no longer reported public" fix lives only in the regex path; the AST path loses the method entirely.
- **Fix shape**: failing parser spec; convert argument nodes into children alongside the receiver, keeping the text field.
- **Dedupe**: new. EXTB-16 (block receiver chains) is the same class, Low.

### EXTB-6. `MermaidRenderer#render_dependency_map` drops every edge of a current-format graph; the committed artifact proves it

- **Evidence**: [executed] (committed `docs/self-analysis/dependency-map.md` has 0 `-->` lines across ~2,400 nodes; re-verified). **Spec coverage**: pins the bug (legacy bare-string edges).
- **Files**: `ruby_analyzer/mermaid_renderer.rb:93-103`; caller `lib/tasks/woods.rake:861-877`.
- **Mechanism**: edges are `[{target:, via:}]` hashes since the via migration; the renderer checks `nodes.key?(target)` where target is a Hash: always false. Both `woods:self_analyze` outputs render node-only diagrams: a dependency map with no dependencies.
- **Fix shape**: failing spec feeding a real `DependencyGraph#to_h`; normalize via `DependencyGraph.normalize_edges`. Regenerate `docs/self-analysis/`.
- **Dedupe**: new; the pinning spec must flip.

### EXTB-7. `domain_clusters` is still registration-order dependent despite the #216/B-103 determinism claim

- **Evidence**: [executed], re-verified with a corrected probe (the agent's committed probe had a mis-written order swap; the mechanism reproduces). **Spec coverage**: the rotation spec exists but its fixture cannot see this path.
- **Files**: `graph_analyzer.rb:276-288` (`assign_orphaned_units` iterates `filtered_ids` in registration order, mutating `member_set` between scores).
- **Mechanism**: `Standalone1 -> Standalone2 -> Billing::Invoice`. Processing S2 first assigns it to Billing, then S1 joins through it: members `[Billing::Invoice, Standalone1, Standalone2]`. Processing S1 first leaves S1 unassigned. Full and incremental runs register in different orders, so the MCP `domain_clusters` tool answers differently for identical trees.
- **Fix shape**: add the chained-unnamespaced shape to the rotation fixture (fails today); iterate to a fixed point against a per-round membership snapshot.
- **Dedupe**: reconciliation issue against the #216 CHANGELOG claim.

---

## Index MCP and retrieval

### MCP-1. `reload` fails degraded, and sticks a `reload_failure` into woods_status, on any retriever-wired server that never ran `woods:embed`

- **Evidence**: [executed], re-verified. **Spec coverage**: neighbouring case only (present-but-empty dump).
- **Files**: `mcp/bootstrapper.rb:254, 413-425`; `storage/snapshotter/vector.rb:68-90`; `mcp/server.rb:751-789`.
- **Mechanism**: the ordinary host shape: `OPENAI_API_KEY` exported, extraction run, embed never run: boots `:hydrated` with empty in-memory stores (`load_or_empty`). `reload` uses `load_dump_dir(required: true)` against a nil captured dump and aborts. The agent gets "Reload failed; nothing was swapped", and `woods_status` carries `bootstrap.reload_failure` until a successful reload, which is impossible until an embed runs. Boot and reload disagree about whether "no dump yet" is an error.
- **Fix shape**: failing reload_swap spec ("no promoted dump reloads as zero-count success"); nil captured dump takes the boot-path `load_or_empty` semantics.
- **Dedupe**: post-M7 regression surface; new.

### MCP-2. `reload` answers `reloaded: true` with stale data on flat indexes whenever `reload_stores!` takes a zero-count early return

- **Evidence**: [executed], re-verified (manifest rewritten to 99 on disk; tool answered `reloaded=true total_units=1`). **Spec coverage**: only configurations no packaged executable produces.
- **Files**: `bootstrapper.rb:239-246, 272` (early returns never call `reader.reload!`); `server.rb:751-810` (the reloader branch never falls back to `with_exclusive_reload`); `exe/woods-mcp:50-52`, `exe/woods-mcp-http:69-71` (both always wire a reloader); `index_reader.rb:97-100` (flat index never self-refreshes).
- **Mechanism**: on a flat (pre-2.0) index the reader's only freshness path is `reload`. A pattern-only boot (the #138 extract-only host, the shape most likely to still run flat output) hits the `unless retriever` early return, touches nothing, and reports success with the retired index.
- **Fix shape**: failing server spec with `retriever_reloader:` wired and `retriever: nil` against the flat fixture; every early return still runs `reader&.reload!`.
- **Dedupe**: contradicts the CHANGELOG reload description ("refreshes the JSON index AND re-hydrates the retriever"). New.

### MCP-3. A raising `PipelineLock#acquire` permanently wedges `pipeline_extract`/`pipeline_embed`

- **Evidence**: [executed], re-verified. **Spec coverage**: `acquire == false` contention only; L6 covered one layer lower.
- **Files**: `mcp/server.rb:1143, 1163-1174, 1221-1229` (nothing rescues between `pipeline_start` and the background hand-off), `coordination/pipeline_lock.rb:63-84` (acquire rescues only EEXIST; EACCES/EROFS propagate).
- **Mechanism**: a read-only index dir (the documented Docker mount) makes `acquire` raise. The first call answers `corrupt_artifact` (a misdiagnosis), leaks `@pipeline_in_flight`, and every later call answers `already_running` until process restart.
- **Fix shape**: failing spec (acquire raises EACCES; second call is not already_running); wrap the region with rescue SystemCallError → typed error, `ensure pipeline_finish unless handed_off`.
- **Dedupe**: sibling of L6, distinct site. New.

### MCP-4. After a host reboot, an orphaned pipeline task reports `working` forever

- **Evidence**: [executed], re-verified. **Spec coverage**: pins the bug (`store_spec.rb:364-374`).
- **Files**: `mcp/tasks/store.rb:318-345` (`foreign_producer?` classifies any boot-id mismatch as alive), `:291-298` (only terminal records expire), `:445-472` (sweep removes only expired/corrupt).
- **Mechanism**: reboot-after-crash mid-`pipeline_extract` is the headline crash-resilience scenario. The boot-id mismatch reads as "foreign producer, leave alone", the record never expires, and the client polls `working` forever. The conservatism protects NFS-shared stores; nothing distinguishes the reboot case and no age backstop exists.
- **Fix shape**: failing spec ("foreign-boot working record older than a bounded window resolves to failed"); treat foreign producers as alive only while the record is younger than a generous window (e.g. 24h from `updated_at`).
- **Dedupe**: behavior-as-documented in CLAUDE.md, but the documentation and the crash-resilience claim contradict each other.

### MCP-5. Stateless `woods-mcp-http` can serve a retired generation indefinitely under sustained overlapping requests

- **Evidence**: [executed], re-verified (40 pinned reads over 2s of overlap all served the old generation; the new one surfaced only after traffic stopped). **Spec coverage**: the two-pin case is pinned as intended behavior.
- **Files**: `index_reader.rb:161-181` (refresh only at pin depth 0→1), `:757-768`; `exe/woods-mcp-http:77-91`; CLAUDE.md ("ensure_fresh! is the correctness path for freshness").
- **Mechanism**: every tool handler pins. On a threaded Rack server with continuous overlap, pin depth never reaches 0 and staleness is unbounded and silent. The multi-agent shared-index deployment stateless mode was built for is exactly the sustained-overlap shape.
- **Fix shape**: failing freshness spec (bounded number of pins after a republish must observe the new generation); when a 0→1 refresh cannot run but the signature moved, set a pending-refresh flag that gates new pins the way `@exclusive_waiters` does.
- **Dedupe**: distinct from B-114 (push); this is the pull path failing its own contract. New.

### MCP-6. M8's typed StoreError misses the pipeline's main store reads

- **Evidence**: [traced], citations re-verified at HEAD. **Spec coverage**: wrapped sites only; the assembler error-path group stubs misses, never raises.
- **Files**: unwrapped: `retrieval/context_assembler.rb:121` (`find_batch`, the primary metadata read of every query), `ranker.rb:280`, `search_executor.rb:154-157, 186, 311-323, 402, 443-449`; wrapped: `retriever.rb:388-393, 564-569, 581-584`; `server.rb:900` rescues StoreError only; `retriever.rb:630-631` still swallows the structural banner to nil.
- **Mechanism**: a store failing inside `find_batch` or any executor call raises raw: the gem wraps it as "Internal error", or ToolContract relabels IO-flavored causes as `corrupt_artifact` (wrong diagnosis for a SQLite file deleted mid-serve). The M8 CHANGELOG claim ("one shared typed store error for every store call site") does not hold for the sites carrying most traffic.
- **Fix shape**: failing retriever specs (find_batch raise → StoreError); translate at the pipeline boundary (wrap executor/ranker/assemble calls in `retriever.rb:311-321`).
- **Dedupe**: reconciliation with the M8 CHANGELOG entry.

---

## Console

### CON-2. `console_sql`'s handler pre-validates with a dialect-blind union validator; the dialect-aware fix is dead on the real transports

- **Evidence**: [executed], re-verified directly (union REJECT vs `:mysql` PASS on the escaped-apostrophe statement). **Spec coverage**: the dialect path is exercised only by bypassing the handler.
- **Files**: `console/tool_specs.rb:670-673` (handler builds `SqlValidator.new`, no dialect), `tools/tier4.rb:48-51` (`console_sql` runs `validator.validate!` first), `dispatch_pipeline.rb:60`, `embedded_executor.rb:746` (the dialect-aware validator, reached only after the handler passes).
- **Mechanism**: on a MySQL host, `WHERE body = 'customer\'s request for update'` is valid MySQL. The union validator's PostgreSQL view ends the literal at `\'`, exposes `for update`, and rejects before the executor's `:mysql` validator can accept. Every MySQL statement whose escape grammar produces a spuriously forbidden PostgreSQL view is falsely rejected. The PR-248 round-2 dialect work is inert on stdio and HTTP alike.
- **Fix shape**: failing booted-style spec driving `handle_json` with a MySQL adapter stub; remove the handler-stage `validate!` for the embedded path (the executor re-validates and alone knows the dialect). No hole opens: the executor already raises `SqlValidationError`.
- **Dedupe**: contradicts the CHANGELOG "validates with the active adapter's dialect" claim. New.

---

## Storage and embedding

### STO-1. A genuine pre-rename `codebase_index` database permanently wedges `Migrator#migrate!`

- **Evidence**: [executed], re-verified. **Spec coverage**: pins the bug (fixture records legacy versions in a table the legacy gem never had).
- **Files**: `db/schema_version.rb:24`, `db/migrations/006_rename_tables.rb:13-27`, `db/migrator.rb:46-53`; callers `extractor.rb:1936`, `mcp/bootstrapper.rb:91`.
- **Mechanism**: the legacy gem recorded versions in `codebase_index_schema_migrations`. Nothing renames that table. Against a real legacy DB, `ensure_table!` creates an empty `woods_schema_migrations`, all six migrations count as pending, 001-005 create fresh empty tables, then 006's `ALTER TABLE codebase_units RENAME TO woods_units` fails: the target exists. Versions 1-5 are now recorded, so every later `migrate!` retries only 006 and fails identically. Permanent wedge from extraction or MCP boot with snapshots enabled; legacy rows stranded.
- **Fix shape**: change the fixture to the real legacy table name (red at HEAD); detect and rename `codebase_index_schema_migrations` before `ensure_table!`.
- **Dedupe**: adjacent to open B-122, distinct. New.

### STO-2. Durable-store reconciliation deletes non-Woods Qdrant points on every embed run

- **Evidence**: [executed] at the Indexer level, re-verified (foreign UUID deleted as vanished); adapter passthrough traced and spec-pinned. **Spec coverage**: reconciliation suite seeds Woods ids only.
- **Files**: `embedding/indexer.rb:349-380, 435-445`; `storage/qdrant.rb:513-520` (each_id yields the raw point id when `woods_identifier` is absent), `:281-286` (canonical UUID passes through `point_id`).
- **Mechanism**: any point another tool wrote in a shared collection can never appear in `@current_identifiers`, so it is always vanished and is deleted whenever the vanished fraction is <= 30%. Silent destruction of another system's vectors, every run, behind a generic warning. The adapter tolerates foreign points on the read side, which invites exactly this sharing.
- **Fix shape**: failing indexer spec (unattributable id survives reconciliation); have `each_id` skip points lacking `IDENTIFIER_KEY`, or skip UUID/integer-shaped ids in `vanished_durable_identifiers`.
- **Dedupe**: #211 did not consider foreign points. New.

---

## Watch daemon and infra

### INF-1. The daemon's polling fallback rebuilds the watcher without its ignore list, re-arming the output-directory feedback loop

- **Evidence**: [traced], re-verified at HEAD (`daemon.rb:696` vs `:1121`). **Spec coverage**: the fallback spec stubs `Watcher.build` and never asserts its arguments.
- **Files**: `watch/daemon.rb:692-698` (fallback: no `ignored:`), `:1120-1153` (primary build passes `ignored: ignored_directories`).
- **Mechanism**: listen failing (inotify exhaustion, the comment's "most likely failure on a large tree") triggers the fallback. A `WOODS_OUTPUT` inside the root but outside the default ignore set (`.woods/`, `woods_index/`) then re-manufactures events every cycle: a daemon that never idles and re-extracts forever: the exact loop `ignored_directories` was built to break.
- **Fix shape**: failing spec asserting `Watcher.build` receives `ignored:`; pass `ignored: ignored_directories` at `daemon.rb:696`.
- **Dedupe**: the two mechanisms were added by different fixes and never intersected. New.

### INF-2. Heartbeat-thread retries run the extraction inline, starving the lock touch and status restamp past the stale window

- **Evidence**: [traced], re-verified at HEAD. **Spec coverage**: retry happy path only.
- **Files**: `watch/daemon.rb:616-658` (heartbeat loop: sleep → restamp → touch → `retry_pending` → `drain` inline), `:115` (LOCK_STALE_TIMEOUT 600), `lib/tasks/woods.rake:80-88` (waiting writers retire stale locks).
- **Mechanism**: carried-forward work retries on the heartbeat thread itself. A retried storm `extract_all` exceeding 600s has its live lock retired by any waiting writer: the two-concurrent-writers clobber the lock exists to prevent. Past 900s the status record ages out too, so `woods:incremental` stops standing down at the same moment. The rake writers solved this with `LockHeartbeat`; the retry path recreates a boundary-less run without it.
- **Fix shape**: failing spec (extraction stubbed to block; assert `lock.touch` arrives mid-flight); run the retry drain under `LockHeartbeat` or on its own thread.
- **Dedupe**: residual of the #169/#170 family; unclaimed. New.

### INF-3 (+ R1-1, encoding family). Two more Woods JSONL readers break under LANG=C: the feedback store and the session-tracer FileStore

- **Evidence**: [executed], both re-verified under a C locale. **Spec coverage**: none (both spec files are ASCII-only, so the suite's own US-ASCII canary never fires).
- **Files**: `feedback/store.rb:71` (`File.foreach`, bare), `:75`; consumers `mcp/server.rb:1663-1684` (`retrieval_explain`, `retrieval_suggest`, GapDetector). `session_tracer/file_store.rb:54, 74, 99, 155` (`File.readlines`, bare); consumer `mcp/server.rb:1039` (`session_trace`).
- **Mechanism**: writes land as raw UTF-8 bytes; reads tag with the process default external. Under the C locale: the exact deployment H1 named: the first entry with an em dash or accent makes `all_entries`, `average_score`, `read`, and `sessions` raise `Encoding::CompatibilityError`. The feedback MCP tools and the `session_trace` tool go down permanently: the poison line stays in the file while writes keep succeeding. Both violate the CLAUDE.md AtomicFile.read contract. Low siblings in the same family: `evaluation/query_set.rb:70` (EXP-7) and the P5 guard spec (R2-3).
- **Fix shape**: failing specs recording non-ASCII content and reading under a forced US-ASCII default external (the `index_reader_encoding_spec` pattern); read with explicit UTF-8, keeping the per-line ParserError skip.
- **Dedupe**: the H1/B-077/P9e sweeps each fixed their own layer and missed these. Reconciliation gap against "every Woods-written JSON artifact is read through AtomicFile.read".

### INF-4 (+ EXP-4). `woods:embed`, `woods:embed_incremental`, and `woods:notion_sync` print per-unit errors and exit 0

- **Evidence**: [traced], re-verified at HEAD (no exit in either block). **Spec coverage**: none for these exit codes.
- **Files**: `lib/tasks/woods.rake:749-783` (embed pair), `:986-995` (notion, no exit); contrast `:1054-1073` (unblocked exits 1, with the stated rationale) and `:1116-1121` (obsidian exits 1); `lib/woods/tasks.rb:127-134` (`print_embed_stats` never exits).
- **Mechanism**: a revoked API key failing mid-run, a full vector store, or a Notion 401 on every page prints `Errors: N` and exits 0. In the CI/cron deployments these tasks target, the pipeline stays green while the index or the Notion database rots. The exit-code contract is inconsistent across sibling tasks with identical CI exposure; #270 fixed the same posture for the extraction family.
- **Fix shape**: subprocess rake specs in the `woods_rake_publication_spec` style asserting non-zero exit; `exit 1 if stats[:errors].positive?` after the print, mirroring unblocked's partial-progress nuance.
- **Dedupe**: continuation of #270; not claimed fixed anywhere.

---

## Exporters

### EXP-1. STI models sharing a table make the Notion Columns sync churn forever

- **Evidence**: [executed], re-verified (warm run: `update_page` +2 where the non-STI twin does +0). **Spec coverage**: the idempotence example checks page sets, not API calls, and uses non-STI fixtures.
- **Files**: `notion/exporter.rb:243-266, 283-302`; `notion/mappers/column_mapper.rb:36-47` (title qualified by table only; `Table` relation per model).
- **Mechanism**: #149 qualified model pages per class but column pages per table. Two STI models emit the same column title (`users.id`) with different Table relations; the manifest is keyed on the title, so the two models overwrite each other's hash every run. The sync can never converge: two PATCHes per shared column per run (a 10-model hierarchy over 30 columns = 600 pointless PATCHes at 3 req/s, forever), reported as "synced". The column's Table relation always points at whichever model synced last.
- **Fix shape**: failing zero-API-calls-on-second-sync spec with STI fixtures; group columns by physical table across models, sync each once with a multi-entry relation.
- **Dedupe**: neighbouring shape of the #149 CHANGELOG claim. New.

### EXP-2. Notion rich_text truncation counts Ruby characters against a 2000 UTF-16-unit limit

- **Evidence**: [executed], re-verified (2500 astral chars truncate to 2000 Ruby chars = 3997 UTF-16 units). **Spec coverage**: pins the char-based shape with pure-ASCII fixtures.
- **Files**: `notion/mappers/shared.rb:14-18`.
- **Mechanism**: Notion's limit is 2000 UTF-16 code units. Text with non-BMP characters (emoji in model header comments are ordinary) passes the char check or truncates to 1997 chars and still ships up to 4000 units. The page 400s on every run: recorded as a per-unit error, never synced, until the source text changes. The prior audit's coverage item was closed with a BMP-only spec, leaving open the exact boundary it warned about.
- **Fix shape**: failing UTF-16-unit assertion in shared_spec; truncate by accumulating `ch.ord >= 0x10000 ? 2 : 1` units.
- **Dedupe**: reconciliation on the coverage close; the API-rejection scenario is unchanged.

### EXP-3. Notion "Last Schema Change" is the extraction timestamp, not the migration timestamp

- **Evidence**: [traced], re-verified at HEAD (`latest_changes` keys on `unit['extracted_at']`; `migration_version` sits unused in the same metadata). **Spec coverage**: pins the bug (fixtures set the two timestamps equal).
- **Files**: `notion/mappers/migration_mapper.rb:20-35`; `extracted_unit.rb:59`; `extractors/migration_extractor.rb:172`; `notion/exporter.rb:339-348`.
- **Mechanism**: a full extraction re-stamps every migration unit with `extracted_at = now`, so the next sync rewrites every table's "Last Schema Change" to the extraction day: which also changes every page's hash, forcing a full-write sync. Under purely incremental extraction the value approximates file-add time by accident, which is why it looked plausible.
- **Fix shape**: failing mapper spec with divergent timestamps; prefer `migration_version` (parse `%Y%m%d%H%M%S`), fall back to `extracted_at`.
- **Dedupe**: new.

---

## Process

### R1-4 (= R2-1). PR-2b never landed; four ledger rows are untracked

- **Evidence**: [traced], re-verified at HEAD (all three files byte-unchanged since c31683c). **Spec coverage**: n/a.
- **Files**: `railtie_support.rb:105` (G-3 warning text), `console/dispatch_pipeline.rb:57-67` (L9), `exe/woods-console:94` (L10), `console/embedded_executor.rb:122-130` (L11).
- **Mechanism**: the remediation shipped PR-2a plus two follow-on security PRs; the reliability half was skipped and nothing recorded the skip. The plan's go/no-go criterion 1 ("every row a merged PR or a backlog ID") reads satisfied when it is not. The four underlying defects keep their original Low ratings.
- **Fix shape**: land PR-2b as specified in the plan (the red specs are already written down), or add four backlog entries with reasons, before tagging 2.0.0.
- **Dedupe**: this is the disposition gap; the defects are prior-audit L9/L10/L11/G-3.
