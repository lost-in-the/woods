- Extract Sidekiq-Cron jobs registered in Ruby config sources (`config/initializers/**/*.rb`,
  `config/environments/*.rb`, `config/application.rb`) as `scheduled_job` units with format
  `:sidekiq_cron_ruby` and a `:scheduled` edge to the job: `Sidekiq::Cron::Job.create(...)`,
  `Sidekiq::Cron::Job.new(...).save`, and `load_from_hash` / `load_from_array` (and their bang forms) with
  a literal Hash or Array. A Ruby config source is parsed once for all of its schedule registrations.
