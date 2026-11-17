- Model callback `side_effects` and `analysis_status` can change for existing model units; no key or identifier changes.
  Run a full `woods:extract` after upgrading: an incremental run corrects only the models it re-extracts.
  State machine `transition_callbacks` `side_effects` and `unanalysed` can change the same way.
