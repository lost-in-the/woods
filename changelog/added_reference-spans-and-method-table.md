- Publish static and ambiguous constant reference spans, and declaration spans
  for associations, callbacks and scopes, in `metadata.references` (#751).
  - An unresolved occurrence whose literal spelling names indexed units gets
    `confidence: "static"` with its one target, or `confidence: "ambiguous"`
    with every typed candidate.
  - Association, callback-method and scope macros get spans where runtime
    metadata confirms them.
  - None of these adds a dependency edge.
- Publish `metadata.methods` on class-based units (#752): name, kind, line
  range, visibility and owner in published-source coordinates, including methods
  of concerns inlined as display blocks.
- The internal reference cache advances to format 7. Run one full extraction
  before resuming incremental extraction or targeted refresh.
