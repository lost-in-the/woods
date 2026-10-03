- Extract sidekiq-scheduler schedules set in Ruby config sources (`Sidekiq.schedule = { ... }` and
  `Sidekiq.set_schedule(name, { ... })` with literal hashes) as `scheduled_job` units with format
  `:sidekiq_scheduler_ruby` and a `:scheduled` edge to the job. Each unit records its `schedule_type`
  (`cron`, `every`, `interval`, `at`, or `in`) and that value; `every`/`interval` durations are
  humanized. A name without a `class` key is used as the class, as sidekiq-scheduler does.
