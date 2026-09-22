# Source and oracle adjudication of the investigation pilot

Adaptive selection retrieved more of the declared supporting evidence, but added no verified defect lead. Both arms produced threshold leads only for the same rounding defect. The adaptive arm found the calendar configuration and correctly reduced concern for the UTC control, yet still missed the non-UTC defect after reading its configuration.

**Authorship disclosure:** I authored the fixtures, collector and executable oracles. This is unblinded source/oracle verification of recorded results, not an independent or blinded review. I read all 32 focused request/response pairs, matched all 48 physical changed/support files to frozen source hashes, and reused the eight recorded private oracles. Their capture copies differ from the original execution receipts only by an appended trailing newline. No further inference or application execution was performed, and no frozen input was changed.

Every focused response, source selection, per-answer validity result and adjudication is retained in [the companion JSON](2026-09-21-adjudication.json). Capture references inside it are relative paths into the retained capture root; they are provenance locators, not a claim that the full capture is published here.

## Keep retrieval, judgment and confirmation separate

| Measure | Static | Adaptive |
| --- | ---: | ---: |
| Completed focused responses | 16 | 16 |
| Valid focused responses | 15 | 16 |
| All declared necessary cards selected | 8/16 | 12/16 |
| Raw defect leads under the frozen rule | 2/8 | 1/8 |
| Raw control leads | 0/8 | 0/8 |
| Source/oracle-verified threshold leads | 2 | 1 |
| Distinct cases behind those leads | 1 | 1 |
| Valid specific control categories unsupported by the tested mechanism | 3 | 1 |

The frozen rule requires contract probability at least 0.8, valid focused answers, a concrete mechanism category and a supplied source location. All three qualifying responses concern rounding case `97bf2156f1`. Repeats are correlated responses about the same case, not separate discovered defects. The adaptive rounding answer at 0.78 names the correct category and helper but misses the threshold; it is not a retrieval failure. Eight static/adaptive focused request pairs—rounding and JSON—are byte-identical. The 0.80 versus 0.78 rounding difference therefore cannot be attributed to different source retrieval.

The necessary-card checklist is diagnostic. In particular, reservation intent explicitly allows a caller-owned transaction. The changed transaction and inspected pool model can support that conditional concern without the actual batch caller card, although reading the caller would establish the concrete application path. Incomplete checklist coverage must not automatically become an unassessed verdict.

## All candidates and both repeats

Probabilities below are the raw contract-violation Nouls for repeats 0 and 1. They are not calibrated accuracy or confirmed findings. A dagger marks an invalid composed response whose Noul itself was valid.

| Fixture | ID | Static r0 / r1 | Adaptive r0 / r1 | Source/oracle assessment |
| --- | --- | --- | --- | --- |
| invoice_rounding control | `7a9d5822d0` | 0.27 / 0.32 | 0.29 / 0.32 | Exact helper amounts, rounded once at the total; both choose none/none. |
| invoice_rounding defect | `97bf2156f1` | 0.80 / 0.80 | 0.78 / 0.80 | Premature per-line rounding; both arms locate the helper. |
| json_key_shape defect | `2fa1ca8b84` | 0.32 / 0.41 | 0.32 / 0.35 | Caller retains string keys; both read it, name input_contract, but select evidence=none. |
| json_key_shape control | `92daced6e0` | 0.25 / 0.27 | 0.24 / 0.23 | Caller symbolizes keys; both choose none/none. |
| local_calendar_day control | `49429b5c36` | 0.63 / 0.65 | 0.20 / 0.22 | UTC behavior satisfies the contract; adaptive correctly clears the concern. |
| local_calendar_day defect | `cd13248951` | 0.63 / 0.62 | 0.30 / 0.34 | Non-UTC mismatch; adaptive reads configuration then incorrectly chooses none/none. |
| nested_reservation defect | `4ed13b9760` | 0.62 / 0.59 | 0.61 / 0.61 | Joined transaction persists rejected decrement; neither reads the batch caller. |
| nested_reservation control | `8f9892b56f` | 0.63† / 0.64 | 0.63 / 0.57 | Savepoint preserves persisted state; some answers still accuse transaction_boundary. |

## What the inspected source establishes

