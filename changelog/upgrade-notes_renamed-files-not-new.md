- Units whose file was renamed inside the history window from older content change `change_frequency` from `new`
  to the count-based value.
  An incremental run refreshes `metadata.git` only for units it touches; run a full `woods:extract` after
  upgrading to reclassify every unit at once.
