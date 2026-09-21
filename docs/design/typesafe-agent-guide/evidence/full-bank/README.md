# Full-bank evidence export

Read [chapter 11](../../11-full-bank-review-lessons.md) and the
[results report](../2026-09-21-typesafe-full-bank-results.md) before treating these
artifacts as an integration template. They are synthetic Rails development
evidence, not an employer application's code or a production benchmark.

| Artifact | What it establishes |
| --- | --- |
| [Source bank](source-question-bank.md), [catalog](catalog.json), [import audit](bank-corrections.md) | Exact 204-question source and explicit interpreter choices |
| [Prospective protocol](protocol.md) | Frozen original trial design; later presentation and delivery changes remain separately disclosed |
| [Metrics](metrics.md), [JSON](metrics.json) | All requested answers, costs, target-mapping caveats, candidate alarms and individual signals |
| [Presentation audit](presentation-audit.json) | Versioned post-capture Tests/Views applicability correction; original responses were unchanged |
| [N+1 sample pair](../../examples/README.md) | Exact first-repeat requests/responses with selected source and all questions |
| [Reviewer addendum](reviewer-posthoc-addendum.md), [JSON](reviewer-posthoc-addendum.json) | Separate delivery-corrected reviewer counts, aggregate usage, first-emission times and posthoc verification |
| [Transfer result](stale-transfer-result.md), [output](stale-transfer-stdout.json), [run receipt](stale-transfer-run.json) | Executed stale-object schedules and preserved original fixture/database identity |
| [Transfer probe](probe_stale_transfer.rb.txt) | Exact executed Ruby probe; `.txt` keeps archived source outside code lint/discovery |
| [Validation pass 1](validation-pass1.md), [pass 2](validation-pass2.md) | Scoped reviews, resolved findings and ownership disclosures |
| [Export manifest](export-manifest.json) | Source and export digests, including documented path normalization |

The probe's exact source dependencies are the
[service](stale-transfer-source/app/services/review_credit_transfer.rb.txt),
[model](stale-transfer-source/app/models/review_wallet.rb.txt), and
[schema](stale-transfer-source/db/schema.rb.txt). Their hashes match the execution
output. Remove the terminal `.txt` only when deliberately reconstructing source
in a disposable fixture. This is not a complete Rails application; the source
checkout's fixture builders provide the surrounding application and dependencies.
The probe writes wallet rows, so run it only in its disposable test application.

The original 144 response files and twelve reviewer transcripts remain local.
This export preserves selected actual bytes and detailed receipts, not an exact
replay of every run. Local relative `tmp/` references inside receipts identify
original provenance locations and will not resolve in this archive. One Docker
command has its absolute checkout prefix replaced with `<woods-checkout>`; hashes
for both original and exported receipts are retained. No raw API credential is
included.

The metrics predate the incidental transfer confirmation. Their original control
label and unverified-alarm accounting remain unchanged. The separate reviewer
addendum confirms only the stale-input mechanism, not every alarm on that control,
and does not retroactively improve planted-target counts.