**Rounding:** Both arms select `investigation_line_amounts.rb` and the same ordinary spec in every repeat. The defect helper rounds each BigDecimal line before the changed total sums them. The oracle records 1.02 instead of 1.01 for three 0.335 amounts and the corresponding negative-credit error. The control preserves exact extended amounts. All four defect category/location pairs are compatible with this verified mechanism, even though one adaptive Noul falls below 0.8. No adaptive retrieval advantage occurs here.

**JSON key shape:** Both arms inspect `investigation_digest_request.rb` and the same ordinary spec. The defect caller uses `JSON.parse(json)` and string-key slices, while the changed consumer fetches symbols. The recorded request persists defaults instead of the explicit heading and 30-day window. All four focused answers name the correct broad `input_contract` category but choose `evidence=none` and return only 0.32–0.41 contract probability. This is a judgment/localization miss after adequate retrieval. The control caller uses `symbolize_names: true`; the four none/none answers fit its tested behavior.

**Reservation:** Static reads the pool and reservation models; adaptive reads the successful-reservation spec and pool model. Neither selects `investigation_reservation_batch.rb`. The defective default nested transaction allows the outer transaction to commit availability -2 after a rejected five-seat request against three seats. The control uses `requires_new: true`; its SQL receipt contains SAVEPOINT and ROLLBACK TO SAVEPOINT, with availability restored to 3 and the outer attempt retained. Static defect repeat 0 names the correct conditional boundary and changed source, but remains below the lead band. Other defect answers choose none while still citing the changed file. The control’s specific transaction accusations are not established by the tested persisted-state contract. Sequential calls are explicitly in scope; this review did not invent a concurrency defect.

**Calendar:** Static selects the event model and export caller, leaving the distinguishing configuration unread in both variants. Its `time_semantics` answer is a plausible risk category, not an established case-specific failure from that packet. Adaptive selects `investigation_calendar.rb` first in all four calendar jobs. That supplies the UTC or New York premise directly. It correctly produces none/none for UTC, but also produces none/none for New York despite the visible `Date.today`/application-zone mismatch. The oracle records the next-day event instead of the intended local-day event in winter and summer. Better retrieval therefore did not produce a positive defect judgment here.

## Falsely specific and inconsistent answers

- Four valid control responses choose a concrete mechanism unsupported by the tested contract: calendar static repeats 0 and 1 (`time_semantics`), reservation static repeat 1 and adaptive repeat 0 (`transaction_boundary`). Their probabilities remain below the lead band, so these are not threshold control leads.
- Reservation control static repeat 0 is invalid: it selects `transaction_boundary` with probability 0.36 while `none` has 0.37. It remains unassessed. Its independently valid 0.63 contract Noul and changed-file evidence Choice are retained without repairing the mechanism selection.
- Four valid reservation responses combine `mechanism=none` with `evidence=changed0`: defect static repeat 1, defect adaptive repeats 0 and 1, and control adaptive repeat 1. These components do not form a coherent supported accusation.
- All four JSON-defect responses select a concrete `input_contract` category while denying any supporting source location. The caller and changed consumer are both present, so the none evidence choice misses available support.
- Static calendar-control repeat 1 cites the changed file despite not reading the UTC premise. Static calendar-defect repeats 0 and 1 cite the same line, but still lack the distinguishing configuration. A source ID indicates a location; it does not supply the missing premise or prove the concern.

## Limits of the comparison

Adaptive inspection helps establish the calendar premise and lowers unsupported concern for the UTC control. It does not improve JSON or rounding retrieval, does not inspect the concrete reservation caller, and adds no threshold-confirmed defect. This is a narrow observation from four curated pairs, two repeats and a two-card budget; it does not show a general review advantage or downstream token savings.

The model emits broad categories and source IDs rather than a narrative explanation. Compatibility with the source/oracle mechanism does not prove that it reasoned through the exact sequence. Conversely, all four planted mechanisms were already executable-oracle verified; that fact must not be reported as four model discoveries. Controls cover the declared contracts and inputs, not global application correctness.

The source and oracle helpers remain [fixtures.py](../fixtures.py), [collect.rb](../collect.rb), and [oracle.rb](../oracle.rb). The companion JSON retains exact hashes for every focused request/response and each source/oracle receipt used in this review.
