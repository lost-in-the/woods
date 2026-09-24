# Source freshness

`woods_status.index.source_freshness` compares the served generation's captured
application inputs with source bytes visible to the reader. It is separate from
index age, HEAD equality, daemon liveness and external database/runtime state.

This capability is included in Woods `2.0.0`. Check the installed gem's
`woods-extract --help`, `rake -T woods:source_status`, and `woods_status` schema
before using it; upgrading the plugin alone does not upgrade Woods.

## Read the result

| State | Meaning | Next step |
|---|---|---|
| `current` | All covered inputs match their consumer baselines, with a verified fresh boot boundary and complete checks. A dirty checkout can be current. | Use the indexed facts within the coverage below. |
| `drifted` | At least one captured input differs, was removed, or a relevant input was added. | Inspect the changed paths; choose a full run or a justified targeted refresh. |
| `unknown` | Evidence is incomplete: for example an old index, missing source/key, scan limit, opaque symlink directory, or unproved boot/consumer boundary. | Inspect `reasons`; use a deep check or fresh full capture as appropriate. |

Drift can coexist with incomplete coverage. `reasons` reports both; absence of a
listed change never proves an omitted input is unchanged. `complete` describes
capture/traversal completion, while boot and consumer qualifications remain in
`reasons`. `counts` contains total observed added/changed/removed paths; each
`changes` list contains at most 30 paths and `truncated` marks longer lists.

**Unreleased after 2.0.0:** `comparison_complete` also identifies whether the
previous consumer baseline can establish additions. A missing or incompatible
baseline stays unknown; it does not make every visible file an addition. Files
not reached by an incomplete scan are not reported as deleted. Matching paths
with different captured identities still prove drift. An unreadable entry leaves
coverage incomplete while scanning continues through accessible siblings.

```json
{"source_check":"deep"}
```

Pass this to `woods_status` for an explicit five-second content scan. The default
`quick` scan has a 250ms budget. Both read and HMAC source bytes; there is no
stat-only `current` shortcut, so same-size/same-mtime edits are detected. Limits
also cap traversal at 50,000 visited files and 128 MiB read. Budgets are checked
between filesystem operations; an operating-system read that itself stalls can
outlast the scan deadline. A limit produces unknown coverage, never current.

The result is tied to the **served** generation, including a reader holding an
older generation during a concurrent publication. It is recomputed on each call;
a source edit does not require an index generation change to become visible.

**Unreleased after 2.0.0:** `recommendations` separates recovery actions:

- `deep_check`: the quick reader reached its time limit; request one deep check.
- `inspect_source_scan`: inspect `verification_reasons`, permissions, source
  mapping and scan limits; a deeper scan cannot repair unavailable inputs.
- `fresh_capture`: the captured baseline, boot or consumer evidence is incomplete;
  fix the reported cause and run the launcher in a fresh process.

Several recommendations can apply together. `verification_reasons` describes the
current reader scan; `reasons` also retains capture failures. A quick reader limit
alone does not require rebuilding the index.

## Establish a fresh baseline

Run the launcher through the application's installed bundle:

```bash
bundle exec woods-extract full
bundle exec woods-extract incremental app/services/checkout.rb app/views/orders/show.html.erb
bundle exec woods-extract refresh routes controllers
```

`--root PATH` selects the application root. `--output PATH` selects the index
(default `WOODS_OUTPUT`, otherwise `tmp/woods`); relative output paths resolve
under the application root. Repeat `--source-root PATH` to include additional
application-relative directories used by custom loaders. Use the same declaration
on subsequent launcher runs. Paths are separate arguments, preserving spaces,
commas and newlines. Refresh accepts known extractor names. Invalid arguments
fail before extraction; the launcher propagates the child's failure or daemon
stand-down exit 75. Split oversized incremental batches or choose full.

For an application with a custom `config.output_dir`, **always pass the matching
`--output PATH` or `WOODS_OUTPUT`**. The launcher cannot evaluate Rails configuration
before capturing its boot inputs. In Woods 2.0.0, its implicit `tmp/woods` default
overrides custom configuration and can create a second index.

