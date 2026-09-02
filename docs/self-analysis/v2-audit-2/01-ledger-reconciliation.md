# 01. Ledger reconciliation

Every row of the prior audit's disposition ledger (`v2-prerelease-audit/12-remediation-plan.md`), verified against `c31683c..79c156d`.

Method per row: find the closing commit, read the fix diff and HEAD code, read the regression spec, judge whether the spec would catch a regression, then attack the fix's neighbouring shapes.

## Verdict summary

| Verdict | Count | Rows |
|---|---|---|
| closed-verified | 58 | everything not listed below |
| closed-weak | 1 | M2 |
| still-open, untracked | 4 | G-3, L9, L10, L11 |
| deferred-with-reason | 11 | P3, P7, P9b, L3, L7, L12, L13, L14, L15, L21, Inspector/B-117 |
| superseded by a stronger fix | 2 | L5 (G-1 collision abort), L19 (B-136 flock pins) |

Notes on the deferred set: P3, P7, P9b and B-117 have substantive backlog entries (B-132, B-129, B-131, B-117). **The seven deferred lows have reasons only in the out-of-repo audit ledger** (R2-2, low).

## High and G rows

| ID | Closing commits | Regression spec | Verdict | Notes |
|---|---|---|---|---|
| H1 | 3a36063, 5d8678d (#247); 31b2873 (#257) | spec/mcp/index_reader_encoding_spec.rb | closed-verified [executed] | Spec forces US-ASCII default external; fails without the fix. Family residuals found elsewhere: R1-1, INF-3, EXP-7, R2-3. |
| H2 | d79e56d, a216259, 0c0c8b0, 12dba3d, 44a6acc, 99c3393, 3f6e846 (#248/#268); wiring 48633b5, 4f4717e (#265) | embedded_executor_query_spec, contract_matrix_runtime_spec:883-1023 | closed-verified [executed] | 44 neighbouring shapes probed and held. New neighbour found: CON-1 (alias onto a protected header, not of a protected column). |
| H3 | a7c1178 (#250) | n/a | closed-verified | BACKEND_MATRIX.md:232 now 512. |
| G-1 | 48b4489 + 8 commits (#251), e448803 (#256) | source_nesting_spec #governed_class_name, extractor_spec:1972, booted-lane fixtures | closed-verified [executed offline] | 19 + 22 shapes probed. Residuals: EXTA-1 (trailing comments), EXTA-7 (zeitwerk < 2.6.4). Booted lane not executed here. |
| G-2 | b0ccdb8 (#256) | index_validator_spec:106-165 | closed-verified | Type-dir allowlist from `Extractor::EXTRACTORS`; flow family validated separately. |
| G-3 | **none** | none | **still-open** | railtie_support.rb:105 byte-identical to the audited text. No backlog entry, no CHANGELOG line. See R1-4. |
| G-4 | e9273b0, 99648b2, 1e98b10 (#253) | update_check_spec:147-190 | closed-verified | Ahead/equal/offline/prerelease all pinned. |

## M and O rows

| ID | Closing commits | Regression spec | Verdict | Notes |
|---|---|---|---|---|
| M1 | be427d2, e448803 (#256) | incremental_equivalence_spec:440-536 (:booted_app) | closed-verified [traced] | Re-add gated on loader-claimed constant. Neighbouring shapes held. Lane not executed here. |
| M2 | 1aceed6 (#256) | controller_extractor_spec:313, 329 | **closed-weak** [executed] | The fluent-chained style named in the original finding still returns empty (R1-2 = EXTA-5). |
| M3 | 2d6a77b, 7b35434, 675dbbc (#256) | flow_incremental_spec (15 ex) | closed-verified | All three defects plus four fail-closed abort paths pinned. |
| M4 | 0884838, 137f19d (#248) | sql_validator_spec:187, 700 | closed-verified [executed] | Every `AS (...)` body walked; WITH-attached top-level DML also closed. |
| M5 | 0884838, c330729, 9f6420f (#248) | sql_validator_spec:273-652 | closed-verified [executed] | Dialect-aware, comment-split forms rejected. But see CON-2: the handler-stage union validator makes the dialect awareness dead on the real transport. |
| M6 | cda4ca9 (#257) | bootstrapper_spec:459-491 | closed-verified | Boot state from store health; typed degraded_index. |
| M7 | 07bbc43 (#259), reworked 5e4e195, 3115166 (#264) | reload_swap_spec (22 ex) | closed-verified | Build-then-swap under the writer lock. New neighbours: MCP-1, MCP-2. |
| M8 | 151c83d (#257) | retriever_spec:762-769 | closed-verified | For the three wrapped sites. The pipeline's main store reads are still unwrapped: MCP-6. |
| M9 | a139569 (#257) | config_resolver_spec:405+ | closed-verified | Whitespace-only key on the woods.json path is a low residual (R1-5). |
| M10 | 19b5e92 (#252) | vector_spec:386+ | closed-verified [executed] | The old bug-pinning spec is gone. A stale tolerance block remains (STO-12b). |
| M11 | 98a5d47 (#252) | fsync assertions in three writer specs | closed-verified [traced] | Crash-consistency itself is unprovable in-process; the fsync calls are pinned. |
| O1 | a5f8a55 (#252) | atomic_file_spec:49-61, status_spec:21 | closed-verified [executed] | 0600 default pinned; watch_status 0644 by design. |
| O2 | 3f28dd2 (#252) | metadata_store_spec:339-370 | closed-verified | busy_timeout 5000 + bounded retry. |

## P rows (performance)

| ID | Disposition | Verdict | Notes |
|---|---|---|---|
| P1 | 0d5800b | closed-verified [executed] | Cache lifetime = one run on every entry point including the daemon. Byte-identity pinned. |
| P2 | d2edf1d | closed-verified | Same lifetime argument. |
| P3 | deferred → B-132 (open) | deferred-with-reason | Substantive backlog entry. |
| P4 | 0c89bab + 89d1b50 | closed-verified [executed] | Lua migration is single-key atomic; eviction math exact. Residuals: R2-5 (read-path WRONGTYPE), INF-13 (CHANGELOG overstates ordering). |
| P5 | 9e30003, 1232f3e, ae9abd2 | closed-verified on Ruby >= 3.2 | No bound exists on the 3.0/3.1 floor (R2-4). The guard spec itself fails under a C locale (R2-3). |
| P6 | d931b10 + bd02606 | closed-verified [executed] | Deep-freeze holds; consumers read-only. |
| P7 | deferred → B-129 (open) | deferred-with-reason | |
| P8 | 0087b7d + e6b5f08 | closed-verified [executed] | Tie/protect exact. Corrupt files invisible to retention (R2-6, low). |
| P9a | e6832c1 | closed-verified | |
| P9b | deferred → B-131 (open) | deferred-with-reason | |
| P9c | 3d57d95 | closed-verified [executed] | Alternation equivalence holds. |
| P9d | 3076a8c | closed-verified | |
| P9e | 1b3a679 (PR-5) | closed-verified | Last bare artifact read removed. New non-IndexReader bare reads found: see 04 (encoding family). |

## L rows

| ID | Verdict | Notes |
|---|---|---|
| L1 | closed-verified (73c0565) | Guarded like the ModelNameCache twin. |
| L2 | closed-verified (85abe6f) | Positional if-children. `unless` neighbour was never probed: EXTB-4. |
| L3 | deferred-with-reason (record weak) | No backlog entry (R2-2). |
| L4 | closed-verified (be427d2) | Comment rewritten. |
| L5 | superseded | G-1's fail-closed collision is stronger than the deferral promised. B-063 resolved. |
| L6 | closed-verified (3fe6bf8) | handoff flag + ensure. New sibling leak one layer up: MCP-3. |
| L7 | deferred-with-reason (record weak) | Code unchanged, spec-pinned deliberate. |
| L8 | closed-verified (8a5d4d7) | :trace before :locate. |
| L9, L10, L11 | **still-open** | PR-2b never landed. dispatch_pipeline.rb:57-67, exe/woods-console:94, embedded_executor.rb:122-130 all unchanged. |
| L12, L13, L14, L15 | deferred-with-reason (record weak) | Reasons only in the audit folder. |
| L16 | closed-verified (34843d2) | finish-then-nil, shared helper. |
| L17 | closed-verified (21611a5) | Pin deliberately flipped. |
| L18 | closed-verified (9a9d0de) | Typed error before I/O, both adapters. |
| L19 | superseded | Fixed outright as B-136 (#270): cross-process flock pins. Stronger than the recorded deferral. |
| L20 | closed-verified (768338e) | Both stores exclude the captured SHA. |
| L21 | deferred-with-reason (record weak) | Blocked on tokenizers gem. |
| L22 | closed-verified (16b19c4) | `type: ''` neighbour still accepted (STO-9, low). |

## D rows and coverage items

All eleven D rows: **closed-verified** against HEAD code (a7c1178, e136dff, 387788e, 6fc8154). Spot-checked line by line.

| Coverage item | Verdict | Evidence |
|---|---|---|
| Watch.build / containerized? | closed-verified [executed] | spec/watch/watcher_spec.rb, green. |
| Redis live | closed-verified [traced] | redis service + both live specs wired in ci.yml live-backends. Lane not executable here. |
| Packaged-gem CI | closed-verified | `package-smoke` job runs on every PR (ci.yml:322-335). |
| Perf workflow | closed-verified | .github/workflows/perf.yml: dispatch + nightly cron. |
| InputContract | closed-verified [executed] | input_contract_spec, green. |
| AstSourceExtraction | closed-verified [executed] | Direct mixin spec. |
| Migrations 001-003/006 | closed-verified [executed] | Column-level asserts. But the 006 fixture pins a state no legacy DB had: STO-1. |
| Notion truncation | closed-verified [executed] | BMP shape only; the non-BMP boundary is still open: EXP-2. |
| Encoding tests | closed-verified [executed] | index_reader_encoding_spec. |
| Inspector | deferred → B-117 (ready) | Pendings still visible, not silenced. |

## Second-generation tail (PRs #264, #267, #270)

All eleven rows closed-verified. Executed where probes were possible.

| ID | Closing | Spec | Verdict |
|---|---|---|---|
| tail-M1 (git range exit 0) | d6eb88d, 54dd987 (#267) | woods_rake_incremental_git_diff_spec | closed-verified |
| tail-M2 (reload store divergence) | cd0cdd7 (#264) | reload_swap_spec:165-228 | closed-verified |
| tail-M3 (vectors.idx truncation) | ee43091 (#264) | vector_spec:720-780 | closed-verified [executed] |
| tail-M4 (SUMMARY totals) | b6f8930 (#267) | incremental_equivalence + extractor_spec | closed-verified |
| tail-M8 (wholesale phantoms) | 0023d58, c614c35, 0f63229 (#267) | extractor_spec:1013-1210 | closed-verified |
| B-133 | 3120597 (#270) | metadata_store_spec | closed-verified [executed] |
| B-134 | 3120597 | snapshotter + index_artifact specs | closed-verified [executed] |
| B-135 | 3120597 | json_snapshot_store_spec | closed-verified [executed] |
| B-136 | 3120597 | publication_atomicity_spec:258 | closed-verified |
| B-137 | 3120597 | woods_rake_publication_spec | closed-verified |
| B-138 | 3120597 | woods_rake_watch_status_spec | closed-verified |

## The one broken completeness claim

**R1-4 (medium): the ledger's go/no-go criterion 1 is false at HEAD.** Four rows (G-3, L9, L10, L11) were assigned to PR-2b (`fix/console-reliability`). That PR does not exist in `c31683c..HEAD`. No backlog entry records a deferral. Fix: land PR-2b as planned, or record four backlog entries, before tagging.
