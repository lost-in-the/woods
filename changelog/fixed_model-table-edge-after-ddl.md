- An incremental run that re-runs the table units also re-extracts a loaded
  model whose table was created, dropped or re-qualified by that change, so
  its `table` edge, columns and schema header match a full extraction without
  re-running every model.
