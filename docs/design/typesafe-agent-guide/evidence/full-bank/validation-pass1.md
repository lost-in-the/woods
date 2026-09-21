# Validation pass 1 — reproduction and scope

Status: FINAL PASS. Reproduction commands, fixture/application boundaries, recorded execution claims, chapter 11, packaged evidence/citations, and the conditional additional mechanism have no remaining blockers.

Authorship overlap: I authored the additional fixture builder, portable original fixture builder/collector, and stale-transfer probe earlier in this task. This is an author review of those components, not an independent second validation of their design. I did not author the question-bank import, comparator runner, metrics, chapter 11, or results report. The execution receipts are separate from the reasoning reviewer’s finding, but this review does not imply a third-party audit.

Read-only scope: `script/typesafe/rails_bank/{README.md,protocol.md,fixtureREADME.md}`, actual builders/runner/collector/reviewer helpers, original and extra fixture receipts, portable reconstruction receipts, frozen full-bank input/capture records, and the final report draft. No source files were edited. This review note is the only written artifact.

## Clarifications resolved by the author

1. `README.md:33–35`: preparation validates captured deep-freshness/clean-revision receipts and serialized source hashes; it does not recheck a current live application worktree. Suggested text: “Preparation validates the captured deep-freshness and clean-revision receipts, plus serialized source hashes.” Builders' collectors do check live state at capture time. This preserves the application/extraction boundary accurately.
2. Results report lead: “maximum-score ordering” should be “maximum-Noul priority ordering”, since actual bank Scores are explicitly excluded from candidate priority.
3. Results report evidence bullet: qualify “one published generation” as “one published generation per candidate packet”, avoiding a single global generation claim across 24 applications.
4. If the final report retains the follow-up delivery comparison, README should expose the separate `reviewers.py prepare --root ... --delivery-audit` and matching `run` command, identify its post-capture status, and keep it separate from the initial six sessions.

## Verified

- The fixture commands use implemented `--testbed-root`, `--woods-root`, `--output`, and `--template` arguments. Image, bundle volume and Docker-prefix overrides exist. Both builders require explicit output; no old personal `/tmp` template is required by their current source.
- `runner.py prepare --root ... --prior ... --extra ...` works with the portable manifest shape: `app_path` supplies the original candidate location needed for schema materialization checks. Its legacy `--prior-apps` fallback is relevant only to older manifests without `app_path`; moved legacy captures need that override. All shown subsequent CLI commands include required `--root`.
- All current Python helper files parse under Python 3.9 grammar; `Path.is_relative_to` is a Python 3.9 API. Actual smoke execution used the available Python 3.14 runtime, not a Python-version test matrix.
- Portable receipts report 8 original plus 16 extra cases with matching private oracles and deep-current indexes. A second original bootstrap from a clean tracked testbed checkout without a lockfile or database verified another 8 cases.
- Seed-data spot checks on the historical pilot base, frozen extra base, portable original/extra bases, and clean-checkout base all show the demo scale: 5 organizations, 600 articles and 25,000 engagement events. Review tables are empty in the available migrated bases before oracles. These counts do not establish byte-identical seed databases. The public fixture README correctly promises mechanism reconstruction with fresh provenance, and says portable bootstrap runs demo seeds.
- The frozen full-bank schedule has 24 case IDs, 144 requests and exactly one shared-state hash per case across both arms/repeats. Every file in `input-freeze.json` still matches its stored digest.
- Captures contain 144 HTTP-200 attempts and one credential lookup. Baseline input/output totals are 431,154 / 13,065; bank totals are 860,424 / 310,506, matching the report table.
- `git diff --name-only 904226c9..HEAD -- lib exe` is empty. The application fixture changes and experiment wrappers do not change Woods runtime extraction/MCP behavior.
- Full-suite and style receipts match the stated 9,401 examples, zero failures, three pre-existing optional-tokenizer pending examples, and the final 913-file RuboCop run with no offenses (including the additional probe).
- Protocol and README distinguish source/fact/convention signals, private oracle labels, curated evidence, held-out families, post-capture applicability correction, missing evidence, and controlled-fixture limits. No reviewed text overclaims that fresh portable databases are identical historical datasets.

## Final report review

The delivery-comparison placeholder is gone. All four clarifications above are resolved in the current README/report. The report preserves the initial and posthoc reviewer experiments separately, identifies incomplete client display despite complete recorded output, keeps tokens-to-first-finding unavailable, and does not infer causal/general superiority from the small comparison.

