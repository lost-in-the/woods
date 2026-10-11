- Three incremental triggers now cover the runtime facts their families
  publish, so an incremental run matches a full one. Adding or removing a
  job file under `app/jobs`, `app/workers` or `app/sidekiq` re-runs
  `scheduled_jobs`, whose `job_class_resolved` follows whether the named
  class is loaded. A model file under a pack or engine
  (`packs/billing/app/models/invoice.rb`) re-runs `database_tables` and its
  consumers, as a model under `app/models` does, so table ownership follows
  it. A root-level `node_modules/` directory is excluded from
  `config.graphql_document_paths` like a nested one; `**/*.graphql` no longer
  indexes installed packages' operation documents.
