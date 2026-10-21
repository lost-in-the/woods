- View templates (ERB, HAML, jbuilder), Phlex components, view components,
  mailers and controllers now carry `helper_call` edges to the application
  helper modules whose methods they call, and `helper_method` edges to the
  controller or mailer that declares a called name with `helper_method`. A
  helper module mixed into every view by Rails had no incoming edge before.
  `metadata.helper_calls` lists the called names per module;
  `metadata.ambiguous_helper_calls` records a name more than one module
  defines when the runtime cannot say which one Rails resolves;
  `metadata.helper_methods` on a controller or mailer lists the names it
  declares. The catalog is read from `app/helpers` with Prism and
  cross-checked against the runtime (`helper` mixins, dynamic definitions,
  `helper_method`). Only catalog names match: Rails built-ins and partial
  locals never produce an edge. Incremental extraction re-runs the five
  consumers when a helper source changes.
- The view engine protocol gains an optional `scan_method_calls` operation,
  implemented for ERB, HAML and jbuilder.