The delivery comparison's six reports and inspection ledgers support the shown counts: ordinary 8/8 findings with 8/8 distinct inspections, baseline 8/8 with 8/8 inspections, and bank 5/7 planted findings with 5/8 inspections. The second bank run has eight findings in total, including the separately verified conditional mechanism on control f9a470ec. There are 45 distinct candidate opens across those sessions plus one reread. The overlapping-wallet lost-update mechanism appears only in that bank report among these twelve reviewer final reports.

A separately authorized follow-up task added `probe_stale_transfer.rb` and executed it in a new disposable copy. This source addition was outside the read-only document review. Its finalized receipt confirms shared-recipient total 200→190 and shared-sender total 100→110 under stale input snapshots, while fresh loads for the same sequential schedule preserve expected balances and totals. The final report accurately limits this to an admissible read/commit ordering, states that it is not a threaded test or proof of an unspecified caller's behavior, and preserves the original atomicity control label. Frozen source/database fingerprints remain unchanged. The new probe passes its focused RuboCop check.

## Final packaging and chapter 11 review

The two former publishing checks are resolved:

- `docs/design/typesafe-agent-guide/evidence/full-bank/` now contains the source bank, catalog, import audit, prospective protocol, detailed metrics, presentation audit, reviewer addendum, probe, dependency source, stdout, and normalized run receipt. Four paired N+1 request/response files are present under `examples/`. The results report and chapter 11 link these assets. No broken local links were found in the results report, exported report, chapter 11, full-bank evidence README, or examples README.
- `rubocop-completion.log` records 913 files and no offenses, covering the new probe. The final report records the author-reported 45 offline Python checks and 28 retained portable example checks. This packaging review did not rerun those suites or claim a Python-version matrix.

All 20 source/export entries in `export-manifest.json` match their SHA-256 digests. The only full-bank files not individually in that manifest are the manifest itself and its explanatory README. The exported report also matches both original and normalized hashes in `source-manifest.json`. Both sample requests contain all 204 questions and match the original provider-request bytes; response hashes match their original captures. The archived probe and its service/model/schema dependency bytes match the actual execution receipt. `.rb.txt` keeps archived source outside Ruby discovery without changing its contents.

The exported run receipt differs from its original only by the documented replacement of the local checkout prefix in command arguments and the explanatory export note. Runtime, source/database/probe hashes, oracle identity, and results are unchanged. No personal absolute home/attachment paths were found in the full-bank export or paired examples. The archive accurately states that complete 144-response and reviewer transcript collections remain local and that relative provenance paths are not portable lookup paths.

Chapter 11 preserves the separation among facts, conventions, defects, Scores, Choices, applicability, and evidence completeness. Its source/physical-file/generation guidance matches the helpers. It keeps target-mapping errors distinct from model misses, initial and posthoc reviewer runs separate, and the additional transfer mechanism conditional. It neither promotes the fixture experiment to an installed-app feature nor confuses a host application's runtime extraction with Woods' static self-map.

I viewed the supplied screenshot. It displays “Same 27 questions. Same order”, TypeSafe cost `$0.000081`, and completion in `0.114s`; the right comparator is still waiting. Chapter 11 correctly treats that as an example with incomplete inputs/correctness/comparator evidence, not a latency or quality benchmark. Its suggestions for vector-based decisions, relevance filtering, routing, and explicit weighting are labeled proposed adaptations rather than measured improvements. The first-party fan-out, intent-routing, and composite-scoring pages were opened and support the cited design patterns; they do not validate this experiment's maximum-over-204 priority.

The guide-wide `SHA256SUMS` regeneration is the author's planned final assembly step after validation. The artifact-level source/export hashes were checked against the present bytes here; this review does not claim a checksum list generated after its own completion was already verified.

The added community-implementation section attributes its observations to the inspected Jev Review, Blink, and Jev Ultrafast sources, warns that upstream `main` can change, and distinguishes reported showcase numbers from independently measured results. This pass checked those claims' framing against the bank-catalog agent's source review; it did not independently repeat that agent's complete external-code inspection. The proposed bounded investigation loop is explicitly unexecuted, keeps dependent calls sequential, requires evidence verification before ledger updates, and reserves evaluation for untouched cases rather than reusing these exposed pairs as a new holdout. No additional scope or attribution blocker was found.

No source document was edited during this final read-only packaging review. No additional blocker was found.
