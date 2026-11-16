- Request flows continue a `super` call only through the `super_source` an extraction records.
  An index extracted before this release has none, so its flows stop at each `super` call.
  They show it as an unresolved `dynamic_dispatch` of `super`, not as a guessed body.
  Run a full `woods:extract` to record `super_source` for every controller.
- An index extracted before this release also has no `column` in `action_sources`.
  Its flows read no body for an action defined twice in exclusive branches of one line, rather than guess a branch.
  The same full `woods:extract` records it.
