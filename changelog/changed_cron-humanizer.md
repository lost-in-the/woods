- `scheduled_job` units describe many more cron shapes in `metadata[:frequency_human_readable]`, for every
  schedule format (Sidekiq-Cron YAML, Whenever quoted cron lines, Sidekiq periodic registrations, and the
  new Sidekiq-Cron and sidekiq-scheduler sources): every N minutes, hourly at :MM, every N hours at :MM,
  daily at HH:MM, weekly on <day> at HH:MM, weekdays and weekends, monthly on day D at HH:MM, yearly on
  <month> D, day and time lists and ranges, `@daily`-style nicknames, a leading seconds field, and a
  trailing time zone, e.g. `0 7 * * *` is now `daily at 07:00` instead of the raw cron line. Every
  description that names a day includes its time and uses plain day numbers, so the former fixed wording
  changes too: `0 0 * * 0` is `weekly on Sunday at 00:00`, `0 0 1 * *` is `monthly on day 1 at 00:00`,
  and `0 0 1 1 *` is `yearly on January 1 at 00:00`; `every minute`, `every hour`, and
  `daily at midnight` are unchanged. Any shape the describer does not cover is still echoed raw.
  Consumers that matched the raw cron text in this field should read `metadata[:cron_expression]`.
