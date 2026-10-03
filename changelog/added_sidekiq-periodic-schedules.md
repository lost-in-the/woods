- Extract Sidekiq Enterprise periodic registrations (`mgr.register(cron, job_class, options)` inside a
  `periodic` block) from `config/initializers/**/*.rb`, `config/environments/*.rb`, and
  `config/application.rb` as `scheduled_job` units with a `:job` edge to the registered class (#668).
  Options are kept in metadata and a class that is not loaded is reported as a warning. Those sources
  are now recorded as scheduled-job inputs; editing one still requires a full extraction, as before.
