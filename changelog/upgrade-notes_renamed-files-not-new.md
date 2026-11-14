- Units whose file was renamed inside the history window from older content change `change_frequency` from `new`
  to the count-based value.
  So do units whose file is added inside the window only on a branch off `HEAD`'s first-parent chain (for example a
  recreation discarded by an `ours` merge).
  An incremental run refreshes `metadata.git` only for units it touches; run a full `woods:extract` after
  upgrading to reclassify every unit at once.
