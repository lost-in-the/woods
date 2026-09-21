# Quick TypeSafe documentation audit for Woods 2.0 preparation

The sampled documentation is generally usable, with a few concrete corrections
and several opportunities to shorten dense explanations. The audit found one
new watcher-documentation error, tracked as
[#504](https://github.com/lost-in-the/woods/issues/504). Two other stale guidance
items were already covered by [#498](https://github.com/lost-in-the/woods/issues/498).
No canonical document, release fence, version or plugin was changed by this audit.

TypeSafe was used directly: **34 actual Jev requests**, seven typed questions
per section, **238 valid answers**, at an estimated **$0.00955647**. Its readability
and relevance judgments supplied useful editorial locations. Its accuracy layer
was mostly unassessed because the source packets did not cover every claim in
each section: **30 missing-evidence, three support signals and one contradiction
signal**. Neither support nor confidence was treated as proof. The concrete
corrections below were independently verified by the coding agent; they are not
claims of autonomous Jev bug discovery.

The reusable [runner and rubric](../../../script/typesafe/docs_audit/README.md),
[frozen protocol](../../../script/typesafe/docs_audit/protocol.md),
[sampling plan](../../../script/typesafe/docs_audit/audit-plan.json),
[portable per-section receipt](../../../script/typesafe/docs_audit/results/2026-09-21.json),
and [quick-audit runbook](../../development/DOCS_QUICK_AUDIT.md) preserve the method.
This is development tooling outside the packaged gem, not a release gate.

## What was actually checked

The source revision was pinned to
[`c6f875ace375ee0263cc50762b054c9fc47296a1`](https://github.com/lost-in-the/woods/tree/c6f875ace375ee0263cc50762b054c9fc47296a1)
in a detached clean checkout. A disposable Woods self-map was built and its MCP
`woods_status` queried before source investigation. The map was static orientation,
not evidence of host-application runtime behavior.

Seventeen entry, canonical and agent pages contributed two complete heading-content
sections each. **34 of 412 parsed sections** were sampled: **51,756 of 451,728
UTF-8 bytes, or 11.46%**, across those selected pages. This is not 11.46% of the
entire documentation tree. Parent introductions and their child sections are
separate; fenced code stays intact. All omitted headings, exact lines, file hashes
and selected source/spec spans are retained in the receipt.

| Page | Sampled subjects |
| --- | --- |
| `README.md` | Install/configure; two servers and trust boundaries |
| `docs/README.md` | Task navigation; canonical ownership |
| `docs/GETTING_STARTED.md` | Generate/review configuration; connect Index MCP |
| `docs/AGENT_SETUP.md` | Generate/inspect; verify useful behavior |
| `docs/CONFIGURATION_REFERENCE.md` | Core options; Console options |
| `docs/MCP_SERVERS.md` | Index tools; Console inventory/default tools |
| `docs/AGENT_GUIDE.md` | Session status; Index Server boundaries |
| `docs/CONSOLE_MCP_SETUP.md` | Tool support by mode; rollback scope |
| `docs/UPGRADING_TO_2.md` | Changes; verification before rollout |
| `docs/TROUBLESHOOTING.md` | `MissingArtifact`; no client tools |
| `docs/DOCKER_SETUP.md` | Architecture; actual container-launch subsection |
| `docs/SOURCE_FRESHNESS.md` | Result interpretation; partial-extraction scope |
| `docs/INDEX_LAYOUT.md` | Atomicity versus retention; structural snapshots |
| `docs/RETRIEVAL_GUIDE.md` | Lexical retrieval; degradation tiers |
| `docs/WATCH_DAEMON.md` | Running it; failure posture |
| `CONTRIBUTING.md` | Setup; proportional validation |
| `CLAUDE.md` | Architecture synopsis; self-map/Docker orientation |

The manually selected implementation/spec context came from 41 distinct files,
including those pages. Source selection was fixed before responses. An unused
preflight preparation was superseded before inference after a heading-only
sample was replaced and watcher/freshness evidence improved; no responses were
used to choose the final sample. The final batch had no retries or follow-up calls.

## Independently verified corrections

1. **Watcher retries do not require another file event.**
   [`docs/WATCH_DAEMON.md:127–132`](https://github.com/lost-in-the/woods/blob/c6f875ace375ee0263cc50762b054c9fc47296a1/docs/WATCH_DAEMON.md#L127)
   says a degraded cycle waits for the next event. The heartbeat calls
   `retry_pending` at `lib/woods/watch/daemon.rb:724–746`, which starts a separate
   retry drain at lines 770–788. The existing `spec/watch/daemon_spec.rb:282`
   example starts carried work through the heartbeat without a new file event;
   it passed. Say that pending work retries on the next event **or heartbeat**,
   with the separate worker allowing heartbeat/lock refresh to continue.
   Tracked in [#504](https://github.com/lost-in-the/woods/issues/504).
   This was an agent source spot-check: D030 returned missing evidence, Noul 0.12
   and no accuracy target. Its packet did not include the heartbeat call site.
2. **A released correction still says “unreleased.”**
   [`docs/MCP_SERVERS.md:183`](https://github.com/lost-in-the/woods/blob/c6f875ace375ee0263cc50762b054c9fc47296a1/docs/MCP_SERVERS.md#L183)
   calls the session-identity fixes unreleased after beta2. The same paragraph
   and corrected implementation are already in `v2.0.0.beta3` at `84fc59c1`;
   `SessionFlowAssembler` has no diff between that tag and the pinned checkout.
   The distributed diagnostic skill also states beta3 availability. Replace the
   stale sentence with the actual availability. This belongs to existing
   [#498](https://github.com/lost-in-the/woods/issues/498).
   Jev selected D011/B04 for readability and relevance; the coding agent then
   checked the release claim. Jev's accuracy answer was missing evidence, and
   its packet did not contain the tag history.
3. **The coding-agent Docker synopsis conflicts with the canonical default.**
   [`CLAUDE.md:73`](https://github.com/lost-in-the/woods/blob/c6f875ace375ee0263cc50762b054c9fc47296a1/CLAUDE.md#L73)
   presents host-side Index MCP as the general setup. `docs/DOCKER_SETUP.md:7`
   and lines 132–188 default to the application container; host launch is
   optional when Ruby, the bundle and index are host-visible. Update the short
   synopsis to that same distinction. Also covered by existing
   [#498](https://github.com/lost-in-the/woods/issues/498).
   This is a guidance inconsistency, not a runtime defect or a Jev accuracy hit.

No duplicate issues were filed for #498. These are documentation findings;
the audit identified no new runtime defect or release-blocking execution failure.
It does not establish that none exists outside the sample.

## What the accuracy signals did and did not establish

Both concrete model investigation triggers were checked:

| Signal | Verification and disposition |
| --- | --- |
| D012, Console inventory: `contradicted`, contradiction Noul 0.62, accuracy target `none` | Rejected as an unlocalized contradiction. The actual registration matrix and specs confirm 31 schemas, nine default tools and eleven with read-tool opt-in. The dispatch code supplies validation, bounds, table checks, redaction and scanning. Missing packet evidence was not a contradiction. |
| D004, canonical owners: `missing_evidence`, but accuracy selector chose the 35-extractor paragraph | Not confirmed. The generated inventory records 35 extractor registrations and matches this claim. That inventory was not in the model packet. |

The three support signals remain model signals about selected evidence. The 30
missing-evidence answers remain unassessed; no automatic pass or correctness
percentage is calculated. The independent accuracy-status and block-selector
questions sometimes disagreed, so their raw answers remain separate.

This plan provided weak accuracy coverage: asking about **all material claims in
a section** makes one unsupported detail sufficient for an unknown result, and
some decisive callers/tag records were omitted. A next version should build
bounded **individual claim/evidence pairs** from the section, preserve their
relationships, and request missing source before judging them. Keep section-level
readability/relevance separate. That is an evidence-selection and question-granularity
lesson, not evidence that Jev is incapable of accuracy checks. No changed rubric
was rerun on these exposed sections to improve the reported result.

## Editorial suggestions worth retaining

Readability median was **2.755/3** (range 2.14–2.95); relevance median was **2.81/3**
(range 1.25–2.98). The rubric's upper levels mean usable/clear or directly relevant,
not correctness. These are one-run subjective judgments, not calibrated quality
grades or before/after measurements. Jev selected a readability block in all 34
sections, so a selected block alone is not evidence that rewriting is necessary.

- **MCP tool inventory, lines 163–184 (D011, readability 2.20).** Keep the concise
  tool table near the start; move the long session-identity contract into a named
  subsection and link to it. Its detail remains useful, but obscures inventory
  lookup. Fix the independently verified stale release sentence as above.
- **Contributor validation, lines 99–100 (D032, 2.17).** Split commands required
  for a contributor from the dense coverage-policy explanation, retaining a link
  and the distinction between default and opt-in lanes.
- **Source freshness, lines 83–94 (D024, 2.18).** Introduce “consumer scope” with
  one short definition, then keep the service/events example and separately list
  cases that remain unknown. Preserve the operational qualifications.
- **Agent architecture synopsis, `CLAUDE.md:3` (D033, 2.24).** Break the long layer
  inventory into a compact list. Label Console's 31 schemas versus 9/11 callable
  tools explicitly, as the canonical MCP guide already does.
- **Lexical setup, lines 180–191 (D027, 2.32).** Separate the standalone MCP
  environment command from the Ruby-builder path and consolidate the repeated
  explanation that a Rails initializer does not configure a separate MCP process.

One low relevance signal was rejected: the README's trust-boundary section scored
1.25, but its disclosure of live data and provider/source exposure directly helps
an installer choose safely. Retain it; splitting its long paragraph is an optional
readability change. Necessary limitations should not be removed merely to raise
a relevance score. None of these editorial suggestions was applied automatically.

## Operational evidence and limits

| Measure | Observed |
| --- | ---: |
| Requests / valid HTTP-200 responses | 34 / 34 |
| Questions requested / valid | 238 / 238 |
| Input / free output tokens | 227,535 / 10,877 |
| Estimated input cost at $0.042/M | $0.00955647 |
| Median request latency | 0.444 seconds |
| Sum of concurrent request times, not wall time | 17.535 seconds |
| Credential lookups / retries / unknown-usage attempts | 1 / 0 / 0 |
| Rounding warnings | 0 |

The price basis is the current [TypeSafe model documentation](https://docs.typesafe.ai/models),
not an invoice. The coding agent's source selection, investigation and writing
time is outside this provider cost. The 34,737-byte largest serialized request
fit the local conservative byte budgets; bytes are not provider tokens.

Seven offline runner checks passed, including fenced headings, CRLF/UTF-8
preservation, missing/oversized sections, changed source/request/response refusal,
path restrictions and missing-evidence accounting. The targeted watcher test and
50 Console-contract/Index-registration examples passed at the pinned revision.
The Console registration probe returned the documented nine default and eleven
opt-in names. The coordinator subsequently ran the full default gem suite on the
research branch: 9,401 examples, zero failures and three optional-tokenizer pending
checks; RuboCop inspected 915 files with no offenses. Those checks validate the
combined tooling checkpoint, not all claims on the separately pinned main revision.
No additional Rails matrix or live application boot was needed for the docs runner;
it changes no packaged runtime behavior.

The same coding agent selected source, wrote the adapter/tests and adjudicated
results. The coordinator performed the single credential-backed capture and
deduplicated/filed the documentation issue. This is not an independent benchmark.
Raw local requests, responses and frozen snapshots remain under
`tmp/typesafe-docs-audit-2026-09-21/run/`; the portable receipt contains selected
actual judgments, coverage, hashes and adjudication, not an exact full-run replay.
No key, employer handoff, application data, generated self-map or personal path is
included in the reusable files. Nothing here authorizes a release transition.
