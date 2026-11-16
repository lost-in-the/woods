- Request flows continue a `super` call only through the `super_source` an extraction records.
  An index extracted before this release has none, so its flows stop at each `super` call.
  They show it as an unresolved `dynamic_dispatch` of `super`, not as a guessed body.
  Run a full `woods:extract` to record `super_source` for every controller.
