- Extract Sidekiq schedules from `config/schedule.yml` (format `:sidekiq_schedule`; Sidekiq-Cron's default
  schedule file and a common separate sidekiq-scheduler file) and from the `:scheduler: :schedule:` section
  of `config/sidekiq.yml` (format `:sidekiq_scheduler`) as `scheduled_job` units with a `:scheduled` edge.
  Both record the sidekiq-scheduler schedule type (`cron`, `every`, `interval`, `at`, `in`). Editing
  `config/schedule.yml` re-extracts scheduled jobs incrementally; `config/sidekiq.yml` stays a restart
  trigger, so its edits still need a full extraction.
