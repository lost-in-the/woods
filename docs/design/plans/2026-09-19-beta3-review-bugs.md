# Reproduced bugs from the beta3 release-sized review

For the adjacent Woods development session: these are concrete bug reports, not
an architecture handoff. Filed on GitHub at the user's request after the trial:

- [#490: clear raises for non-legacy session IDs](https://github.com/lost-in-the/woods/issues/490).
- [#491: append revives expired session history](https://github.com/lost-in-the/woods/issues/491).
- [#492: malformed snapshot units break listing and capture](https://github.com/lost-in-the/woods/issues/492).

Both affected files were still byte-identical to beta3 on main
`6aa043d59ce70168cb36dc9937bcc828bcf4f912` when the issues were filed.

## Follow-up verification — 2026-09-21

All three issues are closed. [PR #493](https://github.com/lost-in-the/woods/pull/493)
fixes session clearing and expiration, including mixed legacy/encoded histories.
[PR #494](https://github.com/lost-in-the/woods/pull/494) validates persisted
snapshot shapes while retaining legacy-compatible optional fields.

Verified main `904226c91b36a6656e3d6ab7ff2de3f74a9cdc23` with the original
six-case reproduction plus the FileStore, JsonSnapshotStore and new snapshot-shape
suites: **165 examples, zero failures**. All checks reported by GitHub for both
merged PRs passed. Local command:

```bash
bin/rspec -Ilib script/typesafe/probes/release_review_regressions_spec.rb \
  spec/session_tracer/file_store_spec.rb \
  spec/temporal/json_snapshot_store_spec.rb \
  spec/temporal/json_snapshot_shape_spec.rb
```

Machine-readable local results are in
`tmp/typesafe-main-followup-2026-09-21/spec-results.json`. No new inference was
run for this check; this verifies the fixes, not Jev's ability to distinguish
the fixed versions. The original findings below describe the pre-fix state.

Tested release: `v2.0.0.beta3`, commit
`84fc59c18047870a7b45e6da049064ff78427e93`. Both affected source files were
byte-identical on observed main `8fa5f358c5f8da5e31b3c1975f13a4c07697f266`.
Tests used Ruby 4.0.6 and disposable local directories, without Rails or a database.

Run the six-case reproduction from the Woods checkout being evaluated:

```bash
bundle exec rspec -Ilib \
  script/typesafe/probes/release_review_regressions_spec.rb
```

On beta3: **6 examples, 3 failures**. The three ordinary controls pass. This
standalone file is outside `spec/`, so it does not introduce intentional failures
into the default suite. Each reproduction should become a normal regression with
its eventual fix.

## 1. Clearing a non-legacy session ID deletes the record, then raises

File: `lib/woods/session_tracer/file_store.rb`, `clear` and `legacy_session_path`.

```ruby
store.record('user:é', { event: 'recorded' })
store.clear('user:é') # TypeError: no implicit conversion of nil into String
```

The store supports these IDs through its reversible Base64 filename encoding.
`legacy_session_path` returns nil for an ID outside the old ASCII character set.
`clear` removes the encoded file, then unconditionally passes that nil legacy path
to `FileUtils.rm_f`. The caller sees a failure even though deletion happened.
The same path applies to many ordinary punctuated IDs, not only Unicode.

The stable v1.6.2 implementation clears the example without raising. This is a
regression in the new filename/legacy-migration path. Guard the optional legacy
path; preserve deletion of both paths for valid legacy IDs and test repeated clear.

## 2. Appending to an expired file session revives its old history

File: `lib/woods/session_tracer/file_store.rb`, `record`.

Create a store with `ttl: 60`, record an event, age the JSONL file by 120 seconds,
then record another event **without an intervening read/list operation**. Reading
the session returns both the expired and new events. The paired control confirms
that reading the aged session before appending expires it as expected.

`record` loads old lines before checking expiration, replaces the file, and only
then calls `prune_sessions!`. Replacement refreshes mtime, so the prior history
escapes expiration. Apply TTL before reusing existing history under the same
store lock. Test ordinary recent appends, expired appends, legacy migration and
clock behavior. This is a defect in the new TTL behavior; v1.6.2's FileStore did
not offer a TTL option, so do not call it a regression in an existing v1 TTL API.

## 3. A malformed nested snapshot entry breaks listing and future capture

File: `lib/woods/temporal/json_snapshot_store.rb`, `read_snapshot`,
`symbolize_snapshot` and `symbolize_units`.

After one valid snapshot, place this valid JSON but invalid snapshot object in
`snapshots/bbb222.json`:

```json
{
  "git_sha": "bbb222",
  "extracted_at": "2026-01-02T00:00:00Z",
  "units": { "User": null }
}
```

Both `list` and capture of a subsequent valid snapshot raise
`NoMethodError: undefined method '[]' for nil`. `read_snapshot` checks only the
outer Hash. The unchecked nested value reaches `symbolize_units`, including from
`find_latest` during capture. The class's corrupt-snapshot degradation behavior
does not cover this shape. Ordinary valid captures continue to pass.

The same malformed-entry failure reproduces on v1.6.2: this is a pre-existing
robustness gap found while investigating a changed file, not a newly introduced
beta3 regression. Validate the persisted snapshot shape and treat unusable files
consistently with corrupt snapshots; avoid hiding unrelated programming errors
behind a blanket rescue. Invalid user-supplied Git SHA arguments should retain
their explicit errors. No data deletion or remote exploit was demonstrated.

## Evidence and attribution

Artifacts under `tmp/typesafe-release-trial-2026-09-19/`:

- `new-regressions.json` / `.log`: six-case RSpec reproduction.
- `investigation-probe-results.json`: exception details and revived history.
- `stable-comparison-probes.json`: v1.6.2 clear behavior, missing TTL API and
  pre-existing snapshot failure.
- `current-main-check.json`: source identity against observed main.
- `selected-specs.json` and `context-specs.json`: **306 existing examples pass**.

Jev ranked the FileStore and JsonSnapshotStore files for investigation. It did
not identify these exact triggers or produce explanations. The coordinator's
source review and executable probes established the mechanisms. No fixes are
included; independently reproduce and check adjacent work before implementing.
