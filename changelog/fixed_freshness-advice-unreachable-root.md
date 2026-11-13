- `woods_status` source freshness no longer recommends `fresh_capture` when the recorded source root is not a
  directory where the server runs (an index extracted in a container and read on the host).
  The state stays `unknown` and the reason stays `source_root_unavailable`.
  The recommendation is the new `map_source_root`, and `root_advice` gives the remedy as text:
  launch the server where the root exists, or set `WOODS_SOURCE_ROOT` to the path of the same checkout on this
  machine.
  The SessionStart hook prints the same advice.
