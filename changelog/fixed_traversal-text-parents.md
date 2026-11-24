- `dependencies` and `dependents` text output no longer prints a row under a sibling it has no edge to (#1041).
  This applies to the Markdown, plain and Claude formats.
  Each row now sits under a listed row one depth shallower whose `deps` name it.
  A row whose parent is not listed (filtered out, or on another page) is printed at the top level with its depth.
  JSON output, row order in the payload, depths and counts are unchanged.
