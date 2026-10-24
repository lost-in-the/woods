- Report persistent generation retention pins to readers: `Woods::PublishedIndex.retention_pins(index_dir)`
  returns the pinned generation numbers, and `woods_status` adds `index.retention_pins`. Unreadable pin
  state raises from the Ruby API and reports `retention_pins: null` with `retention_pins_error` in status,
  never an empty list.
