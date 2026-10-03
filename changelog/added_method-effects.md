- Attribute side effects to public methods. Model, service, job, PORO,
  manager, mailer and controller units gain `metadata.method_effects`: per
  public method, the jobs enqueued, mail sent, services called, columns
  written, events published and HTTP clients called, with the effects of
  same-class methods it calls under `via_method` (three calls deep). Their
  existing `job_enqueue`, mailer and service edges gain `through`, naming the
  public methods that reach the target; no edge is added or removed, and
  `dependents` answers are unchanged. `config.method_effects_limit` (default
  50) caps the map per unit and sets `method_effects_truncated`. Callback
  metadata is unchanged. Run a full extraction to populate existing indexes.
