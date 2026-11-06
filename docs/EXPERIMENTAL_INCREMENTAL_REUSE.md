# Incremental reuse client pilot

This feature-branch prototype is disabled by default. It combines exact graph
and analysis reuse with bounded reuse of template parsing facts. It is intended
for a development pilot, not a release or a general performance guarantee.

## Install the branch

Pin the feature branch in the application's Gemfile, then install through the
application's normal bundle/container workflow:

```ruby
gem "woods", github: "lost-in-the/woods",
  branch: "experiment/incremental-reuse-pilot-20261106"
```

```sh
bundle install
bundle exec ruby -r woods -e 'puts Gem.loaded_specs.fetch("woods").full_gem_path'
```

Record the resolved Git revision from `Gemfile.lock`. A Git checkout can report
the same Woods version as other commits. The gem version is unchanged.

Add an initializer that loads the pilot only when requested:

```ruby
# config/initializers/woods_incremental_reuse_pilot.rb
if ENV.fetch("WOODS_EXPERIMENTAL_INCREMENTAL_REUSE", "0") != "0"
  require "woods/experimental/incremental_reuse"
end
```

The pilot requires sequential extraction:

```ruby
Woods.configure do |config|
  config.concurrent_extraction = false
end
```

Restart the Rails/indexing process with
`WOODS_EXPERIMENTAL_INCREMENTAL_REUSE=combined`. Other values are `graph`,
`templates`, and `0` (off); `1` also means combined. No new rake command or MCP
tool is registered. Use the normal Woods extraction and watcher commands.

## What is enabled

The template cache compares the source returned by Woods' UTF-8 reader and
rechecks recorded file, owner, and navigation resolution queries. Helper and
frontend resolution, the complete caller-prefix fixed point, registration,
source consumption, flows, pruning and atomic publication still run normally.
Deleting, renaming or adding templates invalidates the inventory. Cached facts
are owned copies, not shared mutable units or cached ASTs. Stored template blobs
are capped at 10,000 entries and 64 MiB; whole-process memory is not capped there.

Graph reuse requires complete canonical graph equality, not just equal edges.
Analysis also requires the previous exact digest, analyzer options, inspected
implementation/constants, application-source predicates and current unresolved
controller resolution to match. The existing graph bytes/ranking are retained
only when equivalent. Changed inputs use the original writer and analyzer.

Each process retains one indexed session. The first operation is cold. A
successful normal analysis seeds graph reuse for later operations in that same
process; importing an existing index does not invent a runtime witness for it.
A full extraction always computes its graph normally and can warm the caches.
The watcher creates fresh extractors but can reuse the process-local session.
Fresh CLI processes do not inherit caches and may show little or no benefit.

Caches bind to the published generation token and output/application roots.
Another writer's publication, mode/root changes, failures or a fork discard
state. Pending graph state becomes reusable only after this writer's successful
publication is still current. A no-op preserves the marker. Index data and
source freshness flags are not rewritten to make reuse appear current.

Concurrent extraction falls back to the original implementation. Enabled pilot
operations are serialized within their process; ordinary cross-process writer
fencing remains intact. Nested pilot extraction is rejected. Do not fork during
an active extraction. Arbitrary monkeypatches, concurrent runtime mutation and
the broader Ruby/Rails matrix are not qualified by this pilot.

## Compare in a private development fixture

Use a separate development index and disposable database/source checkout. Start
with a full extraction, then compare realistic template edits, shared-partial
edits, dependency changes, deletion/rename and Ruby reload cases against a
separately booted full extraction. Keep source, flows, references, graph/impact,
freshness and output permissions in the comparison. Do not use client payloads
in public benchmark reports or issues.

Measure the complete operation, including initial cache construction and Rails
reload, and report repeated matched controls with the flag off. Warm cache
updates and first-use/CLI runs are different workloads. The original synthetic
Omarchy investigation found a conditional shared-partial benefit; ordinary text
edits did not establish a reliable standalone template-cache speedup. It did not
establish a subsecond publishing update or native watcher latency guarantee.

Inspect counters in the same indexing process, after an operation:

```ruby
Woods::Experimental::IncrementalReuse.stats
# mode, generation, graph counters, template counts/entries/serialized bytes
```

This returns copied counters without source payloads and writes nothing to
stdout. `Woods::Experimental::IncrementalReuse.reset!` drops process-local
caches between operations and does not delete the index.

## Local qualification

The pilot was checked on Ruby 4.0.7 / Rails 8.1.4 on Omarchy, using a disposable
synthetic application with approximately 1,087 units. Focused local verification
passed 511 examples, including 49 pilot-specific examples; repository-wide lint,
the generated surface inventory and gem build/load checks were also run.

Booted comparisons cover a full extraction, shared-partial and dependency edits,
rename, deletion, helper reload, no-op and failed-write recovery. They compare
units/flows with the repository differential oracle, plus graph, references,
impact and output permissions against independently booted full extractions.
These are correctness checks, not new latency measurements of this packaged branch.

The same sequence with reuse disabled retained the same freshness states and
reasons. Direct resident API calls lack a verified boot boundary; after the
low-level helper reload this fixture also reports unverified runtime consumption
and drift. The pilot preserves those limitations. A matching unit/graph oracle
does not turn that state into a fresh-source guarantee. Native watcher latency
and the complete supported Ruby/Rails matrix remain unqualified.

The normal `script/ci-local --hosted-pr` preflight was attempted but blocked by
missing Bundler 4.0.23 for the installed Ruby 3.3.13. The focused checks above ran
under Ruby 4.0.7. Hosted CI status is separate; no merge gate is waived by these
local results.

## Disable or roll back

Unset the flag (or set it to `0`) and restart the indexing process. The original
extraction path is then used. To leave this branch, restore the previous Gemfile
pin and bundle through the application's normal workflow. The published index
format has not changed. Take a fresh full extraction when changing Woods builds
or extraction configuration, as the existing baseline contract requires.

An earlier Ruby 4.0.7/YJIT native crash during graph hub sorting remains
unresolved; it did not recur in the investigation's subsequent required full
runs. This pilot is not a fix for that crash or an Omarchy diagnosis.
