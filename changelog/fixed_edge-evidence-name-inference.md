- Edge evidence no longer calls two kinds of edge `verified` when only the target's existence was checked. A
  model's `polymorphic_interface` edge (the association name camelized, kept when a constant of that name exists)
  and an `external_consumer`'s `reads_table` and `writes_table` edges (an operator's declaration, kept when the
  table is in the live schema) are now `static`. docs/MCP_SERVERS.md also states the known false positives of
  route-helper and `view_render` edges, which stay `verified`.
