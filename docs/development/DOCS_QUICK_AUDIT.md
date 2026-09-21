# Quick documentation audit with TypeSafe

Use this method to find bounded documentation leads before a release or after a
public behavior change. It combines typed judgments with implementation evidence;
it does not certify the release or replace command/spec verification.

The reusable runner is [script/typesafe/docs_audit](../../script/typesafe/docs_audit/README.md).
The [September 21 audit](../design/plans/2026-09-21-typesafe-release-docs-audit.md)
records its first actual run. This is source-checkout development tooling, outside
the packaged gem, with no automatic canonical-doc edits or CI gate.

1. Pin the source revision in a disposable clean checkout. Read `AGENTS.md`,
   `CONTRIBUTING.md`, `CLAUDE.md` and canonical ownership in `docs/README.md`.
   Create the disposable Woods self-map before broad investigation. Its static
   relationships orient source ownership; they do not prove runtime Rails facts.
2. Choose 12–18 relevant entry/canonical/agent pages, then one or two coherent
   heading sections per page. State each page's actual audience and purpose.
   Include precise implementation, executable registration and spec spans for
   claims being checked. A neighboring document is useful context, but is not
   independent proof of runtime behavior. Keep missing evidence explicit.
3. Version and review the rubric, sampling plan and protocol before inference.
   Preparation lists every sampled/omitted section, exact line/byte coverage,
   whole-file hashes and selected-span hashes. ATX headings inside fenced code
   remain code. Parent introductions do not silently include children. Oversized
   sections stop preparation; choose another coherent section or an explicit
   smaller scope, never silently truncate.
4. Inspect the frozen requests, then explicitly capture with one credential load.
   Each sampled section receives independent readability/relevance Scores,
   evidence-relation Choice, concrete-contradiction Noul and bounded block
   selectors with `none`. Keep raw answers, failures, model identity, usage and
   latency. The live step sends the selected source to TypeSafe and incurs usage.
5. Read every concrete accuracy lead against current source and tests. Confirm
   exact file/line and a small reproduction where it matters. Report separately:
   confirmed false claims, missing evidence, rejected model leads and subjective
   editorial suggestions. Inspect obvious contradictions within the sampled scope
   even when Jev chooses `none`, and distinguish agent-found from model-led issues.
6. Retain the baseline text and captures. Apply only independently verified fixes
   through an ordinary reviewed change. Deduplicate known issues before filing.
   Release version/fence changes still belong to the repository release tasks.

Readability and relevance have different meanings. A dense reference may be
relevant but hard to scan; a readable aside may belong elsewhere. Neither Score
is a probability that the page is correct. The accuracy Choice distinguishes
support, contradiction, missing evidence and no checkable claim. A confident
answer with missing evidence is still unassessed. Parallel questions cannot
consume one another's answers, so a selected block is a lead rather than an
explanation from another answer.

Record the actual coverage denominator. Reviewing 34 sampled sections from 17
pages does not audit all sections, every link/example or the historical design
tree. One run has no repeatability estimate or independently labeled accuracy
rate. Keep provider cost separate from reviewer time; input estimates are not
invoices. Publish only deliberately selected public documentation/source evidence,
never raw credentials, private application contents or personal configuration.

Read current [TypeSafe API](https://docs.typesafe.ai/api),
[Score](https://docs.typesafe.ai/primitives/score),
[Choice](https://docs.typesafe.ai/primitives/choice), and
[evidence-relation cookbook](https://docs.typesafe.ai/cookbooks/citation_check)
before adapting the integration. The cookbook's demonstration auto-accept
threshold is not used here: source/spec adjudication is always required for an
accuracy finding.
