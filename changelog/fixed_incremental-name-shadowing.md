- An incremental run now re-extracts an unchanged unit whose reference resolves to a constant the run added,
  removed or redefined.
  Adding `Billing::ReconcileJob` used to leave an unchanged `Billing::Invoice` enqueueing the top-level
  `ReconcileJob` until the next full extraction, because the graph before the run held no edge to the new job.
  Jobs, services, mailers and model short names follow the same rule.
  An edit inside a method body touches no constant and costs nothing extra.
