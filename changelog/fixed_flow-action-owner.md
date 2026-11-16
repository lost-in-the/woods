- Request flows now follow the action body Ruby dispatches, which `action_sources` records.
  A prepended override was skipped for the controller's own definition of the same action.
  A prepended override that calls `super` now includes the controller's own body at the `super` call.
  Of two definitions of one action in a controller, the later one is read, as Ruby runs it.
  An action whose recorded body no indexed unit holds shows only its filters, not a shadowed local body.
  Precomputed flows (`precompute_flows`) and `trace_flow` change alike.