**Unreleased after 2.0.0 ([#591](https://github.com/lost-in-the/woods/issues/591)):**
an implicit default no longer injects `WOODS_OUTPUT` into Rails boot. The task
compares finalized configuration with that preboot default and refuses a mismatch
before extraction, naming the configured path and explicit output remedy. An
initializer using `ENV.fetch('WOODS_OUTPUT', custom_path)` therefore retains its
configured default for this check. Explicit CLI/environment output still overrides
configuration and binds capture, key and publication to the same directory.
The refused launch may already have created a private key under `tmp/woods`, but
publishes no generation there and preserves the configured index's generation.

The launcher captures source before a **fresh child** evaluates its Gemfile,
Rakefile, Rails boot and eager loading. A private one-use handoff binds the capture
to root, output, action, rules, nonce and parent process. It waits for the child
and removes the handoff when the child exits. Source is checked again before
publication. In Woods 2.0.0, edits during boot/extraction retain the earlier
identity and are reported in the new generation, rather than being silently
adopted as a current baseline.

**Unreleased after 2.0.0; planned for 2.1:** the
[constant-reference writer](EXTRACTOR_REFERENCE.md#constant-source-references)
requires verified source for its graph evidence. Source changes after capture,
during boot or extraction, refuse publication while reference enrichment
participates. The final verification also checks covered non-Ruby inputs. The
preceding generation remains active instead of publishing a new drifted
generation. Retry against stable source in a fresh process. The existing
generation can still report drift through `woods_status`.

Existing Rake tasks, direct `Extractor` calls and the watch daemon remain usable.
Their post-boot capture is marked `unverified_boot_boundary`; current bytes alone
cannot prove what a previously booted Rails process consumed. A fresh launcher
full run replaces that uncertainty. Hooks continue their existing refresh flow;
enabling hooks does not implicitly restart or replace a daemon.

## Scope and partial extraction

Coverage follows the shared file/whole-app dispatch rules and reload policy:
application and lib Ruby, known views/locales/tests/packages/schedules/schema and
boot configuration. Source-only boot coverage also includes `Rakefile`,
`config.ru`, root gemspecs and otherwise-unclassified Ruby helpers under `config/`.
Normal generated/hidden directories are pruned before traversal, using the watch
scanner's exclusions. Explicit source roots override generic exclusions; the
index output is always excluded. Contained file symlinks are checked for stable
resolution; directory symlinks and escaping/unreadable inputs leave uncertainty.

**Unreleased after 2.0.0; planned for 2.1:** source paths use UTF-8 bytes even
when the process locale is `C`. A filename with invalid UTF-8 bytes produces
`undecodable_source_path` and incomplete coverage; directory entries with those
names are pruned. Diagnostic labels escape the original bytes and are bounded.
The watcher skips these entries, and reference verification retains the preceding
generation. Rename the affected entries to valid UTF-8 names before a fresh
capture. Explicit root/output paths with invalid UTF-8 bytes are rejected as
configuration errors.

Every consuming scope keeps its own identities. An events scan can reread a
service file while its service unit remains untouched; refreshing events does
not certify the retained service unit. Successful file/whole-extractor work
updates only its scopes, including negative results and confirmed deletion.
Unchanged scopes keep their earlier baseline. Boot inputs advance only on a full
run. Partial runtime changes retain an explicit `runtime_consumption` uncertainty
when Woods cannot prove every retained reflected fact was re-serialized. Named
framework refreshes do not certify unrelated application inputs. A handled
extractor error retains an explicit `extractor:<name>` uncertainty even if the
extractor returns an empty result. Successful consumers keep their own evidence;
a later full run without that failure can replace the uncertainty.
In the unreleased reference writer planned for 2.1, successfully returned models
also retain their individual source evidence when another model fails. An
optional framework model with a missing table therefore does not prevent
unrelated incremental work; the model-extractor uncertainty remains visible.
If an older writer already published a baseline without that individual evidence,
run one full extraction after upgrading to rebuild it.

With the **unreleased reference writer planned for 2.1**, an edited Ruby service
retained by an events-only refresh instead prevents publication: its current
source cannot certify its older runtime facts or cached reference resolution.
See [reference baseline recovery](INCREMENTAL_EXTRACTION.md#source-reference-baseline-and-upgrades).
Omitted non-reference inputs retain their earlier consumer identity. The watcher
keeps failed work for retry; it does not expand an incomplete batch or rebuild a
missing reference baseline automatically.

Custom loader source outside captured roots, missing eager-load coverage and
uncaptured application-owned unit paths remain unknown. This is application
source evidence: it does not certify external database schemas/data, remote
configuration, installed gem bytes, provider state or live runtime services.
**Unreleased after 2.0.0:** RubyGems installation metadata can establish that
loaded/unit source inside the application directory belongs to an installed gem,
including gems installed under `vendor/bundle`. Such files do not create false
application-coverage errors. A vendor-shaped directory alone is insufficient;
local path gems and custom loaders still need captured source roots. Explicit
`--source-root` declarations retain coverage even for installed gem directories.

## Containers and hooks

Run the launcher inside the application container when that is where the bundle
and source exist, for example `docker compose exec -T app bundle exec woods-extract full`.
An MCP reader must see the source and original private key; otherwise it reports
unknown. `woods:source_status` has no Rails environment prerequisite and uses the
same verifier without Rails initialization or provider work. Its optional
Base64-encoded JSON transport supports `output`, `root` (an explicit reader-side
source mapping), and `mode` (`quick` or `deep`).

**Unreleased after 2.0.0:** results expose `recorded_root` (writer location),
`checked_root` (the directory actually scanned), and `root_source` (`recorded`,
`explicit`, or `working_directory`). `current` applies only to that checked root.
The MCP IndexReader keeps using the recorded root; it does not infer a checkout
from the index's location. For a copied index, a current result about the original
root says nothing about edits in the copy. Run `woods:source_status` in the copy,
or provide an explicit `root` mapping. The task defaults to its process working
directory, including inside containers; launch it from the application root, not
an unrelated directory or a monorepo parent. Missing source remains unknown.

The opt-in SessionStart hook uses `WOODS_HOOK_RAKE` and `WOODS_OUTPUT`, including a
Docker command prefix without requiring a host application bundle. It prints
an actionable drift or unknown warning and stays quiet for current evidence.
Its ten-second process deadline includes command startup; the scan uses quick
mode. Missing older tasks and failed/timed-out commands report unknown. Cancelling
Docker exec does not itself prove the process inside the container stopped.
A quiet session hook does not acknowledge deferred PostToolUse queue entries.
**Unreleased after 2.0.0:** unknown warnings use the returned recommendations,
including every applicable recovery action. A quick reader timeout advises a deep
check without requiring a rebuild. Older tasks without recommendations retain
the conservative generic unknown warning.

## Artifact and cost

Each atomic payload contains versioned `source_inputs.json`. It records a compact
identity table shared by per-consumer scope/path maps, root, rules fingerprint,
generation, coverage and scan metrics. All file identities use HMAC-SHA256 with
`<output>/.source-inputs.key`, a 32-byte, owner-only private file outside payloads.
Low-entropy secret-bearing input files receive the same protection as ordinary
source; no source bytes or raw secret hashes are added to this artifact. Do not
publish the key with an index. Missing, insecure or mismatched keys produce
unknown; Woods does not silently repair permissions or rotate keys. Independent
outputs have different identities and must be compared using their own keys and
consumer semantics, not raw manifest equality.

### Identity-key recovery

Verified launching refuses an unavailable, insecure or malformed
`<output>/.source-inputs.key`; it cannot establish verified capture without that
key. In the unreleased diagnostics after 2.0.0, the error names the path and safe
file requirements while reader reason codes remain unchanged. No key bytes are
printed and Woods does not chmod, chown, replace or rotate the file automatically.

Inspect the file and mount from the application environment. It must be a regular
file, not a symlink/FIFO, contain exactly 32 bytes, belong to the process's UID,
and grant no group/other permissions (normally mode `0600`). A host/container UID
mismatch requires correcting the selected runtime user or deliberately repairing
ownership of the known original key. Confirm the file belongs to this index before
changing permissions. Do not expose the key in logs or copy it into payloads.

If the original key is lost, replaced or cannot be trusted, retain the previous
index and establish a fresh full baseline in a new empty output directory with
the intended application user. Configure the writer and readers together.
Do not replace a key and assume the old generation now has valid source evidence.

Failed/no-op extraction does not advance the artifact's published generation.
Flat fallback and older indexes lack verified atomic source evidence.
`WOODS_PROFILE=1` reports `source capture` and `source verification` separately.
Capture/recheck each allow up to ten seconds with the same file/byte caps.

**Unreleased after 2.0.0:** both the published manifest and the private launcher
handoff have a 16 MiB serialized-size limit, matching their readers. Oversized
evidence refuses publication or child startup with a bounded diagnostic; the
preceding payload remains active. Narrow unnecessarily broad additional source
roots or reduce scoped inputs before retrying. There is no silent truncation of
consumer identities. Version-1 manifests remain readable; the optional
`comparison_complete` field supplements existing coverage errors, and legacy
missing-baseline errors remain conservative.

September 2026 fixture measurements: a pinned Writebook source tree (456 visited
files, 223 hashed, 233KB) completed quick scans in median 36ms native / 45ms on a
Linux container bind mount. Discourse (26,133 visited, 6,209 hashed, 56.4MB) needed
about 1.6–2 seconds; quick scans returned unknown, while five-second scans completed
traversal and still reported an opaque directory symlink. Native Ruby 4.0 and
container Ruby 3.4 differed, so these are a budget envelope, not a filesystem
speed comparison or a macOS virtiofs benchmark. Measure your own application;
a large or slow source tree may need a deep check. Rebuilding a verified baseline
does not remove the reader's time, file or byte limits.
