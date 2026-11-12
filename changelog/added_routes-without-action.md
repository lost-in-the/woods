- `lookup` flags a controller's routes that no action answers.
  `metadata.routes` lists every route drawn to the controller while `metadata.actions` lists only the actions it has,
  and nothing marked the difference: `resources :things` on a controller with three actions read as seven live routes.
  A controller unit now carries `metadata.routes_without_action`, the sorted action names, after `routes`,
  and the text formats mark each one in `routes` as `destroy (no action)`.
  It is the `missing_action` verdict of `graph_analysis`' `unresolvable_routes` for the same generation,
  so an inherited or gem-defined action, an implicit template and `action_missing` are never flagged.
  The key is absent when every route has an action, and is added at read time, not stored in the unit JSON.
