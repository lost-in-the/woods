- Request flows now follow the action body Ruby dispatches, which `action_sources` records.
  A prepended override was skipped for the controller's own definition of the same action.
  A body that calls `super` continues, at each call, into the definition Ruby reaches from it.
  The continuation keeps statement order and sits inside the branch or transaction that holds the call.
  The controller extractor records that definition, one hop, as `super_source` in the action's `action_sources` entry.
  It can be another prepended module, the controller's own body, or a base controller's.
  Without that record, the flow stops at the call and shows it as an unresolved `dynamic_dispatch` of `super`.
  Of two definitions of one action in one owner, the later one is read, as Ruby runs it, even on one line.
  Of definitions in exclusive branches of one line, the one Ruby compiled is read.
  `action_sources` records the column at which its `def` starts, as `column`.
  An action whose recorded body no indexed unit holds shows only its filters, not a shadowed local body.
  Precomputed flows (`precompute_flows`) and `trace_flow` change alike.
