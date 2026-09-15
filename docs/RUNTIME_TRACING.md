# Ruby runtime trace enrichment

`Woods::RubyAnalyzer::TraceEnricher` records Ruby method events during a block
and can attach that evidence to Ruby method units. This is a Ruby API; Rails
session tracing and the MCP `trace_flow` tool are separate features.

```ruby
require 'woods/ruby_analyzer'

traces = Woods::RubyAnalyzer::TraceEnricher.record { application.run }
units = Woods::RubyAnalyzer.analyze(paths: ['lib'], trace_data: traces)
# Or enrich units already analyzed:
Woods::RubyAnalyzer::TraceEnricher.merge(units: units, trace_data: traces)
```

## Caller evidence

Each event contains `class_name`, `method_name`, `event` (`call` or `return`),
`method_kind`, `path`, `line`, `caller_class`, `caller_method`,
`caller_method_kind`, and `return_class`.
For an observed `Caller#invoke` calling `Callee#run`, the callee's call and
return events record `caller_class: 'Caller'` and `caller_method: 'invoke'`.
The caller method field contains the method name, not a qualified backtrace label.

The caller is the **nearest Ruby method observed by this recording**. The
recorder does not capture native method frames or block frames, and does not
infer methods already on the stack when recording begins. An unknown caller
has all three caller fields set to `nil`; merge omits those unknown caller entries.
This is scoped execution evidence, not a complete application call graph.

Stacks belong to one recording and are separate for each fiber. Recording
captures the current thread, including fibers running on it, and excludes
other threads. To record work in another thread, invoke `record` in that thread.
Recursion and Ruby return events during exception or nonlocal unwinds balance
the stack. An unmatched return, such as a fiber method entered before recording,
has no inferred caller. Escaping exceptions still propagate and disable the
recorder; a later recording starts with fresh stacks.

`merge` adds `metadata[:trace]` with `call_count`, `callers`, and `return_types`.
A return event during exception unwinding does not establish normal completion;
`return_types` summarizes the return-event values Ruby exposes. Recording does
not change existing method identifiers.

## Method identity

`method_kind` is `instance` or `singleton`. Merge matches the defining owner,
method name, and kind: `Example#run` and `Example.run` keep separate call counts
and return types. This identity survives JSON serialization; symbol keys and
symbol kind values are accepted too. Caller entries retain `caller_method_kind`
when present, so same-name instance and singleton callers remain distinct.

Singleton methods use their defining named class or module. If `Child.run`
inherits `Parent.run`, its events belong to `Parent.run`. Methods supplied by
an extended module retain that module's instance-method identity. Anonymous
owners and singleton methods on individual objects have no named unit;
their `class_name` is `nil`, and merge skips them.

## Older recordings

Older Woods recordings derived `caller_class` from the callee receiver and
`caller_method` from an interpreter-dependent backtrace offset. Their caller
fields can disagree or describe the callee itself. Record again to obtain
corrected caller evidence; merging old JSON cannot reconstruct missing callers.

Recordings without `method_kind` match **instance methods only**. The older
recorder used a normal owner name for instance methods and an opaque string
such as `#<Class:Example>` for singleton methods. Those opaque singleton-owner
records are skipped; record again to obtain a usable singleton identity.
Handwritten fixtures for `Example.run` must specify `method_kind: 'singleton'`.
Merge never guesses the kind from which units happen to be supplied. Unknown
explicit kinds are skipped. Old caller entries without a kind remain untyped.
