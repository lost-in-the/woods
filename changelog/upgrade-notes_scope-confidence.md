- Model `scopes` entries gain one key, `confidence`; no existing key changes.
  Run a full `woods:extract` after upgrading: an incremental run corrects only the models it re-extracts.
  Until then, a scope span on a model written before the upgrade reads `static`.
