- Sidekiq periodic registrations made through a numbered (`_1.register`) or `it` block parameter are now
  extracted. A registration whose cron is computed rather than a string literal keeps its unit with
  `cron_expression: nil` and the argument's source in `metadata[:cron_source]`, and logs a warning.
