- Controller `metadata.actions` no longer lists public methods a gem DSL defines (for example `expose` readers),
  and they get no flows. Run one full `woods:extract` to drop them from every controller.
